# Changelog

All notable changes to PalmSlice, harvested from [PROGRESS.md](PROGRESS.md) and commit history. Dates reflect when a feature was completed, not necessarily committed. Entries are grouped by date, most recent first.

## 2026-10-22

- **PrusaSlicer .ini import and export.** "+" in the printer, material and slice profile lists has **Import PrusaSlicer .ini…**: a flat exported config (File > Export > Export Config) becomes one profile, named after its preset; a config bundle imports every preset of that type, resolving `inherits` (another preset in the bundle, or a PrusaSlicer system preset, which becomes the profile's base). Each editor's PrusaSlicer section has **Export PrusaSlicer .ini**: the profile's complete settings, preset values included, for desktop PrusaSlicer's Import Config

- **3MF files keep their per-part PrusaSlicer settings.** Overrides for the whole part, overrides for height ranges (e.g. a 3DLabPrint aileron's solid end caps, or a two-wall first layer) and variable layer heights are imported with each part and applied on top of the profiles when slicing. Parts carrying them get a badge (model strip on iPhone, sidebar on iPad; also in the touch-and-hold menu) that opens **Settings from File**: what the file sets, in plain language, a switch to turn them off, and a warning when a tilted part makes the height-based ones not line up (they're skipped then; a Z scale stretches them)
- **Create Profiles from This File**: adds the slice profile and material a 3MF was set up with (e.g. "0.3 mm 3DLabPrint" / "3DLabPrint PolyLight 1.0 LW-PLA"), with every one of its settings, and selects them; selects the existing ones if already added
- Verified against the 3MF projects themselves: four Piper J-3 Cub parts imported the PalmSlice way produce the same layer heights and filament use (to 0.001%) as slicing the project directly
- Fix: a single-object 3MF lost its stored settings when renamed after the file
- Bridge: `slicer_imported_object_settings`, `slicer_imported_project_settings`, `slicer_set_object_file_settings`; test-only `slicer_reference_slice_3mf`. Test data for the Cub tests lives in `~/ios-sources/test-data/PS_3MF` (tests skip without it); the simulator can't read `~/Downloads` (macOS privacy protection)

- **All Settings screen** in every printer, material and slice editor: all ~150–300 PrusaSlicer settings of that type, grouped by PrusaSlicer's categories with its labels, units and help text, searchable, with "Changed Only" and expert-level filters. Each value is checked by libslic3r before it's accepted; "Use Preset Value" undoes a change. The editor also shows which PrusaSlicer preset the profile is based on, and slice/material profiles can change it ("Change Base Preset…")
- **New profiles start from PrusaSlicer.** "+" in the slice/material lists: **New Profile** is filled in from the PrusaSlicer preset for the selected printer; **From PrusaSlicer Preset… / Filament…** lists the presets compatible with it. Printers: **From PrusaSlicer Library…** (searchable, ~1,000 printers, added as untested) or **Custom Printer**
- **Built-in printers are generated from their PrusaSlicer presets** (`BuiltInProfiles.swift`: ~930 lines of hand-copied data → 70). Fixes left over from the hand copies: Prusa start G-code uses `[printer_model]` again, and Creality beds keep their real outline (e.g. Ender-3 S1 X 5–215 mm, not 0–215). Copies already saved on a device keep their values
- Profile stores load after the vendor presets (during the splash); if the presets ever fail to load, printers aren't reseeded as an empty list
- Bridge: `slicer_setting_info` (a setting's type, label, category, units, help text and choices from libslic3r's option definitions)
- DEBUG builds: `PALMSLICE_DEBUG_SCREEN=<screen>` opens a screen at launch for simulator screenshots (`DebugScreen.swift`)

- **Profiles convert losslessly to and from PrusaSlicer settings** (`ProfileSettings.swift`). Each printer / material / slice profile is its typed fields plus `extraSettings`: any other PrusaSlicer setting, in PrusaSlicer's .ini format. Values the typed fields can't hold exactly (a speed given as a percentage, a "grid" support style, a bed that starts at X = 5 mm, …) are kept verbatim until that field is edited. Tests import real Creality print, filament and printer presets and check they slice to byte-identical G-code
- **One settings path.** Slicing applies the PrusaSlicer presets, then each profile as `key = value` text through `slicer_apply_settings`, which libslic3r validates. The struct-based `slicer_apply_printer_config` / `_material_config` / `_slice_config` bridge functions are gone. Slice and material profiles can name their own base PrusaSlicer preset (`basePreset`)
- **Material retraction follows PrusaSlicer's model.** New **Set Retraction Here** switch: on (the default, and how existing materials behave) overrides the printer's retraction; off uses the printer's own, as most PrusaSlicer filaments do
- Fix: slicing with only a print preset applied (no PalmSlice slice profile) no longer hangs on a zero layer height

- **Slices now start from PrusaSlicer's own presets.** PrusaSlicer's vendor profile bundles ship in the app (3.2 MB, 32 vendors, ~1,000 printers) and load at launch with libslic3r's `PresetBundle`. Each slice applies the printer's PrusaSlicer preset, its default print preset and a matching filament preset first, then the PalmSlice printer / material / slice profiles on top. Settings PalmSlice doesn't expose (about 150) previously fell back to libslic3r's bare defaults; they now match PrusaSlicer. For the Ender-3 S1 that means, among others: no extra perimeters on overhangs, small areas no longer forced solid, thin walls off, 0.1 mm elephant-foot compensation, nearest seam, 0.85 bridge flow, objects labelled in the G-code
- Built-in printers are linked to their PrusaSlicer printer presets (0.4 mm nozzle variants). Custom printers use the Ender-3 S1's print and filament presets but never its printer settings
- Materials gain a **Type** (PLA, PETG, ABS, FLEX, …) which picks the matching PrusaSlicer filament preset. Saved PETG/ABS/TPU built-ins are typed automatically
- Material retraction now also sets PrusaSlicer's filament retraction overrides, so a vendor filament preset can't silently replace it
- Line Width / First Layer Line Width of 0 now keep PrusaSlicer's value for the printer instead of libslic3r's auto width
- Vendor-preset features PalmSlice can't support are always off: binary G-code (Prusa MK4/MINI), post-processing scripts, embedded thumbnails
- New bridge API: `slicer_presets_load`, `slicer_preset_*` (list, settings, compatibility), `slicer_apply_preset`, `slicer_apply_settings` (PrusaSlicer `key = value` text, validated by libslic3r) and `slicer_get_setting`
- Build step 21 `12_vendor_profiles.sh` copies the vendor bundles for the pinned PrusaSlicer tag. New tests: preset loading, every built-in printer slicing from its preset, and a drift test that fails if any setting PalmSlice doesn't control differs from the vendor preset

## 2026-10-21

- New built-in slice profile **3DLabPrint RC Plane (LW-PLA 0.3 mm)**, following 3DLabPrint's PrusaSlicer guide: 1 wall, no top/bottom layers, 0% infill, Even/Odd slicing, Classic walls, outer wall first, 0 gap-closing radius, 0.42/0.44 mm line widths, 40 mm/s walls, 20 mm/s first layer. For 3DLabPrint plane parts only
- Slice profiles gain **Wall Generator** (Arachne/Classic) and **Outer Wall First** under Walls, and a new **Advanced** section with **Slicing Mode** (Regular/Even-Odd), **Gap Closing Radius** and **Line Width** / **First Layer Line Width**. Defaults match PrusaSlicer, so existing profiles slice as before
- Saved slice profiles now load even when a newer app version adds settings (missing settings take their defaults), instead of being discarded and reseeded
- **eSUN PLA-LW** material retuned to 3DLabPrint's LW-filament settings: 50% flow, 0.01 mm retraction, fan up to 50% when a layer takes under 10 s; still 240 °C. Installs with an unedited copy get the new values automatically
- **Ender 3 S1:** the PrusaSlicer vendor profile, now named **Creality Ender-3 S1**, was print-tested and is the Verified built-in. The app's original hand-written "Ender 3 S1" profile is removed, including from existing installs (one-time migration)
- Printer picker: removed drag-and-drop between Verified and Untested (it didn't work in the list). Use a right swipe or touch-and-hold → Mark Verified / Mark Untested; the Untested footer now says so
- **Slicing engine updated to PrusaSlicer 2.9.6** (from 2.9.4, Nov 2025). Mostly SLA / multi-material work upstream; FFF-relevant fixes include bridge anchoring and cooling slowdown. All 14 built-in printer profiles and the 3MF import tests slice cleanly; G-code output is within 0.01% of 2.9.4's
- Build chain pins upstream versions: `PRUSA_TAG` (`version_2.9.6`) and `LIBBGCODE_COMMIT` in `scripts/common.sh`. Step 02 refuses to build a different PrusaSlicer checkout; step 17 checks out the pinned LibBGCode commit (previously both cloned whatever `main` was)
- iOS patch updated for 2.9.6: libslic3r now links the new `prusa_fdm_mixer` and `sla_time_estimate` libraries (installed by step 18, added to `OTHER_LDFLAGS`); the `sla_time_estimate_app` CLI is skipped on iOS
- Build fixes found during the update: step 18 now fails on a compile error instead of installing a stale `libslic3r.a`; stale CMake caches pointing at a removed SDK (which silently built Mac Catalyst objects) are wiped automatically; Clang 19's new template-keyword error in Boost/CGAL headers is suppressed; step 20 verifies the XCFramework was actually created
- `BUILDING.md`: new "Updating PrusaSlicer" procedure

## 2026-10-18

- First-launch notice reworded as **"Before You Print"** (sliced output can contain errors, use at your own risk, supervise the printer) with no "beta" wording — App Review guideline 2.2 rejects apps that describe themselves as beta. Listing's "BETA NOTE" renamed "PROFILE NOTE"
- New built-in material **eSUN PLA-LW (Lightweight)** for foaming lightweight PLA: 240 °C all layers, 60% flow, 0.8 mm retraction, part fan mostly off (from eSUN's guidance and 3DLabPrint's thin-wall FAQ). Untested
- New built-in slice profile **Lightweight LW-PLA (0.2 mm)** to pair with it: 2 walls, 3 top/bottom layers, 10% gyroid, 45 mm/s with no first-layer slowdown, 150 mm/s travel
- App updates now deliver newly added built-in material and slice profiles to existing installs (previously only fresh installs got them). Each is offered once, so a deleted built-in doesn't return
- First-launch disclaimer: removed the developer liability bullet. **Decline** no longer quits the app (`exit(0)`, which App Review rejects); it keeps the disclaimer up with a note that the terms must be accepted to use PalmSlice

## 2026-10-17

- **3MF, OBJ and AMF import** (file picker and drag-and-drop), alongside STL. Each object in the file becomes its own model, named from the file, with its rotation/scale baked in and the file's plate layout kept. Print settings embedded in 3MF/AMF files are ignored. New bridge call `slicer_import_model_file` uses libslic3r's format loaders directly (not `FileReader`, which would link the OpenCASCADE-dependent STEP loader)
- Fixed picking a non-STL file silently adding an invisible, empty model: unsupported extensions and unreadable meshes now show an error alert
- "Add STL" buttons renamed "Add Model"; the meters-vs-millimeters prompt only appears for unitless formats (STL, OBJ)
- `ModelImporterTests`: 3MF names/rotation/layout, AMF, OBJ, corrupt file, and convert-then-slice of two 3MFs (fixtures in `app/PalmSliceTests/Fixtures/`)

## 2026-10-16

- iPad: the 3D view now runs edge to edge behind the Models and Slice columns, which are translucent dark glass (always dark, to match the viewer) instead of opaque grey/black panels; the floating portrait panels use the same glass
- Build number bumped to 3 for the next TestFlight upload
- **iPad layout**: on regular-width screens the viewer gets a **Models** column (model list with sizes, swipe/long-press to remove, plus the full Move / Rotate / Scale form inline) and a **Slice** column (output filename, profiles, status, Slice / Export, About). Columns dock beside the viewer when the window is ≥ 1000 pt wide and float over it one at a time when narrower (iPad portrait); Slide Over and narrow Split View fall back to the phone layout. Toolbar buttons show/hide each column
- iPad drag-and-drop: drop STL files from Files onto the viewer to import them. Keyboard shortcuts ⌘O (add STL), ⌘R (slice), ⌘E (export)
- **Apple Pencil**: Pencil drags models across the bed and drags gizmo handles while fingers orbit the camera; double-tap / squeeze cycles Move → Rotate → Scale (respects the system "Ignore" setting); Pencil hover (M2+ iPads) and trackpad pointer highlight the gizmo handle under the tip
- Fixed **Center on Bed** zeroing the model's height instead of centring it front-to-back (a rotated model could sink into the bed), and the Drop to Bed fallback resetting front/back position instead of height
- Transform action buttons (Center on Bed, Drop to Bed, Lay Flat, Fit to Bed, Reset) stay on one line instead of wrapping
- Debug builds: `PALMSLICE_DEBUG_STL` environment variable auto-imports an STL at launch for scripted simulator screenshots
- `FUTURE_FEATURES.md`: new Apple Pencil roadmap, led by paint-on supports and paint-on seams

## 2026-10-14

- Fixed the Export button opening a blank sheet: the share sheet was presented with `.sheet(isPresented:)` and read the exported URL before it was set. Export is now driven by `.sheet(item:)`
- New **Export G-code** sheet: rename the file before saving, then **Save to Files…** (choose any folder in Files / iCloud Drive), **Share…**, or **Send to OctoPrint…**. Export no longer silently copies into the app's Documents folder
- OctoPrint integration (`OctoPrintClient.swift`): set the server address and API key once (key stored in the Keychain, with a Test Connection button), browse the server's folders, create new folders, and upload into any of them with a progress bar. Optional "select after upload" and "start printing after upload" toggles. Verified against OctoPrint 1.11.8
- Info.plist: added `NSLocalNetworkUsageDescription` and ATS `NSAllowsLocalNetworking` (plain HTTP allowed only to local hosts). README, `PRIVACY.md`, and `APP_STORE_LISTING.md` updated — the app is no longer network-free
- About screen no longer claims the app makes no network requests; it now mentions the optional OctoPrint upload
- TestFlight build 1.0 (2) uploaded to App Store Connect

## 2026-10-04

- New app icon (pickup truck on a printer bed, replacing the boat) — also applied to the launch/splash image and `images/PalmSliceAppIcon.PNG` — cut out of its white rounded-square backing and filled to full-bleed 1024×1024 like the previous icon
- Slice and Export are now separate steps: **Slice** writes G-code to a temp file and automatically opens the layer preview; **Export G-code** (shown after a slice completes, in both the collapsed bar and expanded panel) copies it to Documents and opens the share sheet. Button reads **Re-slice** once a slice exists
- 8 more untested printer profiles imported from PrusaSlicer's vendor library: Creality Ender-3, Ender-3 S1 (PrusaSlicer vendor version, alongside the hand-authored verified one), Ender-5, Prusa MK4, Elegoo Neptune-3 Pro, Sovol SV06, Voron 2.4 350
- Added `PrinterProfileSliceTests`, which slices a sample model with every built-in printer profile; all 14 pass. It exposed an empty `M862.3 P ""` model check in the Prusa profiles (the bridge doesn't set `printer_model`), so MK3S+, MINI+ and MK4 now hardcode their model name
- Fixed generated G-code filenames (and the live filename preview) including the imported STL's temp-copy UUID prefix; they now use the model's original name
- Privacy manifest now declares `UserDefaults` (reason `CA92.1`); build number bumped to 2; `APP_STORE_LISTING.md` added with draft App Store Connect copy

## 2026-09-12

- Printer profile library expanded with 6 profiles imported from PrusaSlicer's bundled vendor library (Prusa i3 MK3S+, Prusa MINI+, Creality Ender-3 V2, Creality CR-10, Anycubic i3 Mega, Artillery Sidewinder X1) — bed size, max print height, G-code flavor, and start/end G-code pulled from the actual PrusaSlicer `.ini` profiles
- Printer picker now splits profiles into "Verified" (tested on real hardware — Ender 3 S1 only) and "Untested" sections; selecting an untested profile shows a warning alert before it becomes active. Profiles can be promoted/demoted between sections by dragging, a leading swipe action, or a context menu
- `ProfileStore` now merges newly-added built-in profiles into an existing user's saved profile list on load instead of only seeding them on first install, without touching profiles the user has already customized
- Live output filename preview — the output filename field's placeholder shows the exact `.gcode` name that will be saved (model name + layer height + infill %) instead of a generic "(auto)" label; naming logic shared between the preview and the actual save path via `autoOutputStem()`
- First-launch EULA — beta-software / no-liability disclaimer shown once via `hasAcceptedEULA`; Accept continues, Decline exits the app
- About & Licenses moved to a floating (i) button in the bottom-right corner, above the collapsed slice panel
- README "Tested Printers" section added, listing real-world print validation (Ender 3 S1)

## 2026-09-01

- TestFlight build 1.0 (1) archived, signed, and uploaded to App Store Connect
- App Store Connect app record created (bundle ID `com.adickin.PalmSlice`)
- Privacy policy added (`PRIVACY.md`) — the app collects no data
- In-app About/Credits screen (`AboutView.swift`) — links to source repo, AGPL-3.0 license, privacy policy, and third-party license table
- `PalmSliceTests` XCTest target added — 15 tests covering profile Codable round-trips, built-in profile sanity, bridge-int enum uniqueness, and gcode parsing

## 2026-08-19

- Device (non-simulator) build confirmed working — `build_device.sh` populates `~/ios-sysroot-dev`; `libslic3r.xcframework` carries both `ios-arm64` and `ios-arm64-simulator` slices; Debug and Release both build clean for the `iphoneos` SDK

## 2026-04-18

- Interactive 3D translate gizmo — world-aligned X/Y/Z arrows follow the model; "Move" overlay button enters transform mode; drag an arrow to translate along that axis

## 2026-04-17

- Transform controls — `ModelTransform` state (position/rotation/scale) with a `TransformPanelView` sheet (Move / Rotate / Scale sections)
- Snap-to-face ("Lay Flat") — picks the largest downward-facing face via mesh normals + area weighting, converts to SceneKit Euler angles via quaternion
- Fit to bed / Center / Drop to bed helper buttons

## 2026-04-15

- Print time + filament estimate parsed from PrusaSlicer's gcode comments, shown in the status row
- Wireframe toggle for the 3D viewer
- Overhang highlight color mode (red/orange/yellow by downward-facing angle)
- Face normal color mode (normal XYZ mapped to RGB)
- Layer preview — full PrusaSlicer gcode parser (`GCodeParser.swift`) with a layer slider and per-extrusion-type line colors
- Material Profiles — `MaterialProfile` (filament, temperatures, retraction, cooling/fan), `MaterialProfileStore`, built-in PLA/PETG/ABS/TPU profiles, editor and picker UI, `slicer_apply_material_config()` bridge call

## 2026-04-13

- Slicing Profiles — `SliceProfile` (layers, walls, infill, speed, supports, adhesion), built-in Draft/Standard/Fine profiles, editor/picker/help UI, `slicer_apply_slice_config()` bridge call
- Printer Profiles — `PrinterProfile` (machine, printhead, per-extruder), built-in Ender 3 S1 profile, editor/picker UI, `slicer_apply_printer_config()` bridge call

## Foundational

Build chain, PrusaSlicer patches, and the original v1 app prototype — no longer individually dated, see [PROGRESS.md](PROGRESS.md) for the full itemized list.

- Full iOS cross-compilation of the dependency chain (Boost, TBB, CGAL, GMP, MPFR, Qhull, LibBGCode, Clipper2, zlib, libpng, expat, nlohmann/json, cereal, heatshrink) and libslic3r itself, packaged as an XCFramework
- PrusaSlicer patched with a `SLIC3R_IOS` CMake option gating out CURL/OpenGL/GLEW/NLopt/OpenVDB/Z3/JPEG, plus stub source files and headers so the FDM path builds without them
- SwiftUI single-screen prototype: C bridge (`slicer_bridge.h`/`.cpp`), STL load from bundle, hardcoded-settings FDM slicing, G-code export to Documents + Share Sheet + Files app integration
- Real STL file picker, slicing progress indicator, cancellation, and error alerts
- SceneKit 3D viewer (`STLParser.swift`, `STLSceneView.swift`) with orbit-turntable camera, print-bed grid, and XYZ axis gizmo
