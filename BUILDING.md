# Building PalmSlice

Build instructions for compiling the dependency chain and running the app in Xcode. For an overview of what the app does, see [README.md](README.md).

## Prerequisites

- macOS with Xcode 16+ installed (not just CLI tools — full Xcode)
- Apple Silicon Mac recommended (builds target `SIMULATORARM64` by default)
- Homebrew

Everything else (cmake, ninja, xcodegen, …) is installed by step 00.
CGAL 5.6.2 is downloaded from GitHub by step 13 — do **not** `brew install cgal`
(Homebrew ships CGAL 6.x which has an incompatible API).

## Build

```bash
# Clone this repo, then:
./build.sh
```

This runs 22 numbered steps (0–21) in order. Each step is **idempotent** — re-running skips steps that are already done. To restart from a specific step:

```bash
./build.sh --from 7    # restart from Boost
./build.sh --only 3    # run only Clipper2 (toolchain smoke test)
```

Device (non-simulator) builds use `build_device.sh`, which mirrors the same steps against `PLATFORM=OS64`, populating `~/ios-sysroot-dev`.

### Steps

| # | Script | What it does | Time |
|---|--------|-------------|------|
| 0 | `00_prerequisites.sh` | `brew install cmake ninja xcodegen …` | ~1 min |
| 1 | `01_toolchain.sh` | Download `ios.toolchain.cmake` from leetal/ios-cmake | seconds |
| 2 | `02_prusaslicer.sh` | `git clone` PrusaSlicer + submodules + apply iOS patches | ~5 min |
| 3 | `03_clipper2.sh` | Build Clipper2 — **toolchain smoke test** | ~1 min |
| 4 | `04_eigen.sh` | Copy Eigen3 headers (no compilation) | ~1 min |
| 5 | `05_zlib.sh` | Build zlib | ~1 min |
| 6 | `06_libpng.sh` | Build libpng | ~1 min |
| 7 | `07_boost.sh` | Build Boost via b2 | **20–40 min** |
| 8 | `07b_boost_nowide.sh` | Build boost::nowide (from Boost source tree) | ~1 min |
| 9 | `08_tbb.sh` | Build oneTBB | ~5 min |
| 10 | `09_expat.sh` | Build libexpat | ~1 min |
| 11 | `09b_gmp.sh` | Build GMP (pure-C, no assembly) for CGAL exact arithmetic | ~5 min |
| 12 | `09c_mpfr.sh` | Build MPFR (multi-precision float) | ~3 min |
| 13 | `09d_cgal.sh` | Download + install CGAL 5.6.2 headers + cmake config | ~1 min |
| 14 | `09e_cereal.sh` | Install cereal headers + cmake config | seconds |
| 15 | `09f_qhull.sh` | Build Qhull (convex hull) | ~1 min |
| 16 | `09g_heatshrink.sh` | Build heatshrink (compression, needed by LibBGCode) | ~1 min |
| 17 | `09h_libbgcode.sh` | Build LibBGCode (Prusa binary gcode format) | ~2 min |
| 18 | `10_libslic3r.sh` | Build libslic3r from full PrusaSlicer tree | ~10 min |
| 19 | `10b_install_stub_headers.sh` | Install stub headers (seq, nlopt, nanosvg, bundled deps) | ~1 min |
| 20 | `11_xcframework.sh` | Package `libslic3r.a` as XCFramework | seconds |
| 21 | `12_vendor_profiles.sh` | Copy PrusaSlicer's vendor profile bundles (`resources/profiles/*.ini`, FFF only) into `app/PalmSlice/PrusaSlicerProfiles/vendor` | seconds |

Step 21 also copies `profiles/PalmSlice.ini`, PalmSlice's own vendor bundle for printers PrusaSlicer doesn't have (the Snapmaker U1, ported from OrcaSlicer). It's generated: edit `scripts/profiles/make_palmslice_bundle.py` and run `python3 scripts/profiles/make_palmslice_bundle.py profiles/PalmSlice.ini`, then step 21. `SnapmakerU1Tests` checks every key in it is a real PrusaSlicer setting (unknown keys are dropped silently on load).

The vendor profiles are committed, so a fresh clone builds without step 21. Every slice starts from them: the printer's PrusaSlicer preset, its default print preset and a matching filament preset are applied first, then the PalmSlice profiles on top (see `PresetLibrary.swift`).

All deps install into `~/ios-sysroot-sim/`. All source repos clone into `~/ios-sources/`.

**Note:** Steps 11–13 (GMP/MPFR/CGAL) were required because libslic3r uses CGAL for Voronoi diagrams in the Arachne variable-width perimeter algorithm — which is in the active FDM path. GMP is built with `--disable-assembly` (pure C) and `--enable-cxx` (C++ bindings).

## Open in Xcode

After `build.sh` completes:

```bash
cd app

# One-time: set your Apple Developer Team ID for code signing
cp project.local.yml.example project.local.yml
# Edit project.local.yml and replace XXXXXXXXXX with your Team ID.
# Find it with:
#   security find-identity -v -p codesigning | grep "Apple Development"
# It's the string in parentheses, e.g. "Apple Development: Your Name (XXXXXXXXXX)"
# project.local.yml is gitignored — never commit it.

xcodegen
open PalmSlice.xcodeproj
```

Select the **iPhone simulator** target, hit **⌘R**. The app builds and runs in the simulator.

## PrusaSlicer Modifications

libslic3r is built from the PrusaSlicer source tree, pinned to the release tag `PRUSA_TAG` in `scripts/common.sh` (currently **2.9.6**), with two categories of changes:

### CMake option: `SLIC3R_IOS`

Added to `CMakeLists.txt` and `src/libslic3r/CMakeLists.txt`. When `ON`:
- **CURL / OpenGL / GLEW / NLopt / OpenVDB** — skipped entirely (not used by FDM slicing)
- **Z3 / libseqarrange** — excluded from build (sequential arrangement is a GUI feature)
- **JPEG** — excluded (only used for gcode thumbnails, which are optional)
- **PrusaSlicer binary install** — skipped (iOS toolchain would treat it as a MACOSX_BUNDLE)
- **`sla_time_estimate_app`** (`src/sla-time-estimates/CMakeLists.txt`) — skipped for the same reason; only its static library is linked

### Stub source files

Two small stub `.cpp` files are compiled instead of their JPEG/Z3-dependent originals:

| Stub file | Replaces | What it does |
|-----------|----------|-------------|
| `src/libslic3r/GCode/Thumbnails_ios_stub.cpp` | `Thumbnails.cpp` | Upstream's PNG encoder and `thumbnails` parser; JPG/QOI return empty buffers (no libjpeg on iOS) |
| `src/libslic3r/ArrangeHelper_ios_stub.cpp` | `ArrangeHelper.cpp` | `check_seq_conflict` returns `nullopt`; sequential arrange is never invoked in basic FDM |

### Stub headers in `~/ios-sysroot-sim/include/`

| Header | Why needed |
|--------|-----------|
| `libseqarrange/seq_interface.hpp` | `ArrangeHelper.hpp` is included by `Print.cpp`; stub provides Sequential types as forward-declared pointers without Z3 |
| `nlopt.h` | Included by `NLoptOptimizer.hpp` (SLA code); SLA is never called in FDM path |
| `nanosvg/nanosvg.h` | Included by `EmbossShape.hpp`; embossing is not in the slicing path |

### Updating PrusaSlicer

1. Pick the new release tag and set `PRUSA_TAG` in `scripts/common.sh`. Set `LIBBGCODE_COMMIT` to the commit in that tag's `deps/+LibBGCode/LibBGCode.cmake`.
2. Move the source tree: `git -C ~/ios-sources/PrusaSlicer fetch --depth=1 origin tag <tag> && git -C ~/ios-sources/PrusaSlicer checkout -- . && git -C ~/ios-sources/PrusaSlicer checkout <tag>`, and delete the two `*_ios_stub.cpp` files from it. Run this and step 3 from the root of this repo.
3. `git -C ~/ios-sources/PrusaSlicer apply --reject < patches/prusaslicer_ios.patch`, fix any `.rej` hunks by hand, copy the stub `.cpp` files back in (step 02 does this), then regenerate the patch: `git -C ~/ios-sources/PrusaSlicer diff HEAD -- CMakeLists.txt src/CMakeLists.txt src/libslic3r/CMakeLists.txt src/sla-time-estimates/CMakeLists.txt > patches/prusaslicer_ios.patch`.
4. Check `git diff <old> <new> -- src/libslic3r/ArrangeHelper.hpp src/libslic3r/GCode/Thumbnails.hpp` — the stubs must still match those headers.
5. Look for new libraries linked by `src/libslic3r/CMakeLists.txt`; add each `.a` to the bundled-lib loop in `scripts/10_libslic3r.sh` and to `OTHER_LDFLAGS` in `app/project.yml`.
6. Delete the `libbgcode_core.a` and `libslic3r.a` sentinels in both sysroots, run steps 17 and 18 for simulator and device (`PLATFORM=OS64`), then steps 20 and 21, `xcodegen`, and the test suite.
7. Vendor presets get renamed upstream now and then. `PrinterProfileSliceTests` fails if a built-in printer's `systemPreset` (`BuiltInProfiles.systemPresetNames`) no longer exists; `PresetDriftTests` fails if a setting PalmSlice doesn't control stops matching the vendor preset.

## Known Friction Points

| Step | Likely issue | Fix |
|------|-------------|-----|
| Boost (7) | Build time ~30 min on first run | Let it run; subsequent runs skip via sentinel |
| GMP (11) | `--disable-assembly` makes it slower but portable to iOS simulator | No action needed; it's intentional |
| CGAL version | PrusaSlicer 2.7–2.9 uses CGAL 5.6.2 API; CGAL 6.x changed `property_map()` return type | Script installs CGAL 5.6.2 headers from source, not homebrew |
| libslic3r (18) | `Print::apply()` / `export_gcode()` signature may differ from cloned version | Check `git log` in `~/ios-sources/PrusaSlicer`; adjust the flagged lines in `slicer_bridge.cpp` |
| Xcode link | Missing `.a` symbols at link time | Verify `~/ios-sysroot-sim/lib/` has all expected files; cross-check `OTHER_LDFLAGS` in `app/project.yml` |
| Xcode update | CMake caches keep the old SDK path; if that SDK is gone, clang silently targets Mac Catalyst and the XCFramework step fails with a duplicate `ios-arm64-maccatalyst` slice | Steps 17 and 18 now wipe a build dir whose cached SDK no longer exists; for other steps, delete the build dir by hand |
| Clang 19+ (Xcode 16.3+) | `error: a template argument list is expected after a name prefixed by the template keyword` in Boost / CGAL headers | Step 18 passes `-Wno-missing-template-arg-list-after-template-kw` |
| `cmake_minimum_required < 3.5` error | CMake 4.x broke older projects | Add `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` to the cmake invocation |
| Undefined symbol at link | A new dep was added to libslic3r but not to `OTHER_LDFLAGS` | Add the `.a` path to `app/project.yml` and run `xcodegen` |
| Boost.Filesystem in the bridge | `directory_iterator` entries come back with empty paths when called from `slicer_bridge.cpp` (header/library config mismatch); libslic3r's own Boost use is fine | Use `std::filesystem` in bridge code |

## Project Layout

```
PalmSlice/
├── README.md
├── BUILDING.md
├── CHANGELOG.md
├── build.sh                          ← master build entry point (steps 0–21, simulator)
├── build_device.sh                   ← mirrors build.sh for PLATFORM=OS64 (device)
├── patches/
│   ├── prusaslicer_ios.patch         ← CMakeLists changes (SLIC3R_IOS option)
│   ├── ArrangeHelper_ios_stub.cpp    ← stub: no-op sequential arrange (no Z3)
│   └── Thumbnails_ios_stub.cpp       ← stub: empty thumbnails (no JPEG)
├── scripts/
│   ├── common.sh                     ← shared env vars + helpers
│   ├── 00_prerequisites.sh
│   ├── 01_toolchain.sh
│   ├── 02_prusaslicer.sh             ← clone + apply patches/
│   ├── 03_clipper2.sh
│   ├── 04_eigen.sh
│   ├── 05_zlib.sh
│   ├── 06_libpng.sh
│   ├── 07_boost.sh
│   ├── 07b_boost_nowide.sh
│   ├── 08_tbb.sh
│   ├── 09_expat.sh
│   ├── 09b_gmp.sh
│   ├── 09c_mpfr.sh
│   ├── 09d_cgal.sh                   ← downloads CGAL 5.6.2 from GitHub
│   ├── 09e_cereal.sh
│   ├── 09f_qhull.sh
│   ├── 09g_heatshrink.sh
│   ├── 09h_libbgcode.sh
│   ├── 10_libslic3r.sh
│   ├── 10b_install_stub_headers.sh   ← seq stub, nlopt.h, nanosvg, bundled deps
│   ├── 11_xcframework.sh
│   └── 12_vendor_profiles.sh         ← PrusaSlicer vendor presets → app bundle
└── app/
    ├── project.yml                   ← xcodegen spec (links ~40 static libs)
    ├── PalmSlice/
    │   ├── PalmSliceApp.swift
    │   ├── ContentView.swift
    │   ├── slicer_bridge.h           ← C API visible to Swift
    │   ├── slicer_bridge.cpp         ← libslic3r wrapper
    │   ├── PalmSlice-Bridging-Header.h
    │   ├── PresetLibrary.swift       ← loads the vendor presets, applies them per slice
    │   ├── PrusaSlicerProfiles/vendor/ ← vendor .ini bundles (step 21, committed)
    │   └── Resources/
    │       └── cube.stl              ← 20mm test model
    └── PalmSliceTests/               ← XCTest target (fixtures in Fixtures/)
```
