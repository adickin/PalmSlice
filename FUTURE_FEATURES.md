# PalmSlice — Future Features

Planned features that are not yet implemented. This is the single place to
look for "what's next" — it consolidates the previous `BACKLOG.md` plus the
longer-term (non-checklist) items that were living in `PROGRESS.md`'s To Do
section. Where a detailed implementation plan already exists under `Plans/`,
this doc links to it instead of duplicating it.

When a feature here gets built, move it to `PROGRESS.md`'s Completed section
with a date stamp (per the existing convention) and delete its entry here.

---

## Apple Pencil

The first pass is in (see `PROGRESS.md`): Pencil drags models across the bed
and drags gizmo handles while fingers orbit the camera; double-tap / squeeze
cycles Move → Rotate → Scale; hover highlights the gizmo handle under the tip.
Next ideas, in priority order:

1. **Paint-on supports / blockers** *(top pick)* — paint facets of the model
   to force or forbid support, like PrusaSlicer's support painting gizmo.
   Pencil pressure could set brush size. Needs a new C bridge call to pass
   per-facet enforcer/blocker state into libslic3r (its `TriangleSelector`
   format on `ModelVolume::supported_facets`), plus a per-face colour layer
   in `STLSceneView` to show the paint.
2. **Paint seam position** *(top pick)* — same painting machinery, writing
   `ModelVolume::seam_facets` so the seam lands where it's least visible.
   Build after (1), since it reuses the brush, hit-testing and bridge plumbing.
3. **Draw-to-cut** — draw a line across the model to define the cut plane;
   pairs with the Cut tool phase under Model Manipulation.
4. **Lasso multi-select** — draw around several models to select them for a
   group move / rotate / scale (needs multi-selection in `ContentView`).
5. **Hover inspect in layer preview** — hovering over the G-code preview shows
   the extrusion type, speed and layer height of the path under the tip.
6. **Snap on hold** — holding the Pencil still on a gizmo handle snaps
   rotation to 15° steps and moves to the bed grid.
7. **Scribble** already works in every numeric / text field (system feature,
   no work needed) — worth calling out in the App Store listing.

## Color Customization

A way for the user to set colors — most likely a filament/material color
swatch (shown in `MaterialProfilePickerView` and used to tint the model in
the viewer) and/or a UI accent color. Neither `MaterialProfile` nor
`SliceProfile` currently has a color field. Needs scoping: filament color
only, or also a viewer/app theme color?

## Printer Profiles

- **Additional built-in profiles** — the suggested first batch is in; see `Plans/additional_printer_profiles.md`
  for the remaining catalog and how-to-import steps.
- **Multi-extruder bridge** — `SlicerPrinterConfig` currently only passes
  extruder 0; extend to pass per-extruder arrays for nozzle/filament diameter
  and offsets.
- **Reset profile to default** — "Reset to built-in defaults" button in the
  printer profile editor for built-in profiles.

## Slicing Profiles

- **Additional speed settings** — outer perimeter speed, small perimeter
  speed, bridge speed, top solid infill speed (currently only the 4 main
  speeds are exposed; all others use PrusaSlicer defaults).
- **Reset profile to default** — "Reset to built-in defaults" button for
  built-in slice profiles (Draft / Standard / Fine).
- **Seam position** — aligned / nearest / random (`seam_position` key).
- **Extrusion width overrides** — per-feature extrusion width (perimeter,
  infill, top solid) for fine-tuning on non-standard nozzle sizes.

## Model Manipulation

Full plan: `Plans/model_manipulation.md`. Remaining phases:

- **Auto-orient** (Phase 6) — rotate to minimize support area; scores
  candidate rotations by overhang.
- **Cut tool** (Phase 7) — Z-height slider + live cut-plane preview;
  new `slicer_cut_at_z` C bridge call.

## STL Import

- **STL unit detection (inches)** — the metres case is done (sub-2 mm
  imports offer a one-tap ×1000 fix, 2026-08-23). Still open: detecting
  inch-exported models. A 60 mm model exported in inches appears as
  1524 mm wide. Heuristic: if the largest axis is clearly outside the normal
  printing range (> 500 mm), offer [Keep as mm] / [Scale from inches ×25.4].
  Ranges overlap with legitimately large parts, so only prompt when the size
  is far outside the bed.

- **Direct import from model hubs** — pass a Thingiverse (or other model
  hub) URL; the app downloads the zip and auto-slices its contents. Far-future,
  no design work started.

## Infrastructure

- **Haptic feedback** on slice complete.
- **iCloud Drive sync** for profiles and recent files.
- **Broader TestFlight distribution** — currently uploaded for internal
  testing (see `PROGRESS.md`); expanding to an external tester group is
  still open.

## Release / Testing

- **Verify untested printer profiles on real hardware** — 13 of 14 built-ins
  are unverified; promote each to Verified only after a real print.
- **Printer-model placeholders** — `printer_model` / `printer_settings_id`
  aren't set by the bridge, so vendor start G-code that references them
  renders empty (worked around for Prusa by hardcoding). Consider exposing
  them in `SlicerPrinterConfig`.
- **Ultimaker S5/S7 (dual extruder)** — deliberately not included yet. Needs
  the multi-extruder bridge plus its Griffin-header start G-code (importing
  extruder 0 only logs a non-fatal "invalid toolchange (T1)"). Re-import from
  `Ultimaker.ini` once multi-extruder is supported.
- **Refresh seeded built-ins on update** — `mergeInMissingBuiltIns` only adds
  new profiles; saved copies of existing built-ins (e.g. MK3S+/MINI+) keep
  stale G-code. A per-profile "reset to built-in" would fix this too.
