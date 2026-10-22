import SwiftUI

struct PrinterProfileEditorView: View {
    enum Mode {
        case add
        case edit
    }

    let mode: Mode
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: PrinterProfile
    // Comma-separated string representations for per-extruder material diameters
    @State private var materialDiameterStrings: [String]

    init(mode: Mode, profile: PrinterProfile = PrinterProfile()) {
        self.mode = mode
        _draft = State(initialValue: profile)
        _materialDiameterStrings = State(initialValue:
            profile.extruders.map { ext in
                ext.compatibleMaterialDiameters.map { String($0) }.joined(separator: ", ")
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                machineSection
                gcodeSection
                printheadSection
                extrudersSection
                PrusaSlicerSection(
                    profile: $draft,
                    basePresetName: draft.systemPreset ?? "None (custom printer)",
                    baseSettings: draft.systemPreset.flatMap { PresetLibrary.settings(.printer, $0) } ?? [:])
            }
            .navigationTitle(mode == .add ? "New Printer" : "Edit Printer")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .navigationBarItems(
                leading: Button("Cancel") { dismiss() },
                trailing: Button("Save", action: save)
            )
            .onChange(of: draft.numberOfExtruders) { newCount in
                syncExtruders(to: newCount)
            }
        }
    }

    // MARK: Sections

    private var nameSection: some View {
        Section("Name") {
            TextField("Printer name", text: $draft.name)
        }
    }

    private var machineSection: some View {
        Section("Machine") {
            LabeledContent("Bed X (mm)") {
                TextField("220", value: $draft.bedX, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Bed Y (mm)") {
                TextField("220", value: $draft.bedY, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Bed Z (mm)") {
                TextField("250", value: $draft.bedZ, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            Picker("Build Plate Shape", selection: $draft.buildPlateShape) {
                ForEach(BuildPlateShape.allCases, id: \.self) { shape in
                    Text(shape.rawValue).tag(shape)
                }
            }
            Toggle("Origin at Center", isOn: $draft.originAtCenter)
            Toggle("Heated Bed", isOn: $draft.heatedBed)
            Toggle("Heated Build Volume", isOn: $draft.heatedBuildVolume)
        }
    }

    private var gcodeSection: some View {
        Section("G-Code") {
            Picker("G-Code Flavor", selection: $draft.gcodeFlavor) {
                ForEach(GCodeFlavor.allCases) { flavor in
                    Text(flavor.rawValue).tag(flavor)
                }
            }
            GCodeEditorView(label: "Start G-Code", text: $draft.startGCode)
                .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
            GCodeEditorView(label: "End G-Code", text: $draft.endGCode)
                .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private var printheadSection: some View {
        Section("Printhead") {
            LabeledContent("X Min (mm)") {
                TextField("-2", value: $draft.printheadXMin, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Y Min (mm, –=back)") {
                TextField("-2", value: $draft.printheadYMin, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("X Max (mm)") {
                TextField("2", value: $draft.printheadXMax, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Y Max (mm, +=front)") {
                TextField("2", value: $draft.printheadYMax, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Gantry Height (mm)") {
                TextField("0", value: $draft.gantryHeight, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            Stepper("Extruders: \(draft.numberOfExtruders)",
                    value: $draft.numberOfExtruders, in: 1...5)
            Toggle("Apply Extruder Offsets to G-Code",
                   isOn: $draft.applyExtruderOffsetsToGCode)
            Toggle("Start G-Code Must Be First",
                   isOn: $draft.startGCodeMustBeFirst)
        }
    }

    @ViewBuilder
    private var extrudersSection: some View {
        ForEach(draft.extruders.indices, id: \.self) { idx in
            Section("Extruder \(idx + 1)") {
                LabeledContent("Nozzle Diameter (mm)") {
                    TextField("0.4", value: $draft.extruders[idx].nozzleDiameter,
                              format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Material Diameters") {
                    TextField("1.75", text: bindingForMaterialDiameters(idx))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Nozzle Offset X (mm)") {
                    TextField("0", value: $draft.extruders[idx].offsetX, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Nozzle Offset Y (mm)") {
                    TextField("0", value: $draft.extruders[idx].offsetY, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Stepper("Cooling Fan: \(draft.extruders[idx].coolingFanNumber)",
                        value: $draft.extruders[idx].coolingFanNumber, in: 0...5)
                LabeledContent("Extruder Change Duration (s)") {
                    TextField("0", value: $draft.extruders[idx].extruderChangeDuration,
                              format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                GCodeEditorView(label: "Extruder Start G-Code",
                                text: $draft.extruders[idx].startGCode)
                    .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                GCodeEditorView(label: "Extruder End G-Code",
                                text: $draft.extruders[idx].endGCode)
                    .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
    }

    // MARK: Helpers

    private func bindingForMaterialDiameters(_ idx: Int) -> Binding<String> {
        Binding(
            get: {
                idx < materialDiameterStrings.count ? materialDiameterStrings[idx] : ""
            },
            set: { newVal in
                while materialDiameterStrings.count <= idx {
                    materialDiameterStrings.append("")
                }
                materialDiameterStrings[idx] = newVal
            }
        )
    }

    private func syncExtruders(to count: Int) {
        let target = max(1, count)
        while draft.extruders.count < target { draft.extruders.append(ExtruderProfile()) }
        if draft.extruders.count > target { draft.extruders = Array(draft.extruders.prefix(target)) }
        while materialDiameterStrings.count < target { materialDiameterStrings.append("1.75") }
        if materialDiameterStrings.count > target {
            materialDiameterStrings = Array(materialDiameterStrings.prefix(target))
        }
    }

    private func save() {
        // Parse comma-separated material diameter strings back into arrays.
        for idx in draft.extruders.indices {
            let str = idx < materialDiameterStrings.count ? materialDiameterStrings[idx] : "1.75"
            draft.extruders[idx].compatibleMaterialDiameters = str
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .filter { $0 > 0 }
            if draft.extruders[idx].compatibleMaterialDiameters.isEmpty {
                draft.extruders[idx].compatibleMaterialDiameters = [1.75]
            }
        }

        if mode == .add {
            profileStore.add(draft)
        } else {
            profileStore.update(draft)
        }
        dismiss()
    }
}
