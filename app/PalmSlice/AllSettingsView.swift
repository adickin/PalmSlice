import SwiftUI

/// libslic3r's description of a PrusaSlicer setting (slicer_setting_info).
struct SettingInfo {
    enum Kind: String { case float, int, percent, float_or_percent, bool, enum_ = "enum", string, point, points }

    let key: String
    let kind: Kind
    let isVector: Bool
    let isNullable: Bool
    let isMultiline: Bool
    let mode: Int           // 0 simple, 1 advanced, 2 expert
    let label: String
    let fullLabel: String
    let category: String
    let units: String
    let tooltip: String
    let enumValues: [String]
    let enumLabels: [String]

    var displayName: String { fullLabel.isEmpty ? (label.isEmpty ? key : label) : fullLabel }

    init?(key: String) {
        guard let raw = slicer_setting_info(key) else { return nil }
        let f = SettingsText.parse(String(cString: raw)).mapValues(PrusaValue.parseString)
        self.key = key
        kind = Kind(rawValue: f["kind"] ?? "") ?? .string
        isVector = f["vector"] == "1"
        isNullable = f["nullable"] == "1"
        isMultiline = f["multiline"] == "1"
        mode = Int(f["mode"] ?? "") ?? 0
        label = f["label"] ?? ""
        fullLabel = f["full_label"] ?? ""
        category = f["category"].flatMap { $0.isEmpty ? nil : $0 } ?? "Other"
        units = f["sidetext"] ?? ""
        tooltip = f["tooltip"] ?? ""
        enumValues = f["enum_values"].map { $0.split(separator: ";", omittingEmptySubsequences: false).map(String.init) } ?? []
        enumLabels = f["enum_labels"].map { $0.split(separator: ";", omittingEmptySubsequences: false).map(String.init) } ?? []
    }

    private static var cache: [String: SettingInfo] = [:]
    private static let lock = NSLock()
    static func cached(_ key: String) -> SettingInfo? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let info = SettingInfo(key: key)
        cache[key] = info
        return info
    }

    /// A short, readable form of a value for list rows.
    func summary(of value: String) -> String {
        if value == "nil" { return "Inherit" }
        switch kind {
        case .bool:
            return value.split(separator: ",").map { $0 == "1" ? "On" : "Off" }.joined(separator: ", ")
        case .enum_:
            if let i = enumValues.firstIndex(of: value), i < enumLabels.count { return enumLabels[i] }
            return value
        case .string:
            let text = PrusaValue.parseString(value)
            let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let lines = text.split(separator: "\n").count
            if text.isEmpty { return "—" }
            return lines > 1 ? "\(firstLine)… (\(lines) lines)" : firstLine
        default:
            return units.isEmpty || value.contains("%") ? value : "\(value) \(units)"
        }
    }
}

/// "PrusaSlicer" section shown at the bottom of each profile editor: which
/// PrusaSlicer preset the profile builds on, and every PrusaSlicer setting.
struct PrusaSlicerSection<P: PrusaIniProfile>: View {
    @Binding var profile: P
    /// Name of the PrusaSlicer preset this profile is layered on.
    let basePresetName: String?
    /// That preset's settings (the values used where the profile sets nothing).
    let baseSettings: [String: String]
    /// Optional: lets the user choose a different base preset.
    var onChooseBase: (() -> Void)? = nil
    var onResetBase: (() -> Void)? = nil

    var body: some View {
        Section {
            if let basePresetName {
                LabeledContent("Based on") {
                    Text(basePresetName).multilineTextAlignment(.trailing)
                }
            }
            if let onChooseBase {
                Button("Change Base Preset…", action: onChooseBase)
            }
            if let onResetBase {
                Button("Use the Printer's Default Preset", action: onResetBase)
            }
            NavigationLink {
                AllSettingsView(profile: $profile, baseSettings: baseSettings)
            } label: {
                LabeledContent("All Settings") {
                    let changed = profile.extraSettings.count
                    Text(changed == 0 ? "" : "\(changed) changed")
                }
            }
            ShareLink(item: PrusaIniFile(fileName: profile.name,
                                         text: ProfileIni.text(profile, baseSettings: baseSettings)),
                      preview: SharePreview("\(profile.name).ini")) {
                Label("Export PrusaSlicer .ini", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("PrusaSlicer")
        } footer: {
            Text("Settings not shown above come from the PrusaSlicer preset. All Settings lists every one of them; change any to override the preset.")
        }
    }
}

/// Every PrusaSlicer setting of a profile's type, grouped by PrusaSlicer's
/// categories, with the effective value (profile, else base preset).
struct AllSettingsView<P: PrusaSettingsConvertible>: View {
    @Binding var profile: P
    let baseSettings: [String: String]

    @State private var search = ""
    @State private var changedOnly = false
    @State private var showExpert = false

    private struct Row: Identifiable {
        let info: SettingInfo
        var id: String { info.key }
    }

    private var rows: [Row] {
        let keys = PrusaKeys.keys(for: P.presetType).union(profile.extraSettings.keys)
        let terms = search.lowercased().split(separator: " ")
        return keys.compactMap { SettingInfo.cached($0) }
            .filter { info in
                if changedOnly && profile.extraSettings[info.key] == nil
                    && !(P.typedKeys.contains(info.key) && profile.prusaSettings()[info.key] != baseSettings[info.key]) {
                    return false
                }
                if !showExpert && info.mode >= 2 && search.isEmpty && profile.extraSettings[info.key] == nil {
                    return false
                }
                guard !terms.isEmpty else { return true }
                let hay = "\(info.displayName) \(info.key) \(info.category)".lowercased()
                return terms.allSatisfy { hay.contains($0) }
            }
            .sorted { ($0.category, $0.displayName) < ($1.category, $1.displayName) }
            .map(Row.init)
    }

    var body: some View {
        let grouped = Dictionary(grouping: rows, by: \.info.category)
        let effective = profile.prusaSettings()
        List {
            Section {
                Toggle("Changed Only", isOn: $changedOnly)
                Toggle("Show Expert Settings", isOn: $showExpert)
            }
            ForEach(grouped.keys.sorted(), id: \.self) { category in
                Section(category) {
                    ForEach(grouped[category]!) { row in
                        let key = row.info.key
                        let value = effective[key] ?? baseSettings[key] ?? ""
                        NavigationLink {
                            SettingEditView(info: row.info, profile: $profile,
                                            baseValue: baseSettings[key])
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(row.info.displayName)
                                    if profile.extraSettings[key] != nil {
                                        Image(systemName: "pencil.circle.fill")
                                            .foregroundStyle(.orange)
                                            .accessibilityLabel("Changed")
                                    }
                                }
                                Text(row.info.summary(of: value))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search settings")
        .navigationTitle("All Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Edits one PrusaSlicer setting. Every value is checked by libslic3r before
/// it's accepted.
struct SettingEditView<P: PrusaSettingsConvertible>: View {
    let info: SettingInfo
    @Binding var profile: P
    let baseValue: String?

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String? = nil

    private var currentValue: String {
        profile.prusaSettings()[info.key] ?? baseValue ?? ""
    }

    var body: some View {
        Form {
            Section {
                editor
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text(info.displayName)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !info.tooltip.isEmpty { Text(info.tooltip) }
                    Text("PrusaSlicer key: \(info.key)").font(.caption.monospaced())
                }
            }
            if let baseValue {
                Section("PrusaSlicer Preset Value") {
                    Text(info.summary(of: baseValue)).foregroundStyle(.secondary)
                    if profile.extraSettings[info.key] != nil || currentValue != baseValue {
                        Button("Use Preset Value") { apply(baseValue, isReset: true) }
                    }
                }
            }
        }
        .navigationTitle(info.label.isEmpty ? info.key : info.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !(info.kind == .bool || info.kind == .enum_) {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apply(info.kind == .string ? PrusaValue.string(text) : text) }
                }
            }
        }
        .onAppear {
            text = info.kind == .string ? PrusaValue.parseString(currentValue) : currentValue
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch info.kind {
        case .bool where !info.isVector:
            Toggle(info.label.isEmpty ? info.key : info.label, isOn: Binding(
                get: { currentValue == "1" },
                set: { apply($0 ? "1" : "0") }))
        case .bool:
            Toggle(info.label.isEmpty ? info.key : info.label, isOn: Binding(
                get: { currentValue.split(separator: ",").first == "1" },
                set: { apply($0 ? "1" : "0") }))
        case .enum_:
            Picker(info.label.isEmpty ? info.key : info.label, selection: Binding(
                get: { currentValue },
                set: { apply($0) })) {
                ForEach(Array(info.enumValues.enumerated()), id: \.offset) { i, value in
                    Text(i < info.enumLabels.count ? info.enumLabels[i] : value).tag(value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        case .string where info.isMultiline:
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 220)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        default:
            HStack {
                TextField(info.key, text: $text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(info.kind == .string ? .default : .numbersAndPunctuation)
                    .onSubmit { apply(info.kind == .string ? PrusaValue.string(text) : text) }
                if !info.units.isEmpty { Text(info.units).foregroundStyle(.secondary) }
            }
            if info.isVector {
                Text("One value per extruder, separated by commas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Validates with libslic3r, then stores the value on the profile.
    private func apply(_ value: String, isReset: Bool = false) {
        guard let h = slicer_create() else { return }
        defer { slicer_destroy(h) }
        guard slicer_apply_settings(h, "\(info.key) = \(value)\n") == 0 else {
            error = String(cString: slicer_last_error(h))
            return
        }
        // Store libslic3r's own serialization of the value.
        let normalized = slicer_get_setting(h, info.key).map { String(cString: $0) } ?? value
        error = nil
        if isReset && !P.typedKeys.contains(info.key) {
            profile.extraSettings[info.key] = nil
        } else {
            profile.setPrusaSetting(info.key, normalized)
        }
        text = info.kind == .string ? PrusaValue.parseString(normalized) : normalized
        if info.kind != .bool && info.kind != .enum_ { dismiss() }
    }
}
