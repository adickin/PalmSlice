import SwiftUI
import UniformTypeIdentifiers

/// A profile type that can be imported from / exported to a .ini (OrcaSlicer
/// or PrusaSlicer settings; PrusaSlicer ones are renamed on import).
protocol IniProfile: SlicerSettingsConvertible, Identifiable {
    init()
    var name: String { get set }
    /// The OrcaSlicer system preset the profile is layered on.
    var iniBasePreset: String? { get set }
    /// Section prefix in config bundles ("print", "filament", "printer").
    static var iniSection: String { get }
}

extension SliceProfile: IniProfile {
    var iniBasePreset: String? { get { basePreset } set { basePreset = newValue } }
    static var iniSection: String { "print" }
}

extension MaterialProfile: IniProfile {
    var iniBasePreset: String? { get { basePreset } set { basePreset = newValue } }
    static var iniSection: String { "filament" }
}

extension PrinterProfile: IniProfile {
    var iniBasePreset: String? { get { systemPreset } set { systemPreset = newValue } }
    static var iniSection: String { "printer" }
}

/// Reading and writing .ini files: OrcaSlicer configs, and PrusaSlicer
/// configs / config bundles, whose settings are renamed to OrcaSlicer's.
enum ProfileIni {
    static let contentTypes: [UTType] =
        [UTType(filenameExtension: "ini"), .plainText, .data].compactMap { $0 }

    struct Section {
        var type: String?        // "print", "filament", "printer"; nil in a flat config
        var name: String?
        var settings: [String: String]
    }

    /// Splits a .ini into sections. A file without [type:name] headers (an
    /// exported config) is one flat section.
    static func sections(_ text: String) -> [Section] {
        var out = [Section(type: nil, name: nil, settings: [:])]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                let header = line.dropFirst().dropLast()
                let parts = header.split(separator: ":", maxSplits: 1).map(String.init)
                out.append(Section(type: parts.first, name: parts.count > 1 ? parts[1] : nil, settings: [:]))
                continue
            }
            guard !line.hasPrefix("#"), !line.hasPrefix(";"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            out[out.count - 1].settings[key] = value
        }
        return out.filter { !$0.settings.isEmpty }
    }

    /// Profiles of type P in a .ini: every [print:…] (or
    /// filament / printer) preset of a config bundle, with inheritance
    /// resolved, or the one profile in a flat exported config.
    static func profiles<P: IniProfile>(_ type: P.Type, from text: String, fileName: String) -> [P] {
        let all = sections(text)
        let bundle = all.filter { $0.type == P.iniSection && $0.name != nil }
        if bundle.isEmpty {
            guard let flat = all.first(where: { $0.type == nil }) else { return [] }
            var p = P()
            p.importSlicerSettings(OrcaMigration.normalize(flat.settings))
            let id = flat.settings["\(P.iniSection)_settings_id"].flatMap { SettingsText.splitStrings($0).first }
            p.name = id.flatMap { $0.isEmpty ? nil : $0 }
                ?? (fileName as NSString).deletingPathExtension
            return [p]
        }
        let byName = Dictionary(bundle.map { ($0.name!, $0.settings) }, uniquingKeysWith: { a, _ in a })
        let presetType = P.presetType

        // Settings of a bundle preset with its "inherits" chain resolved, and
        // the system preset at the root of the chain, if any.
        func resolve(_ name: String, depth: Int = 0) -> (settings: [String: String], system: String?) {
            guard depth < 16, let own = byName[name] else { return ([:], nil) }
            var merged: [String: String] = [:]
            var system: String? = nil
            for parent in SettingsText.splitStrings(own["inherits"] ?? "").filter({ !$0.isEmpty }) {
                if byName[parent] != nil {
                    let r = resolve(parent, depth: depth + 1)
                    merged.merge(r.settings) { _, new in new }
                    system = system ?? r.system
                } else if let preset = PresetLibrary.settings(presetType, parent) {
                    merged.merge(preset) { _, new in new }
                    system = system ?? parent
                }
            }
            // Each layer is renamed to OrcaSlicer keys before merging, so a
            // PrusaSlicer key overrides the OrcaSlicer one it inherits.
            merged.merge(OrcaMigration.normalize(own)) { _, new in new }
            return (merged, system)
        }

        return bundle.compactMap { section -> P? in
            // "*name*" sections are abstract parents in vendor-style bundles.
            guard let name = section.name, !(name.hasPrefix("*") && name.hasSuffix("*")) else { return nil }
            let resolved = resolve(name)
            var p = P()
            p.iniBasePreset = resolved.system
            p.importSlicerSettings(resolved.settings)
            p.name = name
            return p
        }
    }

    /// A profile's complete settings as an OrcaSlicer .ini: its base preset's
    /// values with the profile's own on top, so it stands alone.
    static func text<P: IniProfile>(_ profile: P, baseSettings: [String: String]) -> String {
        var settings = baseSettings.merging(profile.slicerSettings()) { _, own in own }
        for key in SlicerKeys.ignored { settings[key] = nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
        return "# \(profile.name) — exported from PalmSlice \(stamp)\n"
            + "# OrcaSlicer \(P.iniSection) settings: load with File > Import > Import Configs.\n"
            + SettingsText.serialize(settings)
    }
}

/// A .ini handed to the share sheet.
struct IniProfileFile: Transferable {
    let fileName: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ini-export", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = file.fileName.replacingOccurrences(of: "/", with: "-")
            let url = dir.appendingPathComponent(safe).appendingPathExtension("ini")
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

/// "+" menu item + file importer that adds profiles from a PrusaSlicer .ini.
struct IniImportModifier<P: IniProfile>: ViewModifier {
    @Binding var isPresented: Bool
    let add: ([P]) -> Void
    @State private var message: String? = nil

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: ProfileIni.contentTypes) { result in
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                        message = "Couldn't read \(url.lastPathComponent)."
                        return
                    }
                    let profiles = ProfileIni.profiles(P.self, from: text, fileName: url.lastPathComponent)
                    if profiles.isEmpty {
                        message = "\(url.lastPathComponent) has no \(P.iniSection) settings."
                    } else {
                        add(profiles)
                        message = profiles.count == 1
                            ? "Imported “\(profiles[0].name)”."
                            : "Imported \(profiles.count) profiles: \(profiles.map(\.name).joined(separator: ", "))."
                    }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
            .alert("Import Settings",
                   isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
    }
}

extension View {
    func iniImporter<P: IniProfile>(_ type: P.Type, isPresented: Binding<Bool>,
                                         add: @escaping ([P]) -> Void) -> some View {
        modifier(IniImportModifier<P>(isPresented: isPresented, add: add))
    }
}
