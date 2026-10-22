import SwiftUI

/// Searchable list of PrusaSlicer system presets of one type. Print and
/// filament presets are limited to those compatible with `printerPreset`
/// (or PresetLibrary.fallbackPrinter for custom printers); printer presets
/// list the whole library.
struct PresetPickerView: View {
    let type: PresetType
    let printerPreset: String?
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var names: [String]? = nil
    @State private var search = ""

    private var title: String {
        switch type {
        case .print: return "Default Slice Settings"
        case .filament: return "Default Filaments"
        case .printer: return "Printer Library"
        }
    }

    private var filtered: [String] {
        guard let names else { return [] }
        let terms = search.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return names }
        return names.filter { name in
            let n = name.lowercased()
            return terms.allSatisfy { n.contains($0) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if names == nil {
                    ProgressView("Loading…")
                } else if filtered.isEmpty {
                    Text(search.isEmpty ? "Nothing compatible." : "Nothing matches “\(search)”.")
                        .foregroundStyle(.secondary)
                } else {
                    List(filtered, id: \.self) { name in
                        Button {
                            onPick(name)
                            dismiss()
                        } label: {
                            Text(name).foregroundStyle(.primary)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if type != .printer {
                    Text("Compatible with \(printerPreset ?? PresetLibrary.fallbackPrinter)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.bar)
                }
            }
            .task {
                let type = type, printer = printerPreset
                names = await Task.detached(priority: .userInitiated) {
                    PresetLibrary.compatibleNames(type, printer: printer)
                }.value
            }
        }
    }
}

extension PresetLibrary {
    /// System presets of a type usable with a printer: for print and filament
    /// presets, those compatible with the printer preset (or the fallback
    /// printer); for printers, all of them.
    static func compatibleNames(_ type: PresetType, printer: String?) -> [String] {
        let all = names(type)
        guard type != .printer else { return all }
        let reference = printer.flatMap { exists(.printer, $0) ? $0 : nil } ?? fallbackPrinter
        return all.filter { isCompatible(type, $0, printer: reference) }
    }
}

// MARK: - New profiles from PrusaSlicer presets

extension SliceProfile {
    /// A slice profile starting from a PrusaSlicer print preset: the typed
    /// fields take the preset's values and the preset becomes the base layer.
    static func from(printPreset: String, name: String? = nil) -> SliceProfile {
        var p = SliceProfile()
        p.name = name ?? printPreset
        p.basePreset = printPreset
        if let settings = PresetLibrary.settings(.print, printPreset) { p.updateTyped(fromPrusa: settings) }
        p.extraSettings = p.extraSettings.filter { SliceProfile.typedKeys.contains($0.key) }
        return p
    }

    /// A new profile showing what slicing would use for `printer` right now:
    /// the printer's default PrusaSlicer print preset (not pinned as base).
    static func newProfile(for printer: PrinterProfile?) -> SliceProfile {
        guard let base = PresetLibrary.base(printerPreset: printer?.systemPreset, filamentType: "PLA")
        else { return SliceProfile() }
        var p = from(printPreset: base.print, name: "My Profile")
        p.basePreset = nil
        return p
    }
}

extension MaterialProfile {
    /// A material starting from a PrusaSlicer filament preset.
    static func from(filamentPreset: String, name: String? = nil) -> MaterialProfile {
        var m = MaterialProfile()
        m.name = name ?? filamentPreset
        m.basePreset = filamentPreset
        if let settings = PresetLibrary.settings(.filament, filamentPreset) { m.updateTyped(fromPrusa: settings) }
        m.extraSettings = m.extraSettings.filter { MaterialProfile.typedKeys.contains($0.key) }
        return m
    }

    /// A new PLA material with the values PrusaSlicer uses for `printer`.
    static func newProfile(for printer: PrinterProfile?) -> MaterialProfile {
        guard let base = PresetLibrary.base(printerPreset: printer?.systemPreset, filamentType: "PLA")
        else { return MaterialProfile() }
        var m = from(filamentPreset: base.filament, name: "My Material")
        m.basePreset = nil
        return m
    }
}
