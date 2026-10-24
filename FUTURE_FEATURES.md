# PalmSlice — Future Features

Planned features that are not yet implemented. This is the single place to
look for "what's next" — it consolidates the old backlog plus the
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

- **Multi-extruder printing** — printer profiles already carry per-extruder
  nozzle sizes and offsets, but a slice uses one material for every
  extruder and parts can't be assigned to an extruder, so nothing prints
  with a second extruder. Needs a material per extruder, a per-part extruder
  choice, and checking tool changes / wipe tower output. Unlocks
  dual-extruder printers such as the Ultimaker S5/S7.

## Profiles (printer, slice, material)

- **Reset to default** — a "Reset to Default" button for built-in printer,
  slice and material profiles. Saved copies of built-ins keep the values they
  were created with, so they don't pick up improvements in later app
  versions (`mergeInMissingBuiltIns` only adds missing profiles).

## Slicing Profiles

- **Settings for one part** — give a single part on the bed its own values
  (e.g. 40% infill on a wing tip while the rest of the plate uses 15%),
  optionally only within a height range ("3 walls from 0–5 mm"), like
  PrusaSlicer's per-object and layer-range settings. Today these only come
  from a 3MF (shown read-only in the part's Settings from File sheet, on/off
  only). Plan: a "Settings for This Part" item in the part's context menu
  that reuses `AllSettingsView` (print keys only) to add, edit and remove
  overrides; store them on `PlacedModel` alongside `fileSettings`; slicing
  already applies per-object overrides through
  `slicer_set_object_file_settings`, so the bridge needs no change. Make the
  3MF settings editable through the same screen. Not covered: modifier
  meshes, support blockers/enforcers (see Apple Pencil painting above).

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

- **Verify untested printer profiles on real hardware** — 12 of 13 built-ins
  are unverified; promote each to Verified only after a real print.
