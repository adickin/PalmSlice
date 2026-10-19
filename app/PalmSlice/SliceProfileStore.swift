import Foundation

@MainActor
final class SliceProfileStore: ObservableObject {
    @Published var profiles: [SliceProfile] = []
    @Published var selectedProfileId: UUID?

    var selectedProfile: SliceProfile? {
        profiles.first { $0.id == selectedProfileId }
    }

    private var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("slice_profiles.json")
    }

    // Bump when BuiltInSliceProfiles changes in a breaking way.
    private static let seedVersion = 4
    private static let seedVersionKey = "sliceProfileSeedVersion"

    // MARK: Load / Save

    func load() {
        let savedVersion = UserDefaults.standard.integer(forKey: Self.seedVersionKey)
        let versionMatch = savedVersion >= Self.seedVersion

        if versionMatch,
           let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([SliceProfile].self, from: data),
           !decoded.isEmpty {
            profiles = decoded
        } else {
            profiles = BuiltInSliceProfiles.all
            UserDefaults.standard.set(Self.seedVersion, forKey: Self.seedVersionKey)
            save()
        }

        if mergeInNewBuiltIns() {
            save()
        }

        if selectedProfileId == nil || !profiles.contains(where: { $0.id == selectedProfileId }) {
            selectedProfileId = profiles.first?.id
        }
    }

    private static let offeredBuiltInsKey = "sliceBuiltInsOffered"
    // Built-ins that every install seeded (seed version 4) before offeredBuiltInsKey existed.
    private static let originalBuiltInNames = ["Draft (0.3 mm)", "Standard (0.2 mm)",
                                               "Fine (0.1 mm)", "Thick Walls (0.2 mm)"]

    // Appends built-in slice profiles added since this install last loaded, so app
    // updates deliver new templates to existing users. Each built-in is offered
    // only once (tracked by name), so one the user deleted doesn't come back.
    @discardableResult
    private func mergeInNewBuiltIns() -> Bool {
        let defaults = UserDefaults.standard
        var offered = Set(defaults.stringArray(forKey: Self.offeredBuiltInsKey)
                          ?? Self.originalBuiltInNames)
        var added = false
        for template in BuiltInSliceProfiles.all where !offered.contains(template.name) {
            if !profiles.contains(where: { $0.name == template.name }) {
                profiles.append(template)
                added = true
            }
            offered.insert(template.name)
        }
        defaults.set(offered.sorted(), forKey: Self.offeredBuiltInsKey)
        return added
    }

    func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: Mutations

    func add(_ profile: SliceProfile) {
        profiles.append(profile)
        save()
    }

    func update(_ profile: SliceProfile) {
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
