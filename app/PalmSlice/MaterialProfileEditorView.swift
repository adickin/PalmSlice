import SwiftUI

struct MaterialProfileEditorView: View {
    enum Mode { case add, edit }

    let mode: Mode
    @EnvironmentObject var materialProfileStore: MaterialProfileStore
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: MaterialProfile
    @State private var baseFilament: String? = nil
    @State private var baseSettings: [String: String] = [:]
    @State private var showBasePicker = false

    init(mode: Mode, profile: MaterialProfile = MaterialProfile()) {
        self.mode = mode
        _draft = State(initialValue: profile)
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                filamentSection
                retractionSection
                coolingSection
                DefaultsSection(
                    profile: $draft, basePresetName: baseFilament, baseSettings: baseSettings,
                    onChooseBase: { showBasePicker = true },
                    onResetBase: draft.basePreset == nil ? nil : { draft.basePreset = nil })
            }
            .task(id: "\(draft.basePreset ?? "")|\(draft.filamentType)") { await loadBase() }
            .sheet(isPresented: $showBasePicker) {
                PresetPickerView(type: .filament, printerPreset: profileStore.selectedProfile?.systemPreset) { name in
                    var m = MaterialProfile.from(filamentPreset: name, name: draft.name)
                    m.id = draft.id
                    draft = m
                }
            }
            .navigationTitle(mode == .add ? "New Material Profile" : "Edit Material Profile")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .navigationBarItems(
                leading: Button("Cancel") { dismiss() },
                trailing: Button("Save", action: save)
            )
        }
    }

    /// The PrusaSlicer filament preset this material is layered on for the
    /// selected printer, and its settings.
    private func loadBase() async {
        let printer = profileStore.selectedProfile
        let material = draft
        let result = await Task.detached(priority: .userInitiated) { () -> (String, [String: String])? in
            guard let base = PresetLibrary.base(printerPreset: printer?.systemPreset,
                                                filamentPreset: material.basePreset,
                                                filamentType: material.filamentType) else { return nil }
            return (base.filament, PresetLibrary.settings(.filament, base.filament) ?? [:])
        }.value
        baseFilament = result?.0
        baseSettings = result?.1 ?? [:]
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section("Name") {
            TextField("Profile name", text: $draft.name)
        }
    }

    // PrusaSlicer filament_type values found in its vendor filament presets.
    // FLEX covers TPU/TPE. A saved type not in this list is kept and shown.
    static let baseFilamentTypes = ["PLA", "PETG", "ABS", "ASA", "FLEX", "PA", "PC", "HIPS", "PVA", "PP"]
    private var filamentTypes: [String] {
        Self.baseFilamentTypes.contains(draft.filamentType)
            ? Self.baseFilamentTypes : Self.baseFilamentTypes + [draft.filamentType]
    }
    private var filamentSection: some View {
        Section("Filament & Temperature") {
            Picker("Type", selection: $draft.filamentType) {
                ForEach(filamentTypes, id: \.self) { Text($0).tag($0) }
            }
            Picker("Diameter", selection: $draft.filamentDiameter) {
                Text("1.75 mm").tag(1.75)
                Text("2.85 mm").tag(2.85)
            }

            LabeledContent("First Layer Temp (°C)") {
                TextField("215", value: $draft.firstLayerTemp, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Other Layers Temp (°C)") {
                TextField("210", value: $draft.otherLayersTemp, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("First Layer Bed Temp (°C)") {
                TextField("60", value: $draft.firstLayerBedTemp, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Other Layers Bed Temp (°C)") {
                TextField("55", value: $draft.otherLayersBedTemp, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Flow Rate")
                    Spacer()
                    Text("\(Int((draft.extrusionMultiplier * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $draft.extrusionMultiplier, in: 0.5...1.5, step: 0.01)
            }
        }
    }

    @ViewBuilder
    private var retractionSection: some View {
        Section {
            Toggle("Set Retraction Here", isOn: $draft.setsRetraction)
            if draft.setsRetraction {
                Toggle("Enable Retraction", isOn: $draft.retractionEnabled)
            }

            if draft.setsRetraction && draft.retractionEnabled {
                LabeledContent("Length (mm)") {
                    TextField("5.0", value: $draft.retractionLength, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Speed (mm/s)") {
                    TextField("45", value: $draft.retractionSpeed, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Extra Deretraction (mm)") {
                    TextField("0.0", value: $draft.retractionRestartExtra, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Z-Hop (mm)") {
                    TextField("0.0", value: $draft.zHop, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Min Travel to Retract (mm)") {
                    TextField("1.0", value: $draft.minTravelForRetraction, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("Retraction")
        } footer: {
            Text(draft.setsRetraction
                 ? "These values replace the printer's retraction while this material is used."
                 : "Uses the printer's own retraction settings, like most filaments.")
        }
    }

    @ViewBuilder
    private var coolingSection: some View {
        Section("Cooling & Fan") {
            Toggle("Enable Cooling", isOn: $draft.coolingEnabled)

            if draft.coolingEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Min Fan Speed")
                        Spacer()
                        Text("\(draft.minFanSpeed)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(draft.minFanSpeed) },
                        set: { draft.minFanSpeed = Int($0.rounded()) }
                    ), in: 0...100, step: 1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Max Fan Speed")
                        Spacer()
                        Text("\(draft.maxFanSpeed)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(draft.maxFanSpeed) },
                        set: { draft.maxFanSpeed = Int($0.rounded()) }
                    ), in: 0...100, step: 1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Bridge Fan Speed")
                        Spacer()
                        Text("\(draft.bridgeFanSpeed)%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(draft.bridgeFanSpeed) },
                        set: { draft.bridgeFanSpeed = Int($0.rounded()) }
                    ), in: 0...100, step: 1)
                }

                Stepper("Disable Fan First \(draft.disableFanFirstLayers) Layer\(draft.disableFanFirstLayers == 1 ? "" : "s")",
                        value: $draft.disableFanFirstLayers, in: 0...10)

                Stepper("Fan On Below \(draft.fanBelowLayerTime) sec/layer",
                        value: $draft.fanBelowLayerTime, in: 1...120)

                Stepper("Slow Down Below \(draft.slowdownBelowLayerTime) sec/layer",
                        value: $draft.slowdownBelowLayerTime, in: 1...60)

                LabeledContent("Min Print Speed (mm/s)") {
                    TextField("10", value: $draft.minPrintSpeed, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    // MARK: - Save

    private func save() {
        if mode == .add {
            materialProfileStore.add(draft)
        } else {
            materialProfileStore.update(draft)
        }
        dismiss()
    }
}
