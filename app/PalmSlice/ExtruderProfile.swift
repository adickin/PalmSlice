import Foundation

struct ExtruderProfile: Codable, Identifiable {
    var id: UUID = UUID()
    var nozzleDiameter: Double = 0.4                      // mm
    var compatibleMaterialDiameters: [Double] = [1.75]    // mm; [1.75] or [2.85]
    var offsetX: Double = 0.0                             // mm
    var offsetY: Double = 0.0                             // mm
    var coolingFanNumber: Int = 0                         // 0-based fan index
    var extruderChangeDuration: Double = 0.0              // seconds
    var startGCode: String = ""
    var endGCode: String = ""
}

extension ExtruderProfile {
    // Every field falls back to its default, so adding a field doesn't make
    // saved printers undecodable (ProfileFile would set the file aside).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExtruderProfile()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        nozzleDiameter = try c.decodeIfPresent(Double.self, forKey: .nozzleDiameter) ?? d.nozzleDiameter
        compatibleMaterialDiameters = try c.decodeIfPresent([Double].self, forKey: .compatibleMaterialDiameters)
            ?? d.compatibleMaterialDiameters
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? d.offsetX
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? d.offsetY
        coolingFanNumber = try c.decodeIfPresent(Int.self, forKey: .coolingFanNumber) ?? d.coolingFanNumber
        extruderChangeDuration = try c.decodeIfPresent(Double.self, forKey: .extruderChangeDuration)
            ?? d.extruderChangeDuration
        startGCode = try c.decodeIfPresent(String.self, forKey: .startGCode) ?? d.startGCode
        endGCode = try c.decodeIfPresent(String.self, forKey: .endGCode) ?? d.endGCode
    }
}
