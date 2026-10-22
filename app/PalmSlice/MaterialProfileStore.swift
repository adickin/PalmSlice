import Foundation

@MainActor
final class MaterialProfileStore: ObservableObject {
    @Published var profiles: [MaterialProfile] = []
    @Published var selectedProfileId: UUID?

    var selectedProfile: MaterialProfile? {
        profiles.first { $0.id == selectedProfileId }
    }

    private var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("material_profiles.json")
    }

    // Bump when BuiltInMaterialProfiles changes in a breaking way.
    private static let seedVersion = 1
    private static let seedVersionKey = "materialProfileSeedVersion"

    // MARK: Load / Save

    func load() {
        let savedVersion = UserDefaults.standard.integer(forKey: Self.seedVersionKey)
        let versionMatch = savedVersion >= Self.seedVersion

        if versionMatch,
           let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([MaterialProfile].self, from: data),
           !decoded.isEmpty {
            profiles = decoded
        } else {
            profiles = BuiltInMaterialProfiles.all
            UserDefaults.standard.set(Self.seedVersion, forKey: Self.seedVersionKey)
            save()
        }

        let added = mergeInNewBuiltIns()
        let updated = updateUneditedLWPLA()
        if added || updated {
            save()
        }

        if selectedProfileId == nil || !profiles.contains(where: { $0.id == selectedProfileId }) {
            selectedProfileId = profiles.first?.id
        }
    }

    private static let offeredBuiltInsKey = "materialBuiltInsOffered"
    // Built-ins that every install seeded before offeredBuiltInsKey existed.
    private static let originalBuiltInNames = ["PLA", "PETG", "ABS", "TPU"]

    // Appends built-in materials added since this install last loaded, so app
    // updates deliver new templates to existing users. Each built-in is offered
    // only once (tracked by name), so one the user deleted doesn't come back.
    @discardableResult
    private func mergeInNewBuiltIns() -> Bool {
        let defaults = UserDefaults.standard
        var offered = Set(defaults.stringArray(forKey: Self.offeredBuiltInsKey)
                          ?? Self.originalBuiltInNames)
        var added = false
        for template in BuiltInMaterialProfiles.all where !offered.contains(template.name) {
            if !profiles.contains(where: { $0.name == template.name }) {
                profiles.append(template)
                added = true
            }
            offered.insert(template.name)
        }
        defaults.set(offered.sorted(), forKey: Self.offeredBuiltInsKey)
        return added
    }

    // The eSUN PLA-LW built-in was retuned to 3DLabPrint's LW settings after it
    // shipped. Installs that already have it keep their saved copy, so update
    // that copy too, but only if it still has the original values (an edited
    // copy is left alone).
    private func updateUneditedLWPLA() -> Bool {
        let template = BuiltInMaterialProfiles.esunPLALW
        guard let idx = profiles.firstIndex(where: {
            $0.name == template.name && $0.extrusionMultiplier == 0.6
                && $0.retractionLength == 0.8 && $0.maxFanSpeed == 30
                && $0.fanBelowLayerTime == 15
        }) else { return false }
        var p = template
        p.id = profiles[idx].id
        profiles[idx] = p
        return true
    }

    func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: Mutations

    func add(_ profile: MaterialProfile) {
        profiles.append(profile)
        save()
    }

    func update(_ profile: MaterialProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        save()
    }

    func delete(id: UUID) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        if selectedProfileId == id {
            selectedProfileId = profiles.first?.id
        }
        save()
    }

    func select(id: UUID) {
        selectedProfileId = id
    }
}
