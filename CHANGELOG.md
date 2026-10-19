# Changelog

All notable changes to PalmSlice, harvested from [PROGRESS.md](PROGRESS.md) and commit history. Dates reflect when a feature was completed, not necessarily committed. Entries are grouped by date, most recent first.

## 2026-10-18

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
