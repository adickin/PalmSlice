import XCTest
@testable import PalmSlice

/// Part Settings: the user's per-part overrides and height ranges reach the
/// slice, on top of a file's settings.
final class PartSettingsTests: XCTestCase {
    private let cube = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("PalmSlice/Resources/cube.stl")   // 20 mm

    /// Filament used slicing the cube with `texts` applied in order (file settings, then the user's).
    private func filament(_ texts: [String]) throws -> Double {
        guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
        defer { slicer_destroy(h) }
        let printer = try XCTUnwrap(BuiltInProfiles.all.first { $0.verified })
        try SliceSetup.configure(h, printer: printer, material: BuiltInMaterialProfiles.pla,
                                 slice: BuiltInSliceProfiles.draft)   // 15% infill
        let idx = slicer_add_stl(h, cube.path)
        XCTAssertGreaterThanOrEqual(idx, 0, String(cString: slicer_last_error(h)))
        var t = SlicerModelTransform(); t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
        XCTAssertEqual(slicer_set_object_transform(h, idx, &t), 0)
        for text in texts {
            XCTAssertEqual(slicer_set_object_file_settings(h, idx, text), 0, String(cString: slicer_last_error(h)))
        }
        XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gcode")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0)
        let gcode = try String(contentsOf: out, encoding: .utf8)
        let line = try XCTUnwrap(gcode.split(separator: "\n").first { $0.hasPrefix("; filament used [mm] =") })
        return try XCTUnwrap(Double(line.split(separator: "=").last!.trimmingCharacters(in: .whitespaces)))
    }

    private func settings(_ object: [String: String] = [:], ranges: [ModelFileSettings.HeightRange] = []) -> ModelFileSettings {
        var s = ModelFileSettings()
        s.objectSettings = object
        s.ranges = ranges
        return s
    }

    func testWholePartAndRangesChangeTheSlice() throws {
        let plain = try filament([])
        let solid = try filament([settings(["sparse_infill_density": "100%"]).userText(partHeight: 20)])
        let halfSolid = try filament([settings(ranges: [.init(minZ: 0, maxZ: 10, settings: ["sparse_infill_density": "100%"])])
            .userText(partHeight: 20)])
        XCTAssertGreaterThan(solid, plain * 1.5)
        XCTAssertGreaterThan(halfSolid, plain * 1.2)
        XCTAssertLessThan(halfSolid, solid * 0.9)
    }

    // A user range over a file's range: split, the user's value wins where they overlap.
    func testUserRangesGoOnTopOfFileRanges() throws {
        let file = settings(ranges: [.init(minZ: 0, maxZ: 20, settings: ["sparse_infill_density": "100%"])]).text()
        let user = settings(ranges: [.init(minZ: 10, maxZ: 20, settings: ["sparse_infill_density": "15%"])]).userText(partHeight: 20)
        let fileOnly = try filament([file])
        let both = try filament([file, user])
        let halfSolid = try filament([settings(ranges: [.init(minZ: 0, maxZ: 10, settings: ["sparse_infill_density": "100%"])]).text()])
        XCTAssertLessThan(both, fileOnly * 0.9)
        XCTAssertEqual(both, halfSolid, accuracy: halfSolid * 0.02)
    }

    // Ranges past the top end there; empty or upside-down ones are dropped.
    func testUserTextClampsAndDropsRanges() {
        let s = settings(ranges: [.init(minZ: 5, maxZ: 50, settings: ["wall_loops": "4"]),
                                  .init(minZ: 8, maxZ: 3, settings: ["wall_loops": "4"]),
                                  .init(minZ: 0, maxZ: 5, settings: [:]),
                                  .init(minZ: 25, maxZ: 30, settings: ["wall_loops": "4"])])
        let parsed = ModelFileSettings(text: s.userText(partHeight: 20))
        XCTAssertEqual(parsed?.ranges.count, 1)
        XCTAssertEqual(parsed?.ranges.first?.maxZ, 20)
    }

    func testAllowedKeysArePerObjectSettings() {
        XCTAssertTrue(SettingOverrides.allowedKeys.contains("sparse_infill_density"))
        XCTAssertTrue(SettingOverrides.allowedKeys.contains("wall_loops"))
        XCTAssertFalse(SettingOverrides.allowedKeys.contains("skirt_loops"))       // whole print only
        XCTAssertFalse(SettingOverrides.allowedKeys.contains("extruder"))    // Parts & Tools sets it
    }
}
