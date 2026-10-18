import XCTest
@testable import PalmSlice

/// Converts 3MF / AMF / OBJ files to per-object STLs via the bridge and slices the result.
final class ModelImporterTests: XCTestCase {

    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    private func outputDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("import-test-" + UUID().uuidString)
    }

    /// two_objects.3mf: a 20×20×40 "Tower" at (70, 120) and a 60×15×10 "Bar"
    /// rotated 90° about Z, centred at (142.5, 140). Overall bounds centre: (105, 140).
    func testThreeMFKeepsNamesRotationAndLayout() throws {
        let objects = try convertModelFile(at: fixtures.appendingPathComponent("two_objects.3mf"),
                                           outputDir: outputDir())
        XCTAssertEqual(objects.map(\.name), ["Tower", "Bar"])

        XCTAssertEqual(objects[0].offsetMM.x, -35, accuracy: 0.01)
        XCTAssertEqual(objects[0].offsetMM.y, -20, accuracy: 0.01)
        XCTAssertEqual(objects[1].offsetMM.x, 37.5, accuracy: 0.01)
        XCTAssertEqual(objects[1].offsetMM.y, 0, accuracy: 0.01)

        let bar = try parseSTLMeshInfo(url: objects[1].url)
        XCTAssertEqual(bar.sizeMMX, 15, accuracy: 0.01)
        XCTAssertEqual(bar.sizeMMY, 60, accuracy: 0.01)
        XCTAssertEqual(bar.sizeMMZ, 10, accuracy: 0.01)
    }

    func testAMFConverts() throws {
        let objects = try convertModelFile(at: fixtures.appendingPathComponent("block.amf"),
                                           outputDir: outputDir())
        XCTAssertEqual(objects.count, 1)
        let info = try parseSTLMeshInfo(url: objects[0].url)
        XCTAssertEqual(info.sizeMMX, 40, accuracy: 0.01)
        XCTAssertEqual(info.sizeMMY, 25, accuracy: 0.01)
        XCTAssertEqual(info.sizeMMZ, 15, accuracy: 0.01)
    }

    func testOBJConverts() throws {
        let obj = "/Users/adickin/ios-sources/PrusaSlicer/tests/data/20mm_cube.obj"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: obj), "sample OBJ not available")
        let objects = try convertModelFile(at: URL(fileURLWithPath: obj), outputDir: outputDir())
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(try parseSTLMeshInfo(url: objects[0].url).sizeMMZ, 20, accuracy: 0.01)
    }

    func testCorruptFileReportsError() throws {
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("broken.3mf")
        try Data("not a zip".utf8).write(to: bad)
        XCTAssertThrowsError(try convertModelFile(at: bad, outputDir: outputDir()))
    }

    /// The PrusaSlicer project file carries its own print config; it should be ignored
    /// and the geometry should still convert and slice.
    func testConvertedThreeMFSlices() throws {
        var files = [fixtures.appendingPathComponent("two_objects.3mf")]
        let prusa = URL(fileURLWithPath: "/Users/adickin/ios-sources/PrusaSlicer/tests/data/seam_test_object.3mf")
        if FileManager.default.fileExists(atPath: prusa.path) { files.append(prusa) }

        for file in files {
            let objects = try convertModelFile(at: file, outputDir: outputDir())
            XCTAssertFalse(objects.isEmpty, file.lastPathComponent)

            guard let h = slicer_create() else { XCTFail("slicer_create"); return }
            defer { slicer_destroy(h) }
            for (i, object) in objects.enumerated() {
                let idx = slicer_add_stl(h, object.url.path)
                XCTAssertGreaterThanOrEqual(idx, 0, String(cString: slicer_last_error(h)))
                var t = SlicerModelTransform()
                t.pos_x_mm = object.offsetMM.x
                t.pos_z_mm = -object.offsetMM.y
                t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
                XCTAssertEqual(slicer_set_object_transform(h, Int32(i), &t), 0,
                               String(cString: slicer_last_error(h)))
            }
            XCTAssertEqual(slicer_slice(h, 0.2, 15), 0,
                           "\(file.lastPathComponent): \(String(cString: slicer_last_error(h)))")
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("import-test.gcode")
            XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
            let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            XCTAssertGreaterThan(size, 1000)
            print("IMPORT-SLICE-OK \(file.lastPathComponent) objects=\(objects.count) gcode=\(size)B")
        }
    }
}
