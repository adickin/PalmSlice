import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [PrinterProfile] = []
    @Published var selectedProfileId: UUID?

    var selectedProfile: PrinterProfile? {
        profiles.first { $0.id == selectedProfileId }
    }

    private var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("printer_profiles.json")
    }

    // Bump this any time BuiltInProfiles changes in a way that would break
    // existing saved profiles (e.g. gcode syntax fix, renamed fields).
    // On mismatch the saved file is discarded and re-seeded from BuiltInProfiles.all.
    private static let seedVersion = 2
    private static let seedVersionKey = "profileSeedVersion"

    // MARK: Load / Save

    func load() {
        let savedVersion = UserDefaults.standard.integer(forKey: Self.seedVersionKey)
        let versionMatch = savedVersion >= Self.seedVersion

        if versionMatch,
           let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([PrinterProfile].self, from: data),
           !decoded.isEmpty {
            profiles = decoded
        } else {
            profiles = BuiltInProfiles.all
            UserDefaults.standard.set(Self.seedVersion, forKey: Self.seedVersionKey)
            save()
        }

        let added = mergeInMissingBuiltIns()
        let migrated = retireCustomEnder3S1()
        let linked = linkSystemPresets()
        if added || migrated || linked {
            save()
        }

        if selectedProfileId == nil || !profiles.contains(where: { $0.id == selectedProfileId }) {
            selectedProfileId = (profiles.first { $0.verified } ?? profiles.first)?.id
        }
    }

    // Saved copies of built-in printers from before profiles were based on
    // PrusaSlicer presets: link each to its system preset.
    private func linkSystemPresets() -> Bool {
        var changed = false
        for i in profiles.indices where profiles[i].systemPreset == nil {
            if let key = profiles[i].builtInKey, let name = BuiltInProfiles.systemPresetNames[key] {
                profiles[i].systemPreset = name
                changed = true
            }
        }
        return changed
    }

    // One-time migration: the original hand-written "Ender 3 S1" built-in was
    // replaced by the PrusaSlicer vendor profile once that was print-tested.
    // Removes the old profile and promotes the vendor one to Verified (under
    // its new name, unless the user renamed it). Runs once, so a later
    // "Mark Untested" sticks.
    private static let retiredEnderKey = "retiredCustomEnder3S1"

    private func retireCustomEnder3S1() -> Bool {
        guard !UserDefaults.standard.bool(forKey: Self.retiredEnderKey) else { return false }
        UserDefaults.standard.set(true, forKey: Self.retiredEnderKey)

        let replacement = BuiltInProfiles.crealityEnder3S1
        profiles.removeAll { p in
            p.builtInKey == "ender3s1" || (p.builtInKey == nil && p.name == "Ender 3 S1")
        }
        if let idx = profiles.firstIndex(where: { $0.builtInKey == replacement.builtInKey }) {
            profiles[idx].verified = true
            if profiles[idx].name == "Creality Ender-3 S1 (PrusaSlicer)" {
                profiles[idx].name = replacement.name
            }
            // Keep verified profiles at the top so the fallback selection lands on it.
            let p = profiles.remove(at: idx)
            profiles.insert(p, at: 0)
        }
        return true
    }

    // Adds any BuiltInProfiles template not already present, so a user who
    // already has a saved printer_profiles.json (and may have customized
    // their existing profiles) still picks up newly-added built-ins on
    // their next app update instead of only new installs seeing them.
    // Matches by builtInKey when set; older saved profiles predate that
    // field, so those fall back to matching by name to avoid duplicating
    // a built-in the user already has.
    @discardableResult
    private func mergeInMissingBuiltIns() -> Bool {
        var added = false
        for template in BuiltInProfiles.all {
            let alreadyPresent = profiles.contains { existing in
                if let key = template.builtInKey {
                    if existing.builtInKey == key { return true }
                }
                return existing.builtInKey == nil && existing.name == template.name
            }
            if !alreadyPresent {
                profiles.append(template)
                added = true
            }
        }
        return added
    }

    func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: Mutations

    func add(_ profile: PrinterProfile) {
        var p = profile
        normalizeExtruders(&p)
        profiles.append(p)
        save()
    }

    func update(_ profile: PrinterProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var p = profile
        normalizeExtruders(&p)
        profiles[idx] = p
        save()
    }

    func delete(id: UUID) {
        guard profiles.count > 1 else { return }   // always keep at least one
        profiles.removeAll { $0.id == id }
        if selectedProfileId == id {
            selectedProfileId = profiles.first?.id
        }
        save()
    }

    func select(id: UUID) {
        selectedProfileId = id
    }

    // MARK: Helpers

    // Ensures extruders array length == numberOfExtruders.
    private func normalizeExtruders(_ p: inout PrinterProfile) {
        let target = max(1, p.numberOfExtruders)
        while p.extruders.count < target { p.extruders.append(ExtruderProfile()) }
        if p.extruders.count > target { p.extruders = Array(p.extruders.prefix(target)) }
    }
}
