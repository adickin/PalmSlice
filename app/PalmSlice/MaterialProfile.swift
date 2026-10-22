import Foundation

struct MaterialProfile: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "My Material"

    // MARK: - Filament
    var filamentDiameter: Double = 1.75      // mm  — filament_diameter (per-extruder array)
    // PrusaSlicer filament_type (PLA, PETG, ABS, FLEX, …). Picks the vendor
    // filament preset a slice starts from (see PresetLibrary.base), so
    // settings this profile doesn't set match the material.
    var filamentType: String = "PLA"

    // MARK: - Temperatures
    var firstLayerTemp: Int = 215            // °C  — first_layer_temperature (per-extruder)
    var otherLayersTemp: Int = 210           // °C  — temperature (per-extruder)
    var firstLayerBedTemp: Int = 60          // °C  — first_layer_bed_temperature (per-extruder)
    var otherLayersBedTemp: Int = 55         // °C  — bed_temperature (per-extruder)

    // MARK: - Flow
    var extrusionMultiplier: Double = 1.0    // 0.5–2.0 — extrusion_multiplier (per-extruder)

    // MARK: - Retraction
    // PrusaSlicer keeps retraction on the printer (retract_*); a filament can
    // override it (filament_retract_*). setsRetraction = false uses the
    // printer's; true overrides it with the values below. An imported filament
    // that overrides only some values keeps "nil" for the rest in extraSettings
    // until the field is edited.
    var setsRetraction: Bool = true
    var retractionEnabled: Bool = true { didSet { extraSettings["filament_retract_length"] = nil } }
    var retractionLength: Double = 5.0 { didSet { extraSettings["filament_retract_length"] = nil } }  // mm — filament_retract_length (0 = no retract)
    var retractionSpeed: Double = 45.0 { didSet { extraSettings["filament_retract_speed"] = nil } }  // mm/s — filament_retract_speed
    var retractionRestartExtra: Double = 0.0 { didSet { extraSettings["filament_retract_restart_extra"] = nil } }  // mm — filament_retract_restart_extra: extra pushed after deretraction
    var zHop: Double = 0.0 { didSet { extraSettings["filament_retract_lift"] = nil } }  // mm — filament_retract_lift
    var minTravelForRetraction: Double = 1.0 { didSet { extraSettings["filament_retract_before_travel"] = nil } }  // mm — filament_retract_before_travel

    // MARK: - Cooling / Fan
    var coolingEnabled: Bool = true          // bool — cooling (per-extruder)
    var minFanSpeed: Int = 35                // %   — min_fan_speed (per-extruder)
    var maxFanSpeed: Int = 100               // %   — max_fan_speed (per-extruder)
    var bridgeFanSpeed: Int = 100            // %   — bridge_fan_speed (per-extruder)
    var disableFanFirstLayers: Int = 3       // N   — disable_fan_first_layers (per-extruder)
    var fanBelowLayerTime: Int = 60          // sec — fan_below_layer_time: enable fan if layer prints in under N sec
    var slowdownBelowLayerTime: Int = 5      // sec — slowdown_below_layer_time: slow down if layer prints in under N sec
    var minPrintSpeed: Double = 10.0         // mm/s — min_print_speed: floor speed when cooling slowdown is active

    // MARK: - PrusaSlicer
    // The PrusaSlicer filament preset this profile starts from. nil = a
    // preset matching filamentType for the printer (see PresetLibrary.base).
    var basePreset: String? = nil
    // Any other PrusaSlicer filament setting, in .ini value format (see ProfileSettings.swift).
    var extraSettings: [String: String] = [:]

    // MARK: - Summary (shown in picker row subtitle)
    var pickerSubtitle: String {
        let temp = "\(firstLayerTemp)/\(otherLayersTemp)°C"
        let retract = !setsRetraction ? "Printer retraction"
            : retractionEnabled ? "\(retractionLength) mm retract" : "No retract"
        let fan = coolingEnabled ? "Fan \(minFanSpeed)–\(maxFanSpeed)%" : "Fan off"
        return "\(temp) · \(retract) · \(fan)"
    }
}

// Decodes field by field, falling back to each field's default when a key is
// missing, so materials saved by an older version still load after a field is
// added. In an extension to keep the memberwise init and synthesized encoding.
extension MaterialProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MaterialProfile()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        self.init()
        id = try v(.id, d.id)
        name = try v(.name, d.name)
        filamentDiameter = try v(.filamentDiameter, d.filamentDiameter)
        filamentType = try v(.filamentType, d.filamentType)
        firstLayerTemp = try v(.firstLayerTemp, d.firstLayerTemp)
        otherLayersTemp = try v(.otherLayersTemp, d.otherLayersTemp)
        firstLayerBedTemp = try v(.firstLayerBedTemp, d.firstLayerBedTemp)
        otherLayersBedTemp = try v(.otherLayersBedTemp, d.otherLayersBedTemp)
        extrusionMultiplier = try v(.extrusionMultiplier, d.extrusionMultiplier)
        setsRetraction = try v(.setsRetraction, d.setsRetraction)
        retractionEnabled = try v(.retractionEnabled, d.retractionEnabled)
        retractionLength = try v(.retractionLength, d.retractionLength)
        retractionSpeed = try v(.retractionSpeed, d.retractionSpeed)
        retractionRestartExtra = try v(.retractionRestartExtra, d.retractionRestartExtra)
        zHop = try v(.zHop, d.zHop)
        minTravelForRetraction = try v(.minTravelForRetraction, d.minTravelForRetraction)
        coolingEnabled = try v(.coolingEnabled, d.coolingEnabled)
        minFanSpeed = try v(.minFanSpeed, d.minFanSpeed)
        maxFanSpeed = try v(.maxFanSpeed, d.maxFanSpeed)
        bridgeFanSpeed = try v(.bridgeFanSpeed, d.bridgeFanSpeed)
        disableFanFirstLayers = try v(.disableFanFirstLayers, d.disableFanFirstLayers)
        fanBelowLayerTime = try v(.fanBelowLayerTime, d.fanBelowLayerTime)
        slowdownBelowLayerTime = try v(.slowdownBelowLayerTime, d.slowdownBelowLayerTime)
        minPrintSpeed = try v(.minPrintSpeed, d.minPrintSpeed)
        basePreset = try c.decodeIfPresent(String.self, forKey: .basePreset)
        extraSettings = try v(.extraSettings, d.extraSettings)
    }
}
