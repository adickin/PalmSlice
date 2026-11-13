import SwiftUI

/// One of a model's own modifiers: shape, where it sits and how big it is (mm,
/// in the model's frame before its scale and rotation), its tool and settings.
struct ModifierEditorView: View {
    @Binding var modifier: ModelModifier
    let palette: ToolPalette
    /// The slice profile's values, shown as each setting's default.
    let baseSettings: [String: String]

    /// "20 × 20 × 10 mm · 1 setting"
    static func summary(_ m: ModelModifier) -> String {
        let s = m.sizeMM
        func mm(_ v: Float) -> String { String(format: "%g", (v * 10).rounded() / 10) }
        let size = switch m.shape {
        case .box: "\(mm(s.x)) × \(mm(s.y)) × \(mm(s.z)) mm"
        case .cylinder: "⌀\(mm(s.x)) × \(mm(s.z)) mm"
        case .sphere: "⌀\(mm(s.x)) mm"
        }
        let n = m.settings.count
        return n == 0 ? size : "\(size) · \(n) setting\(n == 1 ? "" : "s")"
    }

    var body: some View {
        Form {
            Section {
                Picker("Shape", selection: shape) {
                    ForEach(ModelModifier.Shape.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                axisRow("X", .red, $modifier.centreMM.x)
                axisRow("Y", .green, $modifier.centreMM.y)
                axisRow("Z", .blue, $modifier.centreMM.z)
                Button("Centre on Model") { modifier.centreMM = .zero }
            } header: {
                Text("Position (mm)")
            } footer: {
                Text("From the model's centre, before the model is scaled or turned. The arrows in the 3D view move it too.")
            }
            Section("Size (mm)") {
                switch modifier.shape {
                case .box:
                    axisRow("X", .red, size(0))
                    axisRow("Y", .green, size(1))
                    axisRow("Z", .blue, size(2))
                case .cylinder:
                    axisRow("⌀", .secondary, diameter(xyOnly: true))
                    axisRow("H", .blue, size(2))
                case .sphere:
                    axisRow("⌀", .secondary, diameter(xyOnly: false))
                }
            }
            Section {
                ToolChips(tool: $modifier.tool, palette: palette, allowsDefault: true)
            } header: {
                Text("Tool")
            } footer: {
                Text("Default keeps the model's tool here.")
            }
            Section {
                NavigationLink {
                    AllSettingsView(profile: overrides, baseSettings: baseSettings,
                                    allowedKeys: SettingOverrides.allowedKeys)
                        .navigationTitle(modifier.name)
                } label: {
                    LabeledContent("Settings", value: modifier.settings.isEmpty ? "None" : "\(modifier.settings.count) changed")
                }
                ForEach(modifier.settings.keys.sorted(), id: \.self) { key in
                    let info = SettingInfo.cached(key)
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info?.displayName ?? key).font(.subheadline)
                            Text(info?.summary(of: modifier.settings[key] ?? "") ?? modifier.settings[key] ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { modifier.settings[key] = nil } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(info?.displayName ?? key)")
                    }
                }
            } header: {
                Text("Settings")
            } footer: {
                Text("Used where the modifier overlaps the model, instead of the model's own settings.")
            }
        }
        .navigationTitle(modifier.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func axisRow(_ label: String, _ colour: Color, _ value: Binding<Float>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(colour).frame(width: 22)
            FloatField(value: value, fmt: "%g")
        }
    }

    /// Changing shape keeps the size sensible: round shapes get equal sides.
    private var shape: Binding<ModelModifier.Shape> {
        Binding(get: { modifier.shape }, set: { shape in
            modifier.shape = shape
            let s = modifier.sizeMM
            switch shape {
            case .box: break
            case .cylinder: modifier.sizeMM = SIMD3(min(s.x, s.y), min(s.x, s.y), s.z)
            case .sphere: modifier.sizeMM = SIMD3(repeating: s.min())
            }
        })
    }

    private func size(_ k: Int) -> Binding<Float> {
        Binding(get: { modifier.sizeMM[k] }, set: { modifier.sizeMM[k] = max(0.5, $0) })
    }

    private func diameter(xyOnly: Bool) -> Binding<Float> {
        Binding(get: { modifier.sizeMM.x }, set: { d in
            let d = max(0.5, d)
            modifier.sizeMM.x = d
            modifier.sizeMM.y = d
            if !xyOnly { modifier.sizeMM.z = d }
        })
    }

    private var overrides: Binding<SettingOverrides> {
        Binding(get: { SettingOverrides(extraSettings: modifier.settings) },
                set: { modifier.settings = $0.extraSettings })
    }
}
