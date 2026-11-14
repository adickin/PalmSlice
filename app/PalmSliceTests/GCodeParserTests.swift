import XCTest
import simd
@testable import PalmSlice

final class GCodeParserTests: XCTestCase {

    private func writeTempGCode(_ contents: String) -> URL {
        let url = scratchDir()
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
        let url = scratchDir().appendingPathComponent("does-not-exist.gcode")
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
        let url = scratchDir().appendingPathComponent("\(UUID()).gcode")
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

final class GCodeFlavourTests: XCTestCase {
    func testBambuTagsParseLayersAndSummary() {
        let gcode = """
        M83
        ; CHANGE_LAYER
        ; Z_HEIGHT: 0.2
        ; LAYER_HEIGHT: 0.2
        ; FEATURE: Outer wall
        G1 X10 Y10 E0
        G1 X20 Y10 E0.5
        ; CHANGE_LAYER
        ; Z_HEIGHT: 0.4
        ; FEATURE: Sparse infill
        G1 X10 Y10 E0.3
        ; filament used [g] = 2.50
        ; model printing time: 10m 2s; total estimated time: 12m 5s
        """
        let parsed = parseGCode(data: Data(gcode.utf8))
        XCTAssertEqual(parsed.layers.count, 2)
        XCTAssertEqual(parsed.layers[0].z, 0.2, accuracy: 0.0001)
        XCTAssertEqual(parsed.layers[0].moves.map(\.type), [.externalPerimeter])
        XCTAssertEqual(parsed.layers[1].z, 0.4, accuracy: 0.0001)
        XCTAssertEqual(parsed.layers[1].moves.map(\.type), [.infill])
        XCTAssertEqual(parsed.summary.printTime, "12m 5s")
        XCTAssertEqual(parsed.summary.filamentG, [2.5])
    }

    func testCRLFLineEndings() {
        let gcode = ";LAYER_CHANGE\r\n;Z:0.2\r\n;TYPE:Perimeter\r\nG1 X0 Y0\r\nG1 X10 Y0 E1\r\n"
        let parsed = parseGCode(data: Data(gcode.utf8))
        XCTAssertEqual(parsed.layers.count, 1)
        XCTAssertEqual(parsed.layers[0].z, 0.2, accuracy: 0.0001)
        XCTAssertEqual(parsed.layers[0].moves.count, 1)
        XCTAssertEqual(parsed.layers[0].moves[0].to.x, 10, accuracy: 0.0001)
    }

    func testArcsAreTessellated() throws {
        // A G3 (counter-clockwise) half circle from (10,0) to (-10,0) around the origin.
        let gcode = """
        G90
        M83
        ;LAYER_CHANGE
        ;Z:0.2
        ;TYPE:Outer wall
        G1 X10 Y0 Z0.2
        G3 X-10 Y0 I-10 J0 E1
        G1 X-10 Y-5 E0.2
        """
        let layer = try XCTUnwrap(parseGCode(data: Data(gcode.utf8)).layers.first)
        XCTAssertGreaterThan(layer.moves.count, 10, "the arc is split into short segments")
        let arc = layer.moves.dropLast()
        for move in arc {
            XCTAssertEqual(simd_length(SIMD2(move.to.x, move.to.y)), 10, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(move.to.y, -0.001, "G3 from +X to -X goes through +Y")
        }
        XCTAssertEqual(arc.last!.to.x, -10, accuracy: 0.0001)
        // The next straight move starts where the arc ended, not at the stale position.
        XCTAssertEqual(layer.moves.last!.from.x, -10, accuracy: 0.0001)
        XCTAssertEqual(layer.moves.last!.from.y, 0, accuracy: 0.0001)
    }

    func testClockwiseFullCircle() {
        let points = arcPoints(from: SIMD3(5, 0, 0), to: SIMD3(5, 0, 0), centre: SIMD2(0, 0), clockwise: true)
        XCTAssertGreaterThan(points.count, 30)
        XCTAssertLessThan(points[0].y, 0, "G2 from +X heads to -Y first")
        XCTAssertEqual(points.last!.x, 5, accuracy: 0.0001)
    }

    func testAbsoluteExtrusionResetByG92() {
        let gcode = """
        M82
        ;LAYER_CHANGE
        ;Z:0.2
        ;TYPE:Perimeter
        G1 X0 Y0
        G1 X10 Y0 E5
        G92 E0
        G1 X20 Y0 E1
        """
        XCTAssertEqual(parseGCode(data: Data(gcode.utf8)).layers.first?.moves.count, 2)
    }
}
