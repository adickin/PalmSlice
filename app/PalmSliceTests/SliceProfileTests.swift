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
        try SliceSetup.apply(profile, label: "Slice profile", to: h)
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

/// PalmSlice profiles ↔ PrusaSlicer settings.
final class ProfileSettingsTests: XCTestCase {

    private let ender = "Creality Ender-3 S1 (0.4 mm nozzle)"

    // Every built-in profile's settings must be accepted by libslic3r, and
    // read back into an identical profile.
    func testBuiltInProfilesRoundTripThroughLibslic3r() throws {
        func roundTrip<P: PrusaSettingsConvertible>(_ profile: P, empty: P) throws -> P {
            guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
            defer { slicer_destroy(h) }
            try SliceSetup.apply(profile, label: "profile", to: h)
            var readBack: [String: String] = [:]
            for key in profile.prusaSettings().keys {
                readBack[key] = slicer_get_setting(h, key).map { String(cString: $0) }
            }
            var copy = empty
            copy.update(fromPrusa: readBack)
            return copy
        }
        for p in BuiltInSliceProfiles.all {
            let copy = try roundTrip(p, empty: SliceProfile())
            XCTAssertEqual(copy.typedPrusaSettings(), p.typedPrusaSettings(), p.name)
        }
        for p in BuiltInMaterialProfiles.all {
            let copy = try roundTrip(p, empty: MaterialProfile())
            XCTAssertEqual(copy.typedPrusaSettings(), p.typedPrusaSettings(), p.name)
        }
        for p in BuiltInProfiles.all {
            let copy = try roundTrip(p, empty: PrinterProfile())
            XCTAssertEqual(copy.typedPrusaSettings(), p.typedPrusaSettings(), p.name)
        }
    }

    // Importing a PrusaSlicer preset into a PalmSlice profile is lossless:
    // slicing with the imported profile on top of a *different* preset of the
    // same type gives the same G-code as slicing with the original preset.
    func testImportedPrintPresetSlicesIdentically() throws {
        let base = try XCTUnwrap(PresetLibrary.base(printerPreset: ender, filamentType: "PLA"))
        let other = try XCTUnwrap(PresetLibrary.names(.print).first {
            $0 != base.print && PresetLibrary.isCompatible(.print, $0, printer: ender)
        })
        var imported = SliceProfile()
        imported.importPrusaSettings(try XCTUnwrap(PresetLibrary.settings(.print, base.print)))
        var otherBase = base
        otherBase.print = other
        try assertSameGCode(base: base, otherBase: otherBase, imported: imported, what: base.print)
    }

    func testImportedFilamentPresetSlicesIdentically() throws {
        let base = try XCTUnwrap(PresetLibrary.base(printerPreset: ender, filamentType: "PLA"))
        let other = try XCTUnwrap(PresetLibrary.base(printerPreset: ender, filamentType: "PETG")).filament
        XCTAssertNotEqual(other, base.filament)
        var imported = MaterialProfile()
        imported.importPrusaSettings(try XCTUnwrap(PresetLibrary.settings(.filament, base.filament)))
        var otherBase = base
        otherBase.filament = other
        try assertSameGCode(base: base, otherBase: otherBase, imported: imported, what: base.filament)
    }

    func testImportedPrinterPresetSlicesIdentically() throws {
        let base = try XCTUnwrap(PresetLibrary.base(printerPreset: ender, filamentType: "PLA"))
        var imported = PrinterProfile()
        imported.importPrusaSettings(try XCTUnwrap(PresetLibrary.settings(.printer, ender)))
        var otherBase = base
        otherBase.printer = "Creality Ender-3 V2 (0.4 mm nozzle)"
        try assertSameGCode(base: base, otherBase: otherBase, imported: imported, what: ender)
    }

    private func assertSameGCode<P: PrusaSettingsConvertible>(base: PresetBase, otherBase: PresetBase,
                                                               imported: P, what: String) throws {
        let a = strip(try sliceSphere(base: base, apply: { _ in }))
        let b = strip(try sliceSphere(base: otherBase, apply: {
            try SliceSetup.apply(imported, label: "imported", to: $0)
        }))
        var diffs: [String] = []
        for i in 0..<max(a.count, b.count) where diffs.count < 20 {
            let x = i < a.count ? a[i] : "<none>", y = i < b.count ? b[i] : "<none>"
            if x != y { diffs.append("line \(i): direct=\(x) | imported=\(y)") }
        }
        XCTAssertTrue(diffs.isEmpty, "imported \(what) slices differently "
                      + "(\(a.count) vs \(b.count) lines):\n" + diffs.joined(separator: "\n"))
    }

    private func sliceSphere(base: PresetBase, apply: (SlicerHandle) throws -> Void) throws -> String {
        let stl = "/Users/adickin/ios-sources/PrusaSlicer/resources/shapes/sphere.stl"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: stl))
        guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
        defer { slicer_destroy(h) }
        XCTAssertTrue(PresetLibrary.apply(base, to: h), String(cString: slicer_last_error(h)))
        try apply(h)
        XCTAssertEqual(slicer_load_stl(h, stl), 0, String(cString: slicer_last_error(h)))
        XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID()).gcode")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
        return try String(contentsOf: out, encoding: .utf8)
    }

    /// Drops lines that legitimately differ: the timestamp and preset names.
    private func strip(_ gcode: String) -> [String] {
        gcode.split(separator: "\n").map(String.init).filter {
            !$0.hasPrefix("; generated by") && !$0.hasPrefix("; print_settings_id")
                && !$0.hasPrefix("; filament_settings_id") && !$0.hasPrefix("; printer_settings_id")
        }
    }

    func testValueEncoding() {
        XCTAssertEqual(PrusaValue.float(0.2), "0.2")
        XCTAssertEqual(PrusaValue.float(45), "45")
        XCTAssertEqual(PrusaValue.percent(15), "15%")
        XCTAssertEqual(PrusaValue.string("G28\nG1 X0\\"), "G28\\nG1 X0\\\\")
        XCTAssertEqual(PrusaValue.parseString("G28\\nG1 X0\\\\"), "G28\nG1 X0\\")
        XCTAssertEqual(PrusaValue.strings(["PLA"]), "PLA")
        XCTAssertEqual(PrusaValue.strings(["Generic PLA"]), "\"Generic PLA\"")
        XCTAssertEqual(SettingsText.splitStrings("\"a b\";\"c\""), ["a b", "c"])
        XCTAssertEqual(SettingsText.splitStrings("PLA;PETG"), ["PLA", "PETG"])
    }
}
