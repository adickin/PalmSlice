import SwiftUI

/// Shows the PrusaSlicer settings a part's 3MF stores on it, lets the user
/// switch them off, and creates PalmSlice profiles from the file's own
/// print / filament settings.
struct ModelFileSettingsView: View {
    @Binding var model: PlacedModel
    @EnvironmentObject var sliceProfileStore: SliceProfileStore
    @EnvironmentObject var materialProfileStore: MaterialProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var createdMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                if let fs = model.fileSettings {
                    Section {
                        Toggle("Use Settings from File", isOn: $model.useFileSettings)
                        if model.useFileSettings && fs.dependsOnHeight && !model.transform.keepsFileHeights {
                            Label("This part is tilted, so the height-based settings below no longer line up and are skipped. Reset its X/Y rotation to use them.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    } footer: {
                        Text("Applied on top of your slice profile and material for this part only.")
                    }

                    if !fs.objectSettings.isEmpty {
                        Section("Whole Part") {
                            settingRows(fs.objectSettings)
                        }
                    }
                    ForEach(Array(fs.ranges.enumerated()), id: \.offset) { _, range in
                        Section("\(PrusaValue.float(range.minZ))–\(PrusaValue.float(range.maxZ)) mm above the bed") {
                            settingRows(range.settings)
                        }
                    }
                    if let heights = fs.layerHeightRange {
                        Section("Layer Height") {
                            LabeledContent("Variable",
                                           value: "\(PrusaValue.float(heights.lowerBound))–\(PrusaValue.float(heights.upperBound)) mm")
                        }
                    }
                }

                if let project = model.projectSettings {
                    Section {
                        Button("Create Profiles from This File") { createProfiles(from: project) }
                        if let createdMessage {
                            Text(createdMessage).font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("File's Print Settings")
                    } footer: {
                        Text("Adds the slice profile and material the file was set up with (\(names(project))) and selects them. Your printer profile is kept.")
                    }
                }
            }
            .navigationTitle(model.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func settingRows(_ settings: [String: String]) -> some View {
        ForEach(settings.keys.sorted(), id: \.self) { key in
            let info = SettingInfo.cached(key)
            LabeledContent(info?.displayName ?? key,
                           value: info?.summary(of: settings[key]!) ?? settings[key]!)
        }
    }

    private func names(_ project: [String: String]) -> String {
        let n = FileProfiles.names(project, fallback: model.name)
        return "“\(n.print)” and “\(n.filament)”"
    }

    private func createProfiles(from project: [String: String]) {
        createdMessage = FileProfiles.apply(project, fallback: model.name,
                                            slices: sliceProfileStore, materials: materialProfileStore)
    }
}

/// Slice profile + material from a 3MF's project settings (shared by the
/// import prompt and the Settings from File sheet).
enum FileProfiles {
    static func names(_ project: [String: String], fallback: String) -> (print: String, filament: String) {
        let print = project["print_settings_id"].map(SettingsText.unquote).flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(fallback) print settings"
        let filament = project["filament_settings_id"].flatMap { SettingsText.splitStrings($0).first }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "\(fallback) filament"
        return (print, filament)
    }

    /// The profiles the file's settings make (not yet added to any store).
    static func candidates(_ project: [String: String], fallback: String) -> (SliceProfile, MaterialProfile) {
        let n = names(project, fallback: fallback)
        var slice = SliceProfile(); slice.importPrusaSettings(project); slice.name = n.print
        var material = MaterialProfile(); material.importPrusaSettings(project); material.name = n.filament
        return (slice, material)
    }

    /// An existing profile with the candidate's name — or a numbered copy
    /// "name (2)" … — whose settings are the same.
    static func match<P: PrusaIniProfile>(_ candidate: P, in profiles: [P]) -> P? {
        profiles.first { p in
            (p.name == candidate.name || p.name.hasPrefix(candidate.name + " (")) &&
                p.prusaSettings() == candidate.prusaSettings()
        }
    }

    /// First free "name", "name (2)", "name (3)"…
    static func freeName<P: PrusaIniProfile>(_ name: String, in profiles: [P]) -> String {
        let taken = Set(profiles.map(\.name))
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name) (\(n))") { n += 1 }
        return "\(name) (\(n))"
    }

    /// True if the file's slice profile and material are already the selected ones.
    @MainActor
    static func alreadySelected(_ project: [String: String], fallback: String,
                                slices: SliceProfileStore, materials: MaterialProfileStore) -> Bool {
        let (slice, material) = candidates(project, fallback: fallback)
        guard let s = slices.selectedProfile, let m = materials.selectedProfile else { return false }
        return match(slice, in: [s]) != nil && match(material, in: [m]) != nil
    }

    /// Selects the file's slice profile and material, adding them if needed.
    /// Returns a sentence describing what happened.
    @MainActor @discardableResult
    static func apply(_ project: [String: String], fallback: String,
                      slices: SliceProfileStore, materials: MaterialProfileStore) -> String {
        var (slice, material) = candidates(project, fallback: fallback)
        var added: [String] = []
        if let existing = match(slice, in: slices.profiles) {
            slices.select(id: existing.id)
            slice = existing
        } else {
            slice.name = freeName(slice.name, in: slices.profiles)
            slices.add(slice); slices.select(id: slice.id)
            added.append(slice.name)
        }
        if let existing = match(material, in: materials.profiles) {
            materials.select(id: existing.id)
            material = existing
        } else {
            material.name = freeName(material.name, in: materials.profiles)
            materials.add(material); materials.select(id: material.id)
            added.append(material.name)
        }
        return added.isEmpty
            ? "Selected “\(slice.name)” and “\(material.name)”, already in your profiles."
            : "Added and selected “\(added.joined(separator: "” and “"))”" +
              (added.count == 2 ? "." : "; selected the existing “\(added.contains(slice.name) ? material.name : slice.name)”.")
    }
}

/// Small badge marking a part that carries settings from its file.
struct FileSettingsBadge: View {
    let model: PlacedModel
    var body: some View {
        if model.fileSettings != nil || model.projectSettings != nil {
            Image(systemName: model.useFileSettings && model.fileSettings != nil
                  ? "slider.horizontal.3" : "slider.horizontal.below.square.and.square.filled")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(model.useFileSettings ? Color.accentColor : Color.secondary)
                .accessibilityLabel("Settings from file")
        }
    }
}
