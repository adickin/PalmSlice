import XCTest
@testable import PalmSlice

final class SliceProfileTests: XCTestCase {

    // A profile saved before the Advanced settings existed must still decode,
    // keeping its values and taking PrusaSlicer's defaults for the new keys.
    func testDecodesProfileSavedBeforeAdvancedSettings() throws {
        var original = BuiltInSliceProfiles.standard
        original.wallCount = 5
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        for key in ["wallGenerator", "externalPerimetersFirst", "slicingMode",
                    "gapClosingRadius", "extrusionWidth", "firstLayerExtrusionWidth"] {
            XCTAssertNotNil(json.removeValue(forKey: key), key)
        }
        let decoded = try JSONDecoder().decode(SliceProfile.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.wallCount, 5)
        XCTAssertEqual(decoded.wallGenerator, .arachne)
        XCTAssertFalse(decoded.externalPerimetersFirst)
        XCTAssertEqual(decoded.slicingMode, .regular)
        XCTAssertEqual(decoded.gapClosingRadius, 0.049)
        XCTAssertEqual(decoded.extrusionWidth, 0)
    }

    // Two nested cubes in one STL, like the overlapping shells 3DLabPrint
    // models use. Regular slicing fills the inner cube in (one outer wall
    // only); Even/Odd treats it as a hole, adding an inner wall loop.
    func testRCPlaneProfileUsesEvenOddAndClassicWalls() throws {
        let stl = FileManager.default.temporaryDirectory.appendingPathComponent("nested_cubes.stl")
        try nestedCubesSTL().write(to: stl, atomically: true, encoding: .utf8)

        let evenOdd = try slice(stl, with: BuiltInSliceProfiles.rcPlane)
        var regularProfile = BuiltInSliceProfiles.rcPlane
        regularProfile.slicingMode = .regular
        let regular = try slice(stl, with: regularProfile)

        XCTAssertTrue(evenOdd.contains("; slicing_mode = even_odd"), "slicing_mode not applied")
        XCTAssertTrue(evenOdd.contains("; perimeter_generator = classic"), "perimeter_generator not applied")
        XCTAssertTrue(evenOdd.contains("; external_perimeters_first = 1"))
        XCTAssertTrue(evenOdd.contains("; slice_closing_radius = 0\n"))
        XCTAssertTrue(evenOdd.contains("; extrusion_width = 0.42\n"))

        let evenOddMM = try XCTUnwrap(filamentUsedMM(evenOdd))
        let regularMM = try XCTUnwrap(filamentUsedMM(regular))
        // Inner loop is half the outer loop's perimeter, so expect ~1.5x.
        XCTAssertGreaterThan(evenOddMM, regularMM * 1.3,
                             "even/odd \(evenOddMM) mm vs regular \(regularMM) mm")
    }

    // MARK: - Helpers

    private func slice(_ stl: URL, with profile: SliceProfile) throws -> String {
        guard let h = slicer_create() else { throw XCTSkip("slicer_create failed") }
        defer { slicer_destroy(h) }
        var cfg = profile.bridgeConfig()
        XCTAssertEqual(slicer_apply_slice_config(h, &cfg), 0, String(cString: slicer_last_error(h)))
        XCTAssertEqual(slicer_load_stl(h, stl.path), 0, String(cString: slicer_last_error(h)))
        XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(profile.slicingMode.bridgeInt).gcode")
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
        return try String(contentsOf: out, encoding: .utf8)
    }

    private func filamentUsedMM(_ gcode: String) -> Double? {
        guard let line = gcode.split(separator: "\n").first(where: { $0.hasPrefix("; filament used [mm] =") })
        else { return nil }
        return Double(line.split(separator: "=").last!.trimmingCharacters(in: .whitespaces))
    }

    private func nestedCubesSTL() -> String {
        var out = "solid nested\n"
        for (lo, hi) in [(0.0, 20.0), (5.0, 15.0)] {
            out += cubeFacets(lo: lo, hi: hi, z: 10)
        }
        return out + "endsolid nested\n"
    }

    // Outward-facing triangles of an axis-aligned box, lo...hi in X/Y, 0...z in Z.
    private func cubeFacets(lo: Double, hi: Double, z: Double) -> String {
        let v = [(lo, lo, 0.0), (hi, lo, 0.0), (hi, hi, 0.0), (lo, hi, 0.0),
                 (lo, lo, z), (hi, lo, z), (hi, hi, z), (lo, hi, z)]
        let quads = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
                     [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]
        var s = ""
        for q in quads {
            for tri in [[q[0], q[1], q[2]], [q[0], q[2], q[3]]] {
                s += "facet normal 0 0 0\nouter loop\n"
                for i in tri { s += "vertex \(v[i].0) \(v[i].1) \(v[i].2)\n" }
                s += "endloop\nendfacet\n"
            }
        }
        return s
    }
}
