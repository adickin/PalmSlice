import XCTest
@testable import PalmSlice

/// Files saved on Windows end lines with "\r\n", which Swift treats as one Character.
final class LineEndingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = scratchDir().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCRLFAsciiSTLLoads() throws {
        let stl = [
            "solid tri",
            "  facet normal 0 0 1",
            "    outer loop",
            "      vertex 0 0 0",
            "      vertex 10 0 0",
            "      vertex 0 20\t5",
            "    endloop",
            "  endfacet",
            "endsolid tri",
            // Padding so the file is longer than a binary STL header.
            String(repeating: " ", count: 100),
        ].joined(separator: "\r\n")
        let url = dir.appendingPathComponent("crlf.stl")
        try Data(stl.utf8).write(to: url)
        let info = try parseSTLMeshInfo(url: url)
        XCTAssertEqual(info.faces.count, 1)
        XCTAssertEqual(info.sizeMM, SIMD3(10, 20, 5))
    }

    func testCRLFIniHasEveryKey() {
        let ini = "# exported\r\nlayer_height = 0.2\r\nwall_loops = 3\r\n\r\n[filament:PLA]\r\nnozzle_temperature = 210\r\n"
        let sections = ProfileIni.sections(ini)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].settings, ["layer_height": "0.2", "wall_loops": "3"])
        XCTAssertEqual(sections[1].type, "filament")
        XCTAssertEqual(sections[1].name, "PLA")
        XCTAssertEqual(sections[1].settings, ["nozzle_temperature": "210"])
        XCTAssertEqual(SettingsText.parse(ini)["wall_loops"], "3")
    }

    func testSettingsDecodeFallsBackFromUTF8() {
        let latin1 = Data("filament_settings_id = Caf\u{e9}\n".data(using: .isoLatin1)!)
        XCTAssertEqual(SettingsText.decode(latin1).map(SettingsText.parse)?["filament_settings_id"], "Caf\u{e9}")
        let utf16 = "layer_height = 0.3\r\n".data(using: .utf16)!   // with BOM
        XCTAssertEqual(SettingsText.decode(utf16).map(SettingsText.parse)?["layer_height"], "0.3")
    }
}

final class MeshSizeTests: XCTestCase {
    /// The size fields pair each scale axis with the mesh size on the same axis:
    /// x width, y depth, z height (bug: Y and Z were swapped).
    func testSizeMMMatchesScaleAxes() {
        let info = STLMeshInfo(faces: [], vertices: [],
                               boundingBoxMM: (min: SIMD3(0, 0, 0), max: SIMD3(10, 20, 30)))
        XCTAssertEqual(info.sizeMM, SIMD3(info.sizeMMX, info.sizeMMY, info.sizeMMZ))
        XCTAssertEqual(info.sizeMM.y, 20, "depth")
        XCTAssertEqual(info.sizeMM.z, 30, "height")
        var t = ModelTransform()
        t.scale.z = 2
        XCTAssertEqual(info.sizeMM * t.scale, SIMD3(10, 20, 60), "doubling scale.z doubles the height")
    }
}
