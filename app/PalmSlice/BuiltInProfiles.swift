import Foundation

// Built-in printers: OrcaSlicer system printer presets (0.4 mm nozzle
// variants), seeded into a new install's ProfileStore and merged into existing
// installs when new ones are added (ProfileStore.mergeInMissingBuiltIns).
//
// Each profile is generated from its preset (PresetLibrary), so bed, G-code
// and printhead values are OrcaSlicer's own; every slice also applies the
// preset itself as its base layer. Only the Creality Ender-3 S1 has been
// print-tested with this app, so it's seeded as verified; the rest start in
// the "untested" list.
enum BuiltInProfiles {
    struct Entry {
        let key: String           // PrinterProfile.builtInKey — stable across renames
        let name: String          // PalmSlice display name
        let systemPreset: String  // OrcaSlicer printer preset
        var verified = false
    }

    static let entries: [Entry] = [
        // Print-tested on a real Ender-3 S1 (2026-10-21, with the PrusaSlicer
        // preset; the OrcaSlicer one hasn't been printed yet). Replaced the
        // app's original hand-written Ender 3 S1 profile (builtInKey
        // "ender3s1"), which ProfileStore removes from existing installs.
        Entry(key: "creality-ender3s1-vendor", name: "Creality Ender-3 S1",
              systemPreset: "Creality Ender-3 S1 0.4 nozzle", verified: true),
        Entry(key: "prusa-mk3s", name: "Prusa i3 MK3S+", systemPreset: "Prusa MK3S 0.4 nozzle"),
        Entry(key: "prusa-mini", name: "Prusa MINI+", systemPreset: "Prusa MINI 0.4 nozzle"),
        Entry(key: "creality-ender3v2", name: "Creality Ender-3 V2", systemPreset: "Creality Ender-3 V2 0.4 nozzle"),
        // OrcaSlicer has no original CR-10; the V2 has the same 300×300×400 bed.
        Entry(key: "creality-cr10", name: "Creality CR-10 V2", systemPreset: "Creality CR-10 V2 0.4 nozzle"),
        Entry(key: "anycubic-i3mega", name: "Anycubic i3 Mega S", systemPreset: "Anycubic i3 Mega S 0.4 nozzle"),
        Entry(key: "artillery-sidewinder-x1", name: "Artillery Sidewinder X1", systemPreset: "Artillery Sidewinder X1 0.4 nozzle"),
        Entry(key: "creality-ender3", name: "Creality Ender-3", systemPreset: "Creality Ender-3 0.4 nozzle"),
        Entry(key: "creality-ender5", name: "Creality Ender-5", systemPreset: "Creality Ender-5 0.4 nozzle"),
        Entry(key: "prusa-mk4", name: "Prusa MK4", systemPreset: "Prusa MK4 0.4 nozzle"),
        Entry(key: "elegoo-neptune3pro", name: "Elegoo Neptune-3 Pro", systemPreset: "Elegoo Neptune 3 Pro 0.4 nozzle"),
        Entry(key: "sovol-sv06", name: "Sovol SV06", systemPreset: "Sovol SV06 0.4 nozzle"),
        Entry(key: "voron-v2-350", name: "Voron 2.4 (350)", systemPreset: "Voron 2.4 350 0.4 nozzle"),
        // Not printed on real hardware yet.
        Entry(key: "snapmaker-u1", name: "Snapmaker U1", systemPreset: "Snapmaker U1 (0.4 nozzle)"),
    ]

    /// OrcaSlicer printer preset by builtInKey, for linking saved copies.
    static var systemPresetNames: [String: String] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.systemPreset) })
    }

    /// The built-in printer for an entry; nil if its preset can't be loaded.
    static func profile(for entry: Entry) -> PrinterProfile? {
        PrinterProfile(systemPreset: entry.systemPreset, name: entry.name,
                       builtInKey: entry.key, verified: entry.verified)
    }

    /// All built-in printers (those whose preset loaded). Loads the vendor
    /// presets on first use.
    static var all: [PrinterProfile] { entries.compactMap(profile(for:)) }
}

extension PrinterProfile {
    /// A printer profile based on an OrcaSlicer printer preset: its typed
    /// fields hold the preset's values, and the preset itself is the base
    /// layer of every slice (so nothing else needs copying). nil if the preset
    /// doesn't exist or the vendor presets failed to load.
    init?(systemPreset: String, name: String? = nil, builtInKey: String? = nil, verified: Bool = false) {
        guard let settings = PresetLibrary.settings(.printer, systemPreset) else { return nil }
        self.init()
        self.name = name ?? systemPreset
        self.builtInKey = builtInKey
        self.verified = verified
        self.systemPreset = systemPreset
        updateTyped(from: settings)
    }
}
