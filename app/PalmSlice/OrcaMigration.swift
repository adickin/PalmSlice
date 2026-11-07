import Foundation

/// One-time move of saved profiles from PalmSlice's PrusaSlicer backend to
/// OrcaSlicer's (November 2026). Typed fields are stored by name and need
/// nothing; extraSettings are renamed to OrcaSlicer keys by the bridge, and
/// base presets OrcaSlicer doesn't have are dropped, so the printer's
/// OrcaSlicer defaults are used instead.
enum OrcaMigration {
    /// Settings with PrusaSlicer keys renamed to OrcaSlicer's; settings
    /// neither knows are dropped. OrcaSlicer settings pass through.
    static func normalize(_ settings: [String: String]) -> [String: String] {
        guard !settings.isEmpty else { return settings }
        return SettingsText.parse(String(cString: slicer_normalize_settings(SettingsText.serialize(settings))))
    }

    /// Runs `migrate` the first time it's called for `store`; returns whether it ran.
    static func once(_ store: String, _ migrate: () -> Void) -> Bool {
        let key = "orcaMigrated." + store
        guard !UserDefaults.standard.bool(forKey: key) else { return false }
        migrate()
        UserDefaults.standard.set(true, forKey: key)
        return true
    }

    /// An OrcaSlicer preset for a saved base preset name: the same name, or
    /// OrcaSlicer's "<name> @System" generic filament; nil if there's none.
    static func preset(_ type: PresetType, _ name: String?) -> String? {
        guard let name else { return nil }
        if PresetLibrary.exists(type, name) { return name }
        if type == .filament, PresetLibrary.exists(type, name + " @System") { return name + " @System" }
        return nil
    }
}
