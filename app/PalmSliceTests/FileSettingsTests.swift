import XCTest
@testable import PalmSlice

/// PrusaSlicer settings stored on objects in 3MF files (read as OrcaSlicer settings).
final class FileSettingsTests: XCTestCase {

    private func convert(_ url: URL) throws -> ConvertedModelObject {
        let dir = scratchDir()
        let objects = try convertModelFile(at: url, outputDir: dir)
        XCTAssertEqual(objects.count, 1)
        return try XCTUnwrap(objects.first)
    }

    /// ranges.3mf: a 20 mm cube with object settings, two height ranges, a
    /// layer height profile and project settings (scripts/fixtures/make_3mf_fixtures.py).
    func testReadsRangesLayerHeightsAndProjectSettings() throws {
        let object = try convert(Fixtures.url("ranges.3mf"))
        let fs = try XCTUnwrap(object.fileSettings)
        XCTAssertEqual(fs.ranges.count, 2)
        XCTAssertEqual(fs.ranges[0].minZ, 0)
        XCTAssertEqual(fs.ranges[0].maxZ, 2)
        XCTAssertEqual(fs.ranges[0].settings["bottom_shell_layers"], "4")
        XCTAssertEqual(fs.ranges[1].minZ, 15)
        XCTAssertEqual(fs.ranges[1].settings["top_shell_layers"], "3")
        XCTAssertEqual(object.projectSettings?["slicing_mode"], "even_odd")
        XCTAssertEqual(object.projectSettings?["print_settings_id"], "Fixture print")

        let heights = try XCTUnwrap(fs.layerHeightRange)
        XCTAssertEqual(heights.lowerBound, 0.08, accuracy: 0.001)

        XCTAssertEqual(fs.objectSettings["sparse_infill_density"], "100%")
        XCTAssertEqual(fs.objectSettings["wall_loops"], "5")
    }

    // The file's settings (solid infill, five walls, the ranges) use more
    // filament than the profile alone.
    func testFileSettingsChangeTheSlice() throws {
        let object = try convert(Fixtures.url("ranges.3mf"))
        let with = try slice(object, useFileSettings: true)
        let without = try slice(object, useFileSettings: false)
        XCTAssertGreaterThan(try filament(with), try filament(without) * 1.02)
    }

    // The variable layer height profile reaches the G-code: 0.08 mm layers
    // from 5 to 10 mm.
    func testVariableLayerHeightsReachTheGCode() throws {
        let object = try convert(Fixtures.url("ranges.3mf"))
        let heights = try slice(object, useFileSettings: true)
            .split(separator: "\n").filter { $0.hasPrefix(";HEIGHT:") }
            .compactMap { Double($0.dropFirst(8)) }
        XCTAssertLessThan(try XCTUnwrap(heights.min()), 0.1)
        let flat = try slice(object, useFileSettings: false)
            .split(separator: "\n").filter { $0.hasPrefix(";HEIGHT:") }
            .compactMap { Double($0.dropFirst(8)) }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(flat.filter { $0 > 0.05 }.min()), 0.2)
    }

    private func slice(_ object: ConvertedModelObject, useFileSettings: Bool) throws -> String {
        guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
        defer { slicer_destroy(h) }
        let printer = try XCTUnwrap(BuiltInProfiles.all.first { $0.verified })
        try SliceSetup.configure(h, printer: printer, material: BuiltInMaterialProfiles.esunPLALW,
                                 slice: BuiltInSliceProfiles.rcPlane)
        let idx = slicer_add_stl(h, object.url.path)
        XCTAssertGreaterThanOrEqual(idx, 0, String(cString: slicer_last_error(h)))
        var t = SlicerModelTransform()
        t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
        XCTAssertEqual(slicer_set_object_transform(h, idx, &t), 0, String(cString: slicer_last_error(h)))
        if useFileSettings, let fs = object.fileSettings {
            XCTAssertEqual(slicer_set_object_file_settings(h, idx, fs.text()), 0, String(cString: slicer_last_error(h)))
        }
        XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
        let out = scratchDir().appendingPathComponent("out.gcode")
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
        return try String(contentsOf: out, encoding: .utf8)
    }

    private func filament(_ gcode: String) throws -> Double {
        let line = try XCTUnwrap(gcode.split(separator: "\n").first { $0.hasPrefix("; filament used [mm] =") })
        return try XCTUnwrap(Double(line.split(separator: "=").last!.trimmingCharacters(in: .whitespaces)))
    }
}

/// End to end: a Cub part imported the PalmSlice way (profiles created from
/// the file + per-part file settings) slices like the 3MF project itself
/// read by OrcaSlicer. 3DLabPrint's Piper J-3 Cub files can't be shipped in
/// the repo: set PALMSLICE_TEST_DATA to the folder holding PS_3MF to run it
/// (`TEST_RUNNER_PALMSLICE_TEST_DATA=… xcodebuild test`).
final class ProjectParityTests: XCTestCase {
    func testCubPartsMatchPrusaSlicerProject() throws {
        guard let data = ProcessInfo.processInfo.environment["PALMSLICE_TEST_DATA"] else {
            throw XCTSkip("PALMSLICE_TEST_DATA not set: the Cub parity test needs third-party files")
        }
        let root = URL(fileURLWithPath: data).appendingPathComponent("PS_3MF")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "no PS_3MF in PALMSLICE_TEST_DATA")
        for part in ["wing/CUB aileron L1.3mf", "fuselage/CUB fuselage 1.3mf",
                     "accessories/CUB motor mount 16x19.3mf", "floats/CUB float L2.3mf"] {
            let file = root.appendingPathComponent(part)
            let tmp = scratchDir().appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            // Reference: the project as PrusaSlicer would slice it.
            let refURL = tmp.appendingPathComponent("ref.gcode")
            var err = [CChar](repeating: 0, count: 512)
            XCTAssertEqual(slicer_reference_slice_3mf(file.path, refURL.path, &err, 512), 0, String(cString: err))

            // PalmSlice: import, profiles from the file, part settings.
            let object = try XCTUnwrap(try convertModelFile(at: file, outputDir: tmp).first)
            let project = try XCTUnwrap(object.projectSettings)
            var printer = PrinterProfile(); printer.importSlicerSettings(project)
            var material = MaterialProfile(); material.importSlicerSettings(project)
            var slice = SliceProfile(); slice.importSlicerSettings(project)
            guard let h = slicer_create() else { return XCTFail("slicer_create") }
            defer { slicer_destroy(h) }
            // Without an OrcaSlicer vendor preset underneath: settings a
            // PrusaSlicer project can't hold (OrcaSlicer-only ones) would
            // otherwise take the preset's values instead of the defaults the
            // reference uses.
            try SliceSetup.apply(printer, label: "printer", to: h)
            try SliceSetup.apply(material, label: "material", to: h)
            try SliceSetup.apply(slice, label: "slice", to: h)
            // The app's path: the native object, then its file settings.
            let idx = slicer_add_model_object(h, try XCTUnwrap(object.nativeURL).path, 1)
            XCTAssertGreaterThanOrEqual(idx, 0, String(cString: slicer_last_error(h)))
            var t = SlicerModelTransform(); t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
            XCTAssertEqual(slicer_set_object_transform(h, idx, &t), 0)
            if let fs = object.fileSettings {
                XCTAssertEqual(slicer_set_object_file_settings(h, idx, fs.text()), 0, String(cString: slicer_last_error(h)))
            }
            XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
            let oursURL = tmp.appendingPathComponent("ours.gcode")
            XCTAssertEqual(slicer_export_gcode(h, oursURL.path), 0, String(cString: slicer_last_error(h)))

            let ref = try String(contentsOf: refURL, encoding: .utf8)
            let ours = try String(contentsOf: oursURL, encoding: .utf8)
            func heights(_ g: String) -> [String] { g.split(separator: "\n").filter { $0.hasPrefix(";HEIGHT:") }.map(String.init) }
            func filament(_ g: String) -> Double {
                Double(g.split(separator: "\n").first { $0.hasPrefix("; filament used [mm] =") }?
                    .split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? -1
            }
            XCTAssertEqual(heights(ours), heights(ref), "\(part): layer heights differ")
            XCTAssertEqual(filament(ours), filament(ref), accuracy: filament(ref) * 0.002,
                           "\(part): filament \(filament(ours)) vs project \(filament(ref)) mm")
            print("PARITY \(part): \(heights(ours).count) layers, filament \(filament(ours)) vs \(filament(ref)) mm")
        }
    }
}

final class FileProfilesTests: XCTestCase {
    private let project = [
        "print_settings_id": "0.3 mm 3DLabPrint", "filament_settings_id": "\"PolyLight LW-PLA\"",
        "layer_height": "0.3", "wall_loops": "1", "nozzle_temperature": "245", "skirt_loops": "1", "brim_width": "0",
    ]

    func testCandidatesSplitPrintAndFilament() {
        let (slice, material) = FileProfiles.candidates(project, fallback: "part")
        XCTAssertEqual(slice.name, "0.3 mm 3DLabPrint")
        XCTAssertEqual(slice.layerHeight, 0.3)
        XCTAssertEqual(slice.skirtLoops, 1)
        XCTAssertEqual(material.name, "PolyLight LW-PLA")
        XCTAssertEqual(material.otherLayersTemp, 245)
    }

    // Same name + same settings is reused; same name, different settings is not,
    // and gets the next free "(n)" name.
    func testMatchAndFreeName() {
        let (slice, _) = FileProfiles.candidates(project, fallback: "part")
        var other = slice
        other.wallCount = 3
        XCTAssertNotNil(FileProfiles.match(slice, in: [slice]))
        XCTAssertNil(FileProfiles.match(slice, in: [other]))
        var copy = slice
        copy.name = "0.3 mm 3DLabPrint (2)"
        XCTAssertNotNil(FileProfiles.match(slice, in: [other, copy]))
        XCTAssertEqual(FileProfiles.freeName(slice.name, in: [other]), "0.3 mm 3DLabPrint (2)")
        XCTAssertEqual(FileProfiles.freeName(slice.name, in: [other, copy]), "0.3 mm 3DLabPrint (3)")
        XCTAssertEqual(FileProfiles.freeName("new", in: [other]), "new")
    }
}
