import Foundation

/// Configures a slicer context from the selected profiles — the one path both
/// the app's slice pipeline and the tests use.
///
/// Layers, last wins:
///   1. OrcaSlicer system presets: the printer's preset, a quality (print
///      preset) and a filament preset (PresetLibrary.base).
///   2. The printer profile, then the material, then the slice profile, each
///      as OrcaSlicer settings (typed fields + extraSettings), validated by
///      libslic3r via slicer_apply_settings. A user quality or material that
///      holds only its changes is first resolved over its base preset.
enum SliceSetup {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The OrcaSlicer presets this combination of profiles starts from
    /// (nil if the vendor presets couldn't be loaded): an OrcaSlicer quality
    /// as is, a user quality over the printer's quality nearest its layer
    /// height; the material's filament when it suits the printer, otherwise
    /// the printer's filament of its type.
    static func base(printer: PrinterProfile, material: MaterialProfile?,
                     slice: SliceProfile) -> PresetBase? {
        PresetLibrary.base(printerPreset: printer.systemPreset,
                           printPreset: slice.isSystem ? slice.basePreset : nil,
                           layerHeight: slice.isSystem ? nil : (slice.isResolved ? slice.layerHeight : slice.ownLayerHeight),
                           filamentPreset: material?.basePreset,
                           filamentType: material?.ownFilamentType ?? "PLA")
    }

    /// A user quality holding only its changes, resolved over `base`.
    static func resolved(_ slice: SliceProfile, base: PresetBase?) -> SliceProfile {
        guard !slice.isResolved, let base else { return slice }
        var s = slice
        s.resolve(over: PresetLibrary.settings(.print, base.print) ?? [:])
        s.isResolved = true
        return s
    }

    /// A user material holding only its changes, resolved over `filament`.
    static func resolved(_ material: MaterialProfile, filament: String?) -> MaterialProfile {
        guard !material.isResolved, let filament else { return material }
        var m = material
        let colour = m.colour
        m.resolve(over: PresetLibrary.settings(.filament, filament) ?? [:])
        if m.extraSettings["filament_colour"] == nil, HexColour(colour) != nil { m.colour = colour }
        m.isResolved = true
        return m
    }

    /// `toolMaterials`: the materials in tools 2, 3, … of a multi-tool
    /// printer (`material` is tool 1's). Tools without one use tool 1's.
    static func configure(_ handle: SlicerHandle, printer: PrinterProfile,
                          material: MaterialProfile?, slice: SliceProfile,
                          toolMaterials: [MaterialProfile] = []) throws {
        let presets = base(printer: printer, material: material, slice: slice)
        if let presets, !PresetLibrary.apply(presets, to: handle) {
            throw Failure(description: String(cString: slicer_last_error(handle)))
        }
        try apply(printer, label: "Printer profile", to: handle)
        if let material { try apply(resolved(material, filament: presets?.filament), label: "Material", to: handle) }
        // Each further tool: its filament preset, then its material, per extruder.
        // Every tool gets one (tool 1's by default), so per-tool vectors such as
        // filament_type always have an entry per tool for the printer's G-code.
        let tools = max(1, printer.numberOfExtruders)
        let perTool = (0..<max(0, tools - 1)).compactMap { $0 < toolMaterials.count ? toolMaterials[$0] : material }
        for (i, toolMaterial) in perTool.enumerated() {
            let tool = Int32(i + 2)
            let filament = base(printer: printer, material: toolMaterial, slice: slice)?.filament
            if let filament, slicer_apply_tool_preset(handle, tool, filament) != 0 {
                throw Failure(description: "Tool \(tool): \(String(cString: slicer_last_error(handle)))")
            }
            let toolMaterial = resolved(toolMaterial, filament: filament)
            if slicer_apply_tool_settings(handle, tool, SettingsText.serialize(toolMaterial.slicerSettings())) != 0 {
                throw Failure(description: "Tool \(tool) material: \(String(cString: slicer_last_error(handle)))")
            }
        }
        try apply(resolved(slice, base: presets), label: "Slice profile", to: handle)
    }

    static func apply<P: SlicerSettingsConvertible>(_ profile: P, label: String,
                                                    to handle: SlicerHandle) throws {
        try applySettings(profile.slicerSettings(), label: label, to: handle)
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

    /// The model's own modifiers, added to its object. Returns an error
    /// message, or nil on success.
    static func applyModifiers(_ handle: SlicerHandle, object: Int32, model: PlacedModel) -> String? {
        for modifier in model.modifiers {
            let text = SettingsText.serialize(modifier.settings)
            var centre = [modifier.centreMM.x, modifier.centreMM.y, modifier.centreMM.z]
            var size = [modifier.sizeMM.x, modifier.sizeMM.y, modifier.sizeMM.z]
            if slicer_add_object_modifier(handle, object, Int32(modifier.shape.rawValue),
                                          &centre, &size, text, Int32(modifier.tool)) != 0 {
                return "\(modifier.name) modifier: \(String(cString: slicer_last_error(handle)))"
            }
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
