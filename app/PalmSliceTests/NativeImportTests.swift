import XCTest
import simd
@testable import PalmSlice

/// 3MF objects are imported natively (volumes, part tools, modifiers, painting,
/// mixes) and sliced the PalmSlice way through slicer_add_model_object.
final class NativeImportTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    private func importFixture(_ name: String, mixes: [ToolMix] = []) throws -> ModelFileImport {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try importModelFile(at: fixtures.appendingPathComponent(name), outputDir: dir, mixes: mixes)
    }

    /// Slices imported objects the way ContentView does, over the file's own
    /// project settings, keeping the file's layout.
    private func slice(_ file: ModelFileImport, keepFileSettings: Bool = true, projectTo: URL? = nil,
                       edit: (inout PlacedModel) -> Void = { _ in }) throws -> String {
        guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
        defer { slicer_destroy(h) }
        let project = try XCTUnwrap(file.objects.first?.projectSettings)
        XCTAssertEqual(slicer_apply_settings(h, SettingsText.serialize(project)), 0, String(cString: slicer_last_error(h)))
        XCTAssertEqual(slicer_set_virtual_extruders(h, ToolMix.json(file.mixes)), 0)
        for object in file.objects {
            var model = PlacedModel(id: UUID(), url: object.url, name: object.name, geometry: nil,
                                    transform: ModelTransform(), fileSettings: object.fileSettings,
                                    useFileSettings: keepFileSettings, nativeURL: object.nativeURL,
                                    extruder: object.extruder, parts: object.parts)
            edit(&model)
            let idx = slicer_add_model_object(h, try XCTUnwrap(model.nativeURL).path, keepFileSettings ? 1 : 0)
            XCTAssertGreaterThanOrEqual(idx, 0, String(cString: slicer_last_error(h)))
            var t = SlicerModelTransform()
            t.pos_x_mm = object.offsetMM.x; t.pos_z_mm = -object.offsetMM.y
            t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
            XCTAssertEqual(slicer_set_object_transform(h, idx, &t), 0)
            XCTAssertNil(SliceSetup.applyTools(h, object: idx, model: model))
            if keepFileSettings, let fs = model.fileSettings {
                XCTAssertEqual(slicer_set_object_file_settings(h, idx, fs.text()), 0, String(cString: slicer_last_error(h)))
            }
            XCTAssertNil(SliceSetup.applyToolBands(h, object: idx, model: model))
        }
        XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gcode")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
        if let projectTo {
            XCTAssertEqual(slicer_export_project_3mf(h, projectTo.path), 0, String(cString: slicer_last_error(h)))
        }
        return try String(contentsOf: out, encoding: .utf8)
    }

    private func referenceSlice(_ name: String) throws -> String {
        try referenceSlice(at: fixtures.appendingPathComponent(name))
    }

    private func referenceSlice(at file: URL) throws -> String {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gcode")
        defer { try? FileManager.default.removeItem(at: out) }
        var err = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(slicer_reference_slice_3mf(file.path, out.path, &err, 512), 0, String(cString: err))
        return try String(contentsOf: out, encoding: .utf8)
    }

    /// Signed volume of a closed mesh: positive when its triangles face outward.
    private func signedVolume(_ info: STLMeshInfo) -> Float {
        var sum: Float = 0
        for i in stride(from: 0, to: info.vertices.count, by: 3) {
            let v = info.vertices
            sum += simd_dot(v[i], simd_cross(v[i + 1], v[i + 2])) / 6
        }
        return sum
    }

    // MARK: Import

    func testKeepsPartsToolsAndModifiers() throws {
        let file = try importFixture("parts.3mf")
        XCTAssertEqual(file.objects.count, 2)   // two instances
        let a = file.objects[0]
        XCTAssertEqual(a.parts.map(\.name), ["tower", "side", "dense", "stripe"])
        XCTAssertEqual(a.parts.map(\.kind), [.part, .part, .modifier, .modifier])
        XCTAssertEqual(a.parts.map(\.extruder), [0, 2, 0, 3])
        XCTAssertEqual(a.parts.map(\.facetCount), [12, 12, 0, 0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(a.nativeURL).path))
        for part in a.parts where part.kind != .part {
            let mesh = try parseSTLMeshInfo(url: try XCTUnwrap(part.meshURL))
            XCTAssertEqual(mesh.faces.count, 12)
        }
        // The display mesh holds just the printable parts: tower + side, 42 × 20 × 20 mm.
        let info = try parseSTLMeshInfo(url: a.url)
        XCTAssertEqual(info.faces.count, 24)
        XCTAssertEqual(info.sizeMMX, 32, accuracy: 0.01)
        XCTAssertEqual(info.sizeMMY, 20, accuracy: 0.01)
        XCTAssertEqual(info.sizeMMZ, 20, accuracy: 0.01)
        XCTAssertGreaterThan(signedVolume(info), 0)

        // The second instance is mirrored in X: the side part is on the other
        // side of the tower, and the mesh still faces outward.
        let b = try parseSTLMeshInfo(url: file.objects[1].url)
        XCTAssertEqual(b.sizeMMX, 32, accuracy: 0.01)
        XCTAssertEqual(signedVolume(b), signedVolume(info), accuracy: 1)
        func sideX(_ m: STLMeshInfo) -> Float { m.vertices[36...].map(\.x).reduce(0, +) / 36 }
        func towerX(_ m: STLMeshInfo) -> Float { m.vertices[..<36].map(\.x).reduce(0, +) / 36 }
        XCTAssertGreaterThan(sideX(info), towerX(info))
        XCTAssertLessThan(sideX(b), towerX(b))
    }

    func testColorMixFileUsesPalmSliceToolNumbers() throws {
        let file = try importFixture("colormix.3mf")
        XCTAssertEqual(file.mixes.map(\.id), [101, 102])
        XCTAssertEqual(file.mixes.map(\.kind), [.blend, .gradient])
        XCTAssertEqual(file.mixes[0].tools, [1, 2])
        XCTAssertEqual(file.mixes[1].tools, [3, 4])
        XCTAssertEqual(file.objects.map(\.name), ["blend", "gradient"])
        XCTAssertEqual(file.objects[0].extruder, 101)
        XCTAssertEqual(file.objects[1].extruder, 1)
        XCTAssertEqual(file.objects[1].parts.map(\.isPainted), [true])
        XCTAssertNil(file.objects[0].fileSettings)   // the tool isn't a file setting
    }

    func testReimportReusesIdenticalMixes() throws {
        let first = try importFixture("colormix.3mf")
        let second = try importFixture("colormix.3mf", mixes: first.mixes)
        XCTAssertEqual(second.mixes, first.mixes)
        XCTAssertEqual(second.objects[0].extruder, 101)
    }

    func testConflictingMixGetsTheNextNumber() throws {
        let other = ToolMix(id: 101, components: [.init(tool: 4, amount: 0.5), .init(tool: 5, amount: 0.5)])
        let file = try importFixture("colormix.3mf", mixes: [other])
        XCTAssertEqual(file.mixes.map(\.id), [101, 102, 103])
        XCTAssertEqual(file.objects[0].extruder, 102)
    }

    // MARK: Slicing

    func testNativeSliceMatchesReferenceSlice() throws {
        let reference = toolsByLayer(try referenceSlice("colormix.3mf"))
        let ours = toolsByLayer(try slice(try importFixture("colormix.3mf")))
        XCTAssertEqual(ours["blend"], reference["blend"])
        XCTAssertEqual(ours["gradient"], reference["gradient"])
        XCTAssertEqual(ours["blend"]?.count, 50)
    }

    // Mixes renumbered on import (paint and object tool) still slice the same.
    func testRenumberedMixesSliceTheSame() throws {
        let reference = toolsByLayer(try referenceSlice("colormix.3mf"))
        let other = ToolMix(id: 101, components: [.init(tool: 4, amount: 0.5), .init(tool: 5, amount: 0.5)])
        let ours = toolsByLayer(try slice(try importFixture("colormix.3mf", mixes: [other])))
        XCTAssertEqual(ours["blend"], reference["blend"])
        XCTAssertEqual(ours["gradient"], reference["gradient"])
    }

    func testPartAndModifierToolsReachTheGCode() throws {
        let file = try importFixture("parts.3mf")
        // T0 tower, T1 side part, T2 stripe modifier.
        XCTAssertEqual(toolChanges(try slice(file)).intersection(["T0", "T1", "T2"]), ["T0", "T1", "T2"])
        // Reassigning the side part in PalmSlice wins over the file.
        let moved = try slice(file) { $0.parts[1].extruder = 3 }
        XCTAssertEqual(toolChanges(moved).intersection(["T0", "T1", "T2"]), ["T0", "T2"])
    }

    // File settings off: the settings-only modifier goes (less infill), the
    // modifier that sets a tool stays.
    func testFileSettingsOffDropsSettingsModifiers() throws {
        let file = try importFixture("parts.3mf")
        let with = try slice(file, keepFileSettings: true)
        let without = try slice(file, keepFileSettings: false)
        XCTAssertGreaterThan(filamentUsedMM(with), filamentUsedMM(without) * 1.05)
        XCTAssertTrue(toolChanges(without).contains("T2"))
    }

    func testObjectToolAssignment() throws {
        let file = try importFixture("parts.3mf")
        let gcode = try slice(file) { model in
            model.extruder = 2
            model.parts = model.parts.map { var p = $0; p.extruder = 0; return p }
        }
        let tools = toolsByLayer(gcode)
        XCTAssertEqual(Set(tools["assembly"] ?? []), [1])
    }

    // Colour by height: from 10 mm up the model prints with T2, merged with
    // the stripe modifier's own range.
    func testToolBandsByHeight() throws {
        let file = try importFixture("parts.3mf")
        let gcode = try slice(file, keepFileSettings: false) { model in
            model.parts = model.parts.map { var p = $0; p.extruder = 0; return p }
            model.toolBands = [ToolBand(fromZ: 10, tool: 2)]
        }
        let tools = try XCTUnwrap(toolsByLayer(gcode)["assembly"])
        XCTAssertEqual(tools.count, 100)   // 0.2 mm layers
        XCTAssertEqual(Set(tools.prefix(49)), [0])
        XCTAssertEqual(Set(tools.suffix(49)), [1])
    }

    // The plate exported as a PrusaSlicer project slices the same in PrusaSlicer's
    // own path: mixes, painting and tool assignments survive the round trip.
    func testProjectExportRoundTrips() throws {
        let other = ToolMix(id: 101, components: [.init(tool: 4, amount: 0.5), .init(tool: 5, amount: 0.5)])
        var file = try importFixture("colormix.3mf", mixes: [other])   // renumbered mixes
        file.mixes.removeAll { $0.id == 101 }                            // and an unused one dropped
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).3mf")
        defer { try? FileManager.default.removeItem(at: project) }
        let ours = toolsByLayer(try slice(file, projectTo: project))
        let desktop = toolsByLayer(try referenceSlice(at: project))
        XCTAssertEqual(desktop["blend"], ours["blend"])
        XCTAssertEqual(desktop["gradient"], ours["gradient"])
        XCTAssertEqual(ours["blend"]?.count, 50)
    }
}
