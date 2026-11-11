import Foundation
import SwiftUI

// PalmSlice profiles ↔ OrcaSlicer settings.
//
// A PalmSlice profile is its typed fields (the settings PalmSlice's editors
// show) plus `extraSettings`: any other OrcaSlicer setting, keyed by
// OrcaSlicer option name with the value in libslic3r's .ini text format.
// `slicerSettings()` writes the whole profile as OrcaSlicer settings; the
// `update(from:)` direction reads them back, putting keys the typed fields
// don't cover into `extraSettings`. Together they make profile import/export
// lossless and let any setting be edited.
//
// Slicing applies, in order: the OrcaSlicer system presets (PresetLibrary),
// then each profile's slicerSettings() through slicer_apply_settings, which
// validates every key and value with libslic3r.

/// A profile type that converts to and from OrcaSlicer settings.
protocol SlicerSettingsConvertible {
    /// Which OrcaSlicer preset collection this profile type corresponds to.
    static var presetType: PresetType { get }
    /// OrcaSlicer keys the typed fields read and write.
    static var typedKeys: Set<String> { get }
    /// Settings that aren't typed fields, in .ini value format.
    var extraSettings: [String: String] { get set }
    /// The typed fields as OrcaSlicer settings (not including extraSettings).
    func typedSlicerSettings() -> [String: String]
    /// Sets the typed fields from the OrcaSlicer keys present in `settings`
    /// (absent keys leave the field unchanged).
    mutating func updateTyped(from settings: [String: String])
}

extension SlicerSettingsConvertible {
    /// The complete profile as OrcaSlicer settings. An extra setting with a
    /// typed key is an imported value the typed field couldn't represent
    /// exactly, so it wins (editing the field clears it).
    func slicerSettings() -> [String: String] {
        typedSlicerSettings().merging(extraSettings) { _, extra in extra }
    }

    /// Applies OrcaSlicer settings to the profile: keys the typed fields
    /// cover set those fields, every other key of this profile's preset type
    /// goes into extraSettings. Keys belonging to another preset type are
    /// ignored (a full OrcaSlicer config holds all three types).
    mutating func update(from settings: [String: String], allowedKeys: Set<String>? = nil) {
        updateTyped(from: settings)
        for (key, value) in settings where !Self.typedKeys.contains(key) {
            if SlicerKeys.ignored.contains(key) { continue }
            if let allowed = allowedKeys, !allowed.contains(key) { continue }
            extraSettings[key] = value
        }
    }

    /// Fills the typed fields (and extraSettings) with `base` and this
    /// profile's own changes on top, for showing and editing it. A profile
    /// keeps only its changes (extraSettings) between edits.
    mutating func resolve(over base: [String: String]) {
        let own = extraSettings
        extraSettings = [:]
        update(from: base.merging(own) { _, mine in mine })
    }

    /// Keeps only the settings that differ from `base` (compared as libslic3r
    /// writes them): the profile's changes, which a slice applies over the
    /// base preset.
    mutating func keepChanges(from base: [String: String]) {
        let mine = OrcaMigration.normalize(slicerSettings())
        let theirs = OrcaMigration.normalize(base)
        extraSettings = mine.filter { theirs[$0.key] != $0.value && !SlicerKeys.ignored.contains($0.key) }
    }

    /// Sets one setting by OrcaSlicer key, routing typed keys to their field.
    mutating func setSlicerSetting(_ key: String, _ value: String) {
        if Self.typedKeys.contains(key) {
            updateTyped(from: [key: value])
        } else {
            extraSettings[key] = value
        }
    }
}

enum SlicerKeys {
    /// Preset bookkeeping and per-file identity — never stored in a profile.
    static let ignored: Set<String> = [
        "inherits", "compatible_printers", "compatible_printers_condition",
        "compatible_prints", "compatible_prints_condition", "renamed_from",
        "print_settings_id", "filament_settings_id", "printer_settings_id",
        "physical_printer_settings_id", "printer_technology",
        "inherits_group", "different_settings_to_system", "print_compatible_printers",
    ]

    /// OrcaSlicer keys belonging to a preset type, taken from any system preset
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

// MARK: - Value encoding (libslic3r .ini format)

/// Encodes and decodes libslic3r option values as they appear in .ini files.
enum SlicerValue {
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
    var slicerName: String {
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
    init?(slicerName: String) {
        guard let p = Self.allCases.first(where: { $0.slicerName == slicerName }) else { return nil }
        self = p
    }
}

extension IroningType {
    /// OrcaSlicer's ironing_type value when ironing is on ("no ironing" = off).
    var slicerName: String {
        switch bridgeInt {
        case 1: return "topmost"
        case 2: return "solid"
        default: return "top"
        }
    }
    init?(slicerName: String) {
        guard let t = Self.allCases.first(where: { $0.slicerName == slicerName }) else { return nil }
        self = t
    }
}

extension GCodeFlavor {
    var slicerName: String {
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
    init?(slicerName: String) {
        guard let f = Self.allCases.first(where: { $0.slicerName == slicerName }) else { return nil }
        self = f
    }
}

// MARK: - Creating profiles from OrcaSlicer settings

extension SlicerSettingsConvertible {
    /// Copies `settings` of this profile's preset type into the profile
    /// (typed fields + extraSettings). With presets loaded, keys of other
    /// preset types are dropped; without them everything is kept.
    mutating func importSlicerSettings(_ settings: [String: String]) {
        let keys = SlicerKeys.keys(for: Self.presetType)
        update(from: settings, allowedKeys: keys.isEmpty ? nil : keys)
    }
}

// MARK: - Slice profile ↔ print settings

extension SliceProfile: SlicerSettingsConvertible {
    static var presetType: PresetType { .print }

    static let typedKeys: Set<String> = [
        "layer_height", "initial_layer_print_height", "wall_loops", "xy_contour_compensation",
        "wall_generator", "wall_sequence",
        "top_shell_layers", "bottom_shell_layers", "top_shell_thickness", "bottom_shell_thickness",
        "sparse_infill_density", "sparse_infill_pattern", "infill_wall_overlap",
        "slicing_mode", "slice_closing_radius", "line_width", "initial_layer_line_width",
        "outer_wall_speed", "inner_wall_speed", "sparse_infill_speed", "travel_speed", "initial_layer_speed",
        "internal_solid_infill_speed", "top_surface_speed",
        "ironing_type", "ironing_flow", "ironing_speed", "ironing_spacing",
        "enable_support", "support_type", "support_on_build_plate_only",
        "support_threshold_angle", "support_object_xy_distance",
        "support_top_z_distance", "support_bottom_z_distance", "support_interface_top_layers",
        "support_interface_bottom_layers", "support_interface_spacing",
        "brim_type", "brim_width", "skirt_loops", "skirt_distance", "raft_layers",
    ]

    func typedSlicerSettings() -> [String: String] {
        typealias V = SlicerValue
        var s: [String: String] = [
            "layer_height": V.float(layerHeight),
            "initial_layer_print_height": V.float(firstLayerHeight),
            "wall_loops": V.int(wallCount),
            "xy_contour_compensation": V.float(horizontalExpansion),
            "wall_generator": wallGenerator == .classic ? "classic" : "arachne",
            "wall_sequence": externalPerimetersFirst ? "outer wall/inner wall" : "inner wall/outer wall",
            "top_shell_layers": V.int(topLayers),
            "bottom_shell_layers": V.int(bottomLayers),
            "top_shell_thickness": V.float(topThickness),
            "bottom_shell_thickness": V.float(bottomThickness),
            "sparse_infill_density": V.percent(Double(infillDensity)),
            "sparse_infill_pattern": infillPattern.slicerName,
            "infill_wall_overlap": V.percent(infillOverlap),
            "slicing_mode": slicingMode == .evenOdd ? "even_odd" : "regular",
            "slice_closing_radius": V.float(gapClosingRadius),
            // One wall speed, like PrusaSlicer's perimeter_speed: OrcaSlicer
            // splits it into outer and inner walls.
            "outer_wall_speed": V.float(printSpeed),
            "inner_wall_speed": V.float(printSpeed),
            "sparse_infill_speed": V.float(infillSpeed),
            "travel_speed": V.float(travelSpeed),
            "initial_layer_speed": V.float(firstLayerSpeed),
            "internal_solid_infill_speed": V.float(solidInfillSpeed),
            "top_surface_speed": V.float(topSolidInfillSpeed),
            "ironing_type": ironingEnabled ? ironingType.slicerName : "no ironing",
            "ironing_flow": V.percent(ironingFlowrate),
            "ironing_speed": V.float(ironingSpeed),
            "ironing_spacing": V.float(ironingSpacing),
            "enable_support": V.bool(generateSupport),
            "support_type": supportStyle == .tree ? "tree(auto)" : "normal(auto)",
            "support_on_build_plate_only": V.bool(supportPlacement == .buildplateOnly),
            "support_threshold_angle": V.int(supportOverhangAngle),
            "support_object_xy_distance": V.float(supportHorizontalExpansion),
            "support_top_z_distance": V.float(supportContactDistance),
            "support_bottom_z_distance": V.float(supportContactDistance),
            "support_interface_top_layers": V.int(supportInterfaceLayers),
            // Same dense seat under the supports as on top of them.
            "support_interface_bottom_layers": V.int(supportInterfaceLayers),
            "support_interface_spacing": V.float(supportInterfaceSpacing),
        ]
        // 0 = keep the base value (the printer's OrcaSlicer process preset).
        if extrusionWidth > 0 { s["line_width"] = V.float(extrusionWidth) }
        if firstLayerExtrusionWidth > 0 { s["initial_layer_line_width"] = V.float(firstLayerExtrusionWidth) }

        s["skirt_loops"] = V.int(skirtLoops)
        s["skirt_distance"] = V.float(skirtDistance)
        s["brim_type"] = brimType.slicerName
        s["brim_width"] = V.float(brimWidth)
        s["raft_layers"] = V.int(raftLayers)
        return s
    }

    mutating func updateTyped(from s: [String: String]) {
        typealias V = SlicerValue
        // Values the typed fields can't represent exactly; kept verbatim in
        // extraSettings once the fields are set (see SliceProfile).
        var verbatim: [String: String] = [:]

        if let v = s["layer_height"].flatMap(V.parseFloat) { layerHeight = v }
        if let v = s["initial_layer_print_height"] {
            if let mm = V.parseAbsolute(v) { firstLayerHeight = mm }
            else { firstLayerHeight = layerHeight * (V.parseFloat(v) ?? 100) / 100; verbatim["initial_layer_print_height"] = v }
        }
        if let v = s["wall_loops"].flatMap(V.parseInt) { wallCount = v }
        if let v = s["xy_contour_compensation"].flatMap(V.parseFloat) { horizontalExpansion = v }
        if let v = s["wall_generator"] { wallGenerator = v == "classic" ? .classic : .arachne }
        if let v = s["wall_sequence"] {
            externalPerimetersFirst = v == "outer wall/inner wall"
            if v != "outer wall/inner wall" && v != "inner wall/outer wall" { verbatim["wall_sequence"] = v }
        }
        if let v = s["top_shell_layers"].flatMap(V.parseInt) { topLayers = v }
        if let v = s["bottom_shell_layers"].flatMap(V.parseInt) { bottomLayers = v }
        if let v = s["top_shell_thickness"].flatMap(V.parseFloat) { topThickness = v }
        if let v = s["bottom_shell_thickness"].flatMap(V.parseFloat) { bottomThickness = v }
        if let v = s["sparse_infill_density"].flatMap(V.parseFloat) { infillDensity = Int(v.rounded()) }
        if let v = s["sparse_infill_pattern"] {
            if let p = InfillPattern(slicerName: v) { infillPattern = p } else { verbatim["sparse_infill_pattern"] = v }
        }
        if let v = s["infill_wall_overlap"], let f = V.parseFloat(v) {
            infillOverlap = f
            if !v.contains("%") { verbatim["infill_wall_overlap"] = v }
        }
        if let v = s["slicing_mode"] {
            slicingMode = v == "even_odd" ? .evenOdd : .regular
            if v != "even_odd" && v != "regular" { verbatim["slicing_mode"] = v }
        }
        if let v = s["slice_closing_radius"].flatMap(V.parseFloat) { gapClosingRadius = v }
        if let v = s["line_width"] {
            extrusionWidth = V.parseAbsolute(v) ?? 0
            if V.parseAbsolute(v) == nil { verbatim["line_width"] = v }
        }
        if let v = s["initial_layer_line_width"] {
            firstLayerExtrusionWidth = V.parseAbsolute(v) ?? 0
            if V.parseAbsolute(v) == nil { verbatim["initial_layer_line_width"] = v }
        }
        // The wall speed field is the outer wall's; a different inner wall
        // speed is kept as is.
        if let v = s["outer_wall_speed"].flatMap(V.parseFloat) { printSpeed = v }
        if let v = s["inner_wall_speed"], V.parseFloat(v) != printSpeed { verbatim["inner_wall_speed"] = v }
        if let v = s["sparse_infill_speed"].flatMap(V.parseFloat) { infillSpeed = v }
        if let v = s["travel_speed"].flatMap(V.parseFloat) { travelSpeed = v }
        // Speeds given as a percentage: the field shows the resolved mm/s,
        // the percentage is what's sliced.
        func relativeSpeed(_ key: String, of reference: Double) -> Double? {
            guard let v = s[key] else { return nil }
            if let mm = V.parseAbsolute(v) { return mm }
            verbatim[key] = v
            return reference * (V.parseFloat(v) ?? 100) / 100
        }
        if let v = relativeSpeed("initial_layer_speed", of: printSpeed) { firstLayerSpeed = v }
        if let v = relativeSpeed("internal_solid_infill_speed", of: infillSpeed) { solidInfillSpeed = v }
        if let v = relativeSpeed("top_surface_speed", of: solidInfillSpeed) { topSolidInfillSpeed = v }
        if let v = s["ironing_type"] {
            ironingEnabled = v != "no ironing"
            if let t = IroningType(slicerName: v) { ironingType = t }
        }
        if let v = s["ironing_flow"].flatMap(V.parseFloat) { ironingFlowrate = v }
        if let v = s["ironing_speed"].flatMap(V.parseFloat) { ironingSpeed = v }
        if let v = s["ironing_spacing"].flatMap(V.parseFloat) { ironingSpacing = v }
        if let v = s["enable_support"].flatMap(V.parseBool) { generateSupport = v }
        if let v = s["support_type"] {
            supportStyle = v.hasPrefix("tree") ? .tree : .normal
            if v != "tree(auto)" && v != "normal(auto)" { verbatim["support_type"] = v }   // manual: painted / enforcers only
        }
        if let v = s["support_on_build_plate_only"].flatMap(V.parseBool) {
            supportPlacement = v ? .buildplateOnly : .everywhere
        }
        if let v = s["support_threshold_angle"].flatMap(V.parseInt) { supportOverhangAngle = v }
        if let v = s["support_object_xy_distance"] {
            if let mm = V.parseAbsolute(v) { supportHorizontalExpansion = mm } else { verbatim["support_object_xy_distance"] = v }
        }
        if let v = s["support_top_z_distance"].flatMap(V.parseFloat) { supportContactDistance = v }
        if let v = s["support_bottom_z_distance"], V.parseFloat(v) != supportContactDistance {
            verbatim["support_bottom_z_distance"] = v
        }
        if let v = s["support_interface_top_layers"].flatMap(V.parseInt) { supportInterfaceLayers = v }
        if let v = s["support_interface_bottom_layers"], V.parseInt(v) != supportInterfaceLayers {
            verbatim["support_interface_bottom_layers"] = v   // e.g. -1 = "same as top"
        }
        if let v = s["support_interface_spacing"].flatMap(V.parseFloat) { supportInterfaceSpacing = v }

        if let v = s["skirt_loops"].flatMap(V.parseInt) { skirtLoops = v }
        if let v = s["skirt_distance"].flatMap(V.parseFloat) { skirtDistance = v }
        if let v = s["brim_type"] {
            if let b = BrimType(slicerName: v) { brimType = b } else { verbatim["brim_type"] = v }
        }
        if let v = s["brim_width"].flatMap(V.parseFloat) { brimWidth = v }
        if let v = s["raft_layers"].flatMap(V.parseInt) { raftLayers = v }

        for (key, value) in verbatim { extraSettings[key] = value }
    }
}

extension BrimType {
    var slicerName: String {
        switch self {
        case .none: return "no_brim"
        case .outerOnly: return "outer_only"
        case .innerOnly: return "inner_only"
        case .outerAndInner: return "outer_and_inner"
        }
    }
    init?(slicerName: String) {
        guard let b = Self.allCases.first(where: { $0.slicerName == slicerName }) else { return nil }
        self = b
    }
}

// MARK: - Material profile ↔ filament settings

extension MaterialProfile: SlicerSettingsConvertible {
    static var presetType: PresetType { .filament }

    /// Filament overrides of the printer's retraction, in OrcaSlicer.
    static let retractionKeys = ["filament_retraction_length", "filament_retraction_speed",
                                 "filament_retract_restart_extra", "filament_z_hop",
                                 "filament_retraction_minimum_travel"]

    /// OrcaSlicer bed temperatures are per plate type; a PalmSlice material
    /// has one, used on every plate. The smooth PEI ("hot") plate is the one
    /// read back.
    static let bedTemperatureKeys = ["hot_plate_temp", "textured_plate_temp", "cool_plate_temp",
                                     "eng_plate_temp", "supertack_plate_temp", "textured_cool_plate_temp"]
    static let firstLayerBedTemperatureKeys = bedTemperatureKeys.map { $0 + "_initial_layer" }

    static let typedKeys: Set<String> = Set([
        "filament_type", "filament_colour", "filament_diameter", "nozzle_temperature_initial_layer",
        "nozzle_temperature", "filament_flow_ratio",
        "slow_down_for_layer_cooling", "fan_min_speed", "fan_max_speed", "overhang_fan_speed",
        "close_fan_the_first_x_layers", "fan_cooling_layer_time", "slow_down_layer_time",
        "slow_down_min_speed",
    ] + retractionKeys + bedTemperatureKeys + firstLayerBedTemperatureKeys)

    func typedSlicerSettings() -> [String: String] {
        typealias V = SlicerValue
        var s: [String: String] = [
            "filament_type": V.strings([filamentType]),
            "filament_colour": V.strings([colour]),
            "filament_diameter": V.floats([filamentDiameter]),
            "nozzle_temperature_initial_layer": V.ints([firstLayerTemp]),
            "nozzle_temperature": V.ints([otherLayersTemp]),
            "filament_flow_ratio": V.floats([extrusionMultiplier]),
            "slow_down_for_layer_cooling": V.bools([coolingEnabled]),
            "fan_min_speed": V.ints([minFanSpeed]),
            "fan_max_speed": V.ints([maxFanSpeed]),
            "overhang_fan_speed": V.ints([bridgeFanSpeed]),
            "close_fan_the_first_x_layers": V.ints([disableFanFirstLayers]),
            "fan_cooling_layer_time": V.ints([fanBelowLayerTime]),
            "slow_down_layer_time": V.ints([slowdownBelowLayerTime]),
            "slow_down_min_speed": V.floats([minPrintSpeed]),
        ]
        for key in Self.bedTemperatureKeys { s[key] = V.ints([otherLayersBedTemp]) }
        for key in Self.firstLayerBedTemperatureKeys { s[key] = V.ints([firstLayerBedTemp]) }
        let values: [Double] = [retractionEnabled ? retractionLength : 0, retractionSpeed,
                                retractionRestartExtra, zHop, minTravelForRetraction]
        for (key, value) in zip(Self.retractionKeys, values) {
            s[key] = setsRetraction ? V.floats([value]) : "nil"
        }
        return s
    }

    mutating func updateTyped(from s: [String: String]) {
        typealias V = SlicerValue
        if let v = s["filament_type"].flatMap({ V.parseStrings($0).first }), !v.isEmpty { filamentType = v }
        if let v = s["filament_colour"].flatMap({ V.parseStrings($0).first }), HexColour(v) != nil { colour = v }
        if let v = s["filament_diameter"].flatMap(V.parseFloat) { filamentDiameter = v }
        if let v = s["nozzle_temperature_initial_layer"].flatMap(V.parseInt) { firstLayerTemp = v }
        if let v = s["nozzle_temperature"].flatMap(V.parseInt) { otherLayersTemp = v }
        if let v = s["hot_plate_temp_initial_layer"].flatMap(V.parseInt) { firstLayerBedTemp = v }
        if let v = s["hot_plate_temp"].flatMap(V.parseInt) { otherLayersBedTemp = v }
        // Other plates' temperatures that differ are kept as they are.
        for key in Self.bedTemperatureKeys.dropFirst() where s[key].flatMap(V.parseInt) != otherLayersBedTemp {
            if let v = s[key] { extraSettings[key] = v }
        }
        for key in Self.firstLayerBedTemperatureKeys.dropFirst() where s[key].flatMap(V.parseInt) != firstLayerBedTemp {
            if let v = s[key] { extraSettings[key] = v }
        }
        if let v = s["filament_flow_ratio"].flatMap(V.parseFloat) { extrusionMultiplier = v }
        if let v = s["slow_down_for_layer_cooling"].flatMap(V.parseBool) { coolingEnabled = v }
        if let v = s["fan_min_speed"].flatMap(V.parseInt) { minFanSpeed = v }
        if let v = s["fan_max_speed"].flatMap(V.parseInt) { maxFanSpeed = v }
        if let v = s["overhang_fan_speed"].flatMap(V.parseInt) { bridgeFanSpeed = v }
        if let v = s["close_fan_the_first_x_layers"].flatMap(V.parseInt) { disableFanFirstLayers = v }
        if let v = s["fan_cooling_layer_time"].flatMap(V.parseInt) { fanBelowLayerTime = v }
        if let v = s["slow_down_layer_time"].flatMap(V.parseInt) { slowdownBelowLayerTime = v }
        if let v = s["slow_down_min_speed"].flatMap(V.parseFloat) { minPrintSpeed = v }

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
            case "filament_retraction_length":
                retractionEnabled = v > 0
                if v > 0 { retractionLength = v }
            case "filament_retraction_speed": retractionSpeed = v
            case "filament_retract_restart_extra": retractionRestartExtra = v
            case "filament_z_hop": zHop = v
            default: minTravelForRetraction = v
            }
        }
        // Some overridden, some not: keep the unset ones following the printer.
        if setsRetraction { for key in unset { extraSettings[key] = "nil" } }
    }
}

// MARK: - Printer profile ↔ printer settings

extension PrinterProfile: SlicerSettingsConvertible {
    static var presetType: PresetType { .printer }

    static let typedKeys: Set<String> = [
        "printable_area", "printable_height", "gcode_flavor", "machine_start_gcode", "machine_end_gcode",
        "nozzle_diameter", "extruder_offset", "extruder_clearance_radius", "extruder_clearance_height_to_rod",
    ]

    func typedSlicerSettings() -> [String: String] {
        typealias V = SlicerValue
        let count = max(1, numberOfExtruders)
        let exts = (0..<count).map { $0 < extruders.count ? extruders[$0] : ExtruderProfile() }
        // Printhead clearance: OrcaSlicer models the head as a cylinder.
        let radius = [printheadXMin, printheadXMax, printheadYMin, printheadYMax].map(abs).max() ?? 0
        var s: [String: String] = [
            "printable_area": V.points(bedOutline()),
            "printable_height": V.float(bedZ),
            "gcode_flavor": gcodeFlavor.slicerName,
            "machine_start_gcode": V.string(startGCode),
            "machine_end_gcode": V.string(endGCode),
            "nozzle_diameter": V.floats(exts.map(\.nozzleDiameter)),
            "extruder_offset": exts.map { "\(V.float($0.offsetX))x\(V.float($0.offsetY))" }.joined(separator: ","),
            "extruder_clearance_radius": V.float(radius),
        ]
        if gantryHeight > 0 { s["extruder_clearance_height_to_rod"] = V.float(gantryHeight) }
        return s
    }

    /// The bed outline in printer coordinates. Circular beds are approximated
    /// by a 64-gon, the way OrcaSlicer stores circular beds.
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

    mutating func updateTyped(from s: [String: String]) {
        typealias V = SlicerValue
        if let raw = s["printable_area"], case let pts = V.parsePoints(raw), pts.count >= 3 {
            let xs = pts.map(\.0), ys = pts.map(\.1)
            bedX = xs.max()! - xs.min()!
            bedY = ys.max()! - ys.min()!
            originAtCenter = xs.min()! < 0 && ys.min()! < 0
            buildPlateShape = pts.count > 4 ? .circular : .rectangular
            // An outline the fields can't reproduce (e.g. a bed starting at
            // X = 5) is kept verbatim until the bed is edited.
            if V.points(bedOutline()) != V.points(pts) { extraSettings["printable_area"] = raw }
        }
        if let v = s["printable_height"].flatMap(V.parseFloat) { bedZ = v }
        if let v = s["gcode_flavor"] {
            if let f = GCodeFlavor(slicerName: v) { gcodeFlavor = f } else { extraSettings["gcode_flavor"] = v }
        }
        if let v = s["machine_start_gcode"] { startGCode = V.parseString(v) }
        if let v = s["machine_end_gcode"] { endGCode = V.parseString(v) }
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
        if let h = s["extruder_clearance_height_to_rod"].flatMap(V.parseFloat) { gantryHeight = h }
    }
}

extension Binding where Value: SlicerSettingsConvertible {
    /// A number setting without a typed field (e.g. filament_cost), for
    /// editing. `perFilament` settings are stored as a one-value list.
    func number(_ key: String, perFilament: Bool = false) -> Binding<Double> {
        Binding<Double>(
            get: { wrappedValue.extraSettings[key].flatMap { SlicerValue.parseFloats($0).first } ?? 0 },
            set: { wrappedValue.extraSettings[key] = perFilament ? SlicerValue.floats([$0]) : SlicerValue.float($0) })
    }
}
