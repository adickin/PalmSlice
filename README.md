# PalmSlice

An iOS on-device 3D printing slicer. Loads an STL, 3MF, OBJ or AMF model, slices it using libslic3r (PrusaSlicer's C++ core compiled as a static library), and exports G-code to the iOS Files app, the share sheet, or an OctoPrint server on your local network.

No cloud. No account. Slicing runs entirely on-device; the only network traffic is the optional OctoPrint upload you trigger yourself.

## NOTE

This entire project will be written by AI.

## Architecture

```
SwiftUI app
    └── ContentView.swift
         └── slicer_bridge.h / .cpp   ← thin C wrapper (Swift can't call C++ directly)
              └── libslic3r.a          ← PrusaSlicer core, cross-compiled for arm64
                   └── ~/ios-sysroot-sim/lib/
                        Boost, TBB, CGAL, GMP, MPFR, Qhull, LibBGCode,
                        heatshrink, Clipper2, zlib, libpng, expat, nlohmann_json, …
```

The XCFramework packages `libslic3r.a` so Xcode can consume it. The C bridge (`slicer_bridge.cpp`) is compiled as part of the app target and links everything together.

Building this from source? See **[BUILDING.md](BUILDING.md)**.

## App

Single-screen SwiftUI app with a live 3D viewer:

- Load STL, 3MF, OBJ or AMF files via the document picker or drag-and-drop; several models at once, with collision and out-of-bed highlighting. A 3MF's per-part settings (overrides, height ranges, variable layer height) come with it, and its print settings can be turned into profiles
- View them in an interactive SceneKit viewer — orbit/pan/zoom, wireframe, overhang/face-normal color modes, layer preview after slicing
- Move / rotate / scale with on-screen gizmos or typed mm sizes, "Lay Flat" snap-to-face, fit-to-bed/center/drop-to-bed helpers
- Choose a printer profile, slice profile, and material profile. Every slice starts from the printer's PrusaSlicer vendor preset (~1,000 printers bundled), with your profiles on top; an All Settings screen exposes every setting, and profiles import/export PrusaSlicer `.ini` files
- Slice on-device with a progress indicator and cancel support
- Export G-code to Files, the Share Sheet (AirDrop, send anywhere), or upload it to an OctoPrint server
- iPad layout with Models / Slice sidebars, drag-and-drop, keyboard shortcuts and Apple Pencil support

See [CHANGELOG.md](CHANGELOG.md) for the history of features as they landed, and [PROGRESS.md](PROGRESS.md) for current status and what's next.

## Tested Printers

Real-world print testing is ongoing. G-code produced by PalmSlice has been sliced and printed on:

| Printer | Notes |
|---------|-------|
| Creality Ender 3 S1 | Primary test printer so far |

This list will grow as more printers are tried. If you print successfully (or unsuccessfully) on
a printer not listed here, please open an issue with the printer model and outcome.

## Why Not Cura / Unity

**Cura (CuraEngine):** architected as a CLI process communicating over a socket — not embeddable. iOS prohibits spawning child processes and loading dynamic libraries at runtime.

**Unity:** adds 100 MB+ runtime overhead and conflicts with iOS's prohibition on dynamic code loading. SwiftUI + SceneKit achieves the same 3D viewing with zero overhead.

**libslic3r:** actual embeddable C++ library, not a CLI. Statically linkable. On A-series chips, slicing a simple model takes under a second.

## Roadmap

- [x] Build chain (all deps + libslic3r cross-compiled for iOS Simulator and device)
- [x] C bridge (load STL / slice / export G-code)
- [x] SwiftUI prototype with SceneKit 3D viewer
- [x] G-code export via Share Sheet + Files app
- [x] Printer / slicing / material profiles
- [x] Model transform controls (move/rotate/scale, snap-to-face, fit-to-bed)
- [x] Confirmed working: valid G-code produced and printed on real hardware
- [x] Multiple models on the bed, with collision detection
- [x] iPad layout + Apple Pencil
- [x] 3MF / OBJ / AMF import, including 3MF per-part settings
- [x] PrusaSlicer vendor presets as the base of every slice; `.ini` import/export
- [x] OctoPrint upload
- [ ] Auto-orient
- [ ] Cut tool
- [ ] Paint-on supports / seams

## License

libslic3r is AGPL-3.0. This app, as a derivative work, is also AGPL-3.0.
