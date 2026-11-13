import SwiftUI
import simd

/// Picks a tool: physical tools 1…N, then mixes, as colour chips. `allowsDefault`
/// adds "Default" (0 = the object's tool, for parts).
struct ToolChips: View {
    @Binding var tool: Int
    let palette: ToolPalette
    var allowsDefault = false

    private var choices: [Int] {
        (allowsDefault ? [0] : []) + Array(1...max(1, palette.physical.count)) + palette.mixes.map(\.id)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(choices, id: \.self) { choice in
                    Button { tool = choice } label: {
                        Group {
                            if choice == 0 {
                                Text("Default").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 5))
                            } else {
                                ToolBadge(tool: choice, colour: palette.colour(choice))
                            }
                        }
                        .padding(2)
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(choice == effective ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice == 0 ? "Default tool" : ToolBadge(tool: choice, colour: .grey).label)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// The physical tool count can shrink below a stored tool; show it as tool 1.
    private var effective: Int {
        if tool == 0 || ToolMix.isMix(tool) { return tool }
        return tool <= palette.physical.count ? tool : 1
    }
}

/// An object's tool and its volumes (parts, modifiers, …) with their tools.
/// Tapping a volume that isn't a printable part shows it in the 3D view.
struct ModelPartsView: View {
    @Binding var model: PlacedModel
    let palette: ToolPalette
    @Binding var shownPart: Int?
    /// The modifier the 3D view's arrows move and size.
    @Binding var activeModifier: UUID?
    /// The slice profile's values, shown as each setting's default.
    let baseSettings: [String: String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ToolChips(tool: $model.extruder.toolDefaultingToOne, palette: palette)
                } header: {
                    Text("Object Tool")
                } footer: {
                    if missingTools.isEmpty == false {
                        Text("This printer has \(palette.physical.count) tool\(palette.physical.count == 1 ? "" : "s"); \(missingTools.map { "T\($0)" }.joined(separator: ", ")) will print with T1.")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    ForEach($model.toolBands) { $band in
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("From height (mm)") {
                                FloatField(value: Binding(get: { Float(band.fromZ) },
                                                          set: { band.fromZ = max(0, Double($0)) }), fmt: "%g")
                            }
                            ToolChips(tool: $band.tool, palette: palette, allowsDefault: true)
                        }
                    }
                    .onDelete { model.toolBands.remove(atOffsets: $0) }
                    Button {
                        let top = model.meshInfo.map { Double($0.sizeMMZ * model.transform.scale.z) } ?? 20
                        let from = model.toolBands.map(\.fromZ).max().map { min(top, $0 + top / 4) } ?? top / 2
                        model.toolBands.append(ToolBand(fromZ: (from * 10).rounded() / 10, tool: 0))
                    } label: {
                        Label("Add Tool Change", systemImage: "plus")
                    }
                } header: {
                    Text("Colour by Height")
                } footer: {
                    Text("From each height up, the model prints with that tool. You can also add one at the current layer in the sliced preview.")
                }
                Section {
                    ForEach($model.modifiers) { $modifier in
                        modifierRow($modifier)
                    }
                    .onDelete { model.modifiers.remove(atOffsets: $0) }
                    Menu {
                        ForEach(ModelModifier.Shape.allCases, id: \.self) { shape in
                            Button { addModifier(shape) } label: { Label(shape.label, systemImage: shape.icon) }
                        }
                    } label: {
                        Label("Add Modifier", systemImage: "plus")
                    }
                } header: {
                    Text("Modifiers")
                } footer: {
                    Text("A modifier changes settings (or the tool) where it overlaps the model, e.g. 100% infill around a screw hole. Tap one to move and size it with the arrows in the 3D view; the model's modifiers show see-through while it's selected.")
                }
                if !model.parts.isEmpty {
                    Section {
                        ForEach(model.parts.indices, id: \.self) { k in
                            partRow(k)
                        }
                    } header: {
                        Text("Parts")
                    } footer: {
                        Text("From the model's file. Its modifiers, negative volumes and support blockers show see-through while the model is selected; tap the eye to highlight one.")
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

    private func modifierRow(_ modifier: Binding<ModelModifier>) -> some View {
        let m = modifier.wrappedValue
        let isActive = activeModifier == m.id
        return HStack {
            Button { activeModifier = isActive ? nil : m.id } label: {
                HStack {
                    Image(systemName: m.shape.icon).foregroundStyle(.yellow).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.name).foregroundStyle(.primary)
                        Text(ModifierEditorView.summary(m)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if m.tool > 0 { ToolBadge(tool: m.tool, colour: palette.colour(m.tool), compact: true) }
                    if isActive {
                        Image(systemName: "move.3d").foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Editing in 3D view")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NavigationLink {
                ModifierEditorView(modifier: modifier, palette: palette, baseSettings: baseSettings)
                    .onAppear { activeModifier = m.id }
            } label: { EmptyView() }
            .frame(width: 20)
        }
        .listRowBackground(isActive ? Color.accentColor.opacity(0.15) : nil)
    }

    /// A new modifier at the model's centre, a third of its size.
    private func addModifier(_ shape: ModelModifier.Shape) {
        let info = model.meshInfo
        var size = SIMD3<Float>(info?.sizeMMX ?? 30, info?.sizeMMY ?? 30, info?.sizeMMZ ?? 30) / 3
        size = simd_max(size, SIMD3(repeating: 5))
        if shape == .sphere { size = SIMD3(repeating: size.min()) }
        if shape == .cylinder { size.x = min(size.x, size.y); size.y = size.x }
        let modifier = ModelModifier(shape: shape, centreMM: .zero,
                                     sizeMM: (size * 10).rounded(.toNearestOrAwayFromZero) / 10,
                                     settings: ["sparse_infill_density": "100%"])
        model.modifiers.append(modifier)
        activeModifier = modifier.id
    }

    @ViewBuilder
    private func partRow(_ k: Int) -> some View {
        let part = model.parts[k]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: part.kind.icon).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(part.name.isEmpty ? "Part \(k + 1)" : part.name).lineLimit(1)
                    Text(part.kind.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if part.isPainted {
                    HStack(spacing: 3) {
                        Image(systemName: "paintbrush.pointed.fill").font(.caption).foregroundStyle(.secondary)
                        ForEach(part.paintedTools, id: \.self) {
                            ToolBadge(tool: $0, colour: palette.colour($0), compact: true)
                        }
                    }
                }
                if part.supportsPainted || part.seamPainted {
                    Text([part.supportsPainted ? "Supports" : nil, part.seamPainted ? "Seam" : nil]
                            .compactMap { $0 }.joined(separator: " · ") + " painted")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if part.kind != .part {
                    Button { shownPart = shownPart == k ? nil : k } label: {
                        Image(systemName: shownPart == k ? "eye.fill" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(shownPart == k ? "Hide in 3D view" : "Show in 3D view")
                }
            }
            if part.kind.takesTool {
                ToolChips(tool: $model.parts[k].extruder, palette: palette, allowsDefault: true)
            }
        }
    }

    private var missingTools: [Int] {
        let used = model.usedTools
        let physical = used.filter { !ToolMix.isMix($0) }.union(palette.physicalTools(used.filter(ToolMix.isMix)))
        return physical.filter { $0 > palette.physical.count }.sorted()
    }
}

extension ModelPart.Kind {
    var label: String {
        switch self {
        case .part: return "Part"
        case .negative: return "Negative volume"
        case .modifier: return "Modifier"
        case .supportBlocker: return "Support blocker"
        case .supportEnforcer: return "Support enforcer"
        }
    }
    var icon: String {
        switch self {
        case .part: return "cube.fill"
        case .negative: return "minus.square"
        case .modifier: return "slider.horizontal.3"
        case .supportBlocker: return "nosign"
        case .supportEnforcer: return "square.stack.3d.up"
        }
    }
    /// Parts and modifiers can set a tool; the others don't print.
    var takesTool: Bool { self == .part || self == .modifier }
}

private extension Int {
    /// The object tool shown as T1 when it's the default (0).
    var toolDefaultingToOne: Int {
        get { self == 0 ? 1 : self }
        set { self = newValue == 1 ? 0 : newValue }
    }
}

extension ModelPart.Kind {
    /// See-through colour when the volume is shown in the 3D view.
    var overlayColour: UIColor {
        switch self {
        case .part: return .lightGray
        case .negative: return .darkGray
        case .modifier: return .systemYellow
        case .supportBlocker: return .systemRed
        case .supportEnforcer: return .systemGreen
        }
    }
}

extension View {
    /// Keeps the view behind a medium-height sheet usable (iOS 16.4+), so a
    /// shown volume can be looked at while the sheet is open.
    @ViewBuilder
    func interactiveBehindMediumSheet() -> some View {
        if #available(iOS 16.4, *) {
            presentationBackgroundInteraction(.enabled(upThrough: .medium))
        } else {
            self
        }
    }
}
