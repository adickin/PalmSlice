# Plan: Multi-tool, Snapmaker U1 and ColorMix support

Goal: let PalmSlice slice multi-colour and ColorMix prints for the Snapmaker U1
(4 independent toolheads, Klipper/Moonraker), using the libslic3r backend we
already ship. No second slicer backend.

Users must be able to choose where colours and mixes go **inside PalmSlice**,
as in desktop PrusaSlicer: per object or part, by height, and by painting areas of the
mesh. Importing a 3MF set up on desktop is a stopgap and a compatibility
feature, not the main workflow. In-app painting (Phase 4) is core work.

Sizes are relative: **S** ≈ a day or two, **M** ≈ under a week, **L** ≈ more than a week.

---

## What we already have (verified 2026-10-28)

| Area | State |
|------|-------|
| ColorMix engine | Built into our libslic3r 2.9.6: `src/libslic3r/Feature/FullSpectrum/VirtualExtruder.{hpp,cpp}`. Blends (2–3 tools, ratios) and Z gradients. `Model::virtual_extruders`, slicing remaps virtual → physical per layer. |
| Colour predictor | `bundled_deps/prusa_fdm_mixer` (`mix()`, `mix_rgb()`, `delta_e_2000()`), already built as `libprusa_fdm_mixer.a` and linked. |
| 3MF ColorMix data | `load_3mf` reads `Metadata/Prusa_Slicer_full_spectrum.json` into `model.virtual_extruders`. |
| Multi-extruder printers | `PrinterProfile.extruders` handles N extruders (offsets, nozzles, per-extruder G-code). |
| Upload | `OctoPrintClient.swift`. Orca's U1 profile uses `host_type = octoprint`, so the U1's Moonraker probably accepts OctoPrint-style uploads. |
| Test hook | `slicer_reference_slice_3mf()` slices a 3MF as desktop PrusaSlicer would. |

## What blocks it today

1. **Import flattens models.** `slicer_import_model_file` bakes each object into one
   STL (`obj->raw_mesh()`), then re-adds it with `slicer_add_stl`. That throws away
   parts (volumes), per-part extruder assignments, painted colour regions and the
   ColorMix definitions.
2. **One filament per slice.** `SliceSetup` applies a single `MaterialProfile`;
   per-extruder filament values are never filled for tools 2–4.
3. **No extruder assignment.** You can't choose which tool prints an object or part.
4. **No toolchange awareness in preview.** `GCodeParser` ignores `T` commands, so
   there's no colour-by-tool view and the wipe tower isn't shown.
5. **No U1 profile.** PrusaSlicer's `Snapmaker.ini` stops at J1/A-series/Artisan.
6. **Thumbnails are off** (`slicer_bridge.cpp:280`). The U1 screen expects
   48×48 and 300×300 PNGs.

---

## Phase 0: Spikes to de-risk first (all S)

Do these before building anything else. Each one can kill or reshape a later phase.

- [x] **0.1 ColorMix on iOS.** (2026-10-29: reference slice on iOS resolves mixes to
  physical tools, `ColorMixTests`; the desktop G-code diff is still to do.) Make a ColorMix 3MF in desktop PrusaSlicer 2.9.6
  (Prusa XL 5T profile), run it through `slicer_reference_slice_3mf` in the
  simulator, and diff the G-code against desktop output. This proves the engine works on-device.
- [ ] **0.2 Upload to a U1.** Point the existing OctoPrint settings at the U1
  (`http://<ip>`, empty or any API key) and upload a file. If it works,
  Phase 2.5 shrinks to polish.
- [ ] **0.3 Hand-made U1 profile, single colour.** Port the Orca start/end G-code
  by hand into a custom printer profile and print one calibration cube. This flushes
  out placeholder-language differences (see 2.2) before we bake a profile in.
- [ ] **0.4 Check what the U1 firmware reads from the file.** Compare the header
  and config block of an Orca U1 file with ours. Does the touchscreen need
  per-tool filament type/colour metadata or thumbnails to start a print?

---

## Phase 1: Multi-tool foundation

Needed for any multi-colour printing, and also helps Prusa XL, IDEX machines and Jubilee.

### 1.1 Keep native models on import (L, the biggest structural change)
- Bridge keeps the imported `Slic3r::Model` in the context instead of baking STLs.
  New `slicer_add_imported_object(handle, import_index)` copies the
  `ModelObject` (all volumes, extruder config, `mm_segmentation_facets`) into
  `ctx->model`. STL/OBJ keep the current path.
- Volume enumeration so Swift can show parts:
  `slicer_object_volume_count`, `slicer_object_volume_name`,
  `slicer_object_volume_type` (part / modifier / negative / support blocker),
  `slicer_export_volume_mesh(handle, obj, vol, out_path)` for display.
- Carry `model.virtual_extruders` over (with `remap_full_spectrum_on_import`
  when the target printer has a different physical tool count).
- `PlacedModel` gains `parts: [ModelPart]` (name, mesh, extruder). The scene
  renders each part separately so it can be tinted by tool colour.
- Collision/BVH keeps working on the merged mesh.
- Risk: transforms. Today the instance matrix is baked into the STL. With native
  objects, `apply_transform_to_object` must compose with the file's own volume
  matrices instead. Cover this with the Cub 3MF parity test.

### 1.2 Extruder assignment (M)
- Bridge: `slicer_set_object_extruder(handle, obj, extruder_1based)` and
  `slicer_set_volume_extruder(handle, obj, vol, extruder_1based)` (writes the
  `extruder` key on the object/volume config; 0 = default).
- UI: a tool chip on each row of `ModelListView` and on each part in a new
  expandable part list. A picker shows physical tools 1…N and, after Phase 3,
  virtual (mix) tools.
- 3D view tints objects/parts by their tool's filament colour.

### 1.3 One filament per tool (M)
- Printer with N extruders → N material slots ("tool strip": colour swatch +
  material name per tool), stored with the session.
- `SliceSetup`: build each per-extruder vector key (`temperature`,
  `filament_type`, `filament_colour`, `extrusion_multiplier`,
  `filament_retract_*`, `filament_max_volumetric_speed`, …) from the N materials
  before `slicer_apply_settings`. Base presets: pass N filament preset names
  (PresetBundle's `filament_presets` vector) instead of one.
- `MaterialProfile` gains `colour` (hex) if it doesn't already have one. It feeds
  `filament_colour`, the 3D tints and the mixer.
- Only tools that are actually used should need a material picked. Warn on unused/empty.

### 1.4 Wipe tower and ooze control (M)
- Surface `wipe_tower`, `wipe_tower_x/y`, width, brim, `wipe_tower_bridging`,
  `ooze_prevention`, `standby_temperature_delta`, prime volumes in a
  "Multi-material" section of the slice profile (the All Settings screen already
  exposes the raw keys).
- Render the wipe tower footprint on the bed (size from libslic3r after a
  slice, estimate before) and let the user drag it. Include it in collision/bed checks.

### 1.5 Preview by tool (M)
- `GCodeParser`: track `T<n>` and Klipper `T<n>` macros, tag segments with tool
  index, and recognise wipe-tower moves (`;TYPE:Wipe tower`).
- `GCodeSceneView`: "Colour by: Feature | Tool" toggle, with the tool palette
  taken from `filament_colour`.
- Slice summary: filament used per tool (from the G-code footer
  `; filament used [g] = a, b, c, d`), number of toolchanges, and wipe tower material.

### 1.6 Colour by height (S, optional quick win)
- `custom_gcode_per_print_z` toolchange entries ("switch to T2 at Z = 12 mm").
  Gives cheap multi-colour without painting and reuses the layer slider in preview.

---

## Phase 2: Snapmaker U1 printer support

### 2.1 Built-in U1 printer profile (M)
- Source: OrcaSlicer `resources/profiles/Snapmaker/machine/fdm_U1.json` +
  `Snapmaker U1 (0.4 nozzle).json` (also 0.2 / 0.6 / 0.8 / 0.4+0.6 variants).
  Orca profiles are AGPL-3.0, the same licence as ours.
- Key values: 270 × 270 × 270 bed (`0.5,1 – 270.5,271`), 4 extruders,
  `gcode_flavor = klipper`, offsets 0×0 (the firmware handles them),
  `retract_length_toolchange = 10`, retract 1.5 mm, z-hop 0.4 (auto lift),
  layer height 0.08–0.32, toolchange time 5 s, M600 pause.
- Ship it as a PalmSlice-owned vendor bundle (e.g. `PalmSlice.ini` next to the
  PrusaSlicer vendor files, loaded by the same `load_configbundle` path) so it
  survives vendor-bundle refreshes in `12_vendor_profiles.sh`.
- Matching print presets (0.08 / 0.12 / 0.16 / 0.20 / 0.28) and generic
  PLA / PETG / TPU filament presets.

### 2.2 Port the G-code templates (M, the tricky part)
Orca's macro language and variable names differ from PrusaSlicer's. Each template
has to be rewritten and tested with real slices:

| Orca | PrusaSlicer |
|------|-------------|
| `change_filament_gcode` | `toolchange_gcode` |
| `bed_temperature_initial_layer_single` | `first_layer_bed_temperature[initial_extruder]` |
| `nozzle_temperature[i]` | `temperature[i]` |
| `print_sequence == "by object"` | `complete_objects` |
| `curr_bed_type == "High Temp Plate"` | no equivalent; drop it or add a printer option |
| `min_vitrification_temperature` | no equivalent; derive from `filament_type` |
| `position[2] = position[2] + 2.0` | not supported; emit an explicit Z move |
| `layer_change_gcode` / `before_layer_change_gcode` | same names exist |

- Keep the firmware macros as-is: `PRINT_START`, `SM_PRINT_AUTO_FEED`,
  `SM_PRINT_FLOW_CALIBRATE`, `SM_PRINT_PREEXTRUDE_FILAMENT INDEX=n`,
  `SET_PRINT_STATS_INFO TOTAL_LAYER/CURRENT_LAYER`, `TIMELAPSE_TAKE_FRAME`,
  `DEFECT_DETECTION_*`, purifier/chamber macros.
- Only feed/calibrate tools that are used (`is_extruder_used[i]`).
- Add a test that slices a 4-tool model with the U1 profile and asserts that no `{`
  placeholder or parser error survives into the G-code.

### 2.3 Thumbnails (M)
- Implement libslic3r's `ThumbnailsGeneratorCallback` in the bridge as a C
  callback into Swift. Swift renders the plate offscreen with SceneKit
  (`SCNRenderer.snapshot`) at the requested sizes and returns PNG bytes.
- Stop blanking `thumbnails` for printers that ask for it (U1: `48x48/PNG, 300x300/PNG`).
  This also helps Klipper/Mainsail users on other printers.

### 2.4 G-code metadata (S)
- Make sure the config footer includes `filament_colour`, `filament_type`,
  `extruder_colour` and per-tool usage so Moonraker's metadata parser and the U1 screen can
  show them. The exact requirements come from spike 0.4.

### 2.5 Send to printer (S–M)
- If spike 0.2 works: label the host type "OctoPrint / Moonraker" and allow an empty API key.
- Native Moonraker client (M): `POST /server/files/upload` (with `print=true`),
  `GET /printer/objects/query?print_stats` for progress, `POST /printer/print/cancel`.
  Optional Bonjour discovery (`_moonraker._tcp`).

---

## Phase 3: ColorMix

### 3.1 Bridge API (S)
Reuse libslic3r's own JSON format so 3MF import, the bridge and Swift share one representation:
```c
// JSON array in Prusa_Slicer_full_spectrum.json format. Normalised and
// filtered against the current physical extruder count; invalid entries dropped.
int         slicer_set_virtual_extruders(SlicerHandle, const char* json);
const char* slicer_get_virtual_extruders(SlicerHandle);          // JSON
// Predicted colour of a mix: parts = "#RRGGBB:ratio;#RRGGBB:ratio[;…]"
int         slicer_mix_color(const char* parts, char* out_hex, int len);
int         slicer_color_delta_e(const char* hex_a, const char* hex_b, double* out);
```
- Virtual tool IDs start at physical count + 1 (U1: 5, 6, …). Anything that
  stores a tool number (part assignment, colour-by-height) must handle them.

### 3.2 Mix editor (M)
- "Mixes" sheet: list of virtual tools with a predicted swatch
  (`prusa_fdm_mixer::mix`, calibrated, median ΔE ≈ 5.7).
- Blend: pick 2–3 physical tools and set the ratios with sliders. The swatch updates live.
- Gradient: stops (tool + position) and an optional Z range (auto = the extent
  of the object/region).
- "Suggest mixes": list useful 2- and 3-way blends of the loaded filaments, dropping
  combinations whose ΔE from an existing colour is below a threshold
  (similar to Prusa's ~40 CMYKW combinations).

### 3.3 Assign mixes (S, built on 1.2)
- Virtual tools appear in the object/part tool picker with their predicted colour,
  and the 3D view tints with the predicted colour.

### 3.4 Slicing guidance (S)
- ColorMix looks best at thin layers. When a virtual tool is in use and
  layer height is > 0.12 mm, suggest 0.08–0.12.
- Explain that every layer change inside a mixed region is a toolchange, and show the
  estimated toolchange count and added time (`machine_tool_change_time` = 5 s on U1).

### 3.5 Preview (S)
- "Colour by tool" shows the actual physical tool per layer (the G-code only
  contains physical tools). Add "Colour by mix" to tint mixed regions with the predicted colour.

### 3.6 3MF round-trip (S–M)
- Import: covered by 1.1 (virtual extruders come along with the model).
- Export a project 3MF (`store_3mf`) including the full-spectrum JSON, so jobs
  set up on the phone open in desktop PrusaSlicer. This is optional but nice for sharing.

---

## Phase 4: Paint colours and mixes on the model (L, core)

This is how users "select the places to colour" in the slicer. It comes right after
the mix editor (3.1–3.2) in the build order. Until it lands, users can paint in desktop
PrusaSlicer and import the 3MF, which 1.1 preserves.

How libslic3r stores it: each `ModelVolume` has `mm_segmentation_facets`, a
`FacetsAnnotation` holding a serialized `TriangleSelector` (per-triangle state =
extruder ID, with recursive triangle subdivision so strokes needn't follow mesh
edges). Slicing turns that into per-layer regions (multi-material segmentation);
virtual IDs are remapped to physical tools per layer (`PrintObjectSlice.cpp`).

### 4.1 Paint data through the bridge (M)
- Keep a `TriangleSelector` per volume in the bridge while a paint session is open:
  `slicer_paint_begin(handle, obj, vol)`, `slicer_paint_end(...)` (writes back
  with `mm_segmentation_facets.set(selector)`), `slicer_paint_clear(...)`.
- Strokes: `slicer_paint_circle(handle, hit_point, hit_facet, radius, extruder,
  camera_dir)` (wraps `TriangleSelector::select_patch`, sphere/circle cursor) and
  `slicer_paint_fill(handle, hit_facet, extruder, smart_angle_deg)` (wraps
  `seed_fill_select_triangles` / `bucket_fill_select_triangles`).
- Display mesh: `slicer_paint_mesh(handle, out_vertices, out_colors_by_extruder)`
  returns the subdivided triangles grouped by state, so Swift can rebuild only the
  painted geometry after each stroke. All coordinates are in the volume's local frame.
- Check performance on a 200k-triangle model on an iPhone 14 Pro. Strokes must
  feel immediate, so throttle and rebuild geometry off the main thread.

### 4.2 Paint mode UI (L)
- A "Paint" mode on the selected object: tool/mix palette (physical tools plus
  virtual mixes with predicted swatches), brush size, Brush / Smart fill /
  Erase, "Clear painting".
- Input: Apple Pencil paints and fingers orbit on iPad (reuse the existing Pencil
  support). On iPhone, one finger paints in paint mode and two fingers orbit/zoom.
- Hit testing: SceneKit `hitTest` gives the face index on the display mesh. Map it
  to the libslic3r facet index (the display mesh must keep libslic3r's triangle
  order, which it does if we export it from the bridge).
- Undo/redo per stroke (snapshot the serialized selector state).
- Render painted triangles as a second geometry layered over the base mesh,
  coloured by tool/mix colour.

### 4.3 Integration (S)
- Painted objects show a badge in `ModelListView`; collision checks still use the base mesh.
- Changing the printer's tool count remaps or drops out-of-range paint states
  (warn before dropping).
- Painting survives transforms (it's in the volume's local frame) and 3MF export (3.6).

---

## Suggested order

1. Phase 0 spikes (about a week, needs a U1 on hand).
2. 1.1 → 1.3 → 1.2 → 1.5. After this, imported multi-colour 3MFs (including
   ColorMix ones painted on desktop) slice and preview correctly on any multi-tool printer.
3. 2.1 + 2.2 + 2.5 gives the first real U1 multi-colour prints.
4. 3.1 → 3.3 gives ColorMix created on the phone, assigned per object/part.
5. Phase 4 (4.1 → 4.2 → 4.3) lets users paint colours and mixes onto areas of the model.
6. 1.4, 2.3, 2.4, 3.4–3.6, 1.6 as polish.

## Testing

- Add an XCTest target (none exists today), starting with bridge-level tests:
  native 3MF import keeps volumes/extruders/virtual extruders; 4-tool slice
  with the U1 profile has no unresolved placeholders; ColorMix 3MF matches
  `slicer_reference_slice_3mf` output exactly.
- Real hardware: one U1 test print per phase, starting with 4-colour
  per-part, then a 2-tool blend, then a gradient.

## Open questions

- Does the U1's OctoPrint compatibility need an API key, and does it start prints on upload?
- Does the U1 refuse or misbehave on files without Orca-specific metadata?
- Should the U1 profile be gated behind a "tested" flag until we've printed with it?
- PrusaSlicer 3.0 is expected to change ColorMix workflows. Watch upstream before
  we freeze the bridge JSON format.
