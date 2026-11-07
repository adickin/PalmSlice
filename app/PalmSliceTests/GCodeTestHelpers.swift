import Foundation
@testable import PalmSlice

/// Physical tool (0-based) that prints each labelled object's outer wall, per
/// layer. (Internal infill may use another of a mix's tools on the same layer.)
/// Needs `gcode_label_objects = octoprint`.
func toolsByLayer(_ gcode: String) -> [String: [Int]] {
    var result: [String: [Int]] = [:]
    var layer = -1, tool = 0
    var object: String?
    var outerWall = false
    var seen = Set<String>()
    for line in gcode.split(separator: "\n") {
        if line.hasPrefix(";LAYER_CHANGE") {
            layer += 1
        } else if line.first == "T", let t = line.split(separator: " ").first.flatMap({ Int($0.dropFirst()) }) {
            tool = t
        } else if line.hasPrefix("; printing object ") {
            object = line.dropFirst(18).split(separator: " ").first.map(String.init)
        } else if line.hasPrefix("; stop printing object") {
            object = nil
        } else if line.hasPrefix(";TYPE:") {
            outerWall = line == ";TYPE:Outer wall" || line == ";TYPE:External perimeter"
        } else if let object, outerWall, line.hasPrefix("G1 "), line.contains(" E"), !line.contains(" E-"),
                  seen.insert("\(object):\(layer)").inserted {
            result[object, default: []].append(tool)
        }
    }
    return result
}

/// Tool-change lines ("T0", "T1", …) in the G-code.
func toolChanges(_ gcode: String) -> Set<String> {
    Set(gcode.split(separator: "\n").compactMap { line -> String? in
        guard line.first == "T", let word = line.split(separator: " ").first, Int(word.dropFirst()) != nil else { return nil }
        return String(word)
    })
}

/// "; filament used [mm] = …" total.
func filamentUsedMM(_ gcode: String) -> Double {
    guard let line = gcode.split(separator: "\n").first(where: { $0.hasPrefix("; filament used [mm] =") }) else { return -1 }
    return line.split(separator: "=").last!.split(separator: ",")
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.reduce(0, +)
}

// Fixed, complete quality profiles for tests that need known numbers (the
// app's everyday qualities come from OrcaSlicer).
extension BuiltInSliceProfiles {
    static let draft = SliceProfile(
        name: "Draft (0.3 mm)", layerHeight: 0.3, firstLayerHeight: 0.3, wallCount: 2,
        topLayers: 3, bottomLayers: 3, infillDensity: 15, infillPattern: .grid,
        printSpeed: 80, infillSpeed: 100, travelSpeed: 150, firstLayerSpeed: 30)

    static let standard = SliceProfile(
        name: "Standard (0.2 mm)", layerHeight: 0.2, firstLayerHeight: 0.2, wallCount: 3,
        topLayers: 4, bottomLayers: 4, infillDensity: 20, infillPattern: .gyroid,
        printSpeed: 60, infillSpeed: 80, travelSpeed: 120, firstLayerSpeed: 30)
}
