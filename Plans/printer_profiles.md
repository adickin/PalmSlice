# Printer Profiles — Implementation Plan

## Goal

Add a complete printer profile system: data model, persistence, built-in profiles (starting with Ender 3 S1), and a SwiftUI editor UI. Profiles are selected before slicing and their settings are passed through the C bridge to libslic3r.

---

## 1. Data Model

### 1.1 GCodeFlavor

```swift
// GCodeFlavor.swift
enum GCodeFlavor: String, CaseIterable, Codable, Identifiable {
    case marlin           = "Marlin"
    case marlin2          = "Marlin 2"
    case klipper          = "Klipper"
    case repRap           = "RepRap (Sprinter)"
    case repRapFirmware   = "RepRap (Firmware)"
    case teacup           = "Teacup"
    case makerWare        = "MakerWare"
    case sailfish         = "Sailfish"
    case mach3            = "Mach3"
    case machineKit       = "MachineKit"
    case smoothie         = "Smoothie"
    case noGCode          = "No G-Code"
    var id: String { rawValue }
}
```

### 1.2 BuildPlateShape

```swift
enum BuildPlateShape: String, CaseIterable, Codable {
    case rectangular = "Rectangular"
    case circular    = "Circular"
}
```

### 1.3 ExtruderProfile

```swift
// ExtruderProfile.swift
struct ExtruderProfile: Codable, Identifiable {
    var id: UUID = UUID()
    var nozzleDiameter: Double = 0.4          // mm
    var compatibleMaterialDiameters: [Double] = [1.75]  // mm; usually [1.75] or [2.85]
    var offsetX: Double = 0.0                 // mm
    var offsetY: Double = 0.0                 // mm
    var coolingFanNumber: Int = 0             // fan index (0-based)
    var extruderChangeDuration: Double = 0.0  // seconds
    var startGCode: String = ""
    var endGCode: String = ""
}
```

### 1.4 PrinterProfile

```swift
// PrinterProfile.swift
struct PrinterProfile: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "My Printer"

    // --- Bed / Machine ---
    var bedX: Double = 220.0               // mm (width)
    var bedY: Double = 220.0               // mm (depth)
    var bedZ: Double = 250.0               // mm (height)
    var buildPlateShape: BuildPlateShape = .rectangular
    var originAtCenter: Bool = false
    var heatedBed: Bool = true
    var heatedBuildVolume: Bool = false

    // --- G-Code ---
    var gcodeFlavor: GCodeFlavor = .marlin
    var startGCode: String = ""
    var endGCode: String = ""

    // --- Printhead ---
    var printheadXMin: Double = -2.0       // mm (negative = toward left/front)
    var printheadYMin: Double = -2.0       // mm (negative = toward back)
    var printheadXMax: Double = 2.0        // mm
    var printheadYMax: Double = 2.0        // mm
    var gantryHeight: Double = 0.0         // mm (0 = not relevant)
    var numberOfExtruders: Int = 1
    var applyExtruderOffsetsToGCode: Bool = false
    var startGCodeMustBeFirst: Bool = false

    // --- Per-extruder ---
    var extruders: [ExtruderProfile] = [ExtruderProfile()]
}
```

**Invariant:** `extruders.count` must always equal `numberOfExtruders`. ProfileStore enforces this on save.

---

## 2. Persistence — ProfileStore

```swift
// ProfileStore.swift
@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [PrinterProfile] = []
    @Published var selectedProfileId: UUID?

    var selectedProfile: PrinterProfile? {
        profiles.first { $0.id == selectedProfileId }
    }

    // Call once at app startup
    func load() { ... }   // reads Documents/printer_profiles.json; seeds defaults if empty
    func save() { ... }   // encodes to JSON, writes atomically

    func add(_ profile: PrinterProfile) { ... }
    func update(_ profile: PrinterProfile) { ... }    // replace by id
    func delete(id: UUID) { ... }                      // guard against deleting last profile
    func select(id: UUID) { ... }
}
```

File location: `FileManager.default.urls(for: .documentDirectory)[0]/printer_profiles.json`

On first launch the store writes `BuiltInProfiles.all` to disk, so users can edit the defaults without losing them.

---

## 3. Built-in Profiles

```swift
// BuiltInProfiles.swift
enum BuiltInProfiles {
    static let ender3S1 = PrinterProfile(
        name: "Ender 3 S1",
        bedX: 220, bedY: 220, bedZ: 270,
        buildPlateShape: .rectangular,
        originAtCenter: false,
        heatedBed: true,
        heatedBuildVolume: false,
        gcodeFlavor: .marlin,
        startGCode: """
        ; Ender 3 S1 Start G-code
        ; M413 S0 ; Disable power loss recovery
        G92 E0 ; Reset Extruder

        ; Prep surfaces before auto home for better accuracy
        M140 S{material_bed_temperature_layer_0}
        M104 S{material_print_temperature_layer_0}

        G28 ; Home all axes
        G1 Z10.0 F3000 ; Move Z Axis up little to prevent scratching of Heat Bed
        G1 X0 Y0

        M190 S{material_bed_temperature_layer_0}
        M109 S{material_print_temperature_layer_0}

        G1 X0.1 Y20 Z0.3 F5000.0 ; Move to start position
        G1 X0.1 Y200.0 Z0.3 F1500.0 E15 ; Draw the first line
        G1 X0.4 Y200.0 Z0.3 F5000.0 ; Move to side a little
        G1 X0.4 Y20 Z0.3 F1500.0 E30 ; Draw the second line
        G92 E0 ; Reset Extruder
        G1 Z2.0 F3000 ; Move Z Axis up little to prevent scratching of Heat Bed
        G1 X5 Y20 Z0.3 F5000.0 ; Move over to prevent blob squish
        """,
        endGCode: """
        G91 ;Relative positioning
        G1 E-2 F2700 ;Retract a bit
        G1 E-2 Z0.2 F2400 ;Retract and raise Z
        G1 X5 Y5 F3000 ;Wipe out
        G1 Z10 ;Raise Z more
        G90 ;Absolute positioning

        G1 X0 Y{machine_depth} ;Present print
        M106 S0 ;Turn-off fan
        M104 S0 ;Turn-off hotend
        M140 S0 ;Turn-off bed

        M84 X Y E ;Disable all steppers but Z
        """,
        printheadXMin: -26, printheadYMin: -32, printheadXMax: 32, printheadYMax: 34,
        gantryHeight: 25,
        numberOfExtruders: 1,
        applyExtruderOffsetsToGCode: true,
        startGCodeMustBeFirst: false,
        extruders: [ExtruderProfile(
            nozzleDiameter: 0.4,
            compatibleMaterialDiameters: [1.75],
            offsetX: 0, offsetY: 0,
            coolingFanNumber: 0,
            extruderChangeDuration: 0,
            startGCode: "",
            endGCode: ""
        )]
    )

    static let all: [PrinterProfile] = [ender3S1]
}
```

Additional profiles to add later: Prusa MK4, Bambu X1C, Voron 2.4.

---

## 4. C Bridge Additions

Add a settings struct and a setter function so libslic3r gets the profile data:

```c
// In slicer_bridge.h

typedef struct {
    // Bed
    float bed_x;
    float bed_y;
    float bed_z;
    int   origin_at_center;      // bool
    int   heated_bed;            // bool
    int   gcode_flavor;          // maps to Slic3r::GCodeFlavor enum int values
    const char* start_gcode;
    const char* end_gcode;

    // Printhead
    float printhead_x_min;
    float printhead_y_min;
    float printhead_x_max;
    float printhead_y_max;
    float gantry_height;
    int   extruder_count;
    int   apply_extruder_offsets; // bool

    // Single-extruder shortcut (index 0):
    float nozzle_diameter;        // mm
    float filament_diameter;      // mm
} SlicerPrinterConfig;

// Apply a printer profile to the slicer context.
// Must be called before slicer_slice / slicer_slice_with_progress.
// Returns 0 on success, negative on error.
int slicer_apply_printer_config(SlicerHandle handle,
                                const SlicerPrinterConfig* cfg);
```

**Implementation sketch in slicer_bridge.cpp:**

```cpp
int slicer_apply_printer_config(SlicerHandle handle, const SlicerPrinterConfig* cfg) {
    // Store cfg fields on the context struct so slicer_slice picks them up
    // when it calls print.apply(model, config):
    //   config.set("bed_shape", ...)        — rectangular polygon from bed_x * bed_y
    //   config.set("gcode_flavor", ...)     — cast int to GCodeFlavor enum
    //   config.set("start_gcode", ...)
    //   config.set("end_gcode", ...)
    //   config.set("nozzle_diameter", ...)
    //   config.set("filament_diameter", ...)
    //   config.set("printhead_x_min" etc.)  — extruder clearance settings
}
```

The `GCodeFlavor` int values map to PrusaSlicer's `Slic3r::GCodeFlavor` enum. Store a mapping table as a static array in the .cpp file.

---

## 5. SwiftUI — Files to Create

### 5.1 ProfilePickerView
Sheet that lists all profiles. Tapping a profile selects it and dismisses. Includes Add and Edit/Delete swipe actions.

```
ProfilePickerView
├── List of profiles (name + bed size subtitle, checkmark on selected)
├── "Add New Profile" button at bottom
└── NavigationLink or sheet → PrinterProfileEditorView
```

### 5.2 PrinterProfileEditorView
Full settings editor. Uses a `Form` with sections. Binds to a local copy of `PrinterProfile`; on Save calls `ProfileStore.update()` or `.add()`.

**Sections:**

1. **Name** — `TextField`

2. **Machine** (bed)
   - Bed X (mm) — `TextField` with `.keyboardType(.decimalPad)`
   - Bed Y (mm)
   - Bed Z (mm)
   - Build Plate Shape — `Picker` (rectangular / circular)
   - Origin at center — `Toggle`
   - Heated bed — `Toggle`
   - Heated build volume — `Toggle`

3. **G-Code**
   - G-Code flavor — `Picker` (all `GCodeFlavor` cases)
   - Start G-Code — multi-line `TextEditor` (min height 120pt)
   - End G-Code — multi-line `TextEditor`

4. **Printhead**
   - X Min (mm)
   - Y Min (mm, negative = toward back)
   - X Max (mm)
   - Y Max (mm)
   - Gantry Height (mm)
   - Number of Extruders — `Stepper` (1–5)
   - Apply extruder offsets to G-Code — `Toggle`
   - Start G-Code must be first — `Toggle`

5. **Extruders** — `ForEach` over `profile.extruders` by index
   Each extruder gets a subsection headed "Extruder N":
   - Nozzle Diameter (mm) — `TextField`
   - Compatible Material Diameters — comma-separated `TextField` (parse on save)
   - Nozzle Offset X (mm)
   - Nozzle Offset Y (mm)
   - Cooling Fan Number — `Stepper`
   - Extruder Change Duration (s)
   - Start G-Code — `TextEditor`
   - End G-Code — `TextEditor`

### 5.3 GCodeEditorView (reusable sub-view)
A bordered `TextEditor` with a small label and copy button. Used in all start/end gcode fields.

---

## 6. ContentView Integration

- Add `@StateObject private var profileStore = ProfileStore()` to `PalmSliceApp` and inject via `.environmentObject(profileStore)`.
- In `ContentView`, add a "Printer: [Name]" tappable row in the model section that opens `ProfilePickerView` as a sheet.
- Before calling `slicer_slice_with_progress`, call `slicer_apply_printer_config` with the selected profile's settings.
- If no profile is selected, show an alert prompting the user to pick one.

---

## 7. File List

| File | New / Modified |
|------|---------------|
| `app/PalmSlice/GCodeFlavor.swift` | New |
| `app/PalmSlice/BuildPlateShape.swift` | New |
| `app/PalmSlice/ExtruderProfile.swift` | New |
| `app/PalmSlice/PrinterProfile.swift` | New |
| `app/PalmSlice/ProfileStore.swift` | New |
| `app/PalmSlice/BuiltInProfiles.swift` | New |
| `app/PalmSlice/ProfilePickerView.swift` | New |
| `app/PalmSlice/PrinterProfileEditorView.swift` | New |
| `app/PalmSlice/GCodeEditorView.swift` | New |
| `app/PalmSlice/slicer_bridge.h` | Modified — add `SlicerPrinterConfig` + `slicer_apply_printer_config` |
| `app/PalmSlice/slicer_bridge.cpp` | Modified — implement `slicer_apply_printer_config` |
| `app/PalmSlice/ContentView.swift` | Modified — profile picker button, call `slicer_apply_printer_config` |
| `app/PalmSlice/PalmSliceApp.swift` | Modified — create `ProfileStore`, inject as environment |
| `app/project.yml` | No change needed (files auto-included by xcodegen's glob) |

---

## 8. Implementation Order

1. **Data model** — `GCodeFlavor`, `BuildPlateShape`, `ExtruderProfile`, `PrinterProfile` (no UI, pure Swift structs)
2. **ProfileStore + BuiltInProfiles** — persistence layer; unit-testable
3. **C bridge** — `SlicerPrinterConfig` struct + `slicer_apply_printer_config` in .h/.cpp
4. **GCodeEditorView** — small reusable component
5. **PrinterProfileEditorView** — full form
6. **ProfilePickerView** — list + navigation to editor
7. **ContentView + PalmSliceApp integration** — wire up environment object, profile button, bridge call
8. **Test end-to-end** — slice with Ender 3 S1 profile, verify start/end gcode in output .gcode file

---

## 9. Key libslic3r Config Keys

These are the PrusaSlicer `DynamicPrintConfig` keys that map to profile fields:

| Profile field | Config key | Type |
|---|---|---|
| bedX × bedY | `bed_shape` | `Points` (polygon) |
| gcodeFlavor | `gcode_flavor` | `GCodeFlavor` enum |
| startGCode | `start_gcode` | `String` |
| endGCode | `end_gcode` | `String` |
| nozzleDiameter | `nozzle_diameter` | `Floats` (per extruder) |
| filamentDiameter | `filament_diameter` | `Floats` (per extruder) |
| printheadXMin/YMin/XMax/YMax | `extruder_clearance_radius` (approx) | varies |
| numberOfExtruders | `extruders_count` | `Int` |
| originAtCenter | `center_objects` | `Bool` |

Check `~/ios-sources/PrusaSlicer/src/libslic3r/PrintConfig.cpp` for the exact key names and value types before implementing the bridge.

---

## 10. Open Questions / Decisions

- **Multi-extruder bridge**: The current `SlicerPrinterConfig` only has shortcut fields for extruder 0. For >1 extruder, the bridge needs to accept arrays. Defer multi-extruder until single-extruder path is validated.
- **GCodeFlavor int mapping**: Verify that `Slic3r::GCodeFlavor` integer values match the order in our `GCodeFlavor` enum — PrusaSlicer's enum is defined in `PrintConfig.hpp`.
- **Profile templates vs. user profiles**: Built-in profiles are seeded once to Documents on first launch. Users can edit them freely. There is no "reset to default" in v1 — add later.
- **Bed shape for circular beds**: libslic3r expects `bed_shape` as a polygon. For circular beds, approximate with a polygon (e.g., 64-sided). Handle in `slicer_apply_printer_config`.
