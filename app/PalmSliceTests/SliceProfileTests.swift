import XCTest
@testable import PalmSlice

final class SliceProfileTests: XCTestCase {

    // A profile saved before the Advanced settings existed must still decode,
    // keeping its values and taking the defaults for the new keys.
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
        regularProfile.extraSettings["slicing_mode"] = "regular"
        let regular = try slice(stl, with: regularProfile)

        XCTAssertTrue(evenOdd.contains("; slicing_mode = even_odd"), "slicing_mode not applied")
        XCTAssertTrue(evenOdd.contains("; wall_generator = classic"), "wall_generator not applied")
        XCTAssertTrue(evenOdd.contains("; wall_sequence = outer wall/inner wall"))
        XCTAssertTrue(evenOdd.contains("; slice_closing_radius = 0\n"))
        XCTAssertTrue(evenOdd.contains("; line_width = 0.42\n"))

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

/// PalmSlice profiles ↔ OrcaSlicer settings.
final class ProfileSettingsTests: XCTestCase {

    private let ender = "Creality Ender-3 S1 0.4 nozzle"

    // Every built-in profile's settings must be accepted by libslic3r, and
    // read back into an identical profile.
    func testBuiltInProfilesRoundTripThroughLibslic3r() throws {
        func roundTrip<P: SlicerSettingsConvertible>(_ profile: P, empty: P) throws -> P {
            guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
            defer { slicer_destroy(h) }
            try SliceSetup.apply(profile, label: "profile", to: h)
            var readBack: [String: String] = [:]
            for key in profile.slicerSettings().keys {
                readBack[key] = slicer_get_setting(h, key).map { String(cString: $0) }
            }
            var copy = empty
            copy.update(from: readBack)
            return copy
        }
        // The built-ins hold only their changes: resolved over a base first.
        for changes in BuiltInSliceProfiles.all {
            let p = SliceSetup.resolved(changes, base: PresetLibrary.base(
                printerPreset: nil, layerHeight: changes.ownLayerHeight, filamentType: "PLA"))
            let copy = try roundTrip(p, empty: SliceProfile())
            XCTAssertEqual(copy.typedSlicerSettings(), p.typedSlicerSettings(), p.name)
        }
        for changes in BuiltInMaterialProfiles.all {
            let p = SliceSetup.resolved(changes, filament: PresetLibrary.base(
                printerPreset: nil, filamentType: changes.ownFilamentType)?.filament)
            let copy = try roundTrip(p, empty: MaterialProfile())
            XCTAssertEqual(copy.typedSlicerSettings(), p.typedSlicerSettings(), p.name)
        }
        for p in BuiltInProfiles.all {
            let copy = try roundTrip(p, empty: PrinterProfile())
            XCTAssertEqual(copy.typedSlicerSettings(), p.typedSlicerSettings(), p.name)
        }
    }

    // Importing an OrcaSlicer preset into a PalmSlice profile is lossless:
    // slicing with the imported profile on top of a *different* preset of the
    // same type gives the same G-code as slicing with the original preset.
    func testImportedPrintPresetSlicesIdentically() throws {
        let base = try XCTUnwrap(PresetLibrary.base(printerPreset: ender, filamentType: "PLA"))
        let other = try XCTUnwrap(PresetLibrary.names(.print).first {
            $0 != base.print && PresetLibrary.isCompatible(.print, $0, printer: ender)
        })
        var imported = SliceProfile()
        imported.importSlicerSettings(try XCTUnwrap(PresetLibrary.settings(.print, base.print)))
        var otherBase = base
        otherBase.print = other
        try assertSameGCode(base: base, otherBase: otherBase, imported: imported, what: base.print)
    }

    func testImportedFilamentPresetSlicesIdentically() throws {
        let base = try XCTUnwrap(PresetLibrary.base(printerPreset: ender, filamentType: "PLA"))
        let other = try XCTUnwrap(PresetLibrary.base(printerPreset: ender, filamentType: "PETG")).filament
        XCTAssertNotEqual(other, base.filament)
        var imported = MaterialProfile()
        imported.importSlicerSettings(try XCTUnwrap(PresetLibrary.settings(.filament, base.filament)))
        var otherBase = base
        otherBase.filament = other
        try assertSameGCode(base: base, otherBase: otherBase, imported: imported, what: base.filament)
    }

    func testImportedPrinterPresetSlicesIdentically() throws {
        let base = try XCTUnwrap(PresetLibrary.base(printerPreset: ender, filamentType: "PLA"))
        var imported = PrinterProfile()
        imported.importSlicerSettings(try XCTUnwrap(PresetLibrary.settings(.printer, ender)))
        var otherBase = base
        otherBase.printer = "Creality Ender-3 V2 0.4 nozzle"
        try assertSameGCode(base: base, otherBase: otherBase, imported: imported, what: ender)
    }

    private func assertSameGCode<P: SlicerSettingsConvertible>(base: PresetBase, otherBase: PresetBase,
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

    /// Drops lines that legitimately differ: the timestamp, preset names,
    /// object label ids (OrcaSlicer numbers objects process-wide) and the
    /// filament colour (OrcaSlicer's presets have none; PalmSlice's do).
    private func strip(_ gcode: String) -> [String] {
        gcode.split(separator: "\n").map(String.init).filter {
            !$0.hasPrefix("; generated by") && !$0.hasPrefix("; print_settings_id")
                && !$0.hasPrefix("; filament_colour") && !$0.hasPrefix("; extruder_colour")
                && !$0.hasPrefix("; filament_settings_id") && !$0.hasPrefix("; printer_settings_id")
                && !$0.contains("label id") && !$0.contains("printing object") && !$0.hasPrefix("M486")
                && !$0.contains("EXCLUDE_OBJECT")
        }
    }

    func testValueEncoding() {
        XCTAssertEqual(SlicerValue.float(0.2), "0.2")
        XCTAssertEqual(SlicerValue.float(45), "45")
        XCTAssertEqual(SlicerValue.percent(15), "15%")
        XCTAssertEqual(SlicerValue.string("G28\nG1 X0\\"), "G28\\nG1 X0\\\\")
        XCTAssertEqual(SlicerValue.parseString("G28\\nG1 X0\\\\"), "G28\nG1 X0\\")
        XCTAssertEqual(SlicerValue.strings(["PLA"]), "PLA")
        XCTAssertEqual(SlicerValue.strings(["Generic PLA"]), "\"Generic PLA\"")
        XCTAssertEqual(SettingsText.splitStrings("\"a b\";\"c\""), ["a b", "c"])
        XCTAssertEqual(SettingsText.splitStrings("PLA;PETG"), ["PLA", "PETG"])
    }
}

final class AllSettingsTests: XCTestCase {
    // Every key in the vendor presets has a description for the All Settings list.
    func testEveryPresetKeyHasSettingInfo() {
        for type in [PresetType.print, .filament, .printer] {
            let keys = SlicerKeys.keys(for: type)
            XCTAssertGreaterThan(keys.count, 30, "\(type)")
            let missing = keys.filter { SettingInfo.cached($0) == nil }
            XCTAssertTrue(missing.isEmpty, "no info for \(missing.sorted())")
        }
        let info = SettingInfo.cached("sparse_infill_pattern")!
        XCTAssertEqual(info.kind, .enum_)
        XCTAssertTrue(info.enumValues.contains("gyroid"))
        XCTAssertTrue(SettingInfo.cached("machine_start_gcode")!.isMultiline)
    }

    // Typed keys go to their field; others to extraSettings; editing the field
    // clears a verbatim override.
    func testSetSlicerSettingRouting() {
        var p = SliceProfile()
        p.setSlicerSetting("wall_loops", "5")
        XCTAssertEqual(p.wallCount, 5)
        XCTAssertNil(p.extraSettings["wall_loops"])
        p.setSlicerSetting("seam_position", "back")
        XCTAssertEqual(p.extraSettings["seam_position"], "back")
        p.setSlicerSetting("initial_layer_print_height", "50%")
        XCTAssertEqual(p.slicerSettings()["initial_layer_print_height"], "50%")
        p.firstLayerHeight = 0.25
        XCTAssertEqual(p.slicerSettings()["initial_layer_print_height"], "0.25")
    }
}

final class ProfileIniTests: XCTestCase {
    private let creality = "0.16mm Optimal @Creality Ender3S1"

    // A PrusaSlicer config bundle: presets inherit from a system preset or
    // from each other; abstract "*parent*" sections aren't imported. Its
    // PrusaSlicer keys (perimeters, fill_density, temperature) are renamed.
    func testBundleResolvesInheritance() throws {
        let text = """
        [print:*shared*]
        seam_position = rear
        [print:My LW]
        inherits = \(creality)
        perimeters = 1
        [print:My LW sparse]
        inherits = My LW
        fill_density = 0%
        [filament:Some filament]
        temperature = 240
        """
        let prints = ProfileIni.profiles(SliceProfile.self, from: text, fileName: "bundle.ini")
        XCTAssertEqual(prints.map(\.name), ["My LW", "My LW sparse"])
        XCTAssertEqual(prints[0].basePreset, creality)
        XCTAssertEqual(prints[0].wallCount, 1)
        XCTAssertEqual(prints[1].basePreset, creality)
        XCTAssertEqual(prints[1].wallCount, 1)
        XCTAssertEqual(prints[1].infillDensity, 0)
        // The system preset's values are carried in, e.g. its layer height.
        let preset = try XCTUnwrap(PresetLibrary.settings(.print, creality))
        XCTAssertEqual(SlicerValue.float(prints[0].layerHeight), preset["layer_height"])

        let materials = ProfileIni.profiles(MaterialProfile.self, from: text, fileName: "bundle.ini")
        XCTAssertEqual(materials.map(\.name), ["Some filament"])
        XCTAssertEqual(materials[0].otherLayersTemp, 240)
    }

    // A flat exported config: named after its *_settings_id.
    func testFlatConfig() {
        let text = """
        # generated by PrusaSlicer
        layer_height = 0.3
        perimeters = 1
        temperature = 245
        print_settings_id = 0.3 mm 3DLabPrint
        filament_settings_id = "3DLabPrint PolyLight 1.0 LW-PLA"
        """
        let print = ProfileIni.profiles(SliceProfile.self, from: text, fileName: "config.ini")
        XCTAssertEqual(print.first?.name, "0.3 mm 3DLabPrint")
        XCTAssertEqual(print.first?.layerHeight, 0.3)
        XCTAssertNil(print.first?.extraSettings["temperature"], "filament key leaked into the print profile")
        let material = ProfileIni.profiles(MaterialProfile.self, from: text, fileName: "config.ini")
        XCTAssertEqual(material.first?.name, "3DLabPrint PolyLight 1.0 LW-PLA")
        XCTAssertEqual(material.first?.otherLayersTemp, 245)
    }

    // Export → import gives a profile with the same settings.
    func testExportImportRoundTrip() throws {
        let base = try XCTUnwrap(PresetLibrary.settings(.print, creality))
        var original = BuiltInSliceProfiles.rcPlane
        original.extraSettings["seam_position"] = "rear"
        let text = ProfileIni.text(original, baseSettings: base)
        let back = try XCTUnwrap(ProfileIni.profiles(SliceProfile.self, from: text, fileName: "x.ini").first)
        // Compared as libslic3r re-serializes them (a few values aren't
        // written back character for character).
        XCTAssertEqual(OrcaMigration.normalize(back.slicerSettings()),
                       OrcaMigration.normalize(base.merging(original.slicerSettings()) { _, own in own }
                           .filter { !SlicerKeys.ignored.contains($0.key) }))
    }
}
