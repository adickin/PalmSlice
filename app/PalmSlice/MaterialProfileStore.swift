import Foundation

/// The materials offered for the selected printer: its default filament and
/// OrcaSlicer's generic per type, the OrcaSlicer filaments the user picked
/// from the full list, and the user's own materials, which are stored as
/// changes only and work on every printer.
@MainActor
final class MaterialProfileStore: ObservableObject {
    @Published private(set) var profiles: [MaterialProfile] = []
    /// Remembered across launches.
    @Published var selectedProfileId: UUID? {
        didSet { UserDefaults.standard.set(selectedProfileId?.uuidString, forKey: Self.selectedKey) }
    }
    private static let selectedKey = "lastMaterialID"

    var selectedProfile: MaterialProfile? {
        profiles.first { $0.id == selectedProfileId }
    }

    /// Materials loaded in tools 2, 3, … of a multi-tool printer (tool 1 is
    /// the selected profile). Missing or deleted entries fall back to tool 1's.
    @Published private(set) var toolMaterialIDs: [UUID] = []
    private static let toolMaterialsKey = "toolMaterialIDs"

    /// The material in a tool (1-based).
    func material(forTool tool: Int) -> MaterialProfile? {
        guard tool > 1, tool - 2 < toolMaterialIDs.count,
              let m = profiles.first(where: { $0.id == toolMaterialIDs[tool - 2] }) else { return selectedProfile }
        return m
    }

    /// Whether the tool has its own material (not tool 1's by default).
    func hasOwnMaterial(tool: Int) -> Bool {
        tool == 1 || (tool - 2 < toolMaterialIDs.count && profiles.contains { $0.id == toolMaterialIDs[tool - 2] })
    }

    func setMaterial(_ id: UUID, forTool tool: Int) {
        guard tool > 1 else { return select(id: id) }
        let fallback = selectedProfileId ?? id
        while toolMaterialIDs.count < tool - 1 { toolMaterialIDs.append(fallback) }
        toolMaterialIDs[tool - 2] = id
        UserDefaults.standard.set(toolMaterialIDs.map(\.uuidString), forKey: Self.toolMaterialsKey)
    }

    /// Materials for tools 2…count.
    func toolMaterials(count: Int) -> [MaterialProfile] {
        count < 2 ? [] : (2...count).compactMap { material(forTool: $0) }
    }

    /// The user's own materials (changes only), persisted.
    private var custom: [MaterialProfile] = []
    /// OrcaSlicer filaments picked from the full list, kept on the list.
    private var pinned: [String] = UserDefaults.standard.stringArray(forKey: "pinnedFilaments") ?? []
    private(set) var printerPreset: String?

    var systemProfiles: [MaterialProfile] { profiles.filter(\.isSystem) }
    var customProfiles: [MaterialProfile] { profiles.filter { !$0.isSystem } }

    // Saved materials were reset when defaults moved to OrcaSlicer (Nov 2026);
    // the old material_profiles.json is left in place, unread.
    private var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("materials.json")
    }

    // MARK: Load / Save

    func load(printerPreset: String? = nil) {
        self.printerPreset = printerPreset
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([MaterialProfile].self, from: data) {
            custom = decoded
        } else {
            custom = BuiltInMaterialProfiles.all
            save()
        }
        if selectedProfileId == nil {
            selectedProfileId = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
        }
        toolMaterialIDs = (UserDefaults.standard.stringArray(forKey: Self.toolMaterialsKey) ?? [])
            .compactMap(UUID.init)
        rebuild()
    }

    /// Rebuilds the list for a printer; a selected filament the printer can't
    /// use switches to the printer's default filament.
    func setPrinter(_ printerPreset: String?) {
        guard printerPreset != self.printerPreset || profiles.isEmpty else { return }
        self.printerPreset = printerPreset
        rebuild()
    }

    private func rebuild() {
        let compatible = Set(PresetLibrary.filaments(forPrinter: printerPreset))
        var names = PresetLibrary.featuredFilaments(forPrinter: printerPreset)
        for name in pinned where compatible.contains(name) && !names.contains(name) { names.append(name) }
        profiles = names.map(MaterialProfile.system) + custom.map(resolved)
        if selectedProfileId == nil || !profiles.contains(where: { $0.id == selectedProfileId }) {
            selectedProfileId = profiles.first?.id
        }
    }

    /// The OrcaSlicer filament a material is shown and sliced over on this printer.
    func base(of material: MaterialProfile) -> String? {
        PresetLibrary.base(printerPreset: printerPreset, filamentPreset: material.basePreset,
                           filamentType: material.ownFilamentType)?.filament
    }

    /// A user material with its typed fields showing the result on this printer.
    func resolved(_ material: MaterialProfile) -> MaterialProfile {
        guard !material.isResolved else { return material }
        var m = material
        let colour = m.colour
        m.resolve(over: base(of: m).flatMap { PresetLibrary.settings(.filament, $0) } ?? [:])
        if m.extraSettings["filament_colour"] == nil, HexColour(colour) != nil { m.colour = colour }
        m.isResolved = true
        return m
    }

    /// The material as stored: only what it changes over its base here (its
    /// type and colour always kept, as they choose and show the base).
    func changesOnly(_ material: MaterialProfile) -> MaterialProfile {
        guard material.isResolved else { return material }
        var m = material
        m.isSystem = false
        m.keepChanges(from: base(of: m).flatMap { PresetLibrary.settings(.filament, $0) } ?? [:])
        m.extraSettings["filament_type"] = SlicerValue.strings([m.filamentType])
        m.extraSettings["filament_colour"] = SlicerValue.strings([m.colour])
        m.isResolved = false
        return m
    }

    /// Puts an OrcaSlicer filament on the list (from the full list) and returns its id.
    @discardableResult
    func pin(_ preset: String) -> UUID {
        if !pinned.contains(preset) {
            pinned.append(preset)
            UserDefaults.standard.set(pinned, forKey: "pinnedFilaments")
        }
        rebuild()
        return PresetLibrary.stableID(.filament, preset)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(custom) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: Mutations

    func add(_ profile: MaterialProfile) {
        custom.append(changesOnly(profile))
        save()
        rebuild()
    }

    func update(_ profile: MaterialProfile) {
        guard !profile.isSystem, let idx = custom.firstIndex(where: { $0.id == profile.id }) else { return }
        custom[idx] = changesOnly(profile)
        save()
        rebuild()
    }

    /// Deletes a user material, or takes a picked OrcaSlicer filament off the list.
    func delete(id: UUID) {
        if let name = pinned.first(where: { PresetLibrary.stableID(.filament, $0) == id }) {
            pinned.removeAll { $0 == name }
            UserDefaults.standard.set(pinned, forKey: "pinnedFilaments")
        }
        custom.removeAll { $0.id == id }
        save()
        rebuild()
    }

    func select(id: UUID) {
        selectedProfileId = id
    }
}
