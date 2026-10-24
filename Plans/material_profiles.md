# Material Profiles — Implementation Plan

## Goal

Add a complete material (filament) profile system to PalmSlice. Material profiles own retraction, Z-hop, temperature, cooling, and fan settings — the settings that are material-dependent rather than print-quality-dependent (following PrusaSlicer's filament profile architecture). Built-in profiles ship for PLA, PETG, ABS, and TPU. Users can create, edit, and delete custom profiles. The active profile is applied to the slicer context before every slice.

---

## 1. Data Model (`MaterialProfile.swift`)

```swift
struct MaterialProfile: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "My Material"

    // MARK: - Filament
    var filamentDiameter: Double = 1.75     // mm  — filament_diameter (per-extruder array)

    // MARK: - Temperatures
    var firstLayerTemp: Int = 215           // °C  — first_layer_temperature (per-extruder)
    var otherLayersTemp: Int = 210          // °C  — temperature (per-extruder)
    var firstLayerBedTemp: Int = 60         // °C  — first_layer_bed_temperature (per-extruder)
    var otherLayersBedTemp: Int = 55        // °C  — bed_temperature (per-extruder)

    // MARK: - Flow
    var extrusionMultiplier: Double = 1.0   // 0.5–2.0 — extrusion_multiplier (per-extruder)

    // MARK: - Retraction
    var retractionEnabled: Bool = true
    var retractionLength: Double = 5.0      // mm  — retract_length (per-extruder; 0 = no retract)
    var retractionSpeed: Double = 45.0      // mm/s — retract_speed (per-extruder)
    var zHop: Double = 0.0                  // mm  — retract_lift (per-extruder)
    var minTravelForRetraction: Double = 1.0 // mm — retract_before_travel (per-extruder)
    var retractionRestartExtra: Double = 0.0 // mm — retract_restart_extra (per-extruder): extra pushed after deretraction to compensate ooze

    // MARK: - Cooling / Fan
    var coolingEnabled: Bool = true         // bool — cooling (per-extruder)
    var minFanSpeed: Int = 35               // %   — min_fan_speed (per-extruder)
    var maxFanSpeed: Int = 100              // %   — max_fan_speed (per-extruder)
    var bridgeFanSpeed: Int = 100           // %   — bridge_fan_speed (per-extruder)
    var disableFanFirstLayers: Int = 3      // N   — disable_fan_first_layers (per-extruder)
    var fanBelowLayerTime: Int = 60         // sec — fan_below_layer_time: enable fan if layer prints in under N sec
    var slowdownBelowLayerTime: Int = 5     // sec — slowdown_below_layer_time: slow down if layer prints in under N sec
    var minPrintSpeed: Double = 10.0        // mm/s — min_print_speed: floor when slowing down for cooling

    // MARK: - Summary (shown in picker row subtitle)
    var pickerSubtitle: String {
        let temp = "\(firstLayerTemp)/\(otherLayersTemp)°C"
        let retract = retractionEnabled ? "\(retractionLength) mm retract" : "No retract"
        let fan = coolingEnabled ? "Fan \(minFanSpeed)–\(maxFanSpeed)%" : "Fan off"
        return "\(temp) · \(retract) · \(fan)"
    }
}
```

**PrusaSlicer note:** Temperature, retraction, fan, and filament keys are all **per-extruder arrays** in `DynamicPrintConfig`. The C bridge must wrap each scalar in a single-element vector when setting them (e.g., `ConfigOptionFloats({value})`).

---

## 2. Built-In Profiles (`BuiltInMaterialProfiles.swift`)

| Profile | First/Other Temp | Bed Temp | Retract | Z-hop | restart extra | Fan | fanBelowLayerTime | slowdownBelowLayerTime | minPrintSpeed |
|---------|-----------------|----------|---------|-------|---------------|-----|-------------------|------------------------|---------------|
| PLA     | 215 / 210 °C    | 60 / 55 °C | 5 mm @ 45 mm/s | 0 mm | 0 mm | 35–100%, disable first 3 | 60 s | 5 s | 10 mm/s |
| PETG    | 235 / 230 °C    | 80 / 75 °C | 6 mm @ 25 mm/s | 0.2 mm | 0.2 mm | 30–50%, disable first 3 | 60 s | 10 s | 10 mm/s |
| ABS     | 250 / 245 °C    | 105 / 100 °C | 4 mm @ 45 mm/s | 0.5 mm | 0 mm | off (`coolingEnabled: false`) | 15 s | 15 s | 10 mm/s |
| TPU     | 230 / 225 °C    | 30 / 25 °C | 0 mm (disabled) | 0 mm | 0 mm | 50–100%, disable first 2 | 60 s | 5 s | 5 mm/s |

```swift
enum BuiltInMaterialProfiles {
    static let pla = MaterialProfile(name: "PLA", ...)
    static let petg = MaterialProfile(name: "PETG", ...)
    static let abs = MaterialProfile(name: "ABS", ...)
    static let tpu = MaterialProfile(name: "TPU", retractionEnabled: false, ...)
    static let all: [MaterialProfile] = [pla, petg, abs, tpu]
}
```

---

## 3. Store (`MaterialProfileStore.swift`)

Follows the same pattern as `ProfileStore` / `SliceProfileStore`.

```swift
@MainActor
final class MaterialProfileStore: ObservableObject {
    @Published var profiles: [MaterialProfile] = []
    @Published var selectedProfileId: UUID?

    var selectedProfile: MaterialProfile? { ... }

    private var storeURL: URL { /* material_profiles.json */ }
    private static let seedVersion = 1
    private static let seedVersionKey = "materialProfileSeedVersion"

    func load()               // decode from disk; seed if missing or stale
    func save()               // encode to disk atomically
    func add(_ profile: MaterialProfile)
    func update(_ profile: MaterialProfile)
    func delete(id: UUID)     // guards: profiles.count > 1
    func select(id: UUID)
}
```

---

## 4. C Bridge

### 4.1 Header addition (`slicer_bridge.h`)

```c
// ── Material profile ──────────────────────────────────────────────────────────

typedef struct {
    // Filament
    float filament_diameter;        // mm — filament_diameter[0]

    // Temperatures (°C)
    int   first_layer_temperature;  // first_layer_temperature[0]
    int   temperature;              // temperature[0]
    int   first_layer_bed_temperature; // first_layer_bed_temperature[0]
    int   bed_temperature;          // bed_temperature[0]

    // Flow
    float extrusion_multiplier;     // extrusion_multiplier[0]

    // Retraction (set retract_length=0 to disable without bool flag)
    float retract_length;           // mm — retract_length[0]   (0 = no retraction)
    float retract_speed;            // mm/s — retract_speed[0]
    float retract_lift;             // mm — retract_lift[0]      (Z-hop)
    float retract_before_travel;    // mm — retract_before_travel[0]

    // Retraction restart extra
    float retract_restart_extra;    // mm — retract_restart_extra[0]

    // Cooling / fan
    int   cooling;                  // bool — cooling[0]
    int   min_fan_speed;            // %  — min_fan_speed[0]
    int   max_fan_speed;            // %  — max_fan_speed[0]
    int   bridge_fan_speed;         // %  — bridge_fan_speed[0]
    int   disable_fan_first_layers; // N layers — disable_fan_first_layers[0]
    int   fan_below_layer_time;     // sec — fan_below_layer_time[0]: enable fan if layer finishes in under N sec
    int   slowdown_below_layer_time; // sec — slowdown_below_layer_time[0]: slow down if layer finishes in under N sec
    float min_print_speed;          // mm/s — min_print_speed[0]: floor speed when cooling slowdown is active
} SlicerMaterialConfig;

int slicer_apply_material_config(SlicerHandle handle,
                                  const SlicerMaterialConfig* cfg);
```

### 4.2 Implementation (`slicer_bridge.cpp`)

```cpp
int slicer_apply_material_config(SlicerHandle handle,
                                  const SlicerMaterialConfig* cfg) {
    auto ctx = CTX(handle);
    if (!cfg) return set_err(ctx, "null material config");
    try {
        // Filament diameter (array key — slicer_apply_printer_config may have
        // already set this; material profile takes precedence)
        ctx->config.set_key_value("filament_diameter",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->filament_diameter)}));

        // Temperatures
        ctx->config.set_key_value("first_layer_temperature",
            new Slic3r::ConfigOptionInts({cfg->first_layer_temperature}));
        ctx->config.set_key_value("temperature",
            new Slic3r::ConfigOptionInts({cfg->temperature}));
        ctx->config.set_key_value("first_layer_bed_temperature",
            new Slic3r::ConfigOptionInts({cfg->first_layer_bed_temperature}));
        ctx->config.set_key_value("bed_temperature",
            new Slic3r::ConfigOptionInts({cfg->bed_temperature}));

        // Flow
        ctx->config.set_key_value("extrusion_multiplier",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->extrusion_multiplier)}));

        // Retraction (retract_length == 0 disables retraction natively)
        ctx->config.set_key_value("retract_length",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->retract_length)}));
        ctx->config.set_key_value("retract_speed",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->retract_speed)}));
        ctx->config.set_key_value("retract_lift",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->retract_lift)}));
        ctx->config.set_key_value("retract_before_travel",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->retract_before_travel)}));

        // Fan / cooling
        ctx->config.set_key_value("cooling",
            new Slic3r::ConfigOptionBools({cfg->cooling != 0}));
        ctx->config.set_key_value("min_fan_speed",
            new Slic3r::ConfigOptionInts({cfg->min_fan_speed}));
        ctx->config.set_key_value("max_fan_speed",
            new Slic3r::ConfigOptionInts({cfg->max_fan_speed}));
        ctx->config.set_key_value("bridge_fan_speed",
            new Slic3r::ConfigOptionInts({cfg->bridge_fan_speed}));
        ctx->config.set_key_value("disable_fan_first_layers",
            new Slic3r::ConfigOptionInts({cfg->disable_fan_first_layers}));
        ctx->config.set_key_value("fan_below_layer_time",
            new Slic3r::ConfigOptionInts({cfg->fan_below_layer_time}));
        ctx->config.set_key_value("slowdown_below_layer_time",
            new Slic3r::ConfigOptionInts({cfg->slowdown_below_layer_time}));
        ctx->config.set_key_value("min_print_speed",
            new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->min_print_speed)));

        // Retraction restart extra
        ctx->config.set_key_value("retract_restart_extra",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->retract_restart_extra)}));

        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}
```

**Call order in `runSlice()`:** printer config → material config → slice config → load STL → slice.  Material config after printer config so that the material's `filament_diameter` overrides the printer's default if they differ.

---

## 5. UI

### 5.1 `MaterialProfileEditorView.swift`

A `NavigationStack`-wrapped `Form` with three sections:

**Filament & Flow**
- Filament diameter: `Stepper` 1.25–3.00 mm, step 0.25
- First layer / other layers temperature: `Stepper` 150–320°C, step 1
- First layer / other layers bed temperature: `Stepper` 0–130°C, step 1
- Extrusion multiplier: `Slider` 0.5–1.5 (displayed as %, e.g. "100%")

**Retraction**
- Toggle "Enable Retraction" — hides sub-fields when off
- Retraction length: `Stepper` 0.0–10.0 mm, step 0.5
- Retraction speed: `Stepper` 10–80 mm/s, step 5
- Restart extra: `Stepper` 0.0–2.0 mm, step 0.05 (label: "Extra deretraction length")
- Z-hop: `Stepper` 0.0–2.0 mm, step 0.1
- Min travel before retract: `Stepper` 0.0–5.0 mm, step 0.5

**Cooling & Fan**
- Toggle "Enable Cooling" — hides sub-fields when off
- Min fan speed: `Slider` 0–100%
- Max fan speed: `Slider` 0–100%
- Bridge fan speed: `Slider` 0–100%
- Disable fan for first N layers: `Stepper` 0–10
- Enable fan if layer time below: `Stepper` 1–120 sec, step 1 (label: "Fan on below layer time")
- Slow down if layer time below: `Stepper` 1–60 sec, step 1 (label: "Slow down below layer time")
- Min print speed: `Stepper` 1–30 mm/s, step 1

Toolbar: **Save** button calls `store.update()` / `store.add()`, dismisses the sheet.

### 5.2 `MaterialProfilePickerView.swift`

Mirrors `SliceProfilePickerView`:
- `List` with circle-checkmark selection
- Row: name (bold) + `pickerSubtitle` (secondary caption)
- Swipe-to-delete (guarded: `profiles.count > 1`)
- `+` toolbar button creates a new blank `MaterialProfile` and opens the editor
- Row tap opens the editor for that profile

### 5.3 `ContentView.swift` changes

1. Add `@EnvironmentObject var materialProfileStore: MaterialProfileStore`
2. Add `@State private var showMaterialProfilePicker = false`
3. In `expandedPanelContent`, add a **Material** row between the Slice Profile row and the Divider:

```swift
// Material profile row
Button { showMaterialProfilePicker = true } label: {
    HStack {
        Label(
            materialProfileStore.selectedProfile?.name ?? "No Material Selected",
            systemImage: "drop"
        )
        .font(.subheadline)
        .foregroundStyle(materialProfileStore.selectedProfile == nil ? .red : .primary)
        Spacer()
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
.disabled(isBusy)
```

4. Add `.sheet(isPresented: $showMaterialProfilePicker) { MaterialProfilePickerView() }`
5. In `runSlice()`, after step 4 (apply printer profile) and before step 5 (apply slice profile), add step 4b:

```swift
// 4b. Apply material profile
if let materialProfile = await MainActor.run(body: { materialProfileStore.selectedProfile }) {
    await setPhase("Applying material profile…")
    if !applyMaterialProfile(materialProfile, to: handle) {
        let msg = String(cString: slicer_last_error(handle))
        await MainActor.run { state = .failed(message: msg); showErrorAlert = true }
        return
    }
}
```

6. Add `applyMaterialProfile(_:to:)` helper:

```swift
private func applyMaterialProfile(_ profile: MaterialProfile, to handle: SlicerHandle) -> Bool {
    var cfg = SlicerMaterialConfig()
    cfg.filament_diameter           = Float(profile.filamentDiameter)
    cfg.first_layer_temperature     = Int32(profile.firstLayerTemp)
    cfg.temperature                 = Int32(profile.otherLayersTemp)
    cfg.first_layer_bed_temperature = Int32(profile.firstLayerBedTemp)
    cfg.bed_temperature             = Int32(profile.otherLayersBedTemp)
    cfg.extrusion_multiplier        = Float(profile.extrusionMultiplier)
    cfg.retract_length              = profile.retractionEnabled ? Float(profile.retractionLength) : 0
    cfg.retract_speed               = Float(profile.retractionSpeed)
    cfg.retract_lift                = Float(profile.zHop)
    cfg.retract_before_travel       = Float(profile.minTravelForRetraction)
    cfg.retract_restart_extra       = Float(profile.retractionRestartExtra)
    cfg.cooling                     = profile.coolingEnabled ? 1 : 0
    cfg.min_fan_speed               = Int32(profile.minFanSpeed)
    cfg.max_fan_speed               = Int32(profile.maxFanSpeed)
    cfg.bridge_fan_speed            = Int32(profile.bridgeFanSpeed)
    cfg.disable_fan_first_layers    = Int32(profile.disableFanFirstLayers)
    cfg.fan_below_layer_time        = Int32(profile.fanBelowLayerTime)
    cfg.slowdown_below_layer_time   = Int32(profile.slowdownBelowLayerTime)
    cfg.min_print_speed             = Float(profile.minPrintSpeed)
    return slicer_apply_material_config(handle, &cfg) == 0
}
```

### 5.4 `PalmSliceApp.swift` changes

```swift
@StateObject private var materialProfileStore = MaterialProfileStore()

// In WindowGroup body:
.environmentObject(materialProfileStore)
.task {
    profileStore.load()
    sliceProfileStore.load()
    materialProfileStore.load()
}
```

---

## 6. File Summary

| File | Action |
|------|--------|
| `app/PalmSlice/MaterialProfile.swift` | **New** — `MaterialProfile` struct |
| `app/PalmSlice/BuiltInMaterialProfiles.swift` | **New** — PLA / PETG / ABS / TPU defaults |
| `app/PalmSlice/MaterialProfileStore.swift` | **New** — `@MainActor ObservableObject` |
| `app/PalmSlice/MaterialProfileEditorView.swift` | **New** — Form editor |
| `app/PalmSlice/MaterialProfilePickerView.swift` | **New** — List picker |
| `app/PalmSlice/slicer_bridge.h` | **Edit** — add `SlicerMaterialConfig` + `slicer_apply_material_config` |
| `app/PalmSlice/slicer_bridge.cpp` | **Edit** — implement `slicer_apply_material_config` |
| `app/PalmSlice/ContentView.swift` | **Edit** — material row, sheet, applyMaterialProfile, runSlice step |
| `app/PalmSlice/PalmSliceApp.swift` | **Edit** — add `materialProfileStore` StateObject + env injection |

---

## 7. Implementation Order

1. `MaterialProfile.swift` + `BuiltInMaterialProfiles.swift` — pure Swift data, no dependencies
2. `MaterialProfileStore.swift` — depends on data model
3. `slicer_bridge.h` + `slicer_bridge.cpp` — C bridge extension
4. `MaterialProfileEditorView.swift` + `MaterialProfilePickerView.swift` — UI
5. `PalmSliceApp.swift` — wire up store
6. `ContentView.swift` — add row + sheet + apply call

After step 3, rebuild the XCFramework (`scripts/11_xcframework.sh`) is **not** needed — `slicer_bridge.cpp` is compiled directly by Xcode, not packaged into the framework.

After step 6, run `xcodegen` in `app/` only if `project.yml` is modified (adding new `.swift` files that are not auto-picked up by glob pattern). Check `project.yml` sources glob before adding them manually.

---

## 8. Optional Settings (not in v1)

These settings exist in PrusaSlicer's filament profile and are worth adding later, but are lower-priority for v1.

| Setting | PrusaSlicer key | Notes |
|---------|----------------|-------|
| Fan always on | `fan_always_on` | Keep fan at min speed even on layers cooling logic would skip; useful for bridging |
| Full fan speed layer | `full_fan_speed_layer` | Layer at which fan ramps to `max_fan_speed`; fan linearly ramps between `disable_fan_first_layers` and this layer |
| Wipe on retract | `wipe` (bool) + `retract_before_wipe` (%) | Nozzle wipes while retracting; reduces stringing on PETG/TPU |
| Retract on layer change | `retract_layer_change` | Separate retraction trigger for layer transitions (vs. travel moves) |
| Max volumetric speed | `filament_max_volumetric_speed` | mm³/s cap; important for high-flow filaments and fast printers (0 = uncapped) |
| Filament density | `filament_density` | g/cm³; used to compute weight estimate in gcode comments |
| Shrinkage compensation | `filament_shrink` | XY scale factor (%) to account for material contraction |

---

## 9. PROGRESS.md Updates

When complete, move the entire **Material Profiles** todo block to the **Completed** section and add a date stamp.
