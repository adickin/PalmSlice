import SceneKit
import Foundation

/// A volume of an imported object (PrusaSlicer ModelVolume), in the order of
/// the object's native 3MF.
struct ModelPart: Equatable {
    enum Kind: Int {
        case part = 0, negative, modifier, supportBlocker, supportEnforcer
    }
    var name: String
    var kind: Kind
    /// PalmSlice tool number (`ToolMix.base` + n for mixes); 0 = the object's tool.
    var extruder: Int = 0
    /// Triangles in the object's display STL (printable parts, in order).
    var facetCount: Int = 0
    var isPainted: Bool = false
    /// Tools painted on the part (PalmSlice numbers).
    var paintedTools: [Int] = []
    /// Mesh of a volume that isn't a printable part, in the display STL's frame.
    var meshURL: URL? = nil
}

/// Colour by height: from `fromZ` (mm above the bed) up to the next band, the
/// model prints with `tool` (PalmSlice number; 0 = its own tool).
struct ToolBand: Equatable, Identifiable {
    var id = UUID()
    var fromZ: Double
    var tool: Int
}

struct PlacedModel: Identifiable {
    let id: UUID
    /// Display / collision mesh (an imported object's printable parts merged).
    var url: URL
    var name: String
    var geometry: SCNGeometry?
    var transform: ModelTransform
    var meshInfo: STLMeshInfo?
    var bvh: TriangleBVH?
    var isIntersecting: Bool = false
    /// PrusaSlicer settings stored on this object in its 3MF/AMF file.
    var fileSettings: ModelFileSettings? = nil
    /// Whether to slice with fileSettings (the user can switch them off).
    var useFileSettings: Bool = true
    /// The source file's project-wide PrusaSlicer settings, for creating profiles.
    var projectSettings: [String: String]? = nil
    /// The object as libslic3r keeps it (volumes, their settings, painting),
    /// for models imported from 3MF / AMF / OBJ. nil = slice `url` as an STL.
    var nativeURL: URL? = nil
    /// PalmSlice tool number for the whole object; 0 = the default (tool 1).
    var extruder: Int = 0
    /// The object's volumes (empty for STL models).
    var parts: [ModelPart] = []
    /// Colour by height, sorted by fromZ.
    var toolBands: [ToolBand] = []
    /// Painted triangles to draw over the model (display-STL frame).
    var paint: PaintMesh? = nil
    /// Bumped whenever `paint` changes, so the 3D view knows to redraw it.
    var paintVersion = 0
    /// Display geometry of volumes that aren't printable parts, by volume index,
    /// centred like `geometry`.
    var partGeometries: [Int: SCNGeometry] = [:]

    /// Tools the model prints with (PalmSlice numbers, mixes included).
    /// The default tool counts as tool 1.
    var usedTools: Set<Int> {
        var tools: Set<Int> = [extruder == 0 ? 1 : extruder]
        for part in parts where part.kind == .part || part.kind == .modifier {
            if part.extruder > 0 { tools.insert(part.extruder) }
            tools.formUnion(part.paintedTools)
        }
        for band in toolBands where band.tool > 0 { tools.insert(band.tool) }
        if useFileSettings, let fs = fileSettings {
            for range in fs.ranges { if let t = range.settings["extruder"].flatMap(Int.init), t > 0 { tools.insert(t) } }
        }
        return tools
    }

    /// toolBands as slicer_set_object_tool_ranges text.
    var toolRangesText: String {
        let bands = toolBands.sorted { $0.fromZ < $1.fromZ }
        return bands.enumerated().map { i, band in
            let top = i + 1 < bands.count ? bands[i + 1].fromZ : 100_000
            return "\(PrusaValue.float(band.fromZ)) \(PrusaValue.float(top)) \(band.tool)\n"
        }.joined()
    }

    /// Triangle counts of the printable parts, in display-mesh order.
    var partFacetCounts: [Int] { parts.filter { $0.kind == .part }.map(\.facetCount) }
    var isPainted: Bool { parts.contains { $0.isPainted } }
}
