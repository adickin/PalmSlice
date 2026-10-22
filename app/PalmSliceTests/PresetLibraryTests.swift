import XCTest
@testable import PalmSlice

final class PresetLibraryTests: XCTestCase {

    func testVendorPresetsLoad() throws {
        if case .failure(let e) = PresetLibrary.load() { XCTFail(e.description) }
        let count = try PresetLibrary.load().get()
        XCTAssertGreaterThan(count, 100)
        XCTAssertTrue(PresetLibrary.exists(.printer, PresetLibrary.fallbackPrinter))
        XCTAssertFalse(PresetLibrary.names(.print).isEmpty)
        XCTAssertFalse(PresetLibrary.names(.filament).isEmpty)
    }

    // A custom printer (no PrusaSlicer preset) gets the fallback printer's
    // print/filament presets but never its printer preset.
    func testCustomPrinterBaseSkipsPrinterPreset() throws {
        let base = try XCTUnwrap(PresetLibrary.base(printerPreset: nil, filamentType: "PLA"))
        XCTAssertNil(base.printer)
        XCTAssertTrue(PresetLibrary.isCompatible(.print, base.print, printer: PresetLibrary.fallbackPrinter))
    }

    func testEnderBaseUsesCrealityDefaults() throws {
        let ender = "Creality Ender-3 S1 (0.4 mm nozzle)"
        let base = try XCTUnwrap(PresetLibrary.base(printerPreset: ender, filamentType: "PETG"))
        XCTAssertEqual(base.printer, ender)
        XCTAssertEqual(base.print, PresetLibrary.defaults(forPrinter: ender).print)
        XCTAssertTrue(PresetLibrary.isCompatible(.print, base.print, printer: ender))
        let filamentType = PresetLibrary.settings(.filament, base.filament)?["filament_type"]
        XCTAssertEqual(filamentType.map(SettingsText.unquote), "PETG")
    }
}

/// Settings drift: once the PrusaSlicer base and every PalmSlice profile are
/// applied, any setting a PalmSlice profile doesn't control must still have
/// the vendor preset's value — PalmSlice must not silently fall back to
/// libslic3r's bare defaults (the drift found comparing against 3DLabPrint's
/// PrusaSlicer project files).
final class PresetDriftTests: XCTestCase {

    // Keys the PalmSlice profiles set, plus which presets were applied
    // (recorded in the G-code footer).
    static var palmSliceKeys: Set<String> {
        PrinterProfile.typedKeys.union(MaterialProfile.typedKeys).union(SliceProfile.typedKeys)
            .union(["printer_settings_id", "print_settings_id", "filament_settings_id"])
    }

    func testUnsetSettingsComeFromVendorPresets() throws {
        let printer = BuiltInProfiles.all.first { $0.verified }!
        let material = BuiltInMaterialProfiles.pla
        let slice = BuiltInSliceProfiles.standard
        let base = try XCTUnwrap(SliceSetup.base(printer: printer, material: material, slice: slice))
        guard let h = slicer_create() else { return XCTFail("slicer_create") }
        defer { slicer_destroy(h) }
        try SliceSetup.configure(h, printer: printer, material: material, slice: slice)

        var drifted: [String] = []
        for (type, name) in [(PresetType.printer, base.printer!), (.print, base.print), (.filament, base.filament)] {
            let preset = try XCTUnwrap(PresetLibrary.settings(type, name))
            for (key, value) in preset where !Self.palmSliceKeys.contains(key) {
                let actual = slicer_get_setting(h, key).map { String(cString: $0) }
                if actual != value { drifted.append("\(key): preset=\(value) actual=\(actual ?? "nil")") }
            }
        }
        XCTAssertTrue(drifted.isEmpty, "settings drifted from PrusaSlicer:\n" + drifted.joined(separator: "\n"))
    }
}
