import XCTest
@testable import PalmSlice

/// ColorMix through the app's slice path on the OrcaSlicer backend: a 70/30
/// blend of T1 and T2 assigned to an STL object on the Snapmaker U1.
final class MixSliceTests: XCTestCase {
    /// A 20 × 20 × `height` mm box as an ASCII STL.
    private func boxSTL(height: Double) throws -> URL {
        let v: [SIMD3<Double>] = [[0, 0, 0], [20, 0, 0], [20, 20, 0], [0, 20, 0],
                                  [0, 0, height], [20, 0, height], [20, 20, height], [0, 20, height]]
        let faces = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4],
                     [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]]
        var text = "solid box\n"
        for f in faces {
            text += "facet normal 0 0 0\nouter loop\n"
            for i in f { text += "vertex \(v[i].x) \(v[i].y) \(v[i].z)\n" }
            text += "endloop\nendfacet\n"
        }
        text += "endsolid box\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).stl")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Tool (0-based) of each layer's first outer wall.
    private func outerWallToolPerLayer(_ gcode: String) -> [Int] {
        var tools: [Int] = []
        var tool = 0, layer = -1, recorded = -1
        var outerWall = false
        for line in gcode.split(separator: "\n") {
            if line.hasPrefix(";LAYER_CHANGE") {
                layer += 1
            } else if line.first == "T", let t = line.split(separator: " ").first.flatMap({ Int($0.dropFirst()) }) {
                tool = t
            } else if line.hasPrefix(";TYPE:") {
                outerWall = line == ";TYPE:Outer wall"
            } else if outerWall, layer > recorded, line.hasPrefix("G1 "), line.contains(" E"), !line.contains(" E-") {
                tools.append(tool)
                recorded = layer
            }
        }
        return tools
    }

    /// (print_z, tool of the outer wall) per layer.
    private func layers(_ gcode: String) -> [(z: Double, tool: Int)] {
        var out: [(Double, Int)] = []
        var z = 0.0, tool = 0, recorded = false
        var outerWall = false
        for line in gcode.split(separator: "\n") {
            if line.hasPrefix(";Z:") {
                z = Double(line.dropFirst(3)) ?? z
                recorded = false
            } else if line.first == "T", let t = line.split(separator: " ").first.flatMap({ Int($0.dropFirst()) }) {
                tool = t
            } else if line.hasPrefix(";TYPE:") {
                outerWall = line == ";TYPE:Outer wall"
            } else if outerWall, !recorded, line.hasPrefix("G1 "), line.contains(" E"), !line.contains(" E-") {
                out.append((z, tool))
                recorded = true
            }
        }
        return out
    }

    private func sliceBox(_ mix: ToolMix, height: Double = 10) throws -> (gcode: String, stats: SliceStats) {
        let printer = try XCTUnwrap(BuiltInProfiles.all.first { $0.builtInKey == "snapmaker-u1" })
        guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
        defer { slicer_destroy(h) }
        var white = BuiltInMaterialProfiles.pla
        white.colour = "#FFFFFF"
        var black = BuiltInMaterialProfiles.pla
        black.colour = "#000000"
        try SliceSetup.configure(h, printer: printer, material: white, slice: SliceProfile(), toolMaterials: [black])
        XCTAssertEqual(slicer_set_virtual_extruders(h, ToolMix.json([mix])), 0)
        let idx = slicer_add_stl(h, try boxSTL(height: height).path)
        var t = SlicerModelTransform(); t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
        XCTAssertEqual(slicer_set_object_transform(h, idx, &t), 0)
        XCTAssertEqual(slicer_set_object_extruder(h, idx, Int32(mix.id)), 0)
        XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gcode")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
        return (try String(contentsOf: out, encoding: .utf8),
                try XCTUnwrap(SliceStats(json: String(cString: slicer_print_stats(h)))))
    }

    /// Snapmaker Orca's grey: 39% black over white, each 0.2 mm layer split
    /// into 0.0868 mm black and 0.1132 mm white sub-layers.
    func testSubLayerBlendSplitsEachLayerByTool() throws {
        let grey = ToolMix(id: ToolMix.base + 1, components: [.init(tool: 1, amount: 0.61), .init(tool: 2, amount: 0.39)],
                           subLayers: true)
        let (gcode, stats) = try sliceBox(grey)
        let all = layers(gcode)
        XCTAssertGreaterThan(all.count, 80, "about two sub-layers per 0.2 mm layer")
        for i in 2..<min(all.count, 40) {
            let height = all[i].z - all[i - 1].z
            let expected = all[i].tool == 0 ? 0.1132 : 0.0868
            XCTAssertEqual(height, expected, accuracy: 0.002, "layer \(i) at \(all[i].z) on T\(all[i].tool + 1)")
        }
        // Tools alternate white/black order, so one change per base layer.
        let baseLayers = (10.0 - 0.2) / 0.2
        XCTAssertLessThanOrEqual(Double(stats.filamentChanges), baseLayers + 3)
        XCTAssertGreaterThanOrEqual(Double(stats.filamentChanges), baseLayers - 3)
    }

    func testBlendAlternatesItsToolsByRatio() throws {
        let printer = try XCTUnwrap(BuiltInProfiles.all.first { $0.builtInKey == "snapmaker-u1" })
        guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
        defer { slicer_destroy(h) }
        var white = BuiltInMaterialProfiles.pla
        white.colour = "#FFFFFF"
        var black = BuiltInMaterialProfiles.pla
        black.colour = "#000000"
        try SliceSetup.configure(h, printer: printer, material: black, slice: SliceProfile(), toolMaterials: [white])
        let grey = ToolMix(id: ToolMix.base + 1, components: [.init(tool: 1, amount: 0.7), .init(tool: 2, amount: 0.3)])
        XCTAssertEqual(slicer_set_virtual_extruders(h, ToolMix.json([grey])), 0)

        let stl = try boxSTL(height: 10)
        let idx = slicer_add_stl(h, stl.path)
        XCTAssertGreaterThanOrEqual(idx, 0, String(cString: slicer_last_error(h)))
        var t = SlicerModelTransform(); t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
        XCTAssertEqual(slicer_set_object_transform(h, idx, &t), 0)
        XCTAssertEqual(slicer_set_object_extruder(h, idx, Int32(grey.id)), 0)
        XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gcode")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
        let gcode = try String(contentsOf: out, encoding: .utf8)

        let tools = outerWallToolPerLayer(gcode)
        XCTAssertGreaterThan(tools.count, 40)
        XCTAssertEqual(Set(tools), [0, 1], "the blend prints with T1 and T2 only")
        let share = Double(tools.filter { $0 == 0 }.count) / Double(tools.count)
        XCTAssertEqual(share, 0.7, accuracy: 0.08, "T1 prints about 70% of the layers")

        let stats = try XCTUnwrap(SliceStats(json: String(cString: slicer_print_stats(h))))
        XCTAssertGreaterThan(stats.filamentChanges, 10)
        XCTAssertEqual(Set(stats.filaments.filter { $0.modelG > 0 }.map(\.tool)), [1, 2])
    }
}
