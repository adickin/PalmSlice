import XCTest
@testable import PalmSlice

final class GCodeParserTests: XCTestCase {

    private func writeTempGCode(_ contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".gcode")
        try! contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testParsesLayersAndExtrusionTypes() throws {
        let gcode = """
        M83
        G90
        ;LAYER_CHANGE
        ;Z:0.2
        ;TYPE:Perimeter
        G1 X10 Y10 E0
        G1 X20 Y10 E0.5
        G1 X20 Y20 E0.5
        ;LAYER_CHANGE
        ;Z:0.4
        ;TYPE:Infill
        G1 X10 Y10 E0.3
        G1 X15 Y15 E0.2
        """
        let url = writeTempGCode(gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let layers = parseGCode(url: url)

        XCTAssertEqual(layers.count, 2)

        XCTAssertEqual(layers[0].z, 0.2, accuracy: 0.0001)
        XCTAssertEqual(layers[0].moves.count, 2)
        XCTAssertTrue(layers[0].moves.allSatisfy { $0.type == .perimeter })

        XCTAssertEqual(layers[1].z, 0.4, accuracy: 0.0001)
        XCTAssertEqual(layers[1].moves.count, 2)
        XCTAssertTrue(layers[1].moves.allSatisfy { $0.type == .infill })
    }

    func testTravelMovesWithoutExtrusionAreExcluded() throws {
        // The very first move of a layer (E0, no material laid down) must not
        // appear in the parsed moves — only actual extrusion is visualised.
        let gcode = """
        ;LAYER_CHANGE
        ;Z:0.2
        ;TYPE:Perimeter
        G1 X10 Y10 E0
        """
        let url = writeTempGCode(gcode)
        defer { try? FileManager.default.removeItem(at: url) }

        let layers = parseGCode(url: url)
        XCTAssertTrue(layers.isEmpty, "a layer with only a non-extruding move should produce no layer")
    }

    func testEmptyFileProducesNoLayers() throws {
        let url = writeTempGCode("")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(parseGCode(url: url).isEmpty)
    }

    func testMissingFileProducesNoLayers() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist.gcode")
        XCTAssertTrue(parseGCode(url: url).isEmpty)
    }
}

final class GCodeToolTests: XCTestCase {
    private let gcode = """
    T0
    ;LAYER_CHANGE
    ;Z:0.2
    ;TYPE:External perimeter
    G1 X10 Y10 E1
    G1 X20 Y10 E1
    T1 S1 L0 D0
    ;TYPE:Wipe tower
    G1 X30 Y10 E1
    ;TYPE:Perimeter
    G1 X40 Y10 E1
    ;LAYER_CHANGE
    ;Z:0.4
    T0
    G1 X50 Y10 E1
    ; filament used [g] = 1.50, 0.25
    ; estimated printing time (normal mode) = 1m 2s
    """

    func testMovesCarryTheirTool() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gcode")
        try gcode.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let layers = parseGCode(url: url)
        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(layers[0].moves.map(\.tool), [0, 0, 1, 1])
        XCTAssertEqual(layers[0].moves.map(\.type), [.externalPerimeter, .externalPerimeter, .wipeTower, .perimeter])
        XCTAssertEqual(layers[1].moves.map(\.tool), [0])
    }

    func testSummaryCountsToolChangesAndFilamentPerTool() {
        let summary = GCodeSummary(text: gcode)
        XCTAssertEqual(summary.toolChanges, 2)
        XCTAssertEqual(summary.filamentG, [1.5, 0.25])
        XCTAssertEqual(summary.printTime, "1m 2s")
        XCTAssertEqual(summary.filamentText, "1.75 g (T1 1.50 · T2 0.25)")
    }
}
