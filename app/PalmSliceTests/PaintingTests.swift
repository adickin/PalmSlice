import XCTest
@testable import PalmSlice

/// Colour painting through the bridge (slicer_paint_*), on parts.3mf's tower.
final class PaintingTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// An STL comes back from its native 3MF with its offset on the instance,
    /// not the volume; paint must still land where the display mesh is.
    func testBrushOnImportedSTLStaysInDisplayFrame() throws {
        let cube = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PalmSlice/Resources/cube.stl")   // 0…20 mm
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let native = try XCTUnwrap(importModelFile(at: cube, outputDir: dir).objects.first?.nativeURL)
        guard let h = slicer_create() else { return XCTFail("slicer_create") }
        defer { slicer_destroy(h) }
        XCTAssertEqual(slicer_paint_begin(h, native.path, 0), 0, String(cString: slicer_last_error(h)))

        // A dab on the top face (facet 3 holds x + y > 20).
        XCTAssertEqual(slicer_paint_stroke_begin(h), 0)
        XCTAssertEqual(slicer_paint_brush(h, 3, [6, 15, 20], nil, [10, 10, 100], 3, 2, 0), 0)
        let painted = slicer_paint_mesh_update(h)
        XCTAssertGreaterThan(painted, 0)
        let vertices = UnsafeBufferPointer(start: slicer_paint_mesh_vertices(h), count: Int(painted) * 9)
        XCTAssertTrue(stride(from: 2, to: vertices.count, by: 3).allSatisfy { abs(vertices[$0] - 20) < 0.001 })
        XCTAssertTrue(vertices.allSatisfy { $0 > -0.001 && $0 < 20.001 })
    }

    /// Support and seam painting: only enforce / block states, saved into the
    /// native 3MF on their own layers (colour paint untouched), reported on
    /// import, and the object still slices with supports on.
    func testSupportAndSeamPaintingRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let object = try importModelFile(at: fixtures.appendingPathComponent("parts.3mf"), outputDir: dir).objects[0]
        let native = try XCTUnwrap(object.nativeURL)
        guard let h = slicer_create() else { return XCTFail("slicer_create") }
        defer { slicer_destroy(h) }

        // Seam: enforce on the tower's top face.
        XCTAssertEqual(slicer_paint_begin_layer(h, native.path, 0, SLICER_PAINT_SEAM), 0, String(cString: slicer_last_error(h)))
        XCTAssertEqual(slicer_paint_mesh_update(h), 0)
        XCTAssertEqual(slicer_paint_stroke_begin(h), 0)
        XCTAssertNotEqual(slicer_paint_brush(h, 2, [3, -3, 20], nil, [0, 0, 100], 4, 3, 0), 0, "tools aren't seam states")
        XCTAssertEqual(slicer_paint_brush(h, 2, [3, -3, 20], nil, [0, 0, 100], 4, SLICER_PAINT_ENFORCE, 0), 0)
        XCTAssertGreaterThan(slicer_paint_mesh_update(h), 0)
        let seamSaved = dir.appendingPathComponent("seam.3mf")
        XCTAssertEqual(slicer_paint_end(h, seamSaved.path), 0, String(cString: slicer_last_error(h)))

        // Supports: block a side of the tower, on top of the seam copy.
        XCTAssertEqual(slicer_paint_begin_layer(h, seamSaved.path, 0, SLICER_PAINT_SUPPORTS), 0)
        XCTAssertEqual(slicer_paint_mesh_update(h), 0, "seam paint isn't on the supports layer")
        XCTAssertEqual(slicer_paint_stroke_begin(h), 0)
        XCTAssertEqual(slicer_paint_fill(h, 4, [4, -10, 5], SLICER_PAINT_BLOCK, 30, 1), 0, String(cString: slicer_last_error(h)))
        let saved = dir.appendingPathComponent("painted.3mf")
        XCTAssertEqual(slicer_paint_end(h, saved.path), 0)

        // Colour paint is a separate layer: still none.
        XCTAssertEqual(slicer_paint_begin(h, saved.path, 0), 0)
        XCTAssertEqual(slicer_paint_mesh_update(h), 0)
        slicer_paint_end(h, nil)

        let again = try importModelFile(at: saved, outputDir: dir.appendingPathComponent("again"))
        let tower = try XCTUnwrap(again.objects.first?.parts.first)
        XCTAssertTrue(tower.seamPainted)
        XCTAssertTrue(tower.supportsPainted)
        XCTAssertFalse(tower.isPainted)
        XCTAssertFalse(again.objects.first?.parts[1].supportsPainted ?? true)

        guard let s = slicer_create() else { return XCTFail("slicer_create") }
        defer { slicer_destroy(s) }
        var settings = try XCTUnwrap(object.projectSettings)
        settings["support_material"] = "1"
        XCTAssertEqual(slicer_apply_settings(s, SettingsText.serialize(settings)), 0)
        let idx = slicer_add_model_object(s, saved.path, 1)
        XCTAssertGreaterThanOrEqual(idx, 0, String(cString: slicer_last_error(s)))
        var t = SlicerModelTransform(); t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
        XCTAssertEqual(slicer_set_object_transform(s, idx, &t), 0)
        XCTAssertEqual(slicer_slice(s, 0, 0), 0, String(cString: slicer_last_error(s)))
        XCTAssertEqual(slicer_export_gcode(s, dir.appendingPathComponent("painted.gcode").path), 0)
    }

    func testBrushUndoSaveAndSlice() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = try importModelFile(at: fixtures.appendingPathComponent("parts.3mf"), outputDir: dir)
        let object = file.objects[0]
        let native = try XCTUnwrap(object.nativeURL)
        guard let h = slicer_create() else { return XCTFail("slicer_create") }
        defer { slicer_destroy(h) }

        XCTAssertEqual(slicer_paint_begin(h, native.path, 0), 0, String(cString: slicer_last_error(h)))
        XCTAssertNotEqual(slicer_paint_begin(h, native.path, 2), 0, "modifiers can't be painted")
        XCTAssertEqual(slicer_paint_begin(h, native.path, 0), 0)
        XCTAssertEqual(slicer_paint_mesh_update(h), 0)

        // A brush dab on the tower's top face (z = 20; facet 2 holds x > y).
        XCTAssertEqual(slicer_paint_stroke_begin(h), 0)
        let point: [Float] = [3, -3, 20], camera: [Float] = [0, 0, 100]
        XCTAssertEqual(slicer_paint_brush(h, 2, point, nil, camera, 4, 2, 0), 0, String(cString: slicer_last_error(h)))
        let painted = slicer_paint_mesh_update(h)
        XCTAssertGreaterThan(painted, 0)
        let states = UnsafeBufferPointer(start: slicer_paint_mesh_states(h), count: Int(painted))
        XCTAssertEqual(Set(states), [2])
        let vertices = UnsafeBufferPointer(start: slicer_paint_mesh_vertices(h), count: Int(painted) * 9)
        XCTAssertTrue(stride(from: 2, to: vertices.count, by: 3).allSatisfy { abs(vertices[$0] - 20) < 0.001 })
        var used = [Int32](repeating: 0, count: 8)
        XCTAssertEqual(slicer_paint_used_tools(h, &used, 8), 1)
        XCTAssertEqual(used[0], 2)

        // Undo, redo.
        XCTAssertEqual(slicer_paint_undo(h, 0), 0)
        XCTAssertEqual(slicer_paint_mesh_update(h), 0)
        XCTAssertEqual(slicer_paint_undo(h, 1), 0)
        XCTAssertEqual(slicer_paint_mesh_update(h), painted)

        // Fill the whole side of the tower with tool 3 (smart fill stops at the cube's edges).
        XCTAssertEqual(slicer_paint_stroke_begin(h), 0)
        XCTAssertEqual(slicer_paint_fill(h, 4, [4, -10, 5], 3, 30, 1), 0, String(cString: slicer_last_error(h)))
        XCTAssertEqual(slicer_paint_used_tools(h, &used, 8), 2)

        let saved = dir.appendingPathComponent("painted.3mf")
        XCTAssertEqual(slicer_paint_end(h, saved.path), 0, String(cString: slicer_last_error(h)))

        // The saved object keeps its parts, tools and the new paint.
        let again = try importModelFile(at: saved, outputDir: dir.appendingPathComponent("again"))
        let tower = try XCTUnwrap(again.objects.first?.parts.first)
        XCTAssertTrue(tower.isPainted)
        XCTAssertEqual(tower.paintedTools, [2, 3])
        XCTAssertEqual(again.objects.first?.parts.map(\.name), ["tower", "side", "dense", "stripe"])

        // Slicing prints the painted side with T3 (G-code T2) and the dab with T2 (T1).
        guard let s = slicer_create() else { return XCTFail("slicer_create") }
        defer { slicer_destroy(s) }
        XCTAssertEqual(slicer_apply_settings(s, SettingsText.serialize(try XCTUnwrap(object.projectSettings))), 0)
        let idx = slicer_add_model_object(s, saved.path, 1)
        XCTAssertGreaterThanOrEqual(idx, 0, String(cString: slicer_last_error(s)))
        var t = SlicerModelTransform(); t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
        XCTAssertEqual(slicer_set_object_transform(s, idx, &t), 0)
        XCTAssertEqual(slicer_slice(s, 0, 0), 0, String(cString: slicer_last_error(s)))
        let out = dir.appendingPathComponent("painted.gcode")
        XCTAssertEqual(slicer_export_gcode(s, out.path), 0)
        let tools = toolChanges(try String(contentsOf: out, encoding: .utf8))
        XCTAssertTrue(tools.isSuperset(of: ["T0", "T1", "T2"]), "\(tools)")
    }
}
