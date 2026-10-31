import XCTest
@testable import PalmSlice

/// The Snapmaker U1 from PalmSlice's own vendor bundle (profiles/PalmSlice.ini).
final class SnapmakerU1Tests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures")
    private let bundle = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("profiles/PalmSlice.ini")

    private func u1() throws -> PrinterProfile {
        try XCTUnwrap(BuiltInProfiles.all.first { $0.builtInKey == "snapmaker-u1" })
    }

    // Unknown keys are dropped silently when vendor bundles load, so check
    // every key in the bundle is a PrusaSlicer setting.
    func testBundleUsesOnlyPrusaSlicerKeys() throws {
        let text = try String(contentsOf: bundle, encoding: .utf8)
        var section = ""
        var unknown: [String] = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("[") { section = String(line); continue }
            guard !line.hasPrefix("#"), let eq = line.range(of: " = "),
                  section.hasPrefix("[printer:") || section.hasPrefix("[print:") || section.hasPrefix("[filament:")
            else { continue }
            let key = String(line[..<eq.lowerBound])
            if ["compatible_printers_condition", "inherits", "default_print_profile", "default_filament_profile",
                "printer_model", "printer_variant", "filament_vendor"].contains(key) { continue }
            if slicer_setting_info(key) == nil { unknown.append("\(section) \(key)") }
        }
        XCTAssertEqual(unknown, [])
    }

    func testU1IsABuiltInFourToolPrinter() throws {
        let printer = try u1()
        XCTAssertEqual(printer.numberOfExtruders, 4)
        XCTAssertEqual(printer.bedX, 270, accuracy: 0.01)
        XCTAssertFalse(printer.verified)
        XCTAssertEqual(printer.gcodeFlavor.prusaName, "klipper")
        XCTAssertNotNil(PresetLibrary.base(printerPreset: printer.systemPreset, filamentType: "PLA"))
    }

    /// Slices parts.3mf (tools 1–3) on the U1 and returns the G-code.
    private func sliceOnU1() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = try importModelFile(at: fixtures.appendingPathComponent("parts.3mf"), outputDir: dir)
        guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
        defer { slicer_destroy(h) }
        var petg = BuiltInMaterialProfiles.petg; petg.colour = "#0000FF"
        try SliceSetup.configure(h, printer: try u1(), material: BuiltInMaterialProfiles.pla,
                                 slice: SliceProfile(), toolMaterials: [petg])
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
        let out = dir.appendingPathComponent("u1.gcode")
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
        return try String(contentsOf: out, encoding: .utf8)
    }

    func testFourToolSliceHasNoUnresolvedPlaceholders() throws {
        let gcode = try sliceOnU1()
        // Only the G-code body: the config footer lists the templates themselves.
        let body = gcode.components(separatedBy: "; prusaslicer_config = begin").first ?? gcode
        for line in body.split(separator: "\n") where !line.hasPrefix(";") && !line.hasPrefix("EXCLUDE_OBJECT_DEFINE") {
            XCTAssertFalse(line.contains("{") || line.contains("}") || line.contains("["), "unresolved: \(line)")
        }
        XCTAssertFalse(body.contains("Parsing error"))
        // Tools 1–3 are used: those are fed and calibrated, tool 4 isn't.
        for i in 0..<3 { XCTAssertTrue(body.contains("SM_PRINT_AUTO_FEED EXTRUDER=\(i)\n"), "tool \(i + 1) not fed") }
        XCTAssertFalse(body.contains("SM_PRINT_AUTO_FEED EXTRUDER=3"))
        XCTAssertTrue(body.contains("PRINT_START"))
        XCTAssertTrue(body.contains("SM_PRINT_PREEXTRUDE_FILAMENT INDEX=1"))
        XCTAssertTrue(body.contains("SET_PRINT_STATS_INFO TOTAL_LAYER="))
        XCTAssertTrue(body.contains("EXCLUDE_OBJECT_DEFINE"))
        XCTAssertTrue(body.contains("BED_MESH_CALIBRATE mesh_min="))
        // PETG in tool 2 heats to its own temperature at the tool change.
        XCTAssertTrue(body.contains("M109 S\(BuiltInMaterialProfiles.petg.otherLayersTemp) T1"))
        XCTAssertTrue(gcode.contains("; filament_colour = "))
    }

    // The U1 asks for 48×48 and 300×300 PNGs; PalmSlice renders and embeds them.
    @MainActor
    func testThumbnailsAreEmbedded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let object = try XCTUnwrap(try importModelFile(at: fixtures.appendingPathComponent("parts.3mf"), outputDir: dir).objects.first)
        guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
        defer { slicer_destroy(h) }
        try SliceSetup.configure(h, printer: try u1(), material: BuiltInMaterialProfiles.pla, slice: SliceProfile())
        XCTAssertEqual(slicer_enable_thumbnails(h, 1), 0)
        var sizes = [Int32](repeating: 0, count: 8)
        XCTAssertEqual(slicer_thumbnail_sizes(h, &sizes, 4), 2)
        XCTAssertEqual(Array(sizes.prefix(4)), [48, 48, 300, 300])

        let idx = slicer_add_model_object(h, try XCTUnwrap(object.nativeURL).path, 1)
        var t = SlicerModelTransform(); t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
        XCTAssertEqual(slicer_set_object_transform(h, idx, &t), 0)
        XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))

        var model = PlacedModel(id: UUID(), url: object.url, name: object.name, geometry: nil,
                                transform: ModelTransform(), nativeURL: object.nativeURL, parts: object.parts)
        model.geometry = try parseSTL(url: object.url, partFacetCounts: model.partFacetCounts)
        let pixels = try XCTUnwrap(ThumbnailRenderer.render(models: [model], palette: nil, width: 300, height: 300))
        XCTAssertEqual(pixels.count, 300 * 300 * 4)
        XCTAssertGreaterThan(stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count, 300 * 300 / 20,
                             "the model should cover part of the image")
        XCTAssertEqual(slicer_set_thumbnail(h, 300, 300, pixels), 0)
        let small = try XCTUnwrap(ThumbnailRenderer.render(models: [model], palette: nil, width: 48, height: 48))
        XCTAssertEqual(slicer_set_thumbnail(h, 48, 48, small), 0)

        let out = dir.appendingPathComponent("thumb.gcode")
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
        let gcode = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(gcode.contains("; thumbnail begin 48x48"))
        XCTAssertTrue(gcode.contains("; thumbnail begin 300x300"))
    }
}
