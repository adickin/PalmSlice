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

1. **Draw-to-cut** — draw a line across the model to define the cut plane;
   pairs with the Cut tool phase under Model Manipulation.
2. **Lasso multi-select** — draw around several models to select them for a
   group move / rotate / scale (needs multi-selection in `ContentView`).
3. **Hover inspect in layer preview** — hovering over the G-code preview shows
   the extrusion type, speed and layer height of the path under the tip.
4. **Snap on hold** — holding the Pencil still on a gizmo handle snaps
   rotation to 15° steps and moves to the bed grid.
5. **Scribble** already works in every numeric / text field (system feature,
   no work needed) — worth calling out in the App Store listing.
6. **Pressure-sensitive brush** — Pencil pressure sets the paint brush size
   (colour, support and seam painting are in, 2026-10-29 / 2026-11-01).

## Color Customization

Filament colour is done: materials have a colour (`filament_colour`) that
tints models by tool, the sliced preview and mix predictions (2026-10-29).
Still open: a user-chosen **app accent / viewer theme colour**. Needs
scoping — accent only, or also the 3D view's background and bed colours?

## Slicing Profiles

- **Editable settings from a file** — a 3MF's own part settings are still
  on/off only (Part Settings, 2026-11-01, go on top of them); editing them in
  place, and adding modifier meshes in the app, are open.

## Model Manipulation

Full plan: `Plans/model_manipulation.md`. Remaining phases:

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

- **iCloud Drive sync** for profiles and recent files.
- **Broader TestFlight distribution** — currently uploaded for internal
  testing (see `PROGRESS.md`); expanding to an external tester group is
  still open.

## Release / Testing

- **Verify untested printer profiles on real hardware** — 12 of 13 built-ins
  are unverified; promote each to Verified only after a real print.
