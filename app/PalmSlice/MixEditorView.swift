import SwiftUI

/// The session's ColorMix mixes: each prints as layers alternating between
/// 2–3 physical tools (blend) or shifting from one tool to another over a
/// height range (gradient). Swatches show PrusaSlicer's colour prediction.
struct MixesView: View {
    @Binding var mixes: [ToolMix]
    let palette: ToolPalette
    /// Mix numbers (tool ids) models use, so deleting one can warn.
    let usedTools: Set<Int>
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ToolMix?
    @State private var showSuggestions = false

    var body: some View {
        NavigationStack {
            List {
                if mixes.isEmpty {
                    Text("No mixes yet. A mix prints alternating layers of two or three filaments, which reads as a new colour from a short distance. Use thin layers (0.08–0.12 mm) for the smoothest result.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(mixes) { mix in
                    Button { editing = mix } label: {
                        HStack(spacing: 10) {
                            MixSwatch(mix: mix, palette: palette)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mix.name).foregroundStyle(.primary)
                                Text(summary(mix)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if usedTools.contains(mix.id) {
                                Text("in use").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { mixes.remove(atOffsets: $0) }
                Section {
                    Button { editing = newMix(.blend) } label: { Label("New Blend", systemImage: "circle.lefthalf.filled") }
                    Button { editing = newMix(.gradient) } label: { Label("New Gradient", systemImage: "square.fill.on.square.fill") }
                    Button { showSuggestions = true } label: { Label("Suggest Mixes…", systemImage: "wand.and.stars") }
                        .disabled(palette.physical.count < 2)
                } footer: {
                    if usedTools.contains(where: ToolMix.isMix) {
                        Text("Deleting a mix that's in use prints those parts with their object's tool.")
                    }
                }
            }
            .navigationTitle("Mixes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $editing) { mix in
                MixEditorView(mix: mix, palette: palette) { saved in
                    if let i = mixes.firstIndex(where: { $0.id == saved.id }) { mixes[i] = saved } else { mixes.append(saved) }
                }
            }
            .sheet(isPresented: $showSuggestions) {
                MixSuggestionsView(palette: palette, existing: mixes) { picked in
                    var next = ToolMix.nextID(in: mixes)
                    for var mix in picked {
                        mix.id = next
                        next += 1
                        mixes.append(mix)
                    }
                }
            }
        }
    }

    private func newMix(_ kind: ToolMix.Kind) -> ToolMix {
        let second = min(2, palette.physical.count)
        return ToolMix(id: ToolMix.nextID(in: mixes), kind: kind,
                       components: kind == .blend
                           ? [.init(tool: 1, amount: 0.5), .init(tool: second, amount: 0.5)]
                           : [.init(tool: 1, amount: 0), .init(tool: second, amount: 1)])
    }

    private func summary(_ mix: ToolMix) -> String {
        switch mix.kind {
        case .blend:
            let total = max(mix.components.map(\.amount).reduce(0, +), 0.0001)
            return "Blend " + mix.components.map { "T\($0.tool) \(Int(($0.amount / total * 100).rounded()))%" }.joined(separator: " · ")
        case .gradient:
            var s = "Gradient " + mix.components.sorted { $0.amount < $1.amount }.map { "T\($0.tool)" }.joined(separator: " → ")
            if let lo = mix.minZ, let hi = mix.maxZ { s += String(format: " (%g–%g mm)", lo, hi) }
            return s
        }
    }
}

/// A mix's predicted colour; gradients show their stops' colours too.
struct MixSwatch: View {
    let mix: ToolMix
    let palette: ToolPalette

    var body: some View {
        ZStack {
            if mix.kind == .gradient {
                LinearGradient(colors: mix.components.sorted { $0.amount < $1.amount }.map { palette.colour($0.tool).color },
                               startPoint: .bottom, endPoint: .top)
            } else {
                mix.predictedColour(toolColours: palette.physical).color
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
    }
}

/// Edits one mix: its tools and their shares (blend) or stop positions and
/// height range (gradient), with a live colour prediction.
struct MixEditorView: View {
    @State var mix: ToolMix
    let palette: ToolPalette
    let onSave: (ToolMix) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var autoRange: Bool

    init(mix: ToolMix, palette: ToolPalette, onSave: @escaping (ToolMix) -> Void) {
        _mix = State(initialValue: mix)
        self.palette = palette
        self.onSave = onSave
        _autoRange = State(initialValue: mix.minZ == nil || mix.maxZ == nil)
    }

    private var tools: [Int] { Array(1...max(1, palette.physical.count)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        MixSwatch(mix: mix, palette: palette).scaleEffect(1.6).frame(width: 56, height: 56)
                        VStack(alignment: .leading) {
                            Text(mix.name).font(.headline)
                            Text(mix.predictedColour(toolColours: palette.physical).hex)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Kind", selection: $mix.kind) {
                        Text("Blend").tag(ToolMix.Kind.blend)
                        Text("Gradient").tag(ToolMix.Kind.gradient)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mix.kind) { kind in
                        // Blend shares and gradient stops mean different things; reset them.
                        let n = mix.components.count
                        for i in mix.components.indices {
                            mix.components[i].amount = kind == .blend ? 1 / Double(n) : Double(i) / Double(max(n - 1, 1))
                        }
                    }
                }
                Section {
                    ForEach(mix.components.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Picker(mix.kind == .blend ? "Tool" : "Stop \(i + 1)", selection: $mix.components[i].tool) {
                                    ForEach(tools, id: \.self) { t in Text("T\(t)").tag(t) }
                                }
                                Circle().fill(palette.colour(mix.components[i].tool).color).frame(width: 16, height: 16)
                            }
                            HStack {
                                Text(mix.kind == .blend ? "Share" : "Position").font(.caption).foregroundStyle(.secondary)
                                Slider(value: $mix.components[i].amount, in: mix.kind == .blend ? 0.05...1 : 0...1)
                                Text(mix.kind == .blend ? "\(Int((share(i) * 100).rounded()))%" : "\(Int((mix.components[i].amount * 100).rounded()))%")
                                    .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                    .onDelete { offsets in if mix.components.count - offsets.count >= 2 { mix.components.remove(atOffsets: offsets) } }
                    if mix.components.count < (mix.kind == .blend ? 3 : 5) {
                        Button {
                            let unused = tools.first { t in !mix.components.contains { $0.tool == t } } ?? 1
                            mix.components.append(.init(tool: unused, amount: mix.kind == .blend ? 1 / Double(mix.components.count + 1) : 1))
                        } label: { Label(mix.kind == .blend ? "Add Tool" : "Add Stop", systemImage: "plus") }
                    }
                } header: {
                    Text(mix.kind == .blend ? "Tools" : "Stops (bottom to top)")
                } footer: {
                    Text(mix.kind == .blend
                         ? "Layers cycle through the tools in proportion to their shares, e.g. 2:1 prints two layers of the first tool for every one of the second."
                         : "The mix shifts from the first stop's tool at the bottom to the last stop's at the top.")
                }
                if mix.kind == .gradient {
                    Section {
                        Toggle("Whole Height of the Region", isOn: $autoRange)
                        if !autoRange {
                            LabeledContent("From (mm)") { FloatField(value: zBinding(\.minZ, 0), fmt: "%g") }
                            LabeledContent("To (mm)") { FloatField(value: zBinding(\.maxZ, 20), fmt: "%g") }
                        }
                    } header: {
                        Text("Height Range")
                    } footer: {
                        Text("Off: the gradient runs between fixed heights above the bed.")
                    }
                }
            }
            .navigationTitle(mix.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = mix
                        if saved.kind == .blend || autoRange { saved.minZ = nil; saved.maxZ = nil }
                        if let lo = saved.minZ, let hi = saved.maxZ, hi <= lo { saved.maxZ = lo + 1 }
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(Set(mix.tools).count < 2)
                }
            }
        }
    }

    private func share(_ i: Int) -> Double {
        mix.components[i].amount / max(mix.components.map(\.amount).reduce(0, +), 0.0001)
    }

    private func zBinding(_ key: WritableKeyPath<ToolMix, Double?>, _ fallback: Double) -> Binding<Float> {
        Binding(get: { Float(mix[keyPath: key] ?? fallback) }, set: { mix[keyPath: key] = max(0, Double($0)) })
    }
}

/// Useful 2- and 3-tool blends of the loaded filaments, skipping ones that look
/// like a filament or an existing mix (CIEDE2000 below a threshold).
struct MixSuggestionsView: View {
    let palette: ToolPalette
    let existing: [ToolMix]
    let onAdd: ([ToolMix]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<Int> = []

    private struct Suggestion: Identifiable {
        let id: Int
        let mix: ToolMix
    }

    private var suggestions: [Suggestion] {
        let tools = Array(1...max(1, palette.physical.count))
        var candidates: [ToolMix] = []
        for a in tools { for b in tools where b > a {
            for ratio in [0.25, 0.5, 0.75] {
                candidates.append(ToolMix(id: 0, components: [.init(tool: a, amount: ratio), .init(tool: b, amount: 1 - ratio)]))
            }
            for c in tools where c > b {
                candidates.append(ToolMix(id: 0, components: [.init(tool: a, amount: 1), .init(tool: b, amount: 1), .init(tool: c, amount: 1)]))
            }
        } }
        var kept: [HexColour] = palette.physical + existing.map { $0.predictedColour(toolColours: palette.physical) }
        var out: [Suggestion] = []
        for mix in candidates {
            let colour = mix.predictedColour(toolColours: palette.physical)
            if kept.allSatisfy({ deltaE($0, colour) >= 10 }) {
                kept.append(colour)
                out.append(Suggestion(id: out.count, mix: mix))
            }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                let list = suggestions
                if list.isEmpty {
                    Text("No distinct mixes: give the tools more different colours.").foregroundStyle(.secondary)
                }
                ForEach(list) { s in
                    Button {
                        if picked.contains(s.id) { picked.remove(s.id) } else { picked.insert(s.id) }
                    } label: {
                        HStack {
                            MixSwatch(mix: s.mix, palette: palette)
                            Text(s.mix.components.map { "T\($0.tool)" }.joined(separator: " + ")
                                 + (s.mix.components.count == 2 ? String(format: "  %d:%d", Int(s.mix.components[0].amount * 4), Int(s.mix.components[1].amount * 4)) : ""))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: picked.contains(s.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(picked.contains(s.id) ? Color.accentColor : .secondary)
                        }
                    }
                }
            }
            .navigationTitle("Suggested Mixes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(picked.count)") {
                        let list = suggestions
                        onAdd(list.filter { picked.contains($0.id) }.map(\.mix))
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
    }

    private func deltaE(_ a: HexColour, _ b: HexColour) -> Double {
        var d = 0.0
        return slicer_color_delta_e(a.hex, b.hex, &d) == 0 ? d : 100
    }
}
