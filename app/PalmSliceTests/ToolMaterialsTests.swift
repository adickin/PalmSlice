import XCTest
@testable import PalmSlice

/// One material per tool on a multi-tool printer (SliceSetup toolMaterials).
final class ToolMaterialsTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    private func xl5T() throws -> PrinterProfile {
        try XCTUnwrap(PrinterProfile(systemPreset: "Original Prusa XL - 5T 0.4 nozzle"))
    }

    private func setting(_ h: SlicerHandle, _ key: String) -> String {
        slicer_get_setting(h, key).map { String(cString: $0) } ?? ""
    }

    func testEachToolGetsItsMaterial() throws {
        guard let h = slicer_create() else { return XCTFail("slicer_create") }
        defer { slicer_destroy(h) }
        let printer = try xl5T()
        XCTAssertEqual(printer.numberOfExtruders, 5)
        var red = BuiltInMaterialProfiles.pla; red.colour = "#FF0000"
        var blue = BuiltInMaterialProfiles.petg; blue.colour = "#0000FF"
        try SliceSetup.configure(h, printer: printer, material: red,
                                 slice: BuiltInSliceProfiles.rcPlane, toolMaterials: [blue, blue, red, blue])
        XCTAssertEqual(PrusaValue.parseStrings(setting(h, "filament_type")), ["PLA", "PETG", "PETG", "PLA", "PETG"])
        XCTAssertEqual(PrusaValue.parseStrings(setting(h, "filament_colour")),
                       ["#FF0000", "#0000FF", "#0000FF", "#FF0000", "#0000FF"])
        let temps = PrusaValue.parseFloats(setting(h, "temperature")).map { Int($0) }
        let (r, b) = (red.otherLayersTemp, blue.otherLayersTemp)
        XCTAssertEqual(temps, [r, b, b, r, b])
        XCTAssertEqual(PrusaValue.parseStrings(setting(h, "filament_settings_id")).count, 5)
        XCTAssertNotEqual(PrusaValue.parseStrings(setting(h, "filament_settings_id"))[1],
                          PrusaValue.parseStrings(setting(h, "filament_settings_id"))[0])
    }

    // Without tool materials every tool uses the first material, as before.
    func testToolsDefaultToTheFirstMaterial() throws {
        guard let h = slicer_create() else { return XCTFail("slicer_create") }
        defer { slicer_destroy(h) }
        try SliceSetup.configure(h, printer: try xl5T(), material: BuiltInMaterialProfiles.petg,
                                 slice: BuiltInSliceProfiles.rcPlane)
        XCTAssertEqual(Set(PrusaValue.parseStrings(setting(h, "filament_type"))), ["PETG"])
    }

    // A multi-part 3MF slices on the XL 5T with a different material per tool.
    func testMultiToolSliceOnXL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = try importModelFile(at: fixtures.appendingPathComponent("parts.3mf"), outputDir: dir)
        guard let h = slicer_create() else { return XCTFail("slicer_create") }
        defer { slicer_destroy(h) }
        try SliceSetup.configure(h, printer: try xl5T(), material: BuiltInMaterialProfiles.pla,
                                 slice: BuiltInSliceProfiles.rcPlane,
                                 toolMaterials: [BuiltInMaterialProfiles.petg, BuiltInMaterialProfiles.pla])
        let object = file.objects[0]
        let model = PlacedModel(id: UUID(), url: object.url, name: object.name, geometry: nil,
                                transform: ModelTransform(), nativeURL: object.nativeURL,
                                extruder: object.extruder, parts: object.parts)
        let idx = slicer_add_model_object(h, try XCTUnwrap(object.nativeURL).path, 1)
        XCTAssertGreaterThanOrEqual(idx, 0, String(cString: slicer_last_error(h)))
        var t = SlicerModelTransform(); t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
        XCTAssertEqual(slicer_set_object_transform(h, idx, &t), 0)
        XCTAssertNil(SliceSetup.applyTools(h, object: idx, model: model))
        XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
        let out = dir.appendingPathComponent("out.gcode")
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
        let gcode = try String(contentsOf: out, encoding: .utf8)
        // PETG in tool 2 is heated to its own temperature.
        let petgTemp = BuiltInMaterialProfiles.petg.otherLayersTemp
        XCTAssertTrue(gcode.contains("S\(petgTemp) T1"), "no M104/M109 S\(petgTemp) T1")
        XCTAssertTrue(gcode.contains("; filament_type = PLA;PETG;PLA"))
    }
}
