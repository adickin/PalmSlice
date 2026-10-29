# Handoff: multi-tool, Snapmaker U1, ColorMix and painting

Written 2026-10-29 to start this work in a fresh session. Read this first, then
[u1_colormix.md](u1_colormix.md), the full plan.

## The goal in one paragraph

Make PalmSlice slice multi-colour prints for the **Snapmaker U1** (4 independent
toolheads that swap in and out, Klipper + Moonraker, 270 mm cube) and support
**ColorMix**, Prusa's layer-alternating colour mixing ("Full Spectrum"
internally). Users should choose where colours and mixes go inside the app:
per object or part, by height, and by **painting** areas of the mesh. We stay on the
libslic3r (PrusaSlicer 2.9.6) backend. We decided against adding an OrcaSlicer or
Snapmaker Orca second backend: duplicate `Slic3r` symbols, a second build chain, and
our settings layer uses PrusaSlicer key names throughout.

## Already true (verified, don't re-investigate)

- **ColorMix is compiled into our libslic3r.** Code is in
  `~/ios-sources/PrusaSlicer/src/libslic3r/Feature/FullSpectrum/VirtualExtruder.{hpp,cpp}`.
  - Blends of 2–3 tools with ratios, plus Z gradients.
  - Definitions live on `Model::virtual_extruders`. Virtual IDs come after the
    physical tools (a 4-tool printer's first mix is T5).
  - Slicing remaps virtual → physical per layer (`PrintObjectSlice.cpp`, `PrintApply.cpp`).
  - JSON helpers: `serialize_virtual_extruders_to_json` /
    `deserialize_virtual_extruders_from_json`, plus `normalize_virtual_extruders`,
    `filter_virtual_extruders_for_physical_count` and `remap_full_spectrum_on_import`.
- **Colour predictor** `bundled_deps/prusa_fdm_mixer/prusa_fdm_mixer.hpp`
  (`mix`, `mix_rgb`, `delta_e_2000`) is built (`libprusa_fdm_mixer.a`) and linked.
- **3MF** stores mixes in `Metadata/Prusa_Slicer_full_spectrum.json` (read by
  `load_3mf`), and painted areas as `ModelVolume::mm_segmentation_facets`
  (a `FacetsAnnotation` over a `TriangleSelector`).
- **Painting API in libslic3r** (`TriangleSelector.hpp`): `select_patch` (needs a
  `Cursor`, circle or sphere), `seed_fill_select_triangles`,
  `bucket_fill_select_triangles`. Write back with `FacetsAnnotation::set(selector)`.
  `TriangleStateType::Extruder1 …` encode the tool per triangle.
- **U1 profile source:** OrcaSlicer
  `resources/profiles/Snapmaker/machine/fdm_U1.json` and
  `Snapmaker U1 (0.4 nozzle).json` (also 0.2 / 0.6 / 0.8 / 0.4+0.6), at
  https://github.com/OrcaSlicer/OrcaSlicer/tree/main/resources/profiles/Snapmaker/machine.
  - It uses `host_type = octoprint`, so the U1 likely accepts OctoPrint-style uploads.
  - Its G-code uses Orca-only variables and macro syntax that need porting. The
    mapping table is in the plan, §2.2.
  - PrusaSlicer's `Snapmaker.ini` has no U1.

## Where the code changes start

| What | Where |
|------|-------|
| Import flattens every object to one STL (the main blocker, plan §1.1) | `app/PalmSlice/slicer_bridge.cpp:617` `slicer_import_model_file` (`obj->raw_mesh()` → `0.stl, 1.stl…`), re-added via `slicer_add_stl` (`:536`) |
| Transforms applied to objects | `slicer_bridge.cpp:472` `apply_transform_to_object` |
| Thumbnails forced off | `slicer_bridge.cpp:280` (plan §2.3) |
| Reference slice of a 3MF as desktop PrusaSlicer would (spike 0.1) | `slicer_bridge.cpp:1073` `slicer_reference_slice_3mf` |
| Settings → libslic3r | `slicer_apply_settings` (`slicer_bridge.cpp:977`), built from `SliceSetup.swift` (`base` at :19, one material only) |
| Placed models (no parts, no extruder) | `PlacedModel.swift`, `ModelListView.swift` |
| Preview parser (ignores `T` commands) | `GCodeParser.swift` (`parseGCode` at :35) |
| Upload | `OctoPrintClient.swift`, `ExportSheetView.swift` |
| Per-extruder printer data | `ExtruderProfile.swift`, `ProfileSettings.swift` (~:546) |
| Vendor presets loaded | `scripts/12_vendor_profiles.sh`, `app/PalmSlice/PrusaSlicerProfiles/vendor/` |

## Order of work

1. **Phase 0 spikes** (plan §0). 0.1 can be done now without hardware: make a
   ColorMix 3MF in desktop PrusaSlicer 2.9.6 (Prusa XL 5T), run it through
   `slicer_reference_slice_3mf` in the simulator, and compare with desktop G-code.
   0.2–0.4 need a real U1.
2. **§1.1 native import** (keep `ModelObject`s with volumes, extruders, paint and
   mixes). Design this carefully; everything else builds on it.
3. §1.3 a material per tool → §1.2 tool per object/part → §1.5 preview by tool.
4. §2.1/2.2/2.5 U1 profile, G-code port and upload. First real multi-colour U1 print.
5. §3.1–3.3 ColorMix bridge, mix editor, assigning mixes.
6. **Phase 4 painting** (core, not optional).
7. Polish: wipe tower UI, thumbnails, metadata, 3MF export, colour by height.

## Gotchas from earlier sessions

- Follow `CLAUDE.md`: bridge functions return `int` (0 ok, negative error) and set
  `slicer_last_error`. Never throw across the C boundary. Swift shows an alert on failure.
  Use C++17. Update `CHANGELOG.md` with every commit. Run `xcodegen` in `app/`
  after changing `project.yml`.
- Boost.Filesystem from the bridge returns empty paths (ABI mismatch); use `std::filesystem`.
- After Xcode updates, stale CMake dirs can silently build Mac Catalyst objects.
  Steps 17/18 auto-wipe them. To check a lib's platform: `ar -x lib.a; otool -l x.o | grep -A4 LC_BUILD_VERSION`
  (7 = simulator, 2 = device).
- The simulator can't read `~/Downloads` (TCC), so put test files under
  `~/ios-sources/test-data/` (existing: `PS_3MF/`, the 3DLabPrint Cub parity set).
- DEBUG screenshots: `SIMCTL_CHILD_PALMSLICE_DEBUG_SCREEN=<DebugScreen case>`;
  simulator screenshots need `sips -r 270`.
- There is no XCTest target yet. The plan's Testing section proposes starting one with
  bridge tests (native import keeps volumes/extruders/mixes; U1 slice has no
  unresolved `{…}` placeholders; ColorMix 3MF matches the reference slice).
- The 3MF settings import (per-object settings, layer ranges, variable layer
  height) must keep working once import stops flattening. Re-run the Cub parity check.

## Open questions for the user

- Is a Snapmaker U1 on hand for spikes 0.2–0.4?
- Should the U1 profile be marked untested until it has printed?
- Painting on iPhone: is one-finger paint with two-finger orbit acceptable, or iPad-only at first?

## Prompt to start the next session

> Read `Plans/u1_colormix_handoff.md` and `Plans/u1_colormix.md`. Start with
> spike 0.1 (slice a ColorMix 3MF on iOS via `slicer_reference_slice_3mf`), then
> propose a design for §1.1 native import before writing code.
