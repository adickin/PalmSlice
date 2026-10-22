# PalmSlice — Feature Progress

## To Do

### App Store Release Checklist
- [x] **TestFlight build** — build 1.0 (1) archived, signed (Apple Distribution cert, auto-managed), and uploaded to App Store Connect via `xcodebuild -exportArchive` with `destination: upload` (2026-09-01); real team ID is `S2S63V4EZ9` (`project.local.yml` previously had a stale `5QZ67PK66C`, now fixed)
- [x] **App Store Connect app record** — created (bundle ID `com.adickin.PalmSlice`); screenshots/description/category/age rating/support URL still needed before public release, not required for TestFlight
- [x] **Privacy policy URL** — `PRIVACY.md` added (app collects no data at all); linked from App > About & Licenses and to be pasted into App Store Connect at submission time: `https://github.com/adickin/ISlicer/blob/main/PRIVACY.md`
- [x] **In-app About/Credits screen** — `AboutView.swift`; reachable via a floating (i) button in the bottom-right corner (visible when the slice panel is collapsed, covered by the panel when expanded); links to source repo, AGPL-3.0 license, privacy policy, and the full third-party license table from `LICENSE.md`
- [x] **First-launch safety notice** — `EULAView.swift`; full-screen, non-dismissible cover shown once (gated on `hasAcceptedEULA` in `UserDefaults`) after the splash screen; "Before You Print": sliced output can contain errors, use is at your own risk, supervise the printer (no "beta" wording — App Review guideline 2.2 rejects apps that call themselves beta); "I Understand & Accept" continues, "Decline" keeps the cover up with a must-accept note (no `exit(0)`)
- [x] **Fix `UIDeviceFamily` Info.plist warning** — removed from `project.yml` Info.plist properties; `TARGETED_DEVICE_FAMILY: "1,2"` build setting added instead
- [x] **`ITSAppUsesNonExemptEncryption`** — added to Info.plist via `project.yml` (`false`)
- [x] **Privacy manifest `UserDefaults` declaration** — `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1` added to `PrivacyInfo.xcprivacy` (2026-10-04)
- [x] **Build number bumped to 2** — `CFBundleVersion: "2"` in `project.yml` (1.0 (1) already uploaded)
- [x] **App Store listing copy drafted** — `APP_STORE_LISTING.md` (name, subtitle, description, keywords, category, age rating, review notes). Screenshots still need to be captured manually
- [ ] **App Store screenshots** — required size 6.9"; suggested shot list in `APP_STORE_LISTING.md`
- [x] **Upload build 1.0 (2)** — archived and uploaded via `xcodebuild -exportArchive` (`method: app-store-connect`, `destination: upload`) on 2026-10-14; includes the export sheet and OctoPrint upload. `CFBundleVersion` bumped to `"3"` for the next upload (iPad UI + Apple Pencil)
- [ ] **Broaden real-device test coverage** — currently validated on iPhone 14 Pro → Ender 3 S1 with real prints; try more STL geometries/sizes to rule out crashes/memory pressure on larger meshes
- [x] **basic automated tests** — new `PalmSliceTests` XCTest target (hosted by `PalmSlice`, auto-attached by xcodegen); 15 tests covering profile Codable round-trips, built-in profile sanity, bridge-int enum uniqueness, and `GCodeParser` layer/extrusion-type parsing — all passing on `iphonesimulator`

### High Priority (v1 polish)
_(none outstanding — device build confirmed working on both simulator and device SDKs, see Completed)_

### Viewer
_(all items complete — see Plans/viewer_features.md)_

### Printer Profiles
_(planned additions moved to `FUTURE_FEATURES.md`)_

### Slicing Profiles
_(planned additions moved to `FUTURE_FEATURES.md`)_

### Model Manipulation
Plan: `Plans/model_manipulation.md`
- [x] **Transform controls** — `ModelTransform` state (positionMM / rotationDeg / scale); `pivotNode` in `STLSceneView` applies transform live; `TransformPanelView` sheet with Move / Rotate / Scale sections (2026-04-17)
- [x] **Snap-to-face** — "Lay Flat" button in rotate section; picks largest downward-facing face via `STLMeshInfo` normals + area weighting; converts to SceneKit Euler angles via quaternion (2026-04-17)
- [x] **Fit to bed / Center / Drop to bed** — helper buttons in Move and Scale sections; "Fit to Bed" scales to 90% of bed footprint (2026-04-17)
- [x] **Interactive 3D translate gizmo** — world-aligned X/Y/Z arrows follow model; tap "Move" overlay button to enter transform mode (disables orbit); drag an arrow to translate along that axis; gizmo scales with model; "Orbit" button returns to camera control (2026-04-18)
- [x] **Multi-model** — `PlacedModel` list, per-model transforms/selection, `ModelListView`, multi-object slicing (2026-04-22); precise BVH mesh-collision (`TriangleBVH`, `PreciseIntersectionChecker`) with debounced red-highlight feedback and bed-footprint checks (2026-05-10)
- [x] **Type-in scale sizing + unit-mismatch detection** — mm-per-axis entry back-solves scale; sub-2 mm imports offered a one-tap ×1000 fix (2026-08-23)
- [ ] Remaining phases (Auto-orient, Cut tool) — see `FUTURE_FEATURES.md`

### Infrastructure
- [x] **Proper bundleId** — `com.adickin.PalmSlice` via `bundleIdPrefix` in `project.yml` + `project.local.yml` (team ID set)
- [x] **App icon + launch screen**
- [x] **iPad layout** — see Completed (2026-10-16)
- [ ] Remaining infrastructure items (haptics, iCloud sync, broader TestFlight distribution) — see `FUTURE_FEATURES.md`

## Far future

_(moved to `FUTURE_FEATURES.md`)_

## Completed

### Profiles on PrusaSlicer presets (2026-10-22)
- [x] **PrusaSlicer vendor presets as the base of every slice** — 32 vendor bundles shipped (`PrusaSlicerProfiles/vendor`, build step 21), loaded with libslic3r's `PresetBundle`; printer preset + print preset + filament preset, then PalmSlice profiles. `PresetDriftTests` fails if a setting PalmSlice doesn't control differs from the vendor preset
- [x] **Lossless profile ↔ PrusaSlicer settings conversion** (`ProfileSettings.swift`): typed fields + `extraSettings`; imported print / filament / printer presets slice to byte-identical G-code
- [x] **One settings path** (`SliceSetup` → `slicer_apply_settings`, validated by libslic3r)
- [x] **Built-in printers generated from vendor presets**; "From PrusaSlicer Library…" adds any of ~1,000 printers; new slice/material profiles seeded from the printer's presets or any compatible preset
- [x] **All Settings screen** (every PrusaSlicer setting, categories, help text, validated edits), base preset shown/changeable
- [x] **3MF per-part settings** (object overrides, height ranges, variable layer heights) with badge + Settings from File sheet; **Create Profiles from This File**. Parity with slicing the 3MF project directly verified on Piper J-3 Cub parts
- [x] **PrusaSlicer .ini import** (flat configs and config bundles with inheritance) **and export**

### 3MF / OBJ / AMF import (2026-10-17)
- [x] **3MF, OBJ and AMF import** via picker and drag-and-drop — `slicer_import_model_file` loads the file with libslic3r's format loaders and writes one STL per object instance (rotation/scale/mirroring baked in); each becomes its own model, named from the file, keeping the file's relative layout. (Embedded 3MF/AMF settings were ignored until 2026-10-22, see above.) STEP is not supported (needs OpenCASCADE)
- [x] **Import failures now alert** — unsupported extensions and unreadable meshes show an error instead of silently adding an empty model
- [x] **`ModelImporterTests`** — 3MF names/rotation/layout, AMF, OBJ, corrupt file, and converting + slicing two 3MFs

### iPad UI + Apple Pencil (2026-10-16)
- [x] **iPad layout** — regular width shows a Models sidebar (model list + inline transform form) and a Slice inspector (output name, profiles, status, Slice / Export) around the viewer; columns dock side by side at ≥ 1000 pt wide and float over the viewer one at a time when narrower (iPad portrait); compact width (Slide Over, narrow Split View) falls back to the phone layout. Same state and actions as the phone UI
- [x] **Drag-and-drop STL import** onto the iPad viewer; keyboard shortcuts ⌘O (add STL), ⌘R (slice), ⌘E (export)
- [x] **Apple Pencil** — Pencil drags models across the bed and drags gizmo handles while fingers orbit; double-tap / squeeze cycles Move → Rotate → Scale (respects the system "Ignore" preference); hover highlights the gizmo handle under the tip. Further Pencil ideas in `FUTURE_FEATURES.md`
- [x] **Transform action buttons** stay single-line (no wrapping in the narrow sidebar)

### Slice / Export, Icon, Profiles (2026-10-04)
- [x] **Split Slice and Export** — Slice writes G-code to the temp directory and opens the layer preview automatically; **Export G-code** (collapsed bar + expanded panel) copies it to Documents and presents the share sheet. Slice button becomes "Re-slice" once a slice exists
- [x] **New app icon** (pickup truck) — cut out of its white backing, corners filled, full-bleed 1024×1024, no alpha; also applied to `LaunchImage@1x/2x/3x` and `images/PalmSliceAppIcon.PNG`
- [x] **8 more built-in printer profiles** (all Untested) — Creality Ender-3, Ender-3 S1 (PrusaSlicer vendor), Ender-5, Prusa MK4, Elegoo Neptune-3 Pro, Sovol SV06, Voron 2.4 350; Prusa profiles hardcode their `M862.3` model name since the bridge doesn't set `printer_model`
- [x] **`PrinterProfileSliceTests`** — slices a sample STL with every built-in printer profile (skipped if the sample STL isn't on disk)
- [x] **Fix UUID in generated filenames** — output name now derives from the model's original name, not the temp-copy URL
- [x] **Layer slider text field** — type a layer number instead of dragging; slider restyled as a material card
- [x] **Thick-wall print-quality controls** (2026-08-05) — thickness-first top/bottom shells with pre-slice sanity check, solid/top-solid infill speeds, ironing, support interface controls, infill overlap; "Thick Walls (0.2 mm)" built-in slice profile

### Viewer (2026-04-15)
Plan: `Plans/viewer_features.md`
- [x] **Print time + filament estimate** — `parseGCodeStats()` in `ContentView` scans PrusaSlicer's `; estimated printing time (normal mode) =` and `; filament used [g] =` comments from the exported gcode; displayed in status row + collapsed panel subtitle
- [x] **Wireframe toggle** — `STLParser.buildGeometry` always emits a second `SCNGeometryElement` of type `.line` (3 edges per triangle); `STLSceneView.showWireframe` toggles visibility via `materials[1].transparency`; floating button in viewer overlay
- [x] **Overhang highlight** — `ViewerColorMode.overhang` mode in `STLParser`; per-vertex `SCNGeometrySource` with `.color` semantic; faces with `n.z < -0.5` (STL space) = red-orange, `n.z < 0` = yellow, upward = grey; `.constant` lighting
- [x] **Face normal colour mode** — `ViewerColorMode.faceNormal`; normal XYZ mapped to RGB via `(n+1)/2`; same per-vertex colour source path as overhang; cycled via same overlay button
- [x] **Layer preview** — `GCodeParser.swift`: full PrusaSlicer gcode parser (`parseGCode`) emitting `[GCodeLayer]` with typed `GCodeMove` (`ExtrusionType`); `GCodeSceneView.swift`: async geometry build (Task.detached), per-type line colours, bed grid + axes; `ContentView`: layer slider overlay, toggle button, parses layers immediately after export

### Material Profiles (2026-04-15)
Plan: `Plans/material_profiles.md`
- [x] `MaterialProfile` struct — Codable; filament diameter, temperatures (first layer + other, hotend + bed), extrusion multiplier, retraction (length/speed/restart extra/Z-hop/min travel), cooling/fan (min/max/bridge speed, disable-first-N-layers, fan-below-layer-time, slowdown-below-layer-time, min-print-speed)
- [x] `MaterialProfileStore` — same `@MainActor ObservableObject` pattern as `ProfileStore` / `SliceProfileStore`; JSON to `material_profiles.json`; seed version bump
- [x] `BuiltInMaterialProfiles` — PLA, PETG, ABS, TPU with sensible defaults including cooling/retraction differences per material
- [x] `SlicerMaterialConfig` C struct + `slicer_apply_material_config()` in `slicer_bridge.h/.cpp`; all per-extruder keys wrapped in single-element vectors; `retract_length=0` disables retraction natively
- [x] `MaterialProfileEditorView` — Form with Name / Filament & Temperature / Retraction / Cooling sections; sub-fields hidden behind toggles
- [x] `MaterialProfilePickerView` — circle-checkmark select, row-tap to edit, swipe-to-delete, + button
- [x] `ContentView` — "Material" row (drop icon) below slice profile row; `applyMaterialProfile()` called before slicing (optional — slicing proceeds with bridge defaults if no profile selected); call order: printer → material → slice
- [x] `PalmSliceApp` — `materialProfileStore` as third `@StateObject`, injected as `.environmentObject`, loaded in `.task`

### Slicing Profiles (2026-04-13)
Plan: `Plans/slicing_profiles.md`
- [x] `InfillPattern` enum — gyroid, grid, honeycomb, lines, triangles, cubic, adaptive cubic, lightning; `bridgeInt` ordinals verified against `PrintConfig.hpp` (gyroid=12, grid=4, etc.)
- [x] `SupportStyle` enum — Normal (Snug) / Tree (Organic); `bridgeInt` → smsSnug(1) / smsOrganic(3)
- [x] `SupportPlacement` enum — Everywhere / Touching Build Plate Only
- [x] `BrimType` enum — Outer Only / Inner Only / Outer and Inner; `bridgeInt` → btOuterOnly(1) / btInnerOnly(2) / btOuterAndInner(3)
- [x] `AdhesionType` enum — None / Skirt / Brim / Raft (top-level wrapper; maps to PrusaSlicer's separate `brim_type` / `skirts` / `raft_layers` keys)
- [x] `SliceProfile` struct — all settings Codable; `pickerSubtitle` computed property (layer height · infill % · speed · supports on/off)
- [x] `SliceProfileStore` — `@MainActor ObservableObject`; JSON load/save to `slice_profiles.json`; seed version bump
- [x] `BuiltInSliceProfiles` — Draft (0.3 mm / 15% grid / 80 mm/s), Standard (0.2 mm / 20% gyroid / 60 mm/s), Fine (0.1 mm / 20% gyroid / 40 mm/s)
- [x] `SlicerSliceConfig` C struct + `slicer_apply_slice_config()` — sets all 26 slice settings on `DynamicPrintConfig`; adhesion type fan-out to correct PrusaSlicer keys; speed type bug fixed (`perimeter_speed` / `infill_speed` are `ConfigOptionFloat`, not `ConfigOptionFloatOrPercent`)
- [x] `slice_config_applied` flag on `SlicerContext` — prevents `slicer_slice_with_progress` legacy params from overwriting the slice config
- [x] `SliceProfileEditorView` — Form with Name / Layers / Walls / Top-Bottom / Infill / Speed / Support / Adhesion sections; support sub-options revealed when generate support is on; adhesion sub-options switch by type; help button at bottom
- [x] `SliceProfilePickerView` — circle-checkmark select, row-tap to edit, swipe-to-delete, + button; subtitle shows live profile summary
- [x] `SliceProfileHelpView` — full plain-English descriptions for every setting, organized by section, presented as a sheet from the editor
- [x] `ContentView` — "Slice Profile" row (slider icon) alongside printer row; guards slice if no profile selected; calls `slicer_apply_slice_config` before every slice; status subtitle and gcode filename reflect the active profile
- [x] `PalmSliceApp` — `SliceProfileStore` as second `@StateObject`, injected as `.environmentObject`, loaded in `.task`

### Printer Profiles (2026-04-13)
- [x] `GCodeFlavor` enum — 12 flavors with `bridgeInt` mapping to PrusaSlicer's `GCodeFlavor` enum order
- [x] `BuildPlateShape` — rectangular / circular
- [x] `ExtruderProfile` — nozzle diameter, material diameters, X/Y offset, fan number, change duration, per-extruder start/end gcode
- [x] `PrinterProfile` — full machine + printhead + extruder settings, Codable
- [x] `BuiltInProfiles` — Ender 3 S1 seeded with correct PrusaSlicer placeholder syntax (`{first_layer_temperature[0]}` etc.; `{machine_depth}` hardcoded to 220 — no PrusaSlicer equivalent)
- [x] `ProfileStore` — `@MainActor ObservableObject`; JSON load/save; seed version bump forces re-seed when built-in profiles change
- [x] `GCodeEditorView` — reusable bordered monospaced TextEditor with copy button
- [x] `PrinterProfileEditorView` — Form with Name / Machine / G-Code / Printhead / per-Extruder sections
- [x] `ProfilePickerView` — list with circle-checkmark select, row-tap to edit, swipe-to-delete, + button
- [x] `slicer_bridge` — `SlicerPrinterConfig` C struct + `slicer_apply_printer_config()`; `kFlavorMap[]` keeps Swift `bridgeInt` and C++ enum in sync
- [x] `ContentView` — profile row shows active printer name; "No Printer Selected" alert guards slice; `applyPrinterProfile()` called before every slice
- [x] `PalmSliceApp` — `ProfileStore` created as `@StateObject`, injected as `.environmentObject`, loaded via `.task`

### Build Chain
- [x] iOS CMake toolchain (leetal/ios-cmake, SIMULATORARM64)
- [x] Device build (leetal/ios-cmake, OS64/arm64) — `build_device.sh` → `~/ios-sysroot-dev` fully populated; `libslic3r.xcframework` has both `ios-arm64` and `ios-arm64-simulator` slices; Debug + Release both build clean for `iphoneos` SDK
- [x] Clipper2 — polygon clipping
- [x] Eigen3 — linear algebra headers
- [x] zlib
- [x] libpng
- [x] Boost (b2 cross-compile, static runtime, ~20 libs)
- [x] boost::nowide — UTF-8 file I/O on all platforms
- [x] boost::locale stub — safe no-op (only used in preset loading, not slicing)
- [x] oneTBB — task-based parallelism
- [x] libexpat — XML parsing
- [x] GMP 6.3.0 — exact arithmetic (pure-C, no assembly, C++ bindings enabled)
- [x] MPFR 4.2.2 — multi-precision float (depends on GMP)
- [x] CGAL 5.6.2 — computational geometry (headers + cmake config pointing to our GMP/MPFR)
- [x] cereal — serialization headers
- [x] Qhull — convex hull (custom iOS CMakeLists, no shared lib export issues)
- [x] heatshrink — data compression (custom wrapper, no executable target)
- [x] LibBGCode — Prusa binary gcode format
- [x] nlohmann/json — header-only JSON
- [x] NanoSVG — header-only SVG (fltk fork)
- [x] NLopt 2.5.0 — header-only for compilation (SLA only, not called in FDM path)
- [x] libslic3r — PrusaSlicer core, cross-compiled for arm64-apple-ios-simulator
- [x] XCFramework packaging of libslic3r.a

### PrusaSlicer Patches
- [x] `SLIC3R_IOS` cmake option added to root CMakeLists
- [x] CURL, OpenGL, GLEW, NLopt, OpenVDB gated behind `SLIC3R_IOS`
- [x] Z3 / libseqarrange excluded from build (sequential arrange is GUI-only)
- [x] JPEG excluded (thumbnails are optional in gcode)
- [x] `ArrangeHelper_ios_stub.cpp` — satisfies linker without Z3
- [x] `Thumbnails_ios_stub.cpp` — satisfies linker without JPEG
- [x] Stub `seq_interface.hpp` header in sysroot (Sequential types, no Z3)

### App (2026-09-12)
- [x] **First-launch EULA** — `EULAView.swift`; beta-software / no-liability disclaimer, shown once via `hasAcceptedEULA` UserDefaults flag; Accept continues, Decline exits the app
- [x] **About & Licenses moved to floating (i) button** — bottom-right corner, above the collapsed slice panel; expanded panel overlaps it naturally (same z-order as the rest of the bottom panel)
- [x] **README "Tested Printers" section** — lists real-world print validation; Ender 3 S1 so far
- [x] **Live output filename preview** — output filename field's placeholder shows the exact `.gcode` name that will be saved (model name + layer height + infill %) instead of a generic "(auto)" label; stem-naming logic shared between the preview and the actual save path via `autoOutputStem()` so they can't drift

### App
- [x] SwiftUI single-screen UI
- [x] C bridge (`slicer_bridge.h` / `.cpp`) — Swift ↔ libslic3r
- [x] STL load from app bundle (`cube.stl`)
- [x] FDM slicing with hardcoded settings (0.2 mm / 20% gyroid / Ender-class printer)
- [x] G-code export to app Documents directory
- [x] Share Sheet for AirDrop / Files / send anywhere
- [x] Files app integration (`UIFileSharingEnabled`)
- [x] Xcode project via xcodegen (`app/project.yml`)
- [x] Confirmed: valid G-code produced on-device in iOS Simulator
- [x] Real STL file picker — `UIDocumentPickerViewController`; file copied to temp dir before slicing
- [x] Slicing progress indicator — `Print::set_status_callback` → `ProgressView(value:)`
- [x] Slicing cancellation — `slicer_cancel()` calls `Print::cancel()`; returns to idle cleanly
- [x] Error UI — all failures shown via SwiftUI `.alert` modal
- [x] **SceneKit 3D viewer** — `STLParser.swift` (binary + ASCII STL → `SCNGeometry`, flat normals, unit-box normalisation); `STLSceneView.swift` (`SCNView` with orbit-turntable camera control, print-bed grid, XYZ axis gizmo); mesh rotated −90° around X to convert STL Z-up to SceneKit Y-up (Cura convention: X=right/red, Y=forward/green, Z=up/blue); sample STLs copied to app Documents on first launch
