import XCTest
@testable import PalmSlice

/// Modifiers the user adds to a model (box / cylinder / sphere) reach the slice
/// in the model's own frame, with their tool and settings.
final class ModelModifierTests: XCTestCase {
    /// A 20 × 20 × 10 mm box as an ASCII STL.
    private func boxSTL() throws -> URL {
        let v: [SIMD3<Double>] = [[0, 0, 0], [20, 0, 0], [20, 20, 0], [0, 20, 0],
                                  [0, 0, 10], [20, 0, 10], [20, 20, 10], [0, 20, 10]]
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

    private func slice(_ modifiers: [ModelModifier], rotationZ: Float = 0) throws -> (gcode: String, bedX: Double) {
        let printer = try XCTUnwrap(BuiltInProfiles.all.first { $0.builtInKey == "snapmaker-u1" })
        guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
        defer { slicer_destroy(h) }
        try SliceSetup.configure(h, printer: printer, material: BuiltInMaterialProfiles.pla,
                                 slice: SliceProfile(), toolMaterials: [BuiltInMaterialProfiles.pla])
        let url = try boxSTL()
        var model = PlacedModel(id: UUID(), url: url, name: "box", geometry: nil, transform: ModelTransform())
        model.modifiers = modifiers
        let idx = slicer_add_stl(h, url.path)
        XCTAssertGreaterThanOrEqual(idx, 0, String(cString: slicer_last_error(h)))
        var t = SlicerModelTransform(); t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
        t.rot_y_deg = rotationZ   // SceneKit Y = print Z
        XCTAssertEqual(slicer_set_object_transform(h, idx, &t), 0)
        XCTAssertNil(SliceSetup.applyTools(h, object: idx, model: model))
        XCTAssertNil(SliceSetup.applyModifiers(h, object: idx, model: model))
        XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gcode")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
        return (try String(contentsOf: out, encoding: .utf8), printer.bedX)
    }

    /// X of every outer-wall extrusion, by tool (0-based).
    private func wallX(_ gcode: String) -> [Int: [Double]] {
        var out: [Int: [Double]] = [:]
        var tool = 0, wall = false
        for line in gcode.split(separator: "\n") {
            if line.first == "T", let t = Int(line.dropFirst().prefix { $0.isNumber }) { tool = t }
            else if line.hasPrefix(";TYPE:") { wall = line == ";TYPE:Outer wall" }
            else if wall, line.hasPrefix("G1 "), line.contains(" E"),
                    let x = line.split(separator: " ").first(where: { $0.first == "X" }).flatMap({ Double($0.dropFirst()) }) {
                out[tool, default: []].append(x)
            }
        }
        return out
    }

    /// A box modifier over the model's right half, set to T2: only that half prints with T2.
    func testBoxModifierSetsToolWhereItSits() throws {
        let right = ModelModifier(shape: .box, centreMM: [7.5, 0, 0], sizeMM: [5.5, 30, 30], tool: 2)
        let (gcode, bedX) = try slice([right])
        let walls = wallX(gcode)
        let t2 = try XCTUnwrap(walls[1], "T2 prints the modifier's part")
        XCTAssertGreaterThan(t2.min()!, bedX / 2 + 4, "T2 only on the right")
        XCTAssertLessThan(try XCTUnwrap(walls[0]).min()!, bedX / 2 - 9, "T1 prints the rest")
    }

    /// The modifier turns with the model: a 90° turn moves the model's right
    /// side (+X) to the back (+Y), so T2 is no longer on the right.
    func testModifierFollowsTheModelsRotation() throws {
        let right = ModelModifier(shape: .box, centreMM: [7.5, 0, 0], sizeMM: [5.5, 30, 30], tool: 2)
        let walls = wallX(try slice([right], rotationZ: 90).gcode)
        let t2 = try XCTUnwrap(walls[1])
        XCTAssertLessThan(t2.max()! - t2.min()!, 21)
        XCTAssertGreaterThan(t2.max()! - t2.min()!, 19, "T2 now spans the model's width, along its back")
    }

    /// Settings: 100% infill inside a cylinder, more infill than without.
    func testCylinderModifierChangesSettings() throws {
        /// Filament (mm) extruded as infill.
        func infill(_ gcode: String) -> Double {
            var e = 0.0, infill = false
            for line in gcode.split(separator: "\n") {
                if line.hasPrefix(";TYPE:") { infill = line == ";TYPE:Sparse infill" || line == ";TYPE:Internal solid infill" }
                else if infill, line.hasPrefix("G1 "),
                        let v = line.split(separator: " ").first(where: { $0.first == "E" }).flatMap({ Double($0.dropFirst()) }),
                        v > 0 { e += v }
            }
            return e
        }
        let plain = infill(try slice([]).gcode)
        let core = ModelModifier(shape: .cylinder, centreMM: .zero, sizeMM: [12, 12, 30],
                                 settings: ["sparse_infill_density": "100%"])
        XCTAssertGreaterThan(infill(try slice([core]).gcode), plain * 1.5)
        let ball = ModelModifier(shape: .sphere, centreMM: .zero, sizeMM: [12, 12, 12],
                                 settings: ["sparse_infill_density": "100%"])
        XCTAssertGreaterThan(infill(try slice([ball]).gcode), plain * 1.2)
    }
}
