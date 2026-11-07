import Foundation

/// The slice qualities offered for the selected printer: its OrcaSlicer
/// qualities (regenerated whenever the printer changes) followed by the
/// user's own, which are stored as changes only and work on every printer.
@MainActor
final class SliceProfileStore: ObservableObject {
    /// The list for the current printer: OrcaSlicer qualities, then the
    /// user's own (shown resolved for this printer).
    @Published private(set) var profiles: [SliceProfile] = []
    /// Remembered across launches.
    @Published var selectedProfileId: UUID? {
        didSet { UserDefaults.standard.set(selectedProfileId?.uuidString, forKey: Self.selectedKey) }
    }
    private static let selectedKey = "lastSliceProfileID"

    /// The user's own qualities (changes only), persisted.
    private var custom: [SliceProfile] = []
    /// The OrcaSlicer printer preset the list was built for.
    private(set) var printerPreset: String?

    var selectedProfile: SliceProfile? {
        profiles.first { $0.id == selectedProfileId }
    }

    var systemProfiles: [SliceProfile] { profiles.filter(\.isSystem) }
    var customProfiles: [SliceProfile] { profiles.filter { !$0.isSystem } }

    // Saved qualities were reset when defaults moved to OrcaSlicer (Nov 2026);
    // the old slice_profiles.json is left in place, unread.
    private var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("slice_qualities.json")
    }

    // MARK: Load / Save

    func load(printerPreset: String? = nil) {
        self.printerPreset = printerPreset
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([SliceProfile].self, from: data) {
            custom = decoded
        } else {
            custom = BuiltInSliceProfiles.all
            save()
        }
        if selectedProfileId == nil {
            selectedProfileId = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
        }
        rebuild()
    }

    /// Rebuilds the list for a printer. A selected OrcaSlicer quality the new
    /// printer doesn't have switches to the printer's default quality; the
    /// user's own qualities stay selected.
    func setPrinter(_ printerPreset: String?) {
        guard printerPreset != self.printerPreset || profiles.isEmpty else { return }
        self.printerPreset = printerPreset
        rebuild()
    }

    private func rebuild() {
        let qualities = PresetLibrary.qualities(forPrinter: printerPreset)
        var list = qualities.map(SliceProfile.system)
        list += custom.map(resolved)
        profiles = list
        if selectedProfileId == nil || !profiles.contains(where: { $0.id == selectedProfileId }) {
            let d = PresetLibrary.defaultQuality(forPrinter: printerPreset)
            selectedProfileId = d.map { PresetLibrary.stableID(.print, $0) } ?? profiles.first?.id
        }
    }

    /// The OrcaSlicer quality a profile is shown and sliced over on this printer.
    func base(of profile: SliceProfile) -> String? {
        profile.isSystem ? profile.basePreset
            : PresetLibrary.quality(forPrinter: printerPreset, layerHeight: profile.ownLayerHeight)
    }

    /// A user quality with its typed fields showing the result on this printer.
    func resolved(_ profile: SliceProfile) -> SliceProfile {
        guard !profile.isSystem else { return profile }
        guard !profile.isResolved else { return profile }
        var p = profile
        p.resolve(over: base(of: p).flatMap { PresetLibrary.settings(.print, $0) } ?? [:])
        p.isResolved = true
        return p
    }

    func save() {
        guard let data = try? JSONEncoder().encode(custom) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: Mutations

    /// Adds a user quality. `profile` may be a full set of settings (e.g. from
    /// an .ini or a 3MF); only what differs from this printer's matching
    /// OrcaSlicer quality is kept.
    func add(_ profile: SliceProfile) {
        custom.append(changesOnly(profile))
        save()
        rebuild()
    }

    func update(_ profile: SliceProfile) {
        guard !profile.isSystem, let idx = custom.firstIndex(where: { $0.id == profile.id }) else { return }
        custom[idx] = changesOnly(profile)
        save()
        rebuild()
    }

    /// The profile as stored: only what it changes over its base here.
    func changesOnly(_ profile: SliceProfile) -> SliceProfile {
        guard profile.isResolved else { return profile }
        var p = profile
        p.isSystem = false
        p.basePreset = nil
        let layer = p.slicerSettings()["layer_height"].flatMap(SlicerValue.parseFloat)
        let base = PresetLibrary.quality(forPrinter: printerPreset, layerHeight: layer)
        p.keepChanges(from: base.flatMap { PresetLibrary.settings(.print, $0) } ?? [:])
        // The layer height picks the base quality on every printer, so keep it.
        if let layer { p.extraSettings["layer_height"] = SlicerValue.float(layer) }
        p.isResolved = false
        return p
    }

    func delete(id: UUID) {
        guard custom.contains(where: { $0.id == id }) else { return }
        custom.removeAll { $0.id == id }
        save()
        rebuild()
    }

    func select(id: UUID) {
        selectedProfileId = id
    }
}
