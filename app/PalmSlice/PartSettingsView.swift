import SwiftUI

/// One set of setting overrides, editable in AllSettingsView like a profile.
struct SettingOverrides: SlicerSettingsConvertible {
    static var presetType: PresetType { .print }
    static var typedKeys: Set<String> { [] }
    var extraSettings: [String: String]
    func typedSlicerSettings() -> [String: String] { [:] }
    mutating func updateTyped(from settings: [String: String]) {}

    /// Settings a part or a height range can have (PrusaSlicer's per-object and
    /// per-region settings), less the tool, which Parts & Tools sets.
    static let allowedKeys: Set<String> = Set(String(cString: slicer_object_setting_keys())
        .split(separator: "\n").map(String.init))
        .subtracting(["extruder"])
}

extension ModelFileSettings {
    /// The user's part settings for slicing: ranges that are empty or start
    /// above the part are dropped, and ranges end at the part's top.
    func userText(partHeight: Double) -> String {
        var s = self
        s.ranges = ranges.compactMap { r in
            let hi = min(r.maxZ, partHeight)
            guard hi > r.minZ + 0.001, !r.settings.isEmpty else { return nil }
            return HeightRange(minZ: max(0, r.minZ), maxZ: hi, settings: r.settings)
        }
        return s.text()
    }
}

/// Settings for one part on the bed, over the slice profile (and the part's
/// settings from its file): for the whole part, and for height ranges
/// ("3 walls from 0 to 5 mm"), like PrusaSlicer's per-object and
/// layer-range settings.
struct PartSettingsView: View {
    @Binding var model: PlacedModel
    /// The slice profile's values, shown as each setting's default.
    let baseSettings: [String: String]
    @Environment(\.dismiss) private var dismiss

    private var partHeight: Double {
        model.meshInfo.map { Double($0.sizeMMZ * model.transform.scale.z) } ?? 20
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AllSettingsView(profile: overrides(nil), baseSettings: baseSettings,
                                        allowedKeys: SettingOverrides.allowedKeys)
                            .navigationTitle("Whole Part")
                    } label: {
                        LabeledContent("Settings", value: changedText(model.partSettings.objectSettings))
                    }
                    changedRows(nil)
                } header: {
                    Text("Whole Part")
                } footer: {
                    Text("Used for this part instead of the slice profile's values.")
                }

                Section {
                    ForEach(model.partSettings.ranges.indices, id: \.self) { i in
                        rangeRow(i)
                    }
                    .onDelete { model.partSettings.ranges.remove(atOffsets: $0) }
                    Button {
                        let from = model.partSettings.ranges.map(\.maxZ).max() ?? 0
                        let lo = min(from, max(0, partHeight - 1))
                        model.partSettings.ranges.append(
                            .init(minZ: lo, maxZ: min(partHeight, lo + max(1, partHeight / 4)), settings: [:]))
                    } label: {
                        Label("Add Height Range", systemImage: "plus")
                    }
                } header: {
                    Text("Height Ranges")
                } footer: {
                    Text("Settings for part of the height only, in mm above the bed (this part is \(SlicerValue.float(partHeight)) mm tall). They win over the whole-part settings where they overlap.")
                }

                if model.fileSettings != nil {
                    Section {
                        Text("Settings from this part's file still apply; these go on top of them.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Part Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !model.partSettings.isEmpty {
                        Button("Clear All", role: .destructive) { model.partSettings = ModelFileSettings() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Rows

    private func rangeRow(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("From")
                FloatField(value: height(i, \.minZ), fmt: "%g")
                    .textFieldStyle(.roundedBorder).frame(width: 64)
                Text("to")
                FloatField(value: height(i, \.maxZ), fmt: "%g")
                    .textFieldStyle(.roundedBorder).frame(width: 64)
                Text("mm").foregroundStyle(.secondary)
            }
            if model.partSettings.ranges[i].maxZ <= model.partSettings.ranges[i].minZ {
                Text("The range ends below where it starts, so it's skipped.")
                    .font(.caption).foregroundStyle(.orange)
            }
            NavigationLink {
                AllSettingsView(profile: overrides(i), baseSettings: baseSettings,
                                allowedKeys: SettingOverrides.allowedKeys)
                    .navigationTitle("Height Range")
            } label: {
                LabeledContent("Settings", value: changedText(model.partSettings.ranges[i].settings))
            }
            changedRows(i)
        }
    }

    /// The changed settings of the whole part (nil) or a range, each removable.
    @ViewBuilder
    private func changedRows(_ range: Int?) -> some View {
        let settings = range.map { model.partSettings.ranges[$0].settings } ?? model.partSettings.objectSettings
        ForEach(settings.keys.sorted(), id: \.self) { key in
            let info = SettingInfo.cached(key)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(info?.displayName ?? key).font(.subheadline)
                    Text(info?.summary(of: settings[key] ?? "") ?? settings[key] ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    if let range { model.partSettings.ranges[range].settings[key] = nil }
                    else { model.partSettings.objectSettings[key] = nil }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(info?.displayName ?? key)")
            }
        }
    }

    // MARK: Bindings

    private func overrides(_ range: Int?) -> Binding<SettingOverrides> {
        Binding(
            get: {
                SettingOverrides(extraSettings: range.map { model.partSettings.ranges[$0].settings }
                                 ?? model.partSettings.objectSettings)
            },
            set: { new in
                if let range { model.partSettings.ranges[range].settings = new.extraSettings }
                else { model.partSettings.objectSettings = new.extraSettings }
            })
    }

    private func height(_ i: Int, _ key: WritableKeyPath<ModelFileSettings.HeightRange, Double>) -> Binding<Float> {
        Binding(get: { Float(model.partSettings.ranges[i][keyPath: key]) },
                set: { model.partSettings.ranges[i][keyPath: key] = Double(max(0, $0)) })
    }

    private func changedText(_ settings: [String: String]) -> String {
        settings.isEmpty ? "None" : "\(settings.count) changed"
    }
}
