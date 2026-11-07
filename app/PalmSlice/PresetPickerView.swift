import SwiftUI

/// Searchable list of OrcaSlicer system presets of one type. Print and
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
        case .print: return "OrcaSlicer Qualities"
        case .filament: return "OrcaSlicer Filaments"
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

// MARK: - New profiles from OrcaSlicer presets

extension SliceProfile {
    /// A new user quality starting from an OrcaSlicer quality: the typed
    /// fields show the preset; saving keeps only what's changed from it.
    static func from(printPreset: String, name: String? = nil) -> SliceProfile {
        var p = SliceProfile()
        p.name = name ?? "My " + PresetLibrary.shortName(printPreset)
        p.resolve(over: PresetLibrary.settings(.print, printPreset) ?? [:])
        return p
    }

    /// A new user quality starting from the printer's default quality.
    static func newProfile(for printer: PrinterProfile?) -> SliceProfile {
        guard let quality = PresetLibrary.defaultQuality(forPrinter: printer?.systemPreset)
        else { return SliceProfile() }
        return from(printPreset: quality, name: "My Quality")
    }
}

extension MaterialProfile {
    /// A new user material starting from an OrcaSlicer filament, which stays
    /// its base (where the printer can use it).
    static func from(filamentPreset: String, name: String? = nil) -> MaterialProfile {
        var m = system(filamentPreset)
        m.id = UUID()
        m.isSystem = false
        m.name = name ?? "My " + PresetLibrary.shortName(filamentPreset)
        return m
    }

    /// A new user material starting from the printer's default filament.
    static func newProfile(for printer: PrinterProfile?) -> MaterialProfile {
        guard let filament = PresetLibrary.featuredFilaments(forPrinter: printer?.systemPreset).first
        else { return MaterialProfile() }
        return from(filamentPreset: filament, name: "My Material")
    }
}
