import Foundation

/// Configures a slicer context from the selected profiles — the one path both
/// the app's slice pipeline and the tests use.
///
/// Layers, last wins:
///   1. PrusaSlicer system presets: the printer's preset, a print preset and a
///      filament preset (PresetLibrary.base).
///   2. The printer profile, then the material, then the slice profile, each
///      as PrusaSlicer settings (typed fields + extraSettings), validated by
///      libslic3r via slicer_apply_settings.
enum SliceSetup {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The PrusaSlicer presets this combination of profiles starts from
    /// (nil if the vendor presets couldn't be loaded).
    static func base(printer: PrinterProfile, material: MaterialProfile?,
                     slice: SliceProfile) -> PresetBase? {
        PresetLibrary.base(printerPreset: printer.systemPreset,
                           printPreset: slice.basePreset,
                           filamentPreset: material?.basePreset,
                           filamentType: material?.filamentType ?? "PLA")
    }

    /// `toolMaterials`: the materials in tools 2, 3, … of a multi-tool
    /// printer (`material` is tool 1's). Tools without one use tool 1's.
    static func configure(_ handle: SlicerHandle, printer: PrinterProfile,
                          material: MaterialProfile?, slice: SliceProfile,
                          toolMaterials: [MaterialProfile] = []) throws {
        if let base = base(printer: printer, material: material, slice: slice),
           !PresetLibrary.apply(base, to: handle) {
            throw Failure(description: String(cString: slicer_last_error(handle)))
        }
        try apply(printer, label: "Printer profile", to: handle)
        if let material { try apply(material, label: "Material", to: handle) }
        // Each further tool: its filament preset, then its material, per extruder.
        // Every tool gets one (tool 1's by default), so per-tool vectors such as
        // filament_type always have an entry per tool for the printer's G-code.
        let tools = max(1, printer.numberOfExtruders)
        let perTool = (0..<max(0, tools - 1)).compactMap { $0 < toolMaterials.count ? toolMaterials[$0] : material }
        for (i, toolMaterial) in perTool.enumerated() {
            let tool = Int32(i + 2)
            if let filament = base(printer: printer, material: toolMaterial, slice: slice)?.filament,
               slicer_apply_tool_preset(handle, tool, filament) != 0 {
                throw Failure(description: "Tool \(tool): \(String(cString: slicer_last_error(handle)))")
            }
            if slicer_apply_tool_settings(handle, tool, SettingsText.serialize(toolMaterial.prusaSettings())) != 0 {
                throw Failure(description: "Tool \(tool) material: \(String(cString: slicer_last_error(handle)))")
            }
        }
        try apply(slice, label: "Slice profile", to: handle)
    }

    static func apply<P: PrusaSettingsConvertible>(_ profile: P, label: String,
                                                    to handle: SlicerHandle) throws {
        try applySettings(profile.prusaSettings(), label: label, to: handle)
    }

    static func applySettings(_ settings: [String: String], label: String,
                              to handle: SlicerHandle) throws {
        if slicer_apply_settings(handle, SettingsText.serialize(settings)) != 0 {
            throw Failure(description: "\(label): \(String(cString: slicer_last_error(handle)))")
        }
    }
}

extension SliceSetup {
    /// Sets a model's object and part tools on the object added at `object`.
    /// Returns an error message, or nil on success.
    static func applyTools(_ handle: SlicerHandle, object: Int32, model: PlacedModel) -> String? {
        if slicer_set_object_extruder(handle, object, Int32(model.extruder)) != 0 {
            return String(cString: slicer_last_error(handle))
        }
        guard model.nativeURL != nil else { return nil }
        for (k, part) in model.parts.enumerated()
        where slicer_set_volume_extruder(handle, object, Int32(k), Int32(part.extruder)) != 0 {
            return String(cString: slicer_last_error(handle))
        }
        return nil
    }

    /// Colour by height, merged into the object's height ranges. Call after
    /// the file settings. Returns an error message, or nil on success.
    static func applyToolBands(_ handle: SlicerHandle, object: Int32, model: PlacedModel) -> String? {
        guard !model.toolBands.isEmpty else { return nil }
        return slicer_set_object_tool_ranges(handle, object, model.toolRangesText) == 0
            ? nil : String(cString: slicer_last_error(handle))
    }
}
