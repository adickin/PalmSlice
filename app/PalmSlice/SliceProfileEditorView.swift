import SwiftUI

struct SliceProfileEditorView: View {
    enum Mode { case add, edit }

    let mode: Mode
    @EnvironmentObject var sliceProfileStore: SliceProfileStore
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var materialProfileStore: MaterialProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: SliceProfile
    @State private var showHelp = false
    @State private var basePrint: String? = nil
    @State private var baseSettings: [String: String] = [:]
    @State private var showBasePicker = false

    init(mode: Mode, profile: SliceProfile = SliceProfile()) {
        self.mode = mode
        _draft = State(initialValue: profile)
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                layersSection
                wallsSection
                topBottomSection
                ironingSection
                infillSection
                speedSection
                supportSection
                if (profileStore.selectedProfile?.numberOfExtruders ?? 1) > 1 {
                    multiMaterialSection
                }
                adhesionSection
                advancedSection
                DefaultsSection(
                    profile: $draft, basePresetName: basePrint, baseSettings: baseSettings,
                    onChooseBase: { showBasePicker = true },
                    onResetBase: draft.basePreset == nil ? nil : { draft.basePreset = nil })
                helpButtonSection
            }
            .task(id: draft.basePreset) { await loadBase() }
            .sheet(isPresented: $showBasePicker) {
                PresetPickerView(type: .print, printerPreset: profileStore.selectedProfile?.systemPreset) { name in
                    // Start over from the chosen preset, keeping identity and name.
                    var p = SliceProfile.from(printPreset: name, name: draft.name)
                    p.id = draft.id
                    draft = p
                }
            }
            .navigationTitle(mode == .add ? "New Slice Profile" : "Edit Slice Profile")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .navigationBarItems(
                leading: Button("Cancel") { dismiss() },
                trailing: Button("Save", action: save)
            )
            .sheet(isPresented: $showHelp) {
                SliceProfileHelpView()
            }
        }
    }

    private var helpButtonSection: some View {
        Section {
            Button {
                showHelp = true
            } label: {
                Label("Setting Descriptions", systemImage: "questionmark.circle")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// The PrusaSlicer print preset this profile is layered on for the
    /// selected printer, and its settings.
    private func loadBase() async {
        let printer = profileStore.selectedProfile ?? PrinterProfile()
        let material = materialProfileStore.selectedProfile
        let slice = draft
        let result = await Task.detached(priority: .userInitiated) { () -> (String, [String: String])? in
            guard let base = SliceSetup.base(printer: printer, material: material, slice: slice) else { return nil }
            return (base.print, PresetLibrary.settings(.print, base.print) ?? [:])
        }.value
        basePrint = result?.0
        baseSettings = result?.1 ?? [:]
    }

    // MARK: - Sections

    // Settings without a typed field, read over the base preset and written
    // to the profile's extra settings.
    private func setting(_ key: String) -> String? { draft.prusaSettings()[key] ?? baseSettings[key] }
    private func boolSetting(_ key: String, _ fallback: Bool = false) -> Binding<Bool> {
        Binding(get: { setting(key).flatMap(PrusaValue.parseBool) ?? fallback },
                set: { draft.setPrusaSetting(key, PrusaValue.bool($0)) })
    }
    private func floatSetting(_ key: String, _ fallback: Float = 0, integer: Bool = false) -> Binding<Float> {
        Binding(get: { setting(key).flatMap(PrusaValue.parseFloat).map(Float.init) ?? fallback },
                set: { draft.setPrusaSetting(key, PrusaValue.float(Double(integer ? $0.rounded() : $0))) })
    }

    /// Wipe tower and ooze control, for printers with more than one tool.
    @ViewBuilder
    private var multiMaterialSection: some View {
        Section {
            Toggle("Wipe Tower", isOn: boolSetting("wipe_tower", true))
            if boolSetting("wipe_tower", true).wrappedValue {
                LabeledContent("Width (mm)") { FloatField(value: floatSetting("wipe_tower_width", 60), fmt: "%g") }
                LabeledContent("Brim Width (mm)") { FloatField(value: floatSetting("wipe_tower_brim_width", 2), fmt: "%g") }
                LabeledContent("Bridging (mm)") { FloatField(value: floatSetting("wipe_tower_bridging", 10), fmt: "%g") }
                Toggle("Wipe into Infill", isOn: boolSetting("wipe_into_infill"))
                Toggle("Wipe into Objects", isOn: boolSetting("wipe_into_objects"))
            }
            Toggle("Ooze Prevention", isOn: boolSetting("ooze_prevention"))
            if boolSetting("ooze_prevention").wrappedValue {
                LabeledContent("Standby Temperature Δ (°C)") {
                    FloatField(value: floatSetting("standby_temperature_delta", -5, integer: true), fmt: "%g")
                }
            }
        } header: {
            Text("Multi-Material")
        } footer: {
            Text("Each tool change primes the next tool on the wipe tower. Drag the tower on the bed to place it. Ooze prevention drops idle tools to a standby temperature.")
        }
    }

    private var nameSection: some View {
        Section("Name") {
            TextField("Profile name", text: $draft.name)
        }
    }

    private var layersSection: some View {
        Section("Layers") {
            LabeledContent("Layer Height (mm)") {
                TextField("0.2", value: $draft.layerHeight, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("First Layer Height (mm)") {
                TextField("0.2", value: $draft.firstLayerHeight, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var wallsSection: some View {
        Section("Walls") {
            Stepper("Wall Count: \(draft.wallCount)", value: $draft.wallCount, in: 1...20)
            LabeledContent("Horizontal Expansion (mm)") {
                TextField("0", value: $draft.horizontalExpansion, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            Picker("Wall Generator", selection: $draft.wallGenerator) {
                ForEach(WallGenerator.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Outer Wall First", isOn: $draft.externalPerimetersFirst)
        }
    }

    private func layerThicknessCaption(_ layers: Int) -> String {
        String(format: "≈ %.2f mm", Double(layers) * draft.layerHeight)
    }

    // Min Top/Bottom Thickness is the physically-meaningful control (mm) —
    // typing a thickness updates the layer count to match, the way
    // PrusaSlicer's own UI derives layer count from a target thickness.
    // The layer Stepper still works independently afterward; it just won't
    // rewrite a thickness you already typed.
    private func syncLayersFromThickness() {
        guard draft.layerHeight > 0 else { return }
        if draft.topThickness > 0 {
            draft.topLayers = Int(ceil(draft.topThickness / draft.layerHeight))
        }
        if draft.bottomThickness > 0 {
            draft.bottomLayers = Int(ceil(draft.bottomThickness / draft.layerHeight))
        }
    }

    private var topBottomSection: some View {
        Section("Top / Bottom") {
            Stepper(value: $draft.topLayers, in: 0...20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Top Layers: \(draft.topLayers)")
                    Text(layerThicknessCaption(draft.topLayers))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Stepper(value: $draft.bottomLayers, in: 0...20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bottom Layers: \(draft.bottomLayers)")
                    Text(layerThicknessCaption(draft.bottomLayers))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Min Top Thickness (mm)") {
                TextField("0", value: $draft.topThickness, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Min Bottom Thickness (mm)") {
                TextField("0", value: $draft.bottomThickness, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
        }
        .onChange(of: draft.topThickness) { _ in syncLayersFromThickness() }
        .onChange(of: draft.bottomThickness) { _ in syncLayersFromThickness() }
    }

    private var infillSection: some View {
        Section("Infill") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Density")
                    Spacer()
                    Text("\(draft.infillDensity)%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(draft.infillDensity) },
                    set: { draft.infillDensity = Int($0.rounded()) }
                ), in: 0...100, step: 1)
            }
            Picker("Pattern", selection: $draft.infillPattern) {
                ForEach(InfillPattern.allCases) { pattern in
                    Text(pattern.rawValue).tag(pattern)
                }
            }
            LabeledContent("Infill Overlap (%)") {
                TextField("15", value: $draft.infillOverlap, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var speedSection: some View {
        Section("Speed (mm/s)") {
            LabeledContent("Print (Perimeter)") {
                TextField("60", value: $draft.printSpeed, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Infill") {
                TextField("80", value: $draft.infillSpeed, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Travel") {
                TextField("120", value: $draft.travelSpeed, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("First Layer") {
                TextField("30", value: $draft.firstLayerSpeed, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Solid Infill") {
                TextField("20", value: $draft.solidInfillSpeed, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Top Solid Infill") {
                TextField("15", value: $draft.topSolidInfillSpeed, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var advancedSection: some View {
        Section {
            Picker("Slicing Mode", selection: $draft.slicingMode) {
                ForEach(SlicingMode.allCases) { Text($0.rawValue).tag($0) }
            }
            LabeledContent("Gap Closing Radius (mm)") {
                TextField("0.049", value: $draft.gapClosingRadius, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Line Width (mm)") {
                TextField("Auto", value: $draft.extrusionWidth, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("First Layer Line Width (mm)") {
                TextField("Auto", value: $draft.firstLayerExtrusionWidth, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Line widths of 0 use the default for your printer. Leave these at their defaults unless a model's instructions say otherwise.")
        }
    }

    @ViewBuilder
    private var ironingSection: some View {
        Section("Ironing") {
            Toggle("Enable Ironing", isOn: $draft.ironingEnabled)

            if draft.ironingEnabled {
                Picker("Coverage", selection: $draft.ironingType) {
                    ForEach(IroningType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                LabeledContent("Flow Rate (%)") {
                    TextField("15", value: $draft.ironingFlowrate, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Speed (mm/s)") {
                    TextField("15", value: $draft.ironingSpeed, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Line Spacing (mm)") {
                    TextField("0.1", value: $draft.ironingSpacing, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var supportSection: some View {
        Section("Support") {
            Toggle("Generate Support", isOn: $draft.generateSupport)

            if draft.generateSupport {
                Picker("Style", selection: $draft.supportStyle) {
                    ForEach(SupportStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                Picker("Placement", selection: $draft.supportPlacement) {
                    ForEach(SupportPlacement.allCases) { placement in
                        Text(placement.rawValue).tag(placement)
                    }
                }
                Stepper("Overhang Angle: \(draft.supportOverhangAngle)°",
                        value: $draft.supportOverhangAngle, in: 0...90)
                LabeledContent("Horizontal Expansion (mm)") {
                    TextField("0.7", value: $draft.supportHorizontalExpansion, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Use Support Towers", isOn: $draft.supportUseTowers)

                Stepper("Interface Layers: \(draft.supportInterfaceLayers)",
                        value: $draft.supportInterfaceLayers, in: 0...10)
                LabeledContent("Contact Z Gap (mm)") {
                    TextField("0.15", value: $draft.supportContactDistance, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Interface Spacing (mm)") {
                    TextField("0.2", value: $draft.supportInterfaceSpacing, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var adhesionSection: some View {
        Section {
            Stepper(value: $draft.skirtLoops, in: 0...20) {
                Text(draft.skirtLoops == 0 ? "Skirt: Off" : "Skirt Loops: \(draft.skirtLoops)")
            }
            if draft.skirtLoops > 0 {
                LabeledContent("Skirt Distance (mm)") {
                    TextField("6", value: $draft.skirtDistance, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }
            Picker("Brim", selection: $draft.brimType) {
                ForEach(BrimType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            if draft.brimType != .none {
                LabeledContent("Brim Width (mm)") {
                    TextField("8", value: $draft.brimWidth, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }
            Stepper(value: $draft.raftLayers, in: 0...10) {
                Text(draft.raftLayers == 0 ? "Raft: Off" : "Raft Layers: \(draft.raftLayers)")
            }
        } header: {
            Text("Build Plate Adhesion")
        } footer: {
            Text("Skirt, brim and raft can be combined.")
        }
    }

    // MARK: - Save

    private func save() {
        if mode == .add {
            sliceProfileStore.add(draft)
        } else {
            sliceProfileStore.update(draft)
        }
        dismiss()
    }
}

// MARK: - Help Sheet

private struct SliceProfileHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(helpSections) { section in
                Section(section.title) {
                    ForEach(section.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name)
                                .font(.headline)
                            Text(entry.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Setting Descriptions")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Done") { dismiss() })
        }
    }
}

private struct HelpSection: Identifiable {
    let id = UUID()
    let title: String
    let entries: [HelpEntry]
}

private struct HelpEntry: Identifiable {
    let id = UUID()
    let name: String
    let description: String
}

private let helpSections: [HelpSection] = [
    HelpSection(title: "Layers", entries: [
        HelpEntry(name: "Layer Height",
                  description: "Thickness of each printed layer in mm. Lower values give a smoother surface and finer detail but take much longer to print. Common values: 0.1 mm (fine), 0.2 mm (standard), 0.3 mm (draft)."),
        HelpEntry(name: "First Layer Height",
                  description: "Thickness of only the very first layer. A slightly thicker first layer (e.g. 0.25 mm when printing at 0.2 mm) helps the plastic squish onto the bed and improves adhesion. Usually set equal to or slightly above the main layer height."),
    ]),
    HelpSection(title: "Walls", entries: [
        HelpEntry(name: "Wall Count",
                  description: "Number of perimeter loops printed around the outside of the model. More walls means a stronger, more watertight shell. 2–3 walls is typical; increase to 4+ for parts that need to hold stress or be watertight."),
        HelpEntry(name: "Horizontal Expansion",
                  description: "Shrinks or expands the model outline in XY. Positive values make the print slightly larger (compensates for material shrinkage); negative values make it smaller (useful for tight-tolerance holes or press fits). 0 means no adjustment."),
        HelpEntry(name: "Wall Generator",
                  description: "Arachne (the default) varies line width so thin features and gaps between walls fill cleanly. Classic prints every wall at the same width. Use Classic when a model was designed for it, such as 3DLabPrint planes."),
        HelpEntry(name: "Outer Wall First",
                  description: "Prints the outermost wall before the inner ones on each layer. Gives more accurate outside dimensions and a cleaner skin, but overhangs can sag more because the outer wall has nothing to lean on. Off is the default."),
    ]),
    HelpSection(title: "Top / Bottom", entries: [
        HelpEntry(name: "Top Layers",
                  description: "Number of solid layers printed on the top surface. More layers produce a smoother, more solid top; fewer layers can show the infill pattern through the top. 4–6 is typical for 0.2 mm layer height."),
        HelpEntry(name: "Bottom Layers",
                  description: "Number of solid layers printed on the bottom (first layers on the bed). Similar tradeoff to top layers. Usually the same count as top layers."),
        HelpEntry(name: "Min Top Thickness",
                  description: "The physically-meaningful way to set top thickness: type a target in mm and Top Layers updates automatically to match your layer height. 0.8–1.2 mm is typical — that's usually enough to fully hide the infill pattern without needing an excessive layer count. Set to 0 to go back to specifying Top Layers directly."),
        HelpEntry(name: "Min Bottom Thickness",
                  description: "Same as Min Top Thickness but for the bottom. Set to 0 to go back to specifying Bottom Layers directly."),
    ]),
    HelpSection(title: "Infill", entries: [
        HelpEntry(name: "Density",
                  description: "How much of the interior is filled with plastic, as a percentage. 0% is hollow, 100% is completely solid. 15–20% is common for decorative prints; 40%+ for parts that need structural strength."),
        HelpEntry(name: "Pattern",
                  description: "The geometry of the infill structure inside the model. Gyroid is strong in all directions and prints well at high speeds. Grid is simple and fast. Honeycomb is efficient. Adaptive Cubic gets denser near surfaces automatically. Lightning is ultra-fast with minimal material but weak — good for display models only."),
        HelpEntry(name: "Infill Overlap",
                  description: "How far infill lines push into the perimeters, as a percent of extrusion width. Some overlap is needed to bond the infill to the walls. The stock value is 25%, but on dense or fully-solid parts that over-packs material with nowhere to go, forcing it out through the walls (bulging, rough layer lines). 15% is a good balance; lower it further (10%) if solid parts still bulge, raise it if infill separates from the walls. If bulging persists at low overlap, the cause is likely over-extrusion — calibrate flow via the Material profile's extrusion multiplier."),
    ]),
    HelpSection(title: "Advanced", entries: [
        HelpEntry(name: "Slicing Mode",
                  description: "Regular treats everything inside the model's outer surface as solid. Even/Odd treats areas inside two overlapping shells as empty, so overlaps cancel out. 3DLabPrint planes need Even/Odd to form their internal ribs; other models should use Regular."),
        HelpEntry(name: "Gap Closing Radius",
                  description: "Closes cracks in the model's outline smaller than this radius when slicing, which hides small mesh errors. The default is 0.049 mm. Set 0 for models with intentional tiny gaps, such as 3DLabPrint planes."),
        HelpEntry(name: "Line Width",
                  description: "Width of each extruded line in mm. 0 (Auto) uses your printer's default width, typically about 0.45 mm for a 0.4 mm nozzle. Only set this when a model's instructions give a specific width."),
        HelpEntry(name: "First Layer Line Width",
                  description: "Line width for the first layer only. 0 (Auto) uses your printer's default width. A slightly wider first layer helps it stick to the bed."),
    ]),
    HelpSection(title: "Speed", entries: [
        HelpEntry(name: "Print Speed (Perimeter)",
                  description: "How fast the nozzle moves while printing the outer walls. This has the biggest impact on surface quality — slower produces better results. 40–60 mm/s is typical; go lower for high-detail prints."),
        HelpEntry(name: "Infill Speed",
                  description: "How fast the nozzle moves while printing the interior infill. Since infill is hidden inside the model, it can go faster than the perimeter without affecting visible quality. 60–100 mm/s is common."),
        HelpEntry(name: "Travel Speed",
                  description: "How fast the nozzle moves when not extruding plastic (moving between features). Faster travel reduces stringing and print time. 120–150 mm/s is typical; direct-drive printers can go faster than Bowden."),
        HelpEntry(name: "First Layer Speed",
                  description: "Speed for the entire first layer only. Printing slowly on the first layer gives the plastic more time to adhere to the bed. 20–30 mm/s is common regardless of other speed settings."),
        HelpEntry(name: "Solid Infill",
                  description: "How fast the nozzle moves while printing solid regions (top, bottom, and any solid internal shells) — slower than sparse infill since every pass here is visible or load-bearing. 15–25 mm/s is typical."),
        HelpEntry(name: "Top Solid Infill",
                  description: "How fast the nozzle moves on the very top, outward-facing solid layer specifically. This is the slowest infill speed of all — it's the one surface you'll actually see, so quality matters most here. 10–20 mm/s is typical."),
    ]),
    HelpSection(title: "Ironing", entries: [
        HelpEntry(name: "Enable Ironing",
                  description: "Adds a second, low-flow finishing pass over solid top surfaces after solid infill prints, melting down the ridges left between infill lines for a smoother finish. Most worth turning on when Top Layers or Min Top Thickness is high enough that those ridges are clearly visible on a large flat top — it does add print time."),
        HelpEntry(name: "Coverage",
                  description: "Which surfaces get ironed. All Top Surfaces irons every upward-facing solid region. Topmost Surface Only irons just the very last layer of the print — faster, and enough if only the final top matters. All Solid Surfaces also irons internal solid shells, not just the outside."),
        HelpEntry(name: "Flow Rate",
                  description: "How much plastic the ironing pass extrudes, as a percentage of normal flow. Low on purpose — ironing is meant to smear existing plastic flat, not add more. 10–20% is typical; too high causes over-extrusion and blobs on the ironed surface."),
        HelpEntry(name: "Speed",
                  description: "How fast the ironing pass moves. Slower gives the plastic more time to flatten out but adds print time. 10–20 mm/s is typical."),
        HelpEntry(name: "Line Spacing",
                  description: "Distance between adjacent ironing passes. Smaller spacing gives a smoother result but takes longer since more passes are needed to cover the same area. 0.1 mm is typical."),
    ]),
    HelpSection(title: "Support", entries: [
        HelpEntry(name: "Generate Support",
                  description: "When on, the slicer automatically adds support structures under overhanging sections of the model that would otherwise print in mid-air. Supports are removed after printing and usually leave a rough surface where they touched."),
        HelpEntry(name: "Style",
                  description: "Normal (Snug) generates a tight grid structure — strong but can be hard to remove. Tree (Organic) grows branching columns up from the bed — easier to remove and touches the model less, but takes longer to generate and can be less stable on large overhangs."),
        HelpEntry(name: "Placement",
                  description: "Everywhere allows supports to grow from any part of the model surface. Touching Build Plate Only restricts supports to columns that start from the bed — cleaner result but some overhangs may go unsupported."),
        HelpEntry(name: "Overhang Angle",
                  description: "The steepness of an overhang (measured from vertical) that triggers support generation. 50° is the standard — most FDM printers can bridge shallower angles without support. Lower this value to add more support; raise it to add less."),
        HelpEntry(name: "Horizontal Expansion",
                  description: "Gap in mm between the edge of the model and the edge of the support structure in XY. A larger gap makes supports easier to remove but leaves the overhang slightly unsupported near the edges. 0.5–1.0 mm is typical."),
        HelpEntry(name: "Use Support Towers",
                  description: "Adds a sheath (outer wall) around support columns to make them more rigid and less likely to topple on tall, narrow supports. Useful for tall models with small overhangs far from the bed."),
        HelpEntry(name: "Interface Layers",
                  description: "Number of dense, solid layers placed directly between the support and the model — the 'seat' the part builds on. More layers give a more solid, cleaner supported surface; fewer save time and filament. 3 is a good default. This count is mirrored onto the bottom of the supports as well."),
        HelpEntry(name: "Contact Z Gap",
                  description: "Vertical gap left between the top of the support and the model's supported surface. The larger this gap, the easier supports are to remove — but the rougher and less solid that bottom surface prints. The stock 0.2 mm leaves a full layer-height gap; drop toward 0.10–0.15 mm for a much more solid bottom (at the cost of harder removal)."),
        HelpEntry(name: "Interface Spacing",
                  description: "Line spacing within the interface layers. 0 mm prints a fully solid interface (most solid supported surface); larger values leave gaps that are easier to remove but rougher. 0.2 mm is a good balance."),
    ]),
    HelpSection(title: "Build Plate Adhesion", entries: [
        HelpEntry(name: "Combining",
                  description: "Skirt, brim and raft are independent: use any of them together, or none. Turn all three off when the model has a large flat bottom that adheres well on its own, or the bed surface grips well (e.g. PEI with PLA)."),
        HelpEntry(name: "Skirt",
                  description: "One or more loops printed around — but not touching — the model before the print starts. Primes the nozzle and lets you confirm the first layer height looks correct before the actual print begins. Does not help with adhesion. 0 loops = off."),
        HelpEntry(name: "Brim",
                  description: "A flat ring of extra material printed directly attached to the first layer of the model, extending outward. Greatly increases the contact area with the bed, reducing warping on materials like ABS or PETG and on models with small footprints."),
        HelpEntry(name: "Raft",
                  description: "A thick multi-layer platform printed first, with the actual model on top of it. The raft is peeled off after printing. Most useful for models with very small first-layer footprints, or when printing on a bed that has trouble with first-layer adhesion. 0 layers = off."),
        HelpEntry(name: "Brim Width",
                  description: "How far the brim extends outward from the model edge in mm. Wider brim = more adhesion = harder to remove. 5–8 mm is typical; increase for tall narrow models or warpy materials."),
        HelpEntry(name: "Skirt Loops",
                  description: "How many loops the skirt makes around the model. 1–2 is usually enough to prime the nozzle."),
        HelpEntry(name: "Skirt Distance",
                  description: "How far the skirt sits from the model edge in mm. Keep it small (2–6 mm) so the nozzle is primed close to where printing starts."),
        HelpEntry(name: "Raft Layers",
                  description: "How many layers thick the raft is. More layers make a more stable raft but are harder to remove. 2–3 is typical."),
    ]),
]
