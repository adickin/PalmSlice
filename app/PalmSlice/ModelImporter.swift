import Foundation
import UniformTypeIdentifiers

/// Model file extensions PalmSlice can import. STL is read directly; the rest are
/// converted to per-object STLs by libslic3r (see `convertModelFile`).
let supportedModelExtensions: Set<String> = ["stl", "3mf", "obj", "amf"]

/// Content types offered by the file picker. `.data` stays in the list because
/// model files often arrive without a registered UTI and would otherwise be greyed out;
/// `importModel` rejects unsupported extensions with an alert.
var supportedModelContentTypes: [UTType] {
    supportedModelExtensions.sorted().compactMap {
        UTType(filenameExtension: $0, conformingTo: .data)
    } + [.data]
}

/// Formats that store no units, so a tiny model may really be in meters.
func modelFormatLacksUnits(_ ext: String) -> Bool {
    ext == "stl" || ext == "obj"
}

struct ConvertedModelObject {
    let url: URL
    var name: String
    /// Bounding-box centre relative to the centre of all objects in the file, print X/Y (mm).
    var offsetMM: SIMD2<Float>
    /// PrusaSlicer settings the file stores on this object, if any.
    var fileSettings: ModelFileSettings? = nil
    /// The file's project-wide PrusaSlicer settings (3MF/AMF), if any.
    var projectSettings: [String: String]? = nil
    /// The object as libslic3r keeps it (slicer_add_model_object); nil for STLs.
    var nativeURL: URL? = nil
    /// The object's tool (PalmSlice number, 0 = default).
    var extruder: Int = 0
    var parts: [ModelPart] = []
}

/// The objects in a model file, and the session's mixes with the file's added.
struct ModelFileImport {
    var objects: [ConvertedModelObject]
    var mixes: [ToolMix]
}

struct ModelImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Loads a 3MF / OBJ / AMF file through libslic3r and writes each object into
/// `outputDir` (native 3MF + display STL), with any PrusaSlicer settings the file
/// stores. The file's mixes are merged into `mixes` (identical mixes are reused).
func importModelFile(at url: URL, outputDir: URL, mixes: [ToolMix] = []) throws -> ModelFileImport {
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    guard let handle = slicer_create() else {
        throw ModelImportError(message: "slicer_create() returned nil")
    }
    defer { slicer_destroy(handle) }

    if slicer_set_virtual_extruders(handle, ToolMix.json(mixes)) != 0 {
        throw ModelImportError(message: String(cString: slicer_last_error(handle)))
    }
    let count = slicer_import_model_file(handle, url.path, outputDir.path)
    if count < 0 {
        throw ModelImportError(message: String(cString: slicer_last_error(handle)))
    }

    let project = SettingsText.parse(String(cString: slicer_imported_project_settings(handle)))
    var objects: [ConvertedModelObject] = []
    for i in 0..<Int(count) {
        var ox: Float = 0, oy: Float = 0
        if slicer_imported_object_offset(handle, Int32(i), &ox, &oy) != 0 {
            throw ModelImportError(message: String(cString: slicer_last_error(handle)))
        }
        let parts = (0..<slicer_imported_volume_count(handle, Int32(i))).map { k in
            let kind = ModelPart.Kind(rawValue: Int(slicer_imported_volume_type(handle, Int32(i), k))) ?? .part
            var painted = [Int32](repeating: 0, count: 256)
            let n = slicer_imported_volume_paint_tools(handle, Int32(i), k, &painted, 256)
            return ModelPart(
                name: String(cString: slicer_imported_volume_name(handle, Int32(i), k)),
                kind: kind,
                extruder: Int(slicer_imported_volume_extruder(handle, Int32(i), k)),
                facetCount: Int(slicer_imported_volume_facets(handle, Int32(i), k)),
                isPainted: slicer_imported_volume_painted(handle, Int32(i), k) != 0,
                paintedTools: painted.prefix(Int(n)).map(Int.init),
                meshURL: kind == .part ? nil : outputDir.appendingPathComponent("\(i).v\(k).stl"))
        }
        objects.append(ConvertedModelObject(
            url: outputDir.appendingPathComponent("\(i).stl"),
            name: String(cString: slicer_imported_object_name(handle, Int32(i))),
            offsetMM: SIMD2(ox, oy),
            fileSettings: ModelFileSettings(text: String(cString: slicer_imported_object_settings(handle, Int32(i)))),
            projectSettings: project.isEmpty ? nil : project,
            nativeURL: outputDir.appendingPathComponent("\(i).3mf"),
            extruder: Int(slicer_imported_object_extruder(handle, Int32(i))),
            parts: parts
        ))
    }
    return ModelFileImport(objects: objects, mixes: ToolMix.parse(String(cString: slicer_get_virtual_extruders(handle))))
}

/// The objects in a model file (see importModelFile), without mixes.
func convertModelFile(at url: URL, outputDir: URL) throws -> [ConvertedModelObject] {
    try importModelFile(at: url, outputDir: outputDir).objects
}
