import Foundation

/// OrcaSlicer's system presets (vendor printer / process / filament profiles),
/// bundled in OrcaResources/profiles by scripts/15_orca_profiles.sh and
/// loaded once per process by the C bridge.
///
/// Every slice starts from these: the printer's OrcaSlicer preset, its
/// default print preset and a matching filament preset are applied first, and
/// the PalmSlice printer / material / slice profiles are applied on top. Any
/// setting a PalmSlice profile doesn't control takes OrcaSlicer's value for
/// that printer instead of libslic3r's bare built-in default.
enum PresetType: Int32 {
    case print    = 0   // SLICER_PRESET_PRINT
    case filament = 1   // SLICER_PRESET_FILAMENT
    case printer  = 2   // SLICER_PRESET_PRINTER
}

/// The three system presets a slice is based on.
struct PresetBase: Equatable {
    var printer: String?
    var print: String
    var filament: String
}

enum PresetLibrary {
    /// Used as the print/filament base for printers that aren't based on a
    /// OrcaSlicer preset (custom printers): the printer PalmSlice has verified
    /// on real hardware. Its printer preset itself is NOT applied, so a custom
    /// printer's bed, G-code and machine limits are never Ender-3 S1 values.
    static let fallbackPrinter = "Creality Ender-3 S1 0.4 nozzle"

    private static let lock = NSLock()
    private static var loadResult: Result<Int, PresetLoadError>?

    struct PresetLoadError: Error, CustomStringConvertible {
        let description: String
    }

    /// Loads the bundled vendor profiles on first use. Thread-safe; later calls
    /// return the first result.
    @discardableResult
    static func load() -> Result<Int, PresetLoadError> {
        lock.lock(); defer { lock.unlock() }
        if let loadResult { return loadResult }
        let result: Result<Int, PresetLoadError>
        if let dir = Bundle.main.url(forResource: "OrcaResources", withExtension: nil) {
            let count = Int(slicer_presets_load(dir.path))
            result = count > 0
                ? .success(count)
                : .failure(PresetLoadError(description: String(cString: slicer_presets_last_error())))
        } else {
            result = .failure(PresetLoadError(description: "OrcaResources missing from the app bundle"))
        }
        loadResult = result
        return result
    }

    static var isLoaded: Bool {
        if case .success = load() { return true }
        return false
    }

    static func names(_ type: PresetType) -> [String] {
        guard isLoaded else { return [] }
        return (0..<slicer_preset_count(type.rawValue)).map {
            String(cString: slicer_preset_name(type.rawValue, $0))
        }
    }

    static func exists(_ type: PresetType, _ name: String) -> Bool {
        guard isLoaded else { return false }
        return slicer_preset_config(type.rawValue, name) != nil
    }

    /// A system preset's full settings, keyed by OrcaSlicer option name, with
    /// values serialized as OrcaSlicer writes them. Nil if there's no such preset.
    static func settings(_ type: PresetType, _ name: String) -> [String: String]? {
        guard isLoaded, let ini = slicer_preset_config(type.rawValue, name) else { return nil }
        return SettingsText.parse(String(cString: ini))
    }

    static func isCompatible(_ type: PresetType, _ name: String, printer: String) -> Bool {
        isLoaded && slicer_preset_is_compatible(type.rawValue, name, printer) == 1
    }

    // MARK: - Per-printer lists

    /// The printer preset whose lists apply to a PalmSlice printer: its own
    /// OrcaSlicer preset, or the fallback printer for a custom printer.
    static func reference(for printerPreset: String?) -> String {
        printerPreset.flatMap { exists(.printer, $0) ? $0 : nil } ?? fallbackPrinter
    }

    private static var listCache: [String: [String]] = [:]
    private static let listLock = NSLock()

    private static func cached(_ key: String, _ make: () -> [String]) -> [String] {
        listLock.lock()
        if let hit = listCache[key] { listLock.unlock(); return hit }
        listLock.unlock()
        let value = make()
        listLock.lock(); listCache[key] = value; listLock.unlock()
        return value
    }

    /// Layer height of a print preset (0 if unknown).
    static func layerHeight(ofPrint name: String) -> Double {
        settings(.print, name)?["layer_height"].flatMap(SlicerValue.parseFloat) ?? 0
    }

    /// The printer's OrcaSlicer qualities (print presets), thinnest layers first.
    static func qualities(forPrinter printerPreset: String?) -> [String] {
        let printer = reference(for: printerPreset)
        return cached("print|" + printer) {
            let compatible: [String] = names(.print).filter { isCompatible(.print, $0, printer: printer) }
            let heights: [String: Double] = Dictionary(uniqueKeysWithValues: compatible.map { ($0, layerHeight(ofPrint: $0)) })
            return compatible.sorted { a, b in
                let ha = heights[a] ?? 0, hb = heights[b] ?? 0
                return ha != hb ? ha < hb : a < b
            }
        }
    }

    /// The quality OrcaSlicer selects for the printer: its default print
    /// preset, or (when that name doesn't exist, as for some vendors) the
    /// compatible "Standard" one nearest 0.2 mm.
    static func defaultQuality(forPrinter printerPreset: String?) -> String? {
        let all = qualities(forPrinter: printerPreset)
        if let d = defaults(forPrinter: reference(for: printerPreset)).print, all.contains(d) { return d }
        let standard = all.filter { $0.localizedCaseInsensitiveContains("standard") }
        return closest(to: 0.2, in: standard.isEmpty ? all : standard)
    }

    /// The printer's quality with the layer height nearest `layerHeight`,
    /// preferring its default quality's family on ties.
    static func quality(forPrinter printerPreset: String?, layerHeight: Double?) -> String? {
        guard let layerHeight else { return defaultQuality(forPrinter: printerPreset) }
        let all = qualities(forPrinter: printerPreset)
        let fallback = defaultQuality(forPrinter: printerPreset)
        let best = closest(to: layerHeight, in: all)
        if let fallback, let best, abs(Self.layerHeight(ofPrint: fallback) - Self.layerHeight(ofPrint: best)) < 0.001 { return fallback }
        return best
    }

    private static func closest(to height: Double, in names: [String]) -> String? {
        names.min { abs(layerHeight(ofPrint: $0) - height) < abs(layerHeight(ofPrint: $1) - height) }
    }

    /// Every OrcaSlicer filament for the printer, by name.
    static func filaments(forPrinter printerPreset: String?) -> [String] {
        let printer = reference(for: printerPreset)
        return cached("filament|" + printer) {
            names(.filament).filter { isCompatible(.filament, $0, printer: printer) }
        }
    }

    /// The filaments offered up front for a printer: its default filament(s),
    /// then one generic per material type.
    static func featuredFilaments(forPrinter printerPreset: String?) -> [String] {
        let printer = reference(for: printerPreset)
        return cached("featured|" + printer) {
            let all = filaments(forPrinter: printerPreset)
            var out = defaults(forPrinter: printer).filaments.filter { all.contains($0) }
            for type in ["PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC"] {
                if let f = bestFilament(type: type, among: all, defaults: out), filamentType(f) == type, !out.contains(f) {
                    out.append(f)
                }
            }
            return out
        }
    }

    static func filamentType(_ name: String) -> String {
        SettingsText.splitStrings(settings(.filament, name)?["filament_type"] ?? "").first?.uppercased() ?? ""
    }

    /// A stable id for a system preset entry in the profile lists, so a
    /// selection or tool assignment survives relaunches.
    static func stableID(_ type: PresetType, _ name: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var h1: UInt64 = 0xcbf29ce484222325, h2: UInt64 = 0x84222325cbf29ce4
        for b in "\(type.rawValue)|\(name)".utf8 {
            h1 = (h1 ^ UInt64(b)) &* 0x100000001b3
            h2 = (h2 ^ UInt64(b)) &* 0x1000193 &+ 0x9e3779b97f4a7c15
        }
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: h1 >> (8 * UInt64(i))); bytes[8 + i] = UInt8(truncatingIfNeeded: h2 >> (8 * UInt64(i))) }
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// A preset name without OrcaSlicer's " @Vendor Printer" suffix.
    static func shortName(_ name: String) -> String {
        name.range(of: " @").map { String(name[..<$0.lowerBound]) } ?? name
    }

    /// The print and filament presets a printer preset names as its defaults,
    /// as OrcaSlicer selects them when that printer is picked.
    static func defaults(forPrinter printer: String) -> (print: String?, filaments: [String]) {
        guard let s = settings(.printer, printer) else { return (nil, []) }
        let print = s["default_print_profile"].flatMap { $0.isEmpty ? nil : SettingsText.unquote($0) }
        let filaments = s["default_filament_profile"].map(SettingsText.splitStrings) ?? []
        return (print, filaments)
    }

    /// The system presets a slice should start from, or nil if the presets
    /// couldn't be loaded (the slice then runs on PalmSlice profiles alone).
    ///
    /// - printerPreset: the OrcaSlicer printer preset the PalmSlice printer
    ///   profile is based on, if any.
    /// - printPreset / filamentPreset: explicit base presets chosen by the
    ///   slice / material profile; nil picks the printer's default print preset
    ///   and a filament preset of `filamentType`.
    /// - filamentType: OrcaSlicer filament_type of the material (PLA, PETG…).
    static func base(printerPreset: String?, printPreset: String? = nil, layerHeight: Double? = nil,
                     filamentPreset: String? = nil, filamentType: String) -> PresetBase? {
        guard isLoaded else { return nil }
        let printer = printerPreset.flatMap { exists(.printer, $0) ? $0 : nil }

        // An Orca quality as is; a PalmSlice quality over the printer's
        // quality nearest its layer height (or the printer's default).
        let print: String
        if let explicit = printPreset, exists(.print, explicit) {
            print = explicit
        } else if let p = quality(forPrinter: printer, layerHeight: layerHeight) {
            print = p
        } else {
            return nil
        }

        // A material's own filament preset when it suits this printer,
        // otherwise the printer's filament of the material's type.
        let compatible = filaments(forPrinter: printer)
        let filament: String
        if let explicit = filamentPreset, compatible.contains(explicit) {
            filament = explicit
        } else if let f = bestFilament(type: filamentType, among: compatible,
                                       defaults: defaults(forPrinter: reference(for: printer)).filaments) {
            filament = f
        } else {
            return nil
        }
        return PresetBase(printer: printer, print: print, filament: filament)
    }

    /// Picks the filament preset closest to a generic material of the given
    /// type: the printer's own default if it's that type, then a "Generic"
    /// preset of that type, then any preset of that type, then the printer's
    /// default regardless of type.
    static func bestFilament(type: String, among names: [String],
                                     defaults: [String]) -> String? {
        let wanted = type.uppercased()
        func typeOf(_ name: String) -> String {
            SettingsText.splitStrings(settings(.filament, name)?["filament_type"] ?? "")
                .first?.uppercased() ?? ""
        }
        let available = Set(names)
        let defaultsAvailable = defaults.filter { available.contains($0) }
        if let d = defaultsAvailable.first(where: { typeOf($0) == wanted }) { return d }
        let ofType = names.filter { typeOf($0) == wanted }
        if let generic = ofType.first(where: { $0.localizedCaseInsensitiveContains("generic") }) { return generic }
        return ofType.first ?? defaultsAvailable.first ?? names.first
    }

    /// Applies a base to a slicer context. Printer first, then print, then
    /// filament — the same layering OrcaSlicer uses for its full config.
    static func apply(_ base: PresetBase, to handle: SlicerHandle) -> Bool {
        if let printer = base.printer,
           slicer_apply_preset(handle, PresetType.printer.rawValue, printer) != 0 { return false }
        return slicer_apply_preset(handle, PresetType.print.rawValue, base.print) == 0
            && slicer_apply_preset(handle, PresetType.filament.rawValue, base.filament) == 0
    }
}

/// libslic3r's .ini settings text (OrcaSlicer and PrusaSlicer share it): "key =
/// value" lines, with string-list values as quoted, semicolon-separated items.
enum SettingsText {
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"),
                  let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...])
            if value.hasPrefix(" ") { value.removeFirst() }
            out[key] = value
        }
        return out
    }

    static func serialize(_ settings: [String: String]) -> String {
        settings.keys.sorted().map { "\($0) = \(settings[$0]!)\n" }.joined()
    }

    /// `"a";"b c"` → ["a", "b c"]; also accepts an unquoted single value.
    static func splitStrings(_ value: String) -> [String] {
        guard value.contains("\"") else {
            return value.isEmpty ? [] : value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        }
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in value {
            if escaped {
                current.append(ch == "n" ? "\n" : ch == "r" ? "\r" : ch)
                escaped = false
                continue
            }
            switch ch {
            case "\\" where inQuotes: escaped = true
            case "\"": inQuotes.toggle()
            case ";" where !inQuotes: items.append(current); current = ""
            default: if inQuotes { current.append(ch) }
            }
        }
        items.append(current)
        return items
    }

    static func unquote(_ value: String) -> String {
        splitStrings(value).first ?? value
    }
}
