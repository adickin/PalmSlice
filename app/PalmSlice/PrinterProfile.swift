import Foundation

struct PrinterProfile: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "My Printer"

    // Whether this profile has been confirmed to print correctly on real
    // hardware. Built-in profiles pulled straight from PrusaSlicer's vendor
    // library start out unverified; the user can promote one to verified
    // (see ProfilePickerView). Profiles the user creates themselves default
    // to verified since they're presumably describing a printer they own.
    var verified: Bool = true

    // Stable identifier linking a seeded profile back to its BuiltInProfiles
    // template, so ProfileStore can add newly-introduced built-ins to an
    // existing user's saved profiles without disturbing anything they've
    // customized. nil for user-created profiles.
    var builtInKey: String? = nil

    // The PrusaSlicer system printer preset this profile is based on (e.g.
    // "Creality Ender-3 S1 (0.4 mm nozzle)"). Every slice applies that preset,
    // plus its default print preset and a matching filament preset, before
    // this profile's own settings — see PresetLibrary. nil for printers the
    // user defined from scratch.
    var systemPreset: String? = nil

    // MARK: Bed / Machine
    var bedX: Double = 220.0               // mm (width)
    var bedY: Double = 220.0               // mm (depth)
    var bedZ: Double = 250.0               // mm (height)
    var buildPlateShape: BuildPlateShape = .rectangular
    var originAtCenter: Bool = false
    var heatedBed: Bool = true
    var heatedBuildVolume: Bool = false

    // MARK: G-Code
    var gcodeFlavor: GCodeFlavor = .marlin
    var startGCode: String = ""
    var endGCode: String = ""

    // MARK: Printhead
    var printheadXMin: Double = -2.0       // mm (toward left)
    var printheadYMin: Double = -2.0       // mm (toward back)
    var printheadXMax: Double = 2.0        // mm (toward right)
    var printheadYMax: Double = 2.0        // mm (toward front)
    var gantryHeight: Double = 0.0         // mm
    var numberOfExtruders: Int = 1
    var applyExtruderOffsetsToGCode: Bool = false
    var startGCodeMustBeFirst: Bool = false

    // MARK: Per-extruder
    var extruders: [ExtruderProfile] = [ExtruderProfile()]

    enum CodingKeys: String, CodingKey {
        case id, name, verified, builtInKey, systemPreset
        case bedX, bedY, bedZ, buildPlateShape, originAtCenter, heatedBed, heatedBuildVolume
        case gcodeFlavor, startGCode, endGCode
        case printheadXMin, printheadYMin, printheadXMax, printheadYMax, gantryHeight
        case numberOfExtruders, applyExtruderOffsetsToGCode, startGCodeMustBeFirst
        case extruders
    }

    init() {}

    // Custom decode so profiles saved before `verified`/`builtInKey` existed
    // still decode successfully (missing keys fall back to their defaults)
    // instead of failing and triggering ProfileStore's reseed-from-scratch
    // path, which would wipe the user's saved/edited profiles.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "My Printer"
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? true
        builtInKey = try c.decodeIfPresent(String.self, forKey: .builtInKey)
        systemPreset = try c.decodeIfPresent(String.self, forKey: .systemPreset)

        bedX = try c.decodeIfPresent(Double.self, forKey: .bedX) ?? 220.0
        bedY = try c.decodeIfPresent(Double.self, forKey: .bedY) ?? 220.0
        bedZ = try c.decodeIfPresent(Double.self, forKey: .bedZ) ?? 250.0
        buildPlateShape = try c.decodeIfPresent(BuildPlateShape.self, forKey: .buildPlateShape) ?? .rectangular
        originAtCenter = try c.decodeIfPresent(Bool.self, forKey: .originAtCenter) ?? false
        heatedBed = try c.decodeIfPresent(Bool.self, forKey: .heatedBed) ?? true
        heatedBuildVolume = try c.decodeIfPresent(Bool.self, forKey: .heatedBuildVolume) ?? false

        gcodeFlavor = try c.decodeIfPresent(GCodeFlavor.self, forKey: .gcodeFlavor) ?? .marlin
        startGCode = try c.decodeIfPresent(String.self, forKey: .startGCode) ?? ""
        endGCode = try c.decodeIfPresent(String.self, forKey: .endGCode) ?? ""

        printheadXMin = try c.decodeIfPresent(Double.self, forKey: .printheadXMin) ?? -2.0
        printheadYMin = try c.decodeIfPresent(Double.self, forKey: .printheadYMin) ?? -2.0
        printheadXMax = try c.decodeIfPresent(Double.self, forKey: .printheadXMax) ?? 2.0
        printheadYMax = try c.decodeIfPresent(Double.self, forKey: .printheadYMax) ?? 2.0
        gantryHeight = try c.decodeIfPresent(Double.self, forKey: .gantryHeight) ?? 0.0
        numberOfExtruders = try c.decodeIfPresent(Int.self, forKey: .numberOfExtruders) ?? 1
        applyExtruderOffsetsToGCode = try c.decodeIfPresent(Bool.self, forKey: .applyExtruderOffsetsToGCode) ?? false
        startGCodeMustBeFirst = try c.decodeIfPresent(Bool.self, forKey: .startGCodeMustBeFirst) ?? false

        extruders = try c.decodeIfPresent([ExtruderProfile].self, forKey: .extruders) ?? [ExtruderProfile()]
    }
}
