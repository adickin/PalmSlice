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

- Load an STL, 3MF, OBJ or AMF file via the document picker or drag-and-drop (3MF/AMF print settings are ignored; geometry and layout are kept)
- View it in an interactive SceneKit viewer — orbit/pan/zoom, wireframe, overhang/face-normal color modes, layer preview after slicing
- Move / rotate / scale the model with on-screen gizmos, "Lay Flat" snap-to-face, fit-to-bed/center/drop-to-bed helpers
- Choose a printer profile, slice profile, and material profile (built-ins provided, fully editable)
- Slice on-device with a progress indicator and cancel support
- Export G-code to the app's Documents directory — visible in the iOS Files app and shareable via the Share Sheet (AirDrop, Files, send anywhere)

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
- [ ] Auto-orient / support structures
- [ ] Cut tool
- [ ] Multi-model arrangement
- [ ] iPad layout

## License

libslic3r is AGPL-3.0. This app, as a derivative work, is also AGPL-3.0.
