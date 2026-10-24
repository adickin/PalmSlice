# Slicing Profiles — Implementation Plan

## Goal

Add a complete slicing (print) profile system modelled after the printer profile system: data model, persistence, built-in quality presets, a SwiftUI editor, and a summary card in the picker list. Profiles are selected before slicing and their settings are passed through the C bridge to libslic3r.

> **Material note:** Retraction, Z-hop, cooling, and fan speed are **not** in slice profiles. In PrusaSlicer's architecture these live in the *filament* (material) profile because they are material-dependent. They are tracked separately in the Material Profiles section of PROGRESS.md and will be implemented as part of that feature.

---

## 1. Data Model

### 1.1 Infill Pattern

```swift
// InfillPattern.swift
enum InfillPattern: String, CaseIterable, Codable, Identifiable {
    case gyroid      = "Gyroid"
    case grid        = "Grid"
    case honeycomb   = "Honeycomb"
    case rectilinear = "Lines"
    case triangles   = "Triangles"
    case cubic       = "Cubic"
    case adaptiveCubic = "Adaptive Cubic"
    case lightning   = "Lightning"
    var id: String { rawValue }
}

// Maps to PrusaSlicer's InfillPattern enum (fill_pattern key).
// Ordinals verified against ~/ios-sources/PrusaSlicer/src/libslic3r/PrintConfig.hpp:
// ipRectilinear=0, ipMonotonic=1, ipMonotonicLines=2, ipAlignedRectilinear=3,
// ipGrid=4, ipTriangles=5, ipStars=6, ipCubic=7, ipLine=8, ipConcentric=9,
// ipHoneycomb=10, ip3DHoneycomb=11, ipGyroid=12, ipHilbertCurve=13,
// ipArchimedeanChords=14, ipOctagramSpiral=15, ipAdaptiveCubic=16,
// ipSupportCubic=17, ipSupportBase=18, ipLightning=19
extension InfillPattern {
    var bridgeInt: Int32 {
        switch self {
        case .rectilinear:    return 0
        case .grid:           return 4
        case .triangles:      return 5
        case .cubic:          return 7
        case .honeycomb:      return 10
        case .gyroid:         return 12
        case .adaptiveCubic:  return 16
        case .lightning:      return 19
        }
    }
}
```

### 1.2 SupportStyle

```swift
enum SupportStyle: String, CaseIterable, Codable, Identifiable {
    case normal = "Normal (Snug)"
    case tree   = "Tree (Auto)"
    var id: String { rawValue }
}
```

### 1.3 SupportPlacement

```swift
enum SupportPlacement: String, CaseIterable, Codable, Identifiable {
    case everywhere       = "Everywhere"
    case buildplateOnly   = "Touching Build Plate Only"
    var id: String { rawValue }
}
```

### 1.4 BrimType

```swift
// Maps to PrusaSlicer brim_type: no_brim=0, outer_only=1, inner_only=2, outer_and_inner=3
enum BrimType: String, CaseIterable, Codable, Identifiable {
    case none         = "None"
    case outerOnly    = "Outer Only"
    case innerOnly    = "Inner Only"
    case outerAndInner = "Outer and Inner"
    var id: String { rawValue }
    var bridgeInt: Int32 {
        switch self {
        case .none:         return 0
        case .outerOnly:    return 1
        case .innerOnly:    return 2
        case .outerAndInner: return 3
        }
    }
}
```

### 1.5 SliceProfile

```swift
// SliceProfile.swift
struct SliceProfile: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "My Profile"

    // --- Layers ---
    var layerHeight: Double = 0.2           // mm; PrusaSlicer: layer_height
    var firstLayerHeight: Double = 0.2      // mm; PrusaSlicer: first_layer_height

    // --- Walls (Perimeters) ---
    var wallCount: Int = 3                  // PrusaSlicer: perimeters
    var horizontalExpansion: Double = 0.0   // mm; PrusaSlicer: xy_size_compensation

    // --- Top / Bottom ---
    var topLayers: Int = 4                  // PrusaSlicer: top_solid_layers
    var bottomLayers: Int = 4               // PrusaSlicer: bottom_solid_layers
    var topThickness: Double = 0.0          // mm; 0 = use topLayers count instead; PrusaSlicer: top_solid_min_thickness
    var bottomThickness: Double = 0.0       // mm; 0 = use bottomLayers count; PrusaSlicer: bottom_solid_min_thickness

    // --- Infill ---
    var infillDensity: Int = 20             // %; PrusaSlicer: fill_density (stored as 0.0–1.0, convert on bridge)
    var infillPattern: InfillPattern = .gyroid // PrusaSlicer: fill_pattern

    // --- Speed (mm/s) ---
    var printSpeed: Double = 60.0           // PrusaSlicer: perimeter_speed (use as base)
    var infillSpeed: Double = 80.0          // PrusaSlicer: infill_speed
    var travelSpeed: Double = 120.0         // PrusaSlicer: travel_speed
    var firstLayerSpeed: Double = 30.0      // PrusaSlicer: first_layer_speed

    // --- Support ---
    var generateSupport: Bool = false                       // PrusaSlicer: support_material
    var supportStyle: SupportStyle = .normal               // PrusaSlicer: support_material_style (0=grid/default, 1=snug, 2=tree)
    var supportPlacement: SupportPlacement = .everywhere   // PrusaSlicer: support_material_buildplate_only (inverted)
    var supportOverhangAngle: Int = 50                     // degrees; PrusaSlicer: support_material_threshold
    var supportHorizontalExpansion: Double = 0.7           // mm; PrusaSlicer: support_material_xy_spacing (actually a ratio — see notes below)
    var supportUseTowers: Bool = true                       // PrusaSlicer: support_material_with_sheath (closest equivalent)

    // --- Build Plate Adhesion ---
    var brimType: BrimType = .none          // PrusaSlicer: brim_type
    var brimWidth: Double = 8.0             // mm; PrusaSlicer: brim_width
    var skirtLoops: Int = 1                 // PrusaSlicer: skirts (0 = disabled)
    var skirtDistance: Double = 6.0         // mm; PrusaSlicer: skirt_distance
    var raftLayers: Int = 0                 // PrusaSlicer: raft_layers (0 = no raft)
}
```

**Notes on tricky fields:**
- `support_material_xy_spacing` in PrusaSlicer is expressed as a ratio of `support_material_extrusion_width`, not an absolute mm value. The bridge should pass the mm value and convert to ratio (divide by nozzle diameter * 1.125 or use a fixed 0.7 mm → ratio of ~1.5 for 0.4 mm nozzle). Alternatively expose as mm and convert in the bridge.
- `support_material_style`: PrusaSlicer uses `0=grid`, `1=snug`, `2=tree_slim`, `3=tree_strong`, `4=tree_hybrid`. Map our `normal→1` (snug) and `tree→3` (tree_strong) as sensible defaults.
- `first_layer_height` can be expressed as a percentage string (`"50%"`) or absolute mm in PrusaSlicer config. Always use absolute mm in the bridge struct.
- `skirts > 0` means skirt is active; `skirts = 0` disables the skirt. `brim_type != no_brim` disables the skirt automatically in PrusaSlicer.

---

## 2. Persistence — SliceProfileStore

Same pattern as `ProfileStore`:

```swift
// SliceProfileStore.swift
@MainActor
final class SliceProfileStore: ObservableObject {
    @Published var profiles: [SliceProfile] = []
    @Published var selectedProfileId: UUID?

    var selectedProfile: SliceProfile? {
        profiles.first { $0.id == selectedProfileId }
    }

    func load() { ... }   // reads Documents/slice_profiles.json; seeds defaults if empty
    func save() { ... }   // writes atomically
    func add(_ profile: SliceProfile) { ... }
    func update(_ profile: SliceProfile) { ... }
    func delete(id: UUID) { ... }
    func select(id: UUID) { ... }
}
```

File: `Documents/slice_profiles.json`

---

## 3. Built-in Slice Profiles

Three quality presets covering the most common use cases:

```swift
// BuiltInSliceProfiles.swift
enum BuiltInSliceProfiles {
    static let draft = SliceProfile(
        name: "Draft (0.3 mm)",
        layerHeight: 0.3, firstLayerHeight: 0.3,
        wallCount: 2,
        topLayers: 3, bottomLayers: 3,
        infillDensity: 15, infillPattern: .grid,
        printSpeed: 80, infillSpeed: 100, travelSpeed: 150, firstLayerSpeed: 30
    )
    static let standard = SliceProfile(
        name: "Standard (0.2 mm)",
        layerHeight: 0.2, firstLayerHeight: 0.2,
        wallCount: 3,
        topLayers: 4, bottomLayers: 4,
        infillDensity: 20, infillPattern: .gyroid,
        printSpeed: 60, infillSpeed: 80, travelSpeed: 120, firstLayerSpeed: 30
    )
    static let fine = SliceProfile(
        name: "Fine (0.1 mm)",
        layerHeight: 0.1, firstLayerHeight: 0.1,
        wallCount: 4,
        topLayers: 6, bottomLayers: 6,
        infillDensity: 20, infillPattern: .gyroid,
        printSpeed: 40, infillSpeed: 60, travelSpeed: 120, firstLayerSpeed: 20
    )
    static let all: [SliceProfile] = [draft, standard, fine]
}
```

---

## 4. C Bridge Additions

### slicer_bridge.h

```c
typedef struct {
    // Layers
    float layer_height;
    float first_layer_height;

    // Walls
    int   wall_count;           // perimeters
    float horizontal_expansion; // xy_size_compensation (mm, can be negative)

    // Top / Bottom
    int   top_layers;
    int   bottom_layers;
    float top_thickness;        // 0 = use layer count
    float bottom_thickness;     // 0 = use layer count

    // Infill
    int   infill_density;       // 0–100 %; bridge divides by 100.0 before setting fill_density
    int   infill_pattern;       // InfillPattern::bridgeInt

    // Speed (mm/s)
    float print_speed;          // perimeter_speed
    float infill_speed;
    float travel_speed;
    float first_layer_speed;

    // Support
    int   generate_support;          // bool
    int   support_style;             // 0=grid/snug, 2=tree (maps to support_material_style)
    int   support_buildplate_only;   // bool (inverted from "everywhere")
    int   support_overhang_angle;    // degrees; support_material_threshold
    float support_xy_spacing;        // mm; converted to ratio in bridge
    int   support_use_towers;        // bool (support_material_with_sheath)

    // Adhesion
    int   brim_type;            // BrimType::bridgeInt
    float brim_width;           // mm
    int   skirt_loops;
    float skirt_distance;       // mm
    int   raft_layers;
} SlicerSliceConfig;

// Apply slice settings. Call before slicer_slice / slicer_slice_with_progress.
// Returns 0 on success, negative on error.
int slicer_apply_slice_config(SlicerHandle handle,
                              const SlicerSliceConfig* cfg);
```

### slicer_bridge.cpp — implementation sketch

```cpp
int slicer_apply_slice_config(SlicerHandle handle, const SlicerSliceConfig* cfg) {
    auto* ctx = reinterpret_cast<SlicerContext*>(handle);

    DynamicPrintConfig& c = ctx->slice_config;

    c.set_key_value("layer_height",         new ConfigOptionFloat(cfg->layer_height));
    c.set_key_value("first_layer_height",   new ConfigOptionFloatOrPercent(cfg->first_layer_height, false));
    c.set_key_value("perimeters",           new ConfigOptionInt(cfg->wall_count));
    c.set_key_value("xy_size_compensation", new ConfigOptionFloat(cfg->horizontal_expansion));

    c.set_key_value("top_solid_layers",    new ConfigOptionInt(cfg->top_layers));
    c.set_key_value("bottom_solid_layers", new ConfigOptionInt(cfg->bottom_layers));
    if (cfg->top_thickness > 0.0f)
        c.set_key_value("top_solid_min_thickness",    new ConfigOptionFloat(cfg->top_thickness));
    if (cfg->bottom_thickness > 0.0f)
        c.set_key_value("bottom_solid_min_thickness", new ConfigOptionFloat(cfg->bottom_thickness));

    c.set_key_value("fill_density", new ConfigOptionPercent(cfg->infill_density));
    c.set_key_value("fill_pattern", new ConfigOptionEnum<InfillPattern>(
        static_cast<InfillPattern>(cfg->infill_pattern)));

    c.set_key_value("perimeter_speed",   new ConfigOptionFloatOrPercent(cfg->print_speed, false));
    c.set_key_value("infill_speed",      new ConfigOptionFloatOrPercent(cfg->infill_speed, false));
    c.set_key_value("travel_speed",      new ConfigOptionFloat(cfg->travel_speed));
    c.set_key_value("first_layer_speed", new ConfigOptionFloatOrPercent(cfg->first_layer_speed, false));

    c.set_key_value("support_material", new ConfigOptionBool(cfg->generate_support != 0));
    if (cfg->generate_support) {
        c.set_key_value("support_material_style",
            new ConfigOptionEnum<SupportMaterialStyle>(
                static_cast<SupportMaterialStyle>(cfg->support_style)));
        c.set_key_value("support_material_buildplate_only",
            new ConfigOptionBool(cfg->support_buildplate_only != 0));
        c.set_key_value("support_material_threshold",
            new ConfigOptionInt(cfg->support_overhang_angle));
        // xy_spacing is a ratio of extrusion width in PrusaSlicer
        // Approximate: 0.7 mm / (nozzle_diameter * 1.125) — default 0.4 mm nozzle → ~1.56
        // Store mm value on context and resolve to ratio at slice time using nozzle diameter.
        ctx->support_xy_spacing_mm = cfg->support_xy_spacing;
        c.set_key_value("support_material_with_sheath",
            new ConfigOptionBool(cfg->support_use_towers != 0));
    }

    c.set_key_value("brim_type",     new ConfigOptionEnum<BrimType>(
        static_cast<BrimType>(cfg->brim_type)));
    c.set_key_value("brim_width",    new ConfigOptionFloat(cfg->brim_width));
    c.set_key_value("skirts",        new ConfigOptionInt(cfg->skirt_loops));
    c.set_key_value("skirt_distance",new ConfigOptionFloat(cfg->skirt_distance));
    c.set_key_value("raft_layers",   new ConfigOptionInt(cfg->raft_layers));

    return 0;
}
```

**Important:** In `slicer_slice` / `slicer_slice_with_progress`, merge `ctx->slice_config` into the `DynamicPrintConfig` before calling `print.apply()`. Currently the bridge builds config inline — refactor to accumulate printer + slice configs on the context and apply them together.

---

## 5. SwiftUI Files

### 5.1 SliceProfilePickerView

Mirrors `ProfilePickerView` exactly. Each row shows:
- **Name** (bold)
- Subtitle line: `{layerHeight} mm · {infillDensity}% {infillPattern.rawValue} · {printSpeed} mm/s · Supports: {generateSupport ? "On" : "Off"}`

### 5.2 SliceProfileEditorView

`Form` with the following sections:

**1. Name**
- TextField

**2. Layers**
- Layer Height (mm) — decimal TextField, 0.05–0.5 range hint
- First Layer Height (mm) — decimal TextField

**3. Walls**
- Wall Count — Stepper (1–8)
- Horizontal Expansion (mm) — decimal TextField (negative shrinks, positive expands)

**4. Top / Bottom**
- Top Layers — Stepper (0–20)
- Bottom Layers — Stepper (0–20)
- Min Top Thickness (mm) — decimal TextField (0 = disabled)
- Min Bottom Thickness (mm) — decimal TextField

**5. Infill**
- Infill Density (%) — Slider 0–100, integer step
- Infill Pattern — Picker (all InfillPattern cases)

**6. Speed**
- Print (Perimeter) Speed (mm/s) — decimal TextField
- Infill Speed (mm/s) — decimal TextField
- Travel Speed (mm/s) — decimal TextField
- First Layer Speed (mm/s) — decimal TextField

**7. Support**
- Generate Support — Toggle
  (when on, reveal sub-options via a conditional Section or indented group:)
  - Support Style — Picker (Normal / Tree)
  - Support Placement — Picker (Everywhere / Touching Build Plate Only)
  - Overhang Angle (°) — Stepper (20–90)
  - Horizontal Expansion (mm) — decimal TextField
  - Use Support Towers — Toggle

**8. Build Plate Adhesion**
- Adhesion Type — Picker segmented (None / Skirt / Brim / Raft)
  - If Skirt: Skirt Loops (Stepper 1–5), Skirt Distance (mm)
  - If Brim: Brim Type (Picker: Outer Only / Inner Only / Outer and Inner), Brim Width (mm)
  - If Raft: Raft Layers (Stepper 1–5)

*Note: expose Adhesion Type as a computed wrapper enum in the ViewModel that maps to (brimType / skirtLoops / raftLayers) since PrusaSlicer stores them as separate keys.*

```swift
enum AdhesionType: String, CaseIterable { case none, skirt, brim, raft }
// In editor ViewModel: derive from (skirtLoops > 0, brimType != .none, raftLayers > 0)
// On change: reset the others to their "off" values.
```

---

## 6. ContentView Integration

Add a "Profile: [Name]" tappable row alongside the printer row. Before slicing:
1. Ensure a slice profile is selected (show alert if not).
2. Call `slicer_apply_slice_config` with the selected profile.
3. Call `slicer_apply_printer_config` with the selected printer profile.
4. Then call `slicer_slice_with_progress`.

Inject `SliceProfileStore` as a second `@EnvironmentObject` from `PalmSliceApp`.

---

## 7. File List

| File | New / Modified |
|------|---------------|
| `app/PalmSlice/InfillPattern.swift` | New |
| `app/PalmSlice/SupportStyle.swift` | New |
| `app/PalmSlice/SupportPlacement.swift` | New |
| `app/PalmSlice/BrimType.swift` | New |
| `app/PalmSlice/SliceProfile.swift` | New |
| `app/PalmSlice/SliceProfileStore.swift` | New |
| `app/PalmSlice/BuiltInSliceProfiles.swift` | New |
| `app/PalmSlice/SliceProfilePickerView.swift` | New |
| `app/PalmSlice/SliceProfileEditorView.swift` | New |
| `app/PalmSlice/slicer_bridge.h` | Modified — add `SlicerSliceConfig` + `slicer_apply_slice_config` |
| `app/PalmSlice/slicer_bridge.cpp` | Modified — implement `slicer_apply_slice_config`; refactor config accumulation |
| `app/PalmSlice/ContentView.swift` | Modified — slice profile row, call apply before slice |
| `app/PalmSlice/PalmSliceApp.swift` | Modified — create `SliceProfileStore`, inject as environment |

---

## 8. Implementation Order

1. **Enum files** — `InfillPattern`, `SupportStyle`, `SupportPlacement`, `BrimType`
2. **SliceProfile struct** — pure data, Codable
3. **SliceProfileStore + BuiltInSliceProfiles** — persistence layer
4. **C bridge** — `SlicerSliceConfig` struct + `slicer_apply_slice_config`; refactor bridge to accumulate configs
5. **SliceProfileEditorView** — full Form
6. **SliceProfilePickerView** — list with summary subtitle
7. **ContentView + PalmSliceApp** — wire up second environment object, row, bridge call
8. **End-to-end test** — confirm gyroid infill at 20%, 3 walls, supports, and brim all appear in exported gcode

---

## 9. Key libslic3r Config Keys Reference

| Profile field | PrusaSlicer key | Type |
|---|---|---|
| layerHeight | `layer_height` | `ConfigOptionFloat` |
| firstLayerHeight | `first_layer_height` | `ConfigOptionFloatOrPercent` |
| wallCount | `perimeters` | `ConfigOptionInt` |
| horizontalExpansion | `xy_size_compensation` | `ConfigOptionFloat` |
| topLayers | `top_solid_layers` | `ConfigOptionInt` |
| bottomLayers | `bottom_solid_layers` | `ConfigOptionInt` |
| topThickness | `top_solid_min_thickness` | `ConfigOptionFloat` |
| bottomThickness | `bottom_solid_min_thickness` | `ConfigOptionFloat` |
| infillDensity | `fill_density` | `ConfigOptionPercent` |
| infillPattern | `fill_pattern` | `ConfigOptionEnum<InfillPattern>` |
| printSpeed | `perimeter_speed` | `ConfigOptionFloatOrPercent` |
| infillSpeed | `infill_speed` | `ConfigOptionFloatOrPercent` |
| travelSpeed | `travel_speed` | `ConfigOptionFloat` |
| firstLayerSpeed | `first_layer_speed` | `ConfigOptionFloatOrPercent` |
| generateSupport | `support_material` | `ConfigOptionBool` |
| supportStyle | `support_material_style` | `ConfigOptionEnum<SupportMaterialStyle>` |
| supportPlacement | `support_material_buildplate_only` | `ConfigOptionBool` |
| supportOverhangAngle | `support_material_threshold` | `ConfigOptionInt` |
| supportHorizontalExpansion | `support_material_xy_spacing` | `ConfigOptionFloatOrPercent` (ratio) |
| supportUseTowers | `support_material_with_sheath` | `ConfigOptionBool` |
| brimType | `brim_type` | `ConfigOptionEnum<BrimType>` |
| brimWidth | `brim_width` | `ConfigOptionFloat` |
| skirtLoops | `skirts` | `ConfigOptionInt` |
| skirtDistance | `skirt_distance` | `ConfigOptionFloat` |
| raftLayers | `raft_layers` | `ConfigOptionInt` |

Verify all key names against `~/ios-sources/PrusaSlicer/src/libslic3r/PrintConfig.cpp` before implementing the bridge — names are stable but cross-check the enum ordinals especially for `fill_pattern` and `support_material_style`.

---

## 10. Open Questions / Decisions

- **`support_material_xy_spacing` units**: PrusaSlicer stores this as a ratio of extrusion width, not absolute mm. Plan: expose mm in the UI, convert to ratio in the bridge using `nozzle_diameter * 1.125` as the extrusion width estimate.
- **AdhesionType UI wrapper**: The SwiftUI editor needs a computed `AdhesionType` enum that maps to the three independent PrusaSlicer keys (skirts, brim_type, raft_layers). When switching adhesion type, zero out the other keys.
- **Raft + brim interaction**: PrusaSlicer disallows brim when raft is active. Enforce this in the editor by disabling brim controls when raft is selected.
- **Speed interdependencies**: PrusaSlicer has many more speed fields (outer perimeter, small perimeter, support, bridge, etc.). We expose only the four most impactful ones; the rest get PrusaSlicer's defaults. Add more later without a data model migration since `SliceProfile` is Codable with defaults.
- **Config merge order**: When merging printer + slice configs, apply printer config first, then slice config, so slice settings win on any overlap (e.g., nozzle-derived extrusion widths).
