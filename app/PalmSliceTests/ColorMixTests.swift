import XCTest
@testable import PalmSlice

/// ColorMix (PrusaSlicer "Full Spectrum" virtual extruders) runs on-device.
/// colormix.3mf: two 10 mm cubes on a 5-tool printer, 0.2 mm layers.
/// "blend" is assigned virtual tool 6 (T1:T2 1:1); "gradient" is painted with
/// virtual tool 7 (T3 → T4 over the painted height).
final class ColorMixTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    func testReferenceSliceResolvesMixesToPhysicalTools() throws {
        let file = fixtures.appendingPathComponent("colormix.3mf")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gcode")
        defer { try? FileManager.default.removeItem(at: out) }
        var err = [CChar](repeating: 0, count: 512)
        XCTAssertEqual(slicer_reference_slice_3mf(file.path, out.path, &err, 512), 0, String(cString: err))
        let gcode = try String(contentsOf: out, encoding: .utf8)

        // Only physical tools T0–T4 ever appear; virtual IDs never reach the G-code.
        let toolLines = toolChanges(gcode)
        XCTAssertTrue(toolLines.isSubset(of: ["T0", "T1", "T2", "T3", "T4"]), "\(toolLines)")

        let tools = toolsByLayer(gcode)
        let blend = try XCTUnwrap(tools["blend"])
        let gradient = try XCTUnwrap(tools["gradient"])
        print("COLORMIX blend    \(blend.map(String.init).joined())")
        print("COLORMIX gradient \(gradient.map(String.init).joined())")
        XCTAssertEqual(blend.count, 50)
        XCTAssertEqual(gradient.count, 50)

        // 1:1 blend alternates T0/T1 every layer.
        XCTAssertEqual(Set(blend), [0, 1])
        XCTAssertEqual(zip(blend, blend.dropFirst()).filter { $0 == $1 }.count, 0)

        // Gradient: only T2/T3, mostly T2 in the bottom fifth and mostly T3 in the top fifth.
        XCTAssertEqual(Set(gradient), [2, 3])
        let bottom = gradient.prefix(10), top = gradient.suffix(10)
        XCTAssertGreaterThan(bottom.filter { $0 == 2 }.count, 7)
        XCTAssertGreaterThan(top.filter { $0 == 3 }.count, 7)
    }
}
