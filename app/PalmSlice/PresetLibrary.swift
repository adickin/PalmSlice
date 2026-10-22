import Foundation

/// PrusaSlicer's system presets (vendor printer / print / filament profiles),
/// bundled in PrusaSlicerProfiles/vendor by scripts/12_vendor_profiles.sh and
/// loaded once per process by the C bridge.
///
/// Every slice starts from these: the printer's PrusaSlicer preset, its
/// default print preset and a matching filament preset are applied first, and
/// the PalmSlice printer / material / slice profiles are applied on top. Any
/// setting a PalmSlice profile doesn't control takes PrusaSlicer's value for
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
    /// PrusaSlicer preset (custom printers): the printer PalmSlice has verified
    /// on real hardware. Its printer preset itself is NOT applied, so a custom
    /// printer's bed, G-code and machine limits are never Ender-3 S1 values.
    static let fallbackPrinter = "Creality Ender-3 S1 (0.4 mm nozzle)"

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
        if let dir = Bundle.main.url(forResource: "PrusaSlicerProfiles", withExtension: nil) {
            let count = Int(slicer_presets_load(dir.path))
            result = count > 0
                ? .success(count)
                : .failure(PresetLoadError(description: String(cString: slicer_presets_last_error())))
        } else {
            result = .failure(PresetLoadError(description: "PrusaSlicerProfiles missing from the app bundle"))
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

    /// A system preset's full settings, keyed by PrusaSlicer option name, with
    /// values serialized as PrusaSlicer writes them. Nil if there's no such preset.
    static func settings(_ type: PresetType, _ name: String) -> [String: String]? {
        guard isLoaded, let ini = slicer_preset_config(type.rawValue, name) else { return nil }
        return SettingsText.parse(String(cString: ini))
    }

    static func isCompatible(_ type: PresetType, _ name: String, printer: String) -> Bool {
        isLoaded && slicer_preset_is_compatible(type.rawValue, name, printer) == 1
    }

    /// The print and filament presets a printer preset names as its defaults,
    /// as PrusaSlicer selects them when that printer is picked.
    static func defaults(forPrinter printer: String) -> (print: String?, filaments: [String]) {
        guard let s = settings(.printer, printer) else { return (nil, []) }
        let print = s["default_print_profile"].flatMap { $0.isEmpty ? nil : SettingsText.unquote($0) }
        let filaments = s["default_filament_profile"].map(SettingsText.splitStrings) ?? []
        return (print, filaments)
    }

    /// The system presets a slice should start from, or nil if the presets
    /// couldn't be loaded (the slice then runs on PalmSlice profiles alone).
    ///
    /// - printerPreset: the PrusaSlicer printer preset the PalmSlice printer
    ///   profile is based on, if any.
    /// - filamentType: PrusaSlicer filament_type of the material (PLA, PETG…).
    static func base(printerPreset: String?, filamentType: String) -> PresetBase? {
        guard isLoaded else { return nil }
        let printer = printerPreset.flatMap { exists(.printer, $0) ? $0 : nil }
        let reference = printer ?? fallbackPrinter
        let defaults = defaults(forPrinter: reference)

        let prints = names(.print).filter { isCompatible(.print, $0, printer: reference) }
        guard let print = defaults.print.flatMap({ prints.contains($0) ? $0 : nil }) ?? prints.first
        else { return nil }

        let filaments = names(.filament).filter { isCompatible(.filament, $0, printer: reference) }
        guard let filament = bestFilament(type: filamentType, among: filaments,
                                          defaults: defaults.filaments) else { return nil }
        return PresetBase(printer: printer, print: print, filament: filament)
    }

    /// Picks the filament preset closest to a generic material of the given
    /// type: the printer's own default if it's that type, then a "Generic"
    /// preset of that type, then any preset of that type, then the printer's
    /// default regardless of type.
    private static func bestFilament(type: String, among names: [String],
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
    /// filament — the same layering PrusaSlicer uses for its full config.
    static func apply(_ base: PresetBase, to handle: SlicerHandle) -> Bool {
        if let printer = base.printer,
           slicer_apply_preset(handle, PresetType.printer.rawValue, printer) != 0 { return false }
        return slicer_apply_preset(handle, PresetType.print.rawValue, base.print) == 0
            && slicer_apply_preset(handle, PresetType.filament.rawValue, base.filament) == 0
    }
}

/// PrusaSlicer's .ini settings text: "key = value" lines, with string-list
/// values as quoted, semicolon-separated items.
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
        guard value.contains("\"") else { return value.isEmpty ? [] : [value] }
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in value {
            if escaped { current.append(ch); escaped = false; continue }
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
