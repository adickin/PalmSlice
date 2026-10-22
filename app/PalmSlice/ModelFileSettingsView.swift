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
                        Text("Applied on top of your slice profile and material for this part only, the way PrusaSlicer does.")
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
        let print = project["print_settings_id"].map(SettingsText.unquote) ?? "print settings"
        let filament = project["filament_settings_id"].flatMap { SettingsText.splitStrings($0).first } ?? "filament"
        return "“\(print)” and “\(filament)”"
    }

    /// Adds (or re-selects) a slice profile and material holding the file's
    /// project settings. All of them are kept, so the profiles slice exactly
    /// as the file's PrusaSlicer project would.
    private func createProfiles(from project: [String: String]) {
        let printName = project["print_settings_id"].map(SettingsText.unquote).flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(model.name) print settings"
        let filamentName = project["filament_settings_id"].flatMap { SettingsText.splitStrings($0).first }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "\(model.name) filament"
        var created: [String] = []

        if let existing = sliceProfileStore.profiles.first(where: { $0.name == printName }) {
            sliceProfileStore.select(id: existing.id)
        } else {
            var p = SliceProfile()
            p.importPrusaSettings(project)
            p.name = printName
            sliceProfileStore.add(p)
            sliceProfileStore.select(id: p.id)
            created.append(printName)
        }
        if let existing = materialProfileStore.profiles.first(where: { $0.name == filamentName }) {
            materialProfileStore.select(id: existing.id)
        } else {
            var m = MaterialProfile()
            m.importPrusaSettings(project)
            m.name = filamentName
            materialProfileStore.add(m)
            materialProfileStore.select(id: m.id)
            created.append(filamentName)
        }
        createdMessage = created.isEmpty
            ? "Already in your profiles — selected “\(printName)” and “\(filamentName)”."
            : "Added and selected “\(created.joined(separator: "” and “"))”."
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
