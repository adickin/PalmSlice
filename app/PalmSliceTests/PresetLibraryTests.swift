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

    // Keys the PalmSlice printer / material / slice profiles set (slicer_bridge.cpp
    // apply functions), plus G-code bookkeeping the bridge always overrides.
    static let palmSliceKeys: Set<String> = [
        // slice profile
        "layer_height", "first_layer_height", "perimeters", "xy_size_compensation",
        "perimeter_generator", "external_perimeters_first", "top_solid_layers",
        "bottom_solid_layers", "top_solid_min_thickness", "bottom_solid_min_thickness",
        "fill_density", "fill_pattern", "infill_overlap", "slicing_mode", "slice_closing_radius",
        "perimeter_speed", "infill_speed",
        "travel_speed", "first_layer_speed", "solid_infill_speed", "top_solid_infill_speed",
        "ironing", "ironing_type", "ironing_flowrate", "ironing_speed", "ironing_spacing",
        "support_material", "support_material_style", "support_material_buildplate_only",
        "support_material_threshold", "support_material_xy_spacing", "support_material_with_sheath",
        "support_material_contact_distance", "support_material_interface_layers",
        "support_material_bottom_interface_layers", "support_material_interface_spacing",
        "brim_type", "brim_width", "skirts", "skirt_distance", "raft_layers",
        // material profile
        "filament_diameter", "first_layer_temperature", "temperature", "first_layer_bed_temperature",
        "bed_temperature", "extrusion_multiplier", "retract_length", "retract_speed",
        "retract_restart_extra", "retract_lift", "retract_before_travel", "cooling",
        "min_fan_speed", "max_fan_speed", "bridge_fan_speed", "disable_fan_first_layers",
        "fan_below_layer_time", "slowdown_below_layer_time", "min_print_speed", "fan_always_on",
        "filament_retract_length", "filament_retract_speed", "filament_retract_restart_extra",
        "filament_retract_lift", "filament_retract_before_travel",
        // printer profile
        "bed_shape", "max_print_height", "gcode_flavor", "start_gcode", "end_gcode",
        "nozzle_diameter", "extruder_clearance_radius", "extruder_clearance_height",
        // which presets were applied (recorded in the G-code footer)
        "printer_settings_id", "print_settings_id", "filament_settings_id",
    ]

    func testUnsetSettingsComeFromVendorPresets() throws {
        let printer = BuiltInProfiles.all.first { $0.verified }!
        let material = BuiltInMaterialProfiles.pla
        let slice = BuiltInSliceProfiles.standard
        let base = try XCTUnwrap(PresetLibrary.base(printerPreset: printer.systemPreset,
                                                    filamentType: material.filamentType))
        guard let h = slicer_create() else { return XCTFail("slicer_create") }
        defer { slicer_destroy(h) }
        XCTAssertTrue(PresetLibrary.apply(base, to: h))
        try applyPalmSliceProfiles(printer: printer, material: material, slice: slice, to: h)

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

    // The same calls ContentView's slice pipeline makes.
    private func applyPalmSliceProfiles(printer: PrinterProfile, material: MaterialProfile,
                                        slice: SliceProfile, to h: SlicerHandle) throws {
        let ok: Bool = printer.startGCode.withCString { s in printer.endGCode.withCString { e in
            var cfg = SlicerPrinterConfig()
            cfg.bed_x = Float(printer.bedX); cfg.bed_y = Float(printer.bedY); cfg.bed_z = Float(printer.bedZ)
            cfg.heated_bed = 1
            cfg.gcode_flavor = printer.gcodeFlavor.bridgeInt
            cfg.start_gcode = s; cfg.end_gcode = e
            cfg.printhead_x_min = Float(printer.printheadXMin); cfg.printhead_y_min = Float(printer.printheadYMin)
            cfg.printhead_x_max = Float(printer.printheadXMax); cfg.printhead_y_max = Float(printer.printheadYMax)
            cfg.gantry_height = Float(printer.gantryHeight)
            cfg.extruder_count = 1
            cfg.nozzle_diameter = Float(printer.extruders[0].nozzleDiameter)
            cfg.filament_diameter = 1.75
            return slicer_apply_printer_config(h, &cfg) == 0
        }}
        XCTAssertTrue(ok, String(cString: slicer_last_error(h)))
        var m = SlicerMaterialConfig()
        m.filament_diameter = Float(material.filamentDiameter)
        m.first_layer_temperature = Int32(material.firstLayerTemp); m.temperature = Int32(material.otherLayersTemp)
        m.first_layer_bed_temperature = Int32(material.firstLayerBedTemp); m.bed_temperature = Int32(material.otherLayersBedTemp)
        m.extrusion_multiplier = Float(material.extrusionMultiplier)
        m.retract_length = Float(material.retractionLength); m.retract_speed = Float(material.retractionSpeed)
        m.cooling = 1; m.max_fan_speed = Int32(material.maxFanSpeed)
        XCTAssertEqual(slicer_apply_material_config(h, &m), 0, String(cString: slicer_last_error(h)))
        var sc = slice.bridgeConfig()
        XCTAssertEqual(slicer_apply_slice_config(h, &sc), 0, String(cString: slicer_last_error(h)))
    }
}
