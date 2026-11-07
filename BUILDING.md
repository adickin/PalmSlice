# Building PalmSlice

Build instructions for compiling the dependency chain and running the app in Xcode. For an overview of what the app does, see [README.md](README.md).

## Prerequisites

- macOS with Xcode 16+ installed (not just CLI tools — full Xcode)
- Apple Silicon Mac recommended (builds target `SIMULATORARM64` by default)
- Homebrew

Everything else (cmake, ninja, xcodegen, …) is installed by step 00.
CGAL 5.6.2 is downloaded from GitHub by step 11 — do **not** `brew install cgal`
(Homebrew ships CGAL 6.x which has an incompatible API).

## Build

```bash
# Clone this repo, then:
./build.sh
```

This runs 18 numbered steps (0–17) in order. Each step is **idempotent** — re-running skips steps that are already done. To restart from a specific step:

```bash
./build.sh --from 5    # restart from Boost
./build.sh --only 15   # rebuild libslic3r only
```

Device (non-simulator) builds use `build_device.sh`, which mirrors the same steps against `PLATFORM=OS64`, populating `~/ios-sysroot-dev`.

### Steps

| # | Script | What it does | Time |
|---|--------|-------------|------|
| 0 | `00_prerequisites.sh` | `brew install cmake ninja xcodegen …` | ~1 min |
| 1 | `01_toolchain.sh` | Download `ios.toolchain.cmake` from leetal/ios-cmake | seconds |
| 2 | `13_orcaslicer.sh` | `git clone` OrcaSlicer at `ORCA_TAG` + apply the iOS patch and shims | ~3 min |
| 3 | `05_zlib.sh` | Build zlib | ~1 min |
| 4 | `06_libpng.sh` | Build libpng | ~1 min |
| 5 | `07_boost.sh` | Build Boost via b2 | **20–40 min** |
| 6 | `07b_boost_nowide.sh` | Build boost::nowide (from Boost source tree) | ~1 min |
| 7 | `08_tbb.sh` | Build oneTBB | ~5 min |
| 8 | `09_expat.sh` | Build libexpat | ~1 min |
| 9 | `09b_gmp.sh` | Build GMP (pure-C, no assembly) for CGAL exact arithmetic | ~5 min |
| 10 | `09c_mpfr.sh` | Build MPFR (multi-precision float) | ~3 min |
| 11 | `09d_cgal.sh` | Download + install CGAL 5.6.2 headers + cmake config | ~1 min |
| 12 | `09e_cereal.sh` | Install cereal headers + cmake config | seconds |
| 13 | `09f_qhull.sh` | Build Qhull (convex hull) | ~1 min |
| 14 | `13b_orca_deps.sh` | Build the deps only OrcaSlicer needs: Eigen 5 (headers), NLopt, libnoise, draco, libjpeg-turbo | ~3 min |
| 15 | `14_orca_libslic3r.sh` | Build OrcaSlicer's libslic3r (GUI off, `SLIC3R_IOS` on) and install libs + headers | ~10 min |
| 16 | `11_xcframework.sh` | Package `libslic3r.a` as XCFramework | seconds |
| 17 | `15_orca_profiles.sh` | Copy OrcaSlicer's vendor profiles (JSON only) and `info/`, `flush/` data into `app/PalmSlice/OrcaResources` | seconds |

The profiles (~12,000 small JSON files) are generated, not committed: run step 17 after a fresh clone. Every slice starts from them: the printer's OrcaSlicer preset, its default print preset and a matching filament preset are applied first, then the PalmSlice profiles on top (see `PresetLibrary.swift`).

Shared deps install into `~/ios-sysroot-sim/`; OrcaSlicer's libslic3r and the deps only it needs into `~/ios-sysroot-sim/orca/` (`ORCA_PREFIX`). All source repos clone into `~/ios-sources/`.

**Note:** Steps 9–11 (GMP/MPFR/CGAL) are required because libslic3r uses CGAL for Voronoi diagrams in the Arachne variable-width perimeter algorithm — which is in the active FDM path. GMP is built with `--disable-assembly` (pure C) and `--enable-cxx` (C++ bindings).

**Boost ABI:** `07_boost.sh` compiles Boost with `-DBOOST_AC_USE_PTHREADS -DBOOST_SP_USE_PTHREADS`. Everything that includes Boost headers (libslic3r, the bridge) must use the same defines (step 15 and `GCC_PREPROCESSOR_DEFINITIONS` in `app/project.yml` do), or Boost.Log / Boost.Filesystem objects are laid out differently from the prebuilt libraries and crash.

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

## OrcaSlicer Modifications

libslic3r is built from the OrcaSlicer source tree, pinned to the release tag `ORCA_TAG` in `scripts/common.sh` (currently **v2.4.2**). `patches/orcaslicer_ios.patch` (applied by step 2) holds every change; `patches/orca/ios_shims/openssl/md5.h` maps the MD5 calls onto CommonCrypto instead of building OpenSSL.

### CMake option: `SLIC3R_IOS`

Added to `CMakeLists.txt` and `src/libslic3r/CMakeLists.txt`. When `ON`:
- **OpenSSL / CURL / Freetype / OpenGL / glfw / OpenVDB** — not required (GUI, network and SLA-hollowing only)
- **OpenCV / OpenCASCADE** — not built; `ObjColorUtils.cpp`, `Format/STEP.cpp`, `Format/svg.cpp` and `Shape/TextShape.cpp` are left out (OBJ colour clustering, STEP / SVG import and text shapes — desktop GUI features)
- `iOS_gui_shims.cpp` supplies the nanosvg implementation and `RGB2HSV`, which libslic3r takes from the GUI tree

### Source changes (all under `#ifdef SLIC3R_IOS` where they change behaviour)

| File | Change |
|------|--------|
| `Print.hpp` | `m_isBBLPrinter` and `m_origin` initialized (the GUI always sets them; garbage otherwise) |
| `PrintConfig.cpp`, `PrusaSettingsImport.cpp` | PrusaSlicer option names are renamed to OrcaSlicer's in `handle_legacy` (PalmSlice's saved profiles, `.ini` files, PrusaSlicer 3MFs) |
| `Format/3mf.cpp` | The PrusaSlicer 3MF reader keeps project settings, layer-height profiles, height ranges and per-object / per-part settings (upstream Orca drops them), and reads painting version 2 |
| `TriangleSelector.cpp` | Reads PrusaSlicer 2.9's painting states above 16 (its mixes) as unpainted |
| `Config.cpp` | A bad value in a legacy config doesn't abandon the rest |
| `SLA/Hollowing.cpp`, `utils.cpp`, `Model.*` | No OpenVDB / libproc / STEP / SVG; NFC normalization via CoreFoundation instead of Boost.Locale |

### Updating OrcaSlicer

1. Set `ORCA_TAG` in `scripts/common.sh`, then `git -C ~/ios-sources/OrcaSlicer fetch --depth=1 origin tag <tag> && git -C ~/ios-sources/OrcaSlicer checkout -- . && git -C ~/ios-sources/OrcaSlicer clean -fd src && git -C ~/ios-sources/OrcaSlicer checkout <tag>`.
2. `git -C ~/ios-sources/OrcaSlicer apply --reject < patches/orcaslicer_ios.patch`, fix any `.rej` hunks, then regenerate the patch from the Orca tree: `rm -rf src/libslic3r/ios_shims && git add -N src/libslic3r/iOS_gui_shims.cpp src/libslic3r/PrusaSettingsImport.* && git diff > <repo>/patches/orcaslicer_ios.patch && git reset`, and re-run step 2 to restore the shims.
3. Compare `deps/` recipes with `13b_orca_deps.sh` and new libraries linked by `src/libslic3r/CMakeLists.txt` with `OTHER_LDFLAGS` in `app/project.yml`.
4. Delete the `orca/lib/libslic3r.a` sentinel in both sysroots, run step 15 for simulator and device (`PLATFORM=OS64`), then steps 16 and 17, `xcodegen`, and the test suite.
5. Vendor presets get renamed upstream now and then. `PrinterProfileSliceTests` fails if a built-in printer's `systemPreset` (`BuiltInProfiles.systemPresetNames`) no longer exists.

## Known Friction Points

| Step | Likely issue | Fix |
|------|-------------|-----|
| Boost (7) | Build time ~30 min on first run | Let it run; subsequent runs skip via sentinel |
| GMP (11) | `--disable-assembly` makes it slower but portable to iOS simulator | No action needed; it's intentional |
| CGAL version | libslic3r uses the CGAL 5.6 API; CGAL 6.x changed `property_map()` return type | Script installs CGAL 5.6.2 headers from source, not homebrew |
| libslic3r (15) | `Print::apply()` / `export_gcode()` signature may differ from cloned version | Check `git log` in `~/ios-sources/OrcaSlicer`; adjust `slicer_bridge.cpp` |
| Header shadowing | An old PrusaSlicer `libslic3r/` in `~/ios-sysroot-sim/include` shadows OrcaSlicer's | Step 15 adds the sysroot with `-idirafter`; `project.yml` lists `$(ORCA_PREFIX)` paths first |
| Xcode link | Missing `.a` symbols at link time | Verify `~/ios-sysroot-sim/lib/` has all expected files; cross-check `OTHER_LDFLAGS` in `app/project.yml` |
| Xcode update | CMake caches keep the old SDK path; if that SDK is gone, clang silently targets Mac Catalyst and the XCFramework step fails with a duplicate `ios-arm64-maccatalyst` slice | Step 15 and other CMake steps wipe a build dir whose cached SDK no longer exists; for other steps, delete the build dir by hand |
| Clang 19+ (Xcode 16.3+) | `error: a template argument list is expected after a name prefixed by the template keyword` in Boost / CGAL headers | Step 15 passes `-Wno-missing-template-arg-list-after-template-kw` |
| `cmake_minimum_required < 3.5` error | CMake 4.x broke older projects | Add `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` to the cmake invocation |
| Undefined symbol at link | A new dep was added to libslic3r but not to `OTHER_LDFLAGS` | Add the `.a` path to `app/project.yml` and run `xcodegen` |
| Boost crashes / empty paths | Code built without Boost's ABI defines (see Boost ABI above) | Build with `-DBOOST_AC_USE_PTHREADS -DBOOST_SP_USE_PTHREADS` |

## Project Layout

```
PalmSlice/
├── README.md
├── BUILDING.md
├── CHANGELOG.md
├── build.sh                          ← master build entry point (steps 0–17, simulator)
├── build_device.sh                   ← mirrors build.sh for PLATFORM=OS64 (device)
├── patches/
│   ├── orcaslicer_ios.patch          ← all OrcaSlicer changes (SLIC3R_IOS)
│   └── orca/ios_shims/openssl/md5.h  ← MD5 → CommonCrypto
├── scripts/
│   ├── common.sh                     ← shared env vars + helpers (ORCA_TAG, ORCA_PREFIX)
│   ├── 00_prerequisites.sh
│   ├── 01_toolchain.sh
│   ├── 05_zlib.sh … 09f_qhull.sh     ← shared deps (Boost, TBB, GMP, MPFR, CGAL, …)
│   ├── 11_xcframework.sh
│   ├── 13_orcaslicer.sh              ← clone + apply patches/
│   ├── 13b_orca_deps.sh              ← Eigen 5, NLopt, libnoise, draco, libjpeg-turbo
│   ├── 14_orca_libslic3r.sh
│   └── 15_orca_profiles.sh           ← OrcaSlicer vendor presets → app bundle
└── app/
    ├── project.yml                   ← xcodegen spec
    ├── PalmSlice/
    │   ├── PalmSliceApp.swift
    │   ├── ContentView.swift
    │   ├── slicer_bridge.h           ← C API visible to Swift
    │   ├── slicer_bridge.cpp         ← libslic3r wrapper
    │   ├── PalmSlice-Bridging-Header.h
    │   ├── PresetLibrary.swift       ← loads the vendor presets, applies them per slice
    │   ├── OrcaResources/            ← vendor JSON + info/ + flush/ (step 17, gitignored)
    │   └── Resources/
    │       └── cube.stl              ← 20mm test model
    └── PalmSliceTests/               ← XCTest target (fixtures in Fixtures/)
```
