import XCTest
import simd
@testable import PalmSlice

/// An object prints where it's shown: centred on its printable parts, not on
/// modifiers that reach past them.
final class ModifierCentreTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// modifier_offset.3mf: a 180 × 229 mm box with two infill modifiers past
    /// its +X side (their centre is 8.7 mm right of, and 1.3 mm in front of, the box's).
    func testModifiersDontMoveTheObject() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let object = try XCTUnwrap(importModelFile(at: fixtures.appendingPathComponent("modifier_offset.3mf"),
                                                   outputDir: dir).objects.first)
        XCTAssertEqual(object.parts.map(\.kind), [.part, .modifier, .modifier])
        let printer = try XCTUnwrap(BuiltInProfiles.all.first { $0.builtInKey == "snapmaker-u1" })
        guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
        defer { slicer_destroy(h) }
        try SliceSetup.configure(h, printer: printer, material: BuiltInMaterialProfiles.pla,
                                 slice: SliceProfile(), toolMaterials: [])
        let idx = slicer_add_model_object(h, try XCTUnwrap(object.nativeURL).path, 1)
        XCTAssertGreaterThanOrEqual(idx, 0, String(cString: slicer_last_error(h)))
        var t = SlicerModelTransform()
        t.pos_x_mm = 13.03; t.pos_z_mm = 7.69
        t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
        XCTAssertEqual(slicer_set_object_transform(h, idx, &t), 0)
        XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gcode")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))

        // The outer wall's extent, from the G-code.
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        var wall = false
        for line in try String(contentsOf: out, encoding: .utf8).split(separator: "\n") {
            if line.hasPrefix(";TYPE:") { wall = line == ";TYPE:Outer wall" }
            guard wall, line.hasPrefix("G1 "), line.contains(" E") else { continue }
            var x: Double?, y: Double?
            for w in line.split(separator: " ") {
                if w.first == "X" { x = Double(w.dropFirst()) }
                if w.first == "Y" { y = Double(w.dropFirst()) }
            }
            if let x, let y { lo = simd_min(lo, [x, y]); hi = simd_max(hi, [x, y]) }
        }
        let centre = (lo + hi) / 2
        XCTAssertEqual(centre.x, printer.bedX / 2 + 13.03, accuracy: 0.3)
        XCTAssertEqual(centre.y, printer.bedY / 2 - 7.69, accuracy: 0.3)
    }
}
