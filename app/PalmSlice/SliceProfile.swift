import Foundation

// Support structure style — maps to PrusaSlicer SupportMaterialStyle:
// smsGrid=0, smsSnug=1, smsTree=2, smsOrganic=3
enum SupportStyle: String, CaseIterable, Codable, Identifiable {
    case normal = "Normal (Snug)"
    case tree   = "Tree (Organic)"
    var id: String { rawValue }
    // Bridge uses smsSnug(1) for normal and smsOrganic(3) for tree
    var bridgeInt: Int32 { self == .normal ? 1 : 3 }
}

enum SupportPlacement: String, CaseIterable, Codable, Identifiable {
    case everywhere     = "Everywhere"
    case buildplateOnly = "Touching Build Plate Only"
    var id: String { rawValue }
}

// Brim placement — PrusaSlicer brim_type. Skirt, brim and raft are
// independent and can be combined, as in PrusaSlicer.
enum BrimType: String, CaseIterable, Codable, Identifiable {
    case none          = "None"
    case outerOnly     = "Outer Only"
    case innerOnly     = "Inner Only"
    case outerAndInner = "Outer and Inner"
    var id: String { rawValue }
}

// How perimeters are generated — maps to PrusaSlicer perimeter_generator.
// Arachne (the default since 2.5) varies line width to fill thin features;
// Classic keeps a constant width, which some models (e.g. 3DLabPrint planes)
// are designed around.
enum WallGenerator: String, CaseIterable, Codable, Identifiable {
    case arachne = "Arachne (Variable Width)"
    case classic = "Classic (Fixed Width)"
    var id: String { rawValue }
    var bridgeInt: Int32 { self == .classic ? 0 : 1 }
}

// How closed shells are turned into layer outlines — maps to PrusaSlicer
// slicing_mode. Even/Odd treats a region inside an even number of shells as
// empty, so overlapping shells cancel out; models like 3DLabPrint planes
// rely on this to form their internal ribs.
enum SlicingMode: String, CaseIterable, Codable, Identifiable {
    case regular = "Regular"
    case evenOdd = "Even/Odd"
    var id: String { rawValue }
    var bridgeInt: Int32 { self == .evenOdd ? 1 : 0 }
}

struct SliceProfile: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "My Profile"

    // MARK: - Layers
    var layerHeight: Double = 0.2        // mm  — PrusaSlicer: layer_height
    var firstLayerHeight: Double = 0.2 { didSet { extraSettings["first_layer_height"] = nil } }  // mm  — PrusaSlicer: first_layer_height

    // MARK: - Walls
    var wallCount: Int = 3               // PrusaSlicer: perimeters
    var horizontalExpansion: Double = 0.0 // mm — PrusaSlicer: xy_size_compensation
    var wallGenerator: WallGenerator = .arachne  // PrusaSlicer: perimeter_generator
    var externalPerimetersFirst: Bool = false    // PrusaSlicer: external_perimeters_first

    // MARK: - Top / Bottom
    var topLayers: Int = 4              // PrusaSlicer: top_solid_layers
    var bottomLayers: Int = 4           // PrusaSlicer: bottom_solid_layers
    // Min thickness overrides (0 = rely on layer count only)
    var topThickness: Double = 0.0      // mm — PrusaSlicer: top_solid_min_thickness
    var bottomThickness: Double = 0.0   // mm — PrusaSlicer: bottom_solid_min_thickness

    // MARK: - Infill
    var infillDensity: Int = 20         // %  — PrusaSlicer: fill_density
    var infillPattern: InfillPattern = .gyroid { didSet { extraSettings["fill_pattern"] = nil } }  // PrusaSlicer: fill_pattern
    // Overlap of infill into perimeters (% of extrusion width). Stock is 25%;
    // 15% reduces material squished out through the walls on dense/solid parts.
    var infillOverlap: Double = 15.0 { didSet { extraSettings["infill_overlap"] = nil } }  // %  — PrusaSlicer: infill_overlap

    // MARK: - Advanced (defaults match PrusaSlicer's own)
    var slicingMode: SlicingMode = .regular     // PrusaSlicer: slicing_mode
    var gapClosingRadius: Double = 0.049        // mm — PrusaSlicer: slice_closing_radius
    var extrusionWidth: Double = 0.0 { didSet { extraSettings["extrusion_width"] = nil } }  // mm — PrusaSlicer: extrusion_width (0 = keep base)
    var firstLayerExtrusionWidth: Double = 0.0 { didSet { extraSettings["first_layer_extrusion_width"] = nil } }  // mm — PrusaSlicer: first_layer_extrusion_width (0 = keep base)

    // MARK: - Speed (mm/s)
    var printSpeed: Double = 60.0       // PrusaSlicer: perimeter_speed
    var infillSpeed: Double = 80.0      // PrusaSlicer: infill_speed
    var travelSpeed: Double = 120.0     // PrusaSlicer: travel_speed
    var firstLayerSpeed: Double = 30.0 { didSet { extraSettings["first_layer_speed"] = nil } }  // PrusaSlicer: first_layer_speed
    var solidInfillSpeed: Double = 20.0 { didSet { extraSettings["solid_infill_speed"] = nil } }  // PrusaSlicer: solid_infill_speed
    var topSolidInfillSpeed: Double = 15.0 { didSet { extraSettings["top_solid_infill_speed"] = nil } }  // PrusaSlicer: top_solid_infill_speed

    // MARK: - Ironing
    // A slow, low-flow finishing pass over solid top surfaces after solid
    // infill, smoothing the ridges between infill lines. Most useful when
    // Top Layers (or Min Top Thickness) is high enough that those ridges are
    // clearly visible on a large flat top.
    var ironingEnabled: Bool = false
    var ironingType: IroningType = .topSurfaces  // PrusaSlicer: ironing_type
    var ironingFlowrate: Double = 15.0           // %    — PrusaSlicer: ironing_flowrate
    var ironingSpeed: Double = 15.0              // mm/s — PrusaSlicer: ironing_speed
    var ironingSpacing: Double = 0.1             // mm   — PrusaSlicer: ironing_spacing

    // MARK: - Support
    var generateSupport: Bool = false
    var supportStyle: SupportStyle = .normal { didSet { extraSettings["support_material_style"] = nil } }
    var supportPlacement: SupportPlacement = .everywhere
    var supportOverhangAngle: Int = 50   // degrees — PrusaSlicer: support_material_threshold
    var supportHorizontalExpansion: Double = 0.7 { didSet { extraSettings["support_material_xy_spacing"] = nil } }  // mm — PrusaSlicer: support_material_xy_spacing
    var supportUseTowers: Bool = true    // PrusaSlicer: support_material_with_sheath
    // Support-to-part interface — how solid the supported bottom surface prints.
    // Smaller contact gap + dense interface = more solid bottom, harder removal.
    var supportContactDistance: Double = 0.15 // mm — support_material_contact_distance
    var supportInterfaceLayers: Int = 3 { didSet { extraSettings["support_material_bottom_interface_layers"] = nil } }  // PrusaSlicer: support_material_interface_layers
    var supportInterfaceSpacing: Double = 0.2 // mm — support_material_interface_spacing (0 = solid)

    // MARK: - Build Plate Adhesion (independent; any combination, like PrusaSlicer)
    var skirtLoops: Int = 0             // PrusaSlicer: skirts (0 = no skirt)
    var skirtDistance: Double = 6.0     // mm — PrusaSlicer: skirt_distance
    var brimType: BrimType = .none      // PrusaSlicer: brim_type
    var brimWidth: Double = 8.0         // mm — PrusaSlicer: brim_width
    var raftLayers: Int = 0             // PrusaSlicer: raft_layers (0 = no raft)

    // MARK: - PrusaSlicer
    // Fields marked `didSet { extraSettings[...] = nil }` can't hold every
    // PrusaSlicer value (e.g. a speed given as a percentage); an imported value
    // they can't represent is kept verbatim in extraSettings and wins, until
    // the field is edited in PalmSlice.
    //
    // The PrusaSlicer print preset this profile starts from. nil = the
    // printer's default print preset (see PresetLibrary.base).
    var basePreset: String? = nil
    // Any other PrusaSlicer print setting, in .ini value format (see ProfileSettings.swift).
    var extraSettings: [String: String] = [:]

    // MARK: - Summary (shown in picker row subtitle)
    var pickerSubtitle: String {
        let lh = String(format: "%.2g mm", layerHeight)
        let inf = "\(infillDensity)% \(infillPattern.rawValue)"
        let spd = "\(Int(printSpeed)) mm/s"
        let sup = generateSupport ? "Supports On" : "Supports Off"
        return "\(lh) · \(inf) · \(spd) · \(sup)"
    }
}

// Decodes field by field, falling back to each field's default when a key is
// missing, so slice_profiles.json saved by an older version (before a setting
// existed) still loads instead of failing and reseeding the user's profiles.
// Declared in an extension so the memberwise initializer and synthesized
// encode(to:) / CodingKeys are kept.
extension SliceProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SliceProfile()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        self.init()
        id = try v(.id, d.id)
        name = try v(.name, d.name)
        layerHeight = try v(.layerHeight, d.layerHeight)
        firstLayerHeight = try v(.firstLayerHeight, d.firstLayerHeight)
        wallCount = try v(.wallCount, d.wallCount)
        horizontalExpansion = try v(.horizontalExpansion, d.horizontalExpansion)
        wallGenerator = try v(.wallGenerator, d.wallGenerator)
        externalPerimetersFirst = try v(.externalPerimetersFirst, d.externalPerimetersFirst)
        topLayers = try v(.topLayers, d.topLayers)
        bottomLayers = try v(.bottomLayers, d.bottomLayers)
        topThickness = try v(.topThickness, d.topThickness)
        bottomThickness = try v(.bottomThickness, d.bottomThickness)
        infillDensity = try v(.infillDensity, d.infillDensity)
        infillPattern = try v(.infillPattern, d.infillPattern)
        infillOverlap = try v(.infillOverlap, d.infillOverlap)
        slicingMode = try v(.slicingMode, d.slicingMode)
        gapClosingRadius = try v(.gapClosingRadius, d.gapClosingRadius)
        extrusionWidth = try v(.extrusionWidth, d.extrusionWidth)
        firstLayerExtrusionWidth = try v(.firstLayerExtrusionWidth, d.firstLayerExtrusionWidth)
        printSpeed = try v(.printSpeed, d.printSpeed)
        infillSpeed = try v(.infillSpeed, d.infillSpeed)
        travelSpeed = try v(.travelSpeed, d.travelSpeed)
        firstLayerSpeed = try v(.firstLayerSpeed, d.firstLayerSpeed)
        solidInfillSpeed = try v(.solidInfillSpeed, d.solidInfillSpeed)
        topSolidInfillSpeed = try v(.topSolidInfillSpeed, d.topSolidInfillSpeed)
        ironingEnabled = try v(.ironingEnabled, d.ironingEnabled)
        ironingType = try v(.ironingType, d.ironingType)
        ironingFlowrate = try v(.ironingFlowrate, d.ironingFlowrate)
        ironingSpeed = try v(.ironingSpeed, d.ironingSpeed)
        ironingSpacing = try v(.ironingSpacing, d.ironingSpacing)
        generateSupport = try v(.generateSupport, d.generateSupport)
        supportStyle = try v(.supportStyle, d.supportStyle)
        supportPlacement = try v(.supportPlacement, d.supportPlacement)
        supportOverhangAngle = try v(.supportOverhangAngle, d.supportOverhangAngle)
        supportHorizontalExpansion = try v(.supportHorizontalExpansion, d.supportHorizontalExpansion)
        supportUseTowers = try v(.supportUseTowers, d.supportUseTowers)
        supportContactDistance = try v(.supportContactDistance, d.supportContactDistance)
        supportInterfaceLayers = try v(.supportInterfaceLayers, d.supportInterfaceLayers)
        supportInterfaceSpacing = try v(.supportInterfaceSpacing, d.supportInterfaceSpacing)
        brimType = try v(.brimType, d.brimType)
        brimWidth = try v(.brimWidth, d.brimWidth)
        skirtLoops = try v(.skirtLoops, d.skirtLoops)
        skirtDistance = try v(.skirtDistance, d.skirtDistance)
        raftLayers = try v(.raftLayers, d.raftLayers)
        basePreset = try c.decodeIfPresent(String.self, forKey: .basePreset)
        extraSettings = try v(.extraSettings, d.extraSettings)
        try migrateSingleAdhesionChoice(from: decoder)
    }

    private enum LegacyKeys: String, CodingKey { case adhesionType }

    /// Profiles saved before skirt / brim / raft were independent stored one
    /// adhesionType ("None", "Skirt", "Brim", "Raft") and kept the other
    /// options' values unused. Keep only the chosen one switched on.
    private mutating func migrateSingleAdhesionChoice(from decoder: Decoder) throws {
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        guard let choice = try legacy.decodeIfPresent(String.self, forKey: .adhesionType) else { return }
        if choice != "Skirt" { skirtLoops = 0 }
        if choice != "Brim" { brimType = .none }
        if choice != "Raft" { raftLayers = 0 }
        // A brim_type kept verbatim by the old single-choice mapping.
        if let raw = extraSettings.removeValue(forKey: "brim_type"), let b = BrimType(prusaName: raw), choice == "Brim" {
            brimType = b
        }
    }
}

// MARK: - Profile → C bridge
extension SliceProfile {
    func bridgeConfig() -> SlicerSliceConfig {
        let profile = self
        var cfg = SlicerSliceConfig()
        cfg.layer_height         = Float(profile.layerHeight)
        cfg.first_layer_height   = Float(profile.firstLayerHeight)
        cfg.wall_count           = Int32(profile.wallCount)
        cfg.horizontal_expansion = Float(profile.horizontalExpansion)
        cfg.wall_generator       = profile.wallGenerator.bridgeInt
        cfg.external_perimeters_first = profile.externalPerimetersFirst ? 1 : 0
        cfg.top_layers           = Int32(profile.topLayers)
        cfg.bottom_layers        = Int32(profile.bottomLayers)
        cfg.top_thickness        = Float(profile.topThickness)
        cfg.bottom_thickness     = Float(profile.bottomThickness)
        cfg.infill_density       = Int32(profile.infillDensity)
        cfg.infill_pattern       = profile.infillPattern.bridgeInt
        cfg.infill_overlap       = Float(profile.infillOverlap)
        cfg.slicing_mode         = profile.slicingMode.bridgeInt
        cfg.gap_closing_radius   = Float(profile.gapClosingRadius)
        cfg.extrusion_width      = Float(profile.extrusionWidth)
        cfg.first_layer_extrusion_width = Float(profile.firstLayerExtrusionWidth)
        cfg.print_speed          = Float(profile.printSpeed)
        cfg.infill_speed         = Float(profile.infillSpeed)
        cfg.travel_speed         = Float(profile.travelSpeed)
        cfg.first_layer_speed    = Float(profile.firstLayerSpeed)
        cfg.solid_infill_speed     = Float(profile.solidInfillSpeed)
        cfg.top_solid_infill_speed = Float(profile.topSolidInfillSpeed)
        cfg.ironing              = profile.ironingEnabled ? 1 : 0
        cfg.ironing_type         = profile.ironingType.bridgeInt
        cfg.ironing_flowrate     = Float(profile.ironingFlowrate)
        cfg.ironing_speed        = Float(profile.ironingSpeed)
        cfg.ironing_spacing      = Float(profile.ironingSpacing)
        cfg.generate_support     = profile.generateSupport ? 1 : 0
        cfg.support_style        = profile.supportStyle.bridgeInt
        cfg.support_buildplate_only = profile.supportPlacement == .buildplateOnly ? 1 : 0
        cfg.support_overhang_angle  = Int32(profile.supportOverhangAngle)
        cfg.support_xy_spacing      = Float(profile.supportHorizontalExpansion)
        cfg.support_use_towers      = profile.supportUseTowers ? 1 : 0
        cfg.support_contact_distance = Float(profile.supportContactDistance)
        cfg.support_interface_layers = Int32(profile.supportInterfaceLayers)
        cfg.support_interface_spacing = Float(profile.supportInterfaceSpacing)
        return cfg
    }
}
