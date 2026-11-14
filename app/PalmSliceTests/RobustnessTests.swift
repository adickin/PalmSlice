import XCTest
@testable import PalmSlice

/// A saved profile file that won't decode is set aside, not overwritten.
@MainActor
final class ProfileFileTests: XCTestCase {
    func testUndecodableStoreFileIsKeptAsBackup() throws {
        let dir = scratchDir()
        let file = dir.appendingPathComponent("slice_qualities.json")
        try Data("{ not json".utf8).write(to: file)

        let store = SliceProfileStore(directory: dir, defaults: scratchDefaults())
        store.load(printerPreset: nil)

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("slice_qualities.json.bad-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(backups[0]), encoding: .utf8), "{ not json")
        XCTAssertNotNil(store.storageError, "the user is told")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "defaults saved in its place")
    }

    func testMissingFileIsNotAnError() {
        let store = MaterialProfileStore(directory: scratchDir(), defaults: scratchDefaults())
        store.load(printerPreset: nil)
        XCTAssertNil(store.storageError)
    }

    /// A field added later decodes from a file saved without it.
    func testExtruderDecodesWithMissingFields() throws {
        let json = #"{"nozzleDiameter": 0.6}"#
        let extruder = try JSONDecoder().decode(ExtruderProfile.self, from: Data(json.utf8))
        XCTAssertEqual(extruder.nozzleDiameter, 0.6)
        XCTAssertEqual(extruder.compatibleMaterialDiameters, [1.75])
        XCTAssertEqual(extruder.startGCode, "")
    }
}

/// Cancel at the edges of a slice: before it starts and during export.
final class SliceCancelTests: XCTestCase {
    private func loadedHandle() throws -> SlicerHandle {
        let h = try XCTUnwrap(slicer_create())
        addTeardownBlock { slicer_destroy(h) }
        XCTAssertEqual(slicer_load_stl(h, Fixtures.url("sphere.stl").path), 0, String(cString: slicer_last_error(h)))
        return h
    }

    func testCancelBeforeSliceStartsIsKept() throws {
        let h = try loadedHandle()
        slicer_cancel(h)
        XCTAssertEqual(slicer_slice(h, 0.3, 10), -2)
        XCTAssertEqual(String(cString: slicer_last_error(h)), "canceled")
    }

    func testCancelAttachedLaterStillCancels() throws {
        let h = try loadedHandle()
        let slice = ActiveSlice()
        slice.begin()
        slice.cancel()          // tapped before the context existed
        slice.attach(h)
        XCTAssertEqual(slicer_slice(h, 0.3, 10), -2)
    }

    func testCancelDuringExportReportsCanceled() throws {
        let h = try loadedHandle()
        XCTAssertEqual(slicer_slice(h, 0.3, 10), 0, String(cString: slicer_last_error(h)))
        slicer_cancel(h)
        let out = scratchDir().appendingPathComponent("out.gcode")
        XCTAssertEqual(slicer_export_gcode(h, out.path), -2)
        XCTAssertEqual(String(cString: slicer_last_error(h)), "canceled")
    }
}

final class EdgeCaseTests: XCTestCase {
    private let bed: [SIMD2<Float>] = [SIMD2(-50, -50), SIMD2(50, -50), SIMD2(50, 50), SIMD2(-50, 50)]

    func testArrangeWithEmptyOutlineDoesNotTrap() {
        XCTAssertEqual(PlateArrange.place([[]], around: [[]], bed: bed).count, 1)
        XCTAssertNil(PlateArrange.place([[]], around: [], bed: bed)[0])
    }

    func testStandInColourForToolZero() {
        XCTAssertEqual(HexColour.standIn(forTool: 0, avoiding: []), HexColour.toolStandIns.last)
        XCTAssertEqual(HexColour.standIn(forTool: 1, avoiding: []), HexColour.toolStandIns.first)
    }

    func testExportFileNameIsSanitised() {
        XCTAssertEqual(ContentView.safeFileName("a/b:c\nd"), "a_b_c_d")
        XCTAssertEqual(ContentView.safeFileName("../../x"), "_.._x")
        XCTAssertEqual(ContentView.safeFileName("  "), "model")
    }

    func testPrintStatsJSONSurvivesLongColour() throws {
        // Covered through the bridge: a slice's stats always parse as JSON.
        let h = try XCTUnwrap(slicer_create())
        defer { slicer_destroy(h) }
        let colour = "#" + String(repeating: "A", count: 2000)
        XCTAssertEqual(slicer_apply_settings(h, "filament_colour = \"\(colour)\"\n"), 0, String(cString: slicer_last_error(h)))
        XCTAssertEqual(slicer_load_stl(h, Fixtures.url("sphere.stl").path), 0)
        XCTAssertEqual(slicer_slice(h, 0.3, 10), 0, String(cString: slicer_last_error(h)))
        let out = scratchDir().appendingPathComponent("out.gcode")
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
        let json = String(cString: slicer_print_stats(h))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)))
        XCTAssertNotNil(SliceStats(json: json))
    }
}

/// The app always renders printer thumbnails; the project 3MF must still save.
final class ProjectExportTests: XCTestCase {
    func testProjectSavesWithPrinterThumbnails() throws {
        let h = try XCTUnwrap(slicer_create())
        defer { slicer_destroy(h) }
        XCTAssertEqual(slicer_enable_thumbnails(h, 1), 0)
        XCTAssertEqual(slicer_load_stl(h, Fixtures.url("sphere.stl").path), 0)
        XCTAssertEqual(slicer_slice(h, 0.3, 10), 0, String(cString: slicer_last_error(h)))
        slicer_set_thumbnail(h, 16, 16, [UInt8](repeating: 128, count: 16 * 16 * 4))
        let dir = scratchDir()
        XCTAssertEqual(slicer_export_gcode(h, dir.appendingPathComponent("a.gcode").path), 0)
        XCTAssertEqual(slicer_export_project_3mf(h, dir.appendingPathComponent("a.3mf").path), 0,
                       String(cString: slicer_last_error(h)))
    }
}
