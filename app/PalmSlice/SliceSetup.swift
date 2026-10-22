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

    static func configure(_ handle: SlicerHandle, printer: PrinterProfile,
                          material: MaterialProfile?, slice: SliceProfile) throws {
        if let base = base(printer: printer, material: material, slice: slice),
           !PresetLibrary.apply(base, to: handle) {
            throw Failure(description: String(cString: slicer_last_error(handle)))
        }
        try apply(printer, label: "Printer profile", to: handle)
        if let material { try apply(material, label: "Material", to: handle) }
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
