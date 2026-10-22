import Foundation

// PalmSlice profiles ↔ PrusaSlicer settings.
//
// A PalmSlice profile is its typed fields (the settings PalmSlice's editors
// show) plus `extraSettings`: any other PrusaSlicer setting, keyed by
// PrusaSlicer option name with the value in PrusaSlicer's .ini text format.
// `prusaSettings()` writes the whole profile as PrusaSlicer settings; the
// `init(prusaSettings:)` / `update(fromPrusa:)` direction reads them back,
// putting keys the typed fields don't cover into `extraSettings`. Together they
// make profile import/export lossless and let any setting be edited.
//
// Slicing applies, in order: the PrusaSlicer system presets (PresetLibrary),
// then each profile's prusaSettings() through slicer_apply_settings, which
// validates every key and value with libslic3r.

/// A profile type that converts to and from PrusaSlicer settings.
protocol PrusaSettingsConvertible {
    /// Which PrusaSlicer preset collection this profile type corresponds to.
    static var presetType: PresetType { get }
    /// PrusaSlicer keys the typed fields read and write.
    static var typedKeys: Set<String> { get }
    /// Settings that aren't typed fields, in PrusaSlicer .ini value format.
    var extraSettings: [String: String] { get set }
    /// The typed fields as PrusaSlicer settings (not including extraSettings).
    func typedPrusaSettings() -> [String: String]
    /// Sets the typed fields from the PrusaSlicer keys present in `settings`
    /// (absent keys leave the field unchanged).
    mutating func updateTyped(fromPrusa settings: [String: String])
}

extension PrusaSettingsConvertible {
    /// The complete profile as PrusaSlicer settings. An extra setting with a
    /// typed key is an imported value the typed field couldn't represent
    /// exactly, so it wins (editing the field clears it).
    func prusaSettings() -> [String: String] {
        typedPrusaSettings().merging(extraSettings) { _, extra in extra }
    }

    /// Applies PrusaSlicer settings to the profile: keys the typed fields
    /// cover set those fields, every other key of this profile's preset type
    /// goes into extraSettings. Keys belonging to another preset type are
    /// ignored (a full PrusaSlicer config holds all three types).
    mutating func update(fromPrusa settings: [String: String], allowedKeys: Set<String>? = nil) {
        updateTyped(fromPrusa: settings)
        for (key, value) in settings where !Self.typedKeys.contains(key) {
            if PrusaKeys.ignored.contains(key) { continue }
            if let allowed = allowedKeys, !allowed.contains(key) { continue }
            extraSettings[key] = value
        }
    }

    /// Sets one setting by PrusaSlicer key, routing typed keys to their field.
    mutating func setPrusaSetting(_ key: String, _ value: String) {
        if Self.typedKeys.contains(key) {
            updateTyped(fromPrusa: [key: value])
        } else {
            extraSettings[key] = value
        }
    }
}

enum PrusaKeys {
    /// Preset bookkeeping and per-file identity — never stored in a profile.
    static let ignored: Set<String> = [
        "inherits", "compatible_printers", "compatible_printers_condition",
        "compatible_prints", "compatible_prints_condition", "renamed_from",
        "print_settings_id", "filament_settings_id", "printer_settings_id",
        "physical_printer_settings_id", "printer_technology",
    ]

    /// PrusaSlicer keys belonging to a preset type, taken from any system preset
    /// of that type (each holds every key of its type). Empty if presets aren't loaded.
    static func keys(for type: PresetType) -> Set<String> {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = cache[type] { return cached }
        guard let name = PresetLibrary.names(type).first,
              let settings = PresetLibrary.settings(type, name) else { return [] }
        let keys = Set(settings.keys).subtracting(ignored)
        cache[type] = keys
        return keys
    }
    private static var cache: [PresetType: Set<String>] = [:]
    private static let cacheLock = NSLock()
}

// MARK: - Value encoding (PrusaSlicer .ini format)

/// Encodes and decodes PrusaSlicer option values as they appear in .ini files.
enum PrusaValue {
    static func float(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.10g", v)
        if s.contains("e") { s = String(format: "%.10f", v) }
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
    static func int(_ v: Int) -> String { String(v) }
    static func bool(_ v: Bool) -> String { v ? "1" : "0" }
    static func percent(_ v: Double) -> String { float(v) + "%" }

    /// C-style escaping of a single string (ConfigOptionString).
    static func string(_ v: String) -> String {
        var out = ""
        for ch in v {
            switch ch {
            case "\r": out += "\\r"
            case "\n": out += "\\n"
            case "\r\n": out += "\\r\\n"
            case "\\": out += "\\\\"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Per-extruder vector of floats ("0.4,0.4").
    static func floats(_ v: [Double]) -> String { v.map(float).joined(separator: ",") }
    static func ints(_ v: [Int]) -> String { v.map(String.init).joined(separator: ",") }
    static func bools(_ v: [Bool]) -> String { v.map(bool).joined(separator: ",") }

    /// String list (ConfigOptionStrings): items quoted only when needed.
    static func strings(_ v: [String]) -> String {
        if v.count == 1 && v[0].isEmpty { return "\"\"" }
        return v.map { item in
            let special = item.contains { " ;\t\\\"\r\n".contains($0) }
            guard special else { return item }
            var out = "\""
            for ch in item {
                switch ch {
                case "\\": out += "\\\\"
                case "\"": out += "\\\""
                case "\r": out += "\\r"
                case "\n": out += "\\n"
                case "\r\n": out += "\\r\\n"
                default: out.append(ch)
                }
            }
            return out + "\""
        }.joined(separator: ";")
    }

    /// Points ("0x0,220x0,220x220,0x220").
    static func points(_ v: [(Double, Double)]) -> String {
        v.map { "\(float($0.0))x\(float($0.1))" }.joined(separator: ",")
    }

    // Decoding. Vectors decode to their first element where a scalar is wanted.

    static func parseFloat(_ s: String) -> Double? {
        Double(s.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "") ?? "")
    }
    static func parseFloats(_ s: String) -> [Double] {
        s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
    static func parseInt(_ s: String) -> Int? { parseFloat(s).map { Int($0.rounded()) } }
    static func parseBool(_ s: String) -> Bool? {
        switch s.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) {
        case "1", "true": return true
        case "0", "false": return false
        default: return nil
        }
    }
    /// A FloatOrPercent given in mm; nil if it's a percentage.
    static func parseAbsolute(_ s: String) -> Double? {
        s.contains("%") ? nil : parseFloat(s)
    }
    static func parseString(_ s: String) -> String {
        var out = ""
        var escaped = false
        for ch in s {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "r": out.append("\r")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }
    static func parseStrings(_ s: String) -> [String] { SettingsText.splitStrings(s) }
    static func parsePoints(_ s: String) -> [(Double, Double)] {
        s.split(separator: ",").compactMap { pair in
            let xy = pair.split(separator: "x")
            guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) else { return nil }
            return (x, y)
        }
    }
}

// MARK: - Enum mappings

extension InfillPattern {
    var prusaName: String {
        switch self {
        case .gyroid: return "gyroid"
        case .grid: return "grid"
        case .honeycomb: return "honeycomb"
        case .rectilinear: return "rectilinear"
        case .triangles: return "triangles"
        case .cubic: return "cubic"
        case .adaptiveCubic: return "adaptivecubic"
        case .lightning: return "lightning"
        }
    }
    init?(prusaName: String) {
        guard let p = Self.allCases.first(where: { $0.prusaName == prusaName }) else { return nil }
        self = p
    }
}

extension IroningType {
    var prusaName: String {
        switch bridgeInt {
        case 1: return "topmost"
        case 2: return "solid"
        default: return "top"
        }
    }
    init?(prusaName: String) {
        guard let t = Self.allCases.first(where: { $0.prusaName == prusaName }) else { return nil }
        self = t
    }
}

extension GCodeFlavor {
    var prusaName: String {
        switch self {
        case .marlin: return "marlin"
        case .marlin2: return "marlin2"
        case .klipper: return "klipper"
        case .repRap: return "reprap"
        case .repRapFirmware: return "reprapfirmware"
        case .teacup: return "teacup"
        case .makerWare: return "makerware"
        case .sailfish: return "sailfish"
        case .mach3: return "mach3"
        case .machineKit: return "machinekit"
        case .smoothie: return "smoothie"
        case .noGCode: return "no-extrusion"
        }
    }
    init?(prusaName: String) {
        guard let f = Self.allCases.first(where: { $0.prusaName == prusaName }) else { return nil }
        self = f
    }
}

// MARK: - Creating profiles from PrusaSlicer settings

extension PrusaSettingsConvertible {
    /// Copies `settings` of this profile's preset type into the profile
    /// (typed fields + extraSettings). With presets loaded, keys of other
    /// preset types are dropped; without them everything is kept.
    mutating func importPrusaSettings(_ settings: [String: String]) {
        let keys = PrusaKeys.keys(for: Self.presetType)
        update(fromPrusa: settings, allowedKeys: keys.isEmpty ? nil : keys)
    }
}

// MARK: - Slice profile ↔ print settings

extension SliceProfile: PrusaSettingsConvertible {
    static var presetType: PresetType { .print }

    static let typedKeys: Set<String> = [
        "layer_height", "first_layer_height", "perimeters", "xy_size_compensation",
        "perimeter_generator", "external_perimeters_first",
        "top_solid_layers", "bottom_solid_layers", "top_solid_min_thickness", "bottom_solid_min_thickness",
        "fill_density", "fill_pattern", "infill_overlap",
        "slicing_mode", "slice_closing_radius", "extrusion_width", "first_layer_extrusion_width",
        "perimeter_speed", "infill_speed", "travel_speed", "first_layer_speed",
        "solid_infill_speed", "top_solid_infill_speed",
        "ironing", "ironing_type", "ironing_flowrate", "ironing_speed", "ironing_spacing",
        "support_material", "support_material_style", "support_material_buildplate_only",
        "support_material_threshold", "support_material_xy_spacing", "support_material_with_sheath",
        "support_material_contact_distance", "support_material_interface_layers",
        "support_material_bottom_interface_layers", "support_material_interface_spacing",
        "brim_type", "brim_width", "skirts", "skirt_distance", "raft_layers",
    ]

    func typedPrusaSettings() -> [String: String] {
        typealias V = PrusaValue
        var s: [String: String] = [
            "layer_height": V.float(layerHeight),
            "first_layer_height": V.float(firstLayerHeight),
            "perimeters": V.int(wallCount),
            "xy_size_compensation": V.float(horizontalExpansion),
            "perimeter_generator": wallGenerator == .classic ? "classic" : "arachne",
            "external_perimeters_first": V.bool(externalPerimetersFirst),
            "top_solid_layers": V.int(topLayers),
            "bottom_solid_layers": V.int(bottomLayers),
            "top_solid_min_thickness": V.float(topThickness),
            "bottom_solid_min_thickness": V.float(bottomThickness),
            "fill_density": V.percent(Double(infillDensity)),
            "fill_pattern": infillPattern.prusaName,
            "infill_overlap": V.percent(infillOverlap),
            "slicing_mode": slicingMode == .evenOdd ? "even_odd" : "regular",
            "slice_closing_radius": V.float(gapClosingRadius),
            "perimeter_speed": V.float(printSpeed),
            "infill_speed": V.float(infillSpeed),
            "travel_speed": V.float(travelSpeed),
            "first_layer_speed": V.float(firstLayerSpeed),
            "solid_infill_speed": V.float(solidInfillSpeed),
            "top_solid_infill_speed": V.float(topSolidInfillSpeed),
            "ironing": V.bool(ironingEnabled),
            "ironing_type": ironingType.prusaName,
            "ironing_flowrate": V.percent(ironingFlowrate),
            "ironing_speed": V.float(ironingSpeed),
            "ironing_spacing": V.float(ironingSpacing),
            "support_material": V.bool(generateSupport),
            "support_material_style": supportStyle == .tree ? "organic" : "snug",
            "support_material_buildplate_only": V.bool(supportPlacement == .buildplateOnly),
            "support_material_threshold": V.int(supportOverhangAngle),
            "support_material_xy_spacing": V.float(supportHorizontalExpansion),
            "support_material_with_sheath": V.bool(supportUseTowers),
            "support_material_contact_distance": V.float(supportContactDistance),
            "support_material_interface_layers": V.int(supportInterfaceLayers),
            // Same dense seat under the supports as on top of them.
            "support_material_bottom_interface_layers": V.int(supportInterfaceLayers),
            "support_material_interface_spacing": V.float(supportInterfaceSpacing),
        ]
        // 0 = keep the base value (the printer's PrusaSlicer print preset).
        if extrusionWidth > 0 { s["extrusion_width"] = V.float(extrusionWidth) }
        if firstLayerExtrusionWidth > 0 { s["first_layer_extrusion_width"] = V.float(firstLayerExtrusionWidth) }

        // PalmSlice's single adhesion choice → PrusaSlicer's separate keys.
        s["brim_type"] = adhesionType == .brim ? brimType.prusaName : "no_brim"
        s["brim_width"] = V.float(brimWidth)
        s["skirts"] = V.int(adhesionType == .skirt ? skirtLoops : 0)
        s["skirt_distance"] = V.float(skirtDistance)
        s["raft_layers"] = V.int(adhesionType == .raft ? raftLayers : 0)
        return s
    }

    mutating func updateTyped(fromPrusa s: [String: String]) {
        typealias V = PrusaValue
        // Values the typed fields can't represent exactly; kept verbatim in
        // extraSettings once the fields are set (see SliceProfile).
        var verbatim: [String: String] = [:]

        if let v = s["layer_height"].flatMap(V.parseFloat) { layerHeight = v }
        if let v = s["first_layer_height"] {
            if let mm = V.parseAbsolute(v) { firstLayerHeight = mm }
            else { firstLayerHeight = layerHeight * (V.parseFloat(v) ?? 100) / 100; verbatim["first_layer_height"] = v }
        }
        if let v = s["perimeters"].flatMap(V.parseInt) { wallCount = v }
        if let v = s["xy_size_compensation"].flatMap(V.parseFloat) { horizontalExpansion = v }
        if let v = s["perimeter_generator"] { wallGenerator = v == "classic" ? .classic : .arachne }
        if let v = s["external_perimeters_first"].flatMap(V.parseBool) { externalPerimetersFirst = v }
        if let v = s["top_solid_layers"].flatMap(V.parseInt) { topLayers = v }
        if let v = s["bottom_solid_layers"].flatMap(V.parseInt) { bottomLayers = v }
        if let v = s["top_solid_min_thickness"].flatMap(V.parseFloat) { topThickness = v }
        if let v = s["bottom_solid_min_thickness"].flatMap(V.parseFloat) { bottomThickness = v }
        if let v = s["fill_density"].flatMap(V.parseFloat) { infillDensity = Int(v.rounded()) }
        if let v = s["fill_pattern"] {
            if let p = InfillPattern(prusaName: v) { infillPattern = p } else { verbatim["fill_pattern"] = v }
        }
        if let v = s["infill_overlap"], let f = V.parseFloat(v) {
            infillOverlap = f
            if !v.contains("%") { verbatim["infill_overlap"] = v }
        }
        if let v = s["slicing_mode"] { slicingMode = v == "even_odd" ? .evenOdd : .regular }
        if let v = s["slice_closing_radius"].flatMap(V.parseFloat) { gapClosingRadius = v }
        if let v = s["extrusion_width"] {
            extrusionWidth = V.parseAbsolute(v) ?? 0
            if V.parseAbsolute(v) == nil { verbatim["extrusion_width"] = v }
        }
        if let v = s["first_layer_extrusion_width"] {
            firstLayerExtrusionWidth = V.parseAbsolute(v) ?? 0
            if V.parseAbsolute(v) == nil { verbatim["first_layer_extrusion_width"] = v }
        }
        if let v = s["perimeter_speed"].flatMap(V.parseFloat) { printSpeed = v }
        if let v = s["infill_speed"].flatMap(V.parseFloat) { infillSpeed = v }
        if let v = s["travel_speed"].flatMap(V.parseFloat) { travelSpeed = v }
        // Speeds given as a percentage in PrusaSlicer: the field shows the
        // resolved mm/s, the percentage is what's sliced.
        func relativeSpeed(_ key: String, of reference: Double) -> Double? {
            guard let v = s[key] else { return nil }
            if let mm = V.parseAbsolute(v) { return mm }
            verbatim[key] = v
            return reference * (V.parseFloat(v) ?? 100) / 100
        }
        if let v = relativeSpeed("first_layer_speed", of: printSpeed) { firstLayerSpeed = v }
        if let v = relativeSpeed("solid_infill_speed", of: infillSpeed) { solidInfillSpeed = v }
        if let v = relativeSpeed("top_solid_infill_speed", of: solidInfillSpeed) { topSolidInfillSpeed = v }
        if let v = s["ironing"].flatMap(V.parseBool) { ironingEnabled = v }
        if let v = s["ironing_type"].flatMap(IroningType.init(prusaName:)) { ironingType = v }
        if let v = s["ironing_flowrate"].flatMap(V.parseFloat) { ironingFlowrate = v }
        if let v = s["ironing_speed"].flatMap(V.parseFloat) { ironingSpeed = v }
        if let v = s["ironing_spacing"].flatMap(V.parseFloat) { ironingSpacing = v }
        if let v = s["support_material"].flatMap(V.parseBool) { generateSupport = v }
        if let v = s["support_material_style"] {
            supportStyle = (v == "organic" || v == "tree") ? .tree : .normal
            if v != "organic" && v != "snug" { verbatim["support_material_style"] = v }
        }
        if let v = s["support_material_buildplate_only"].flatMap(V.parseBool) {
            supportPlacement = v ? .buildplateOnly : .everywhere
        }
        if let v = s["support_material_threshold"].flatMap(V.parseInt) { supportOverhangAngle = v }
        if let v = s["support_material_xy_spacing"] {
            if let mm = V.parseAbsolute(v) { supportHorizontalExpansion = mm } else { verbatim["support_material_xy_spacing"] = v }
        }
        if let v = s["support_material_with_sheath"].flatMap(V.parseBool) { supportUseTowers = v }
        if let v = s["support_material_contact_distance"].flatMap(V.parseFloat) { supportContactDistance = v }
        if let v = s["support_material_interface_layers"].flatMap(V.parseInt) { supportInterfaceLayers = v }
        if let v = s["support_material_bottom_interface_layers"], V.parseInt(v) != supportInterfaceLayers {
            verbatim["support_material_bottom_interface_layers"] = v   // e.g. -1 = "same as top"
        }
        if let v = s["support_material_interface_spacing"].flatMap(V.parseFloat) { supportInterfaceSpacing = v }

        if let v = s["brim_width"].flatMap(V.parseFloat) { brimWidth = v }
        if let v = s["skirt_distance"].flatMap(V.parseFloat) { skirtDistance = v }
        let raft = s["raft_layers"].flatMap(V.parseInt)
        let brim = s["brim_type"].flatMap(BrimType.init(prusaName:))
        let skirts = s["skirts"].flatMap(V.parseInt)
        if let raft, raft > 0 { raftLayers = raft }
        if let skirts, skirts > 0 { skirtLoops = skirts }
        if let brim { brimType = brim }
        // A brim only prints with a width; vendor presets often keep
        // brim_type = outer_only with brim_width = 0.
        let hasBrim = brim != nil && brimWidth > 0
        // PrusaSlicer can combine them; PalmSlice picks one (raft > brim > skirt).
        if raft != nil || s["brim_type"] != nil || skirts != nil {
            if let raft, raft > 0 { adhesionType = .raft }
            else if hasBrim { adhesionType = .brim }
            else if let skirts, skirts > 0 { adhesionType = .skirt }
            else { adhesionType = .none }
        }
        if let v = s["brim_type"], adhesionType != .brim, v != "no_brim" { verbatim["brim_type"] = v }

        for (key, value) in verbatim { extraSettings[key] = value }
    }
}

extension BrimType {
    var prusaName: String {
        switch self {
        case .outerOnly: return "outer_only"
        case .innerOnly: return "inner_only"
        case .outerAndInner: return "outer_and_inner"
        }
    }
    /// nil for "no_brim".
    init?(prusaName: String) {
        switch prusaName {
        case "outer_only": self = .outerOnly
        case "inner_only": self = .innerOnly
        case "outer_and_inner": self = .outerAndInner
        default: return nil
        }
    }
}

// MARK: - Material profile ↔ filament settings

extension MaterialProfile: PrusaSettingsConvertible {
    static var presetType: PresetType { .filament }

    /// Filament overrides of the printer's retraction, in PrusaSlicer.
    static let retractionKeys = ["filament_retract_length", "filament_retract_speed",
                                 "filament_retract_restart_extra", "filament_retract_lift",
                                 "filament_retract_before_travel"]

    static let typedKeys: Set<String> = Set([
        "filament_type", "filament_diameter", "first_layer_temperature", "temperature",
        "first_layer_bed_temperature", "bed_temperature", "extrusion_multiplier",
        "cooling", "min_fan_speed", "max_fan_speed", "bridge_fan_speed",
        "disable_fan_first_layers", "fan_below_layer_time", "slowdown_below_layer_time",
        "min_print_speed",
    ] + retractionKeys)

    func typedPrusaSettings() -> [String: String] {
        typealias V = PrusaValue
        var s: [String: String] = [
            "filament_type": V.strings([filamentType]),
            "filament_diameter": V.floats([filamentDiameter]),
            "first_layer_temperature": V.ints([firstLayerTemp]),
            "temperature": V.ints([otherLayersTemp]),
            "first_layer_bed_temperature": V.ints([firstLayerBedTemp]),
            "bed_temperature": V.ints([otherLayersBedTemp]),
            "extrusion_multiplier": V.floats([extrusionMultiplier]),
            "cooling": V.bools([coolingEnabled]),
            "min_fan_speed": V.ints([minFanSpeed]),
            "max_fan_speed": V.ints([maxFanSpeed]),
            "bridge_fan_speed": V.ints([bridgeFanSpeed]),
            "disable_fan_first_layers": V.ints([disableFanFirstLayers]),
            "fan_below_layer_time": V.ints([fanBelowLayerTime]),
            "slowdown_below_layer_time": V.ints([slowdownBelowLayerTime]),
            "min_print_speed": V.floats([minPrintSpeed]),
        ]
        let values: [Double] = [retractionEnabled ? retractionLength : 0, retractionSpeed,
                                retractionRestartExtra, zHop, minTravelForRetraction]
        for (key, value) in zip(Self.retractionKeys, values) {
            s[key] = setsRetraction ? V.floats([value]) : "nil"
        }
        return s
    }

    mutating func updateTyped(fromPrusa s: [String: String]) {
        typealias V = PrusaValue
        if let v = s["filament_type"].flatMap({ V.parseStrings($0).first }), !v.isEmpty { filamentType = v }
        if let v = s["filament_diameter"].flatMap(V.parseFloat) { filamentDiameter = v }
        if let v = s["first_layer_temperature"].flatMap(V.parseInt) { firstLayerTemp = v }
        if let v = s["temperature"].flatMap(V.parseInt) { otherLayersTemp = v }
        if let v = s["first_layer_bed_temperature"].flatMap(V.parseInt) { firstLayerBedTemp = v }
        if let v = s["bed_temperature"].flatMap(V.parseInt) { otherLayersBedTemp = v }
        if let v = s["extrusion_multiplier"].flatMap(V.parseFloat) { extrusionMultiplier = v }
        if let v = s["cooling"].flatMap(V.parseBool) { coolingEnabled = v }
        if let v = s["min_fan_speed"].flatMap(V.parseInt) { minFanSpeed = v }
        if let v = s["max_fan_speed"].flatMap(V.parseInt) { maxFanSpeed = v }
        if let v = s["bridge_fan_speed"].flatMap(V.parseInt) { bridgeFanSpeed = v }
        if let v = s["disable_fan_first_layers"].flatMap(V.parseInt) { disableFanFirstLayers = v }
        if let v = s["fan_below_layer_time"].flatMap(V.parseInt) { fanBelowLayerTime = v }
        if let v = s["slowdown_below_layer_time"].flatMap(V.parseInt) { slowdownBelowLayerTime = v }
        if let v = s["min_print_speed"].flatMap(V.parseFloat) { minPrintSpeed = v }

        // Retraction overrides: "nil" = use the printer's value.
        let given = Self.retractionKeys.filter { s[$0] != nil }
        guard !given.isEmpty else { return }
        let set = given.filter { s[$0] != "nil" }
        setsRetraction = !set.isEmpty
        var unset: [String] = []
        for key in Self.retractionKeys {
            guard let raw = s[key] else { continue }
            guard raw != "nil", let v = V.parseFloat(raw) else { unset.append(key); continue }
            switch key {
            case "filament_retract_length":
                retractionEnabled = v > 0
                if v > 0 { retractionLength = v }
            case "filament_retract_speed": retractionSpeed = v
            case "filament_retract_restart_extra": retractionRestartExtra = v
            case "filament_retract_lift": zHop = v
            default: minTravelForRetraction = v
            }
        }
        // Some overridden, some not: keep the unset ones following the printer.
        if setsRetraction { for key in unset { extraSettings[key] = "nil" } }
    }
}

// MARK: - Printer profile ↔ printer settings

extension PrinterProfile: PrusaSettingsConvertible {
    static var presetType: PresetType { .printer }

    static let typedKeys: Set<String> = [
        "bed_shape", "max_print_height", "gcode_flavor", "start_gcode", "end_gcode",
        "nozzle_diameter", "extruder_offset", "extruder_clearance_radius", "extruder_clearance_height",
    ]

    func typedPrusaSettings() -> [String: String] {
        typealias V = PrusaValue
        let count = max(1, numberOfExtruders)
        let exts = (0..<count).map { $0 < extruders.count ? extruders[$0] : ExtruderProfile() }
        // Printhead clearance: PrusaSlicer models the head as a cylinder.
        let radius = [printheadXMin, printheadXMax, printheadYMin, printheadYMax].map(abs).max() ?? 0
        var s: [String: String] = [
            "bed_shape": V.points(bedOutline()),
            "max_print_height": V.float(bedZ),
            "gcode_flavor": gcodeFlavor.prusaName,
            "start_gcode": V.string(startGCode),
            "end_gcode": V.string(endGCode),
            "nozzle_diameter": V.floats(exts.map(\.nozzleDiameter)),
            "extruder_offset": exts.map { "\(V.float($0.offsetX))x\(V.float($0.offsetY))" }.joined(separator: ","),
            "extruder_clearance_radius": V.float(radius),
        ]
        if gantryHeight > 0 { s["extruder_clearance_height"] = V.float(gantryHeight) }
        return s
    }

    /// The bed outline in printer coordinates. Circular beds are approximated
    /// by a 64-gon, the way PrusaSlicer stores circular beds.
    func bedOutline() -> [(Double, Double)] {
        let ox = originAtCenter ? -bedX / 2 : 0
        let oy = originAtCenter ? -bedY / 2 : 0
        guard buildPlateShape == .circular else {
            return [(ox, oy), (ox + bedX, oy), (ox + bedX, oy + bedY), (ox, oy + bedY)]
        }
        let cx = ox + bedX / 2, cy = oy + bedY / 2
        return (0..<64).map { i in
            let a = Double(i) / 64 * 2 * .pi
            return ((cx + cos(a) * bedX / 2 * 1000).rounded() / 1000,
                    (cy + sin(a) * bedY / 2 * 1000).rounded() / 1000)
        }
    }

    mutating func updateTyped(fromPrusa s: [String: String]) {
        typealias V = PrusaValue
        if let raw = s["bed_shape"], case let pts = V.parsePoints(raw), pts.count >= 3 {
            let xs = pts.map(\.0), ys = pts.map(\.1)
            bedX = xs.max()! - xs.min()!
            bedY = ys.max()! - ys.min()!
            originAtCenter = xs.min()! < 0 && ys.min()! < 0
            buildPlateShape = pts.count > 4 ? .circular : .rectangular
            // An outline the fields can't reproduce (e.g. a bed starting at
            // X = 5) is kept verbatim until the bed is edited.
            if V.points(bedOutline()) != V.points(pts) { extraSettings["bed_shape"] = raw }
        }
        if let v = s["max_print_height"].flatMap(V.parseFloat) { bedZ = v }
        if let v = s["gcode_flavor"] {
            if let f = GCodeFlavor(prusaName: v) { gcodeFlavor = f } else { extraSettings["gcode_flavor"] = v }
        }
        if let v = s["start_gcode"] { startGCode = V.parseString(v) }
        if let v = s["end_gcode"] { endGCode = V.parseString(v) }
        if let nozzles = s["nozzle_diameter"].map(V.parseFloats), !nozzles.isEmpty {
            numberOfExtruders = nozzles.count
            while extruders.count < nozzles.count { extruders.append(ExtruderProfile()) }
            extruders = Array(extruders.prefix(nozzles.count))
            for i in nozzles.indices { extruders[i].nozzleDiameter = nozzles[i] }
        }
        if let offsets = s["extruder_offset"].map(V.parsePoints) {
            for i in offsets.indices where i < extruders.count {
                extruders[i].offsetX = offsets[i].0
                extruders[i].offsetY = offsets[i].1
            }
        }
        if let r = s["extruder_clearance_radius"].flatMap(V.parseFloat) {
            printheadXMin = -r; printheadYMin = -r; printheadXMax = r; printheadYMax = r
        }
        if let h = s["extruder_clearance_height"].flatMap(V.parseFloat) { gantryHeight = h }
    }
}
