# Additional Notes — PalmSlice

Reference material removed from CLAUDE.md for brevity. Last reviewed 2026-10-24 (PrusaSlicer 2.9.6).

## Additional Key Paths

| Path | Purpose |
|------|---------|
| `~/ios-sources/` | All cloned source repos |
| `~/ios-toolchain/ios.toolchain.cmake` | leetal/ios-cmake toolchain |

## PrusaSlicer Modifications

We patch the PrusaSlicer source tree directly. All changes are gated on the `SLIC3R_IOS` cmake option so the upstream desktop build is unaffected.

**Files modified:**
- `~/ios-sources/PrusaSlicer/CMakeLists.txt` — added `SLIC3R_IOS` option; gated CURL, OpenGL/GLEW, NLopt, OpenVDB
- `~/ios-sources/PrusaSlicer/src/CMakeLists.txt` — gated `libseqarrange` add_subdirectory and PrusaSlicer install block
- `~/ios-sources/PrusaSlicer/src/libslic3r/CMakeLists.txt` — excluded JPEG; swapped stub source files; gated libseqarrange link
- `~/ios-sources/PrusaSlicer/src/sla-time-estimates/CMakeLists.txt` — skips the `sla_time_estimate_app` executable on iOS

The changes live in `patches/prusaslicer_ios.patch` and are applied by step 02; see BUILDING.md "Updating PrusaSlicer".

**Stub files added to PrusaSlicer source:**
- `src/libslic3r/ArrangeHelper_ios_stub.cpp` — replaces ArrangeHelper.cpp; `check_seq_conflict` returns nullopt
- `src/libslic3r/GCode/Thumbnails_ios_stub.cpp` — replaces Thumbnails.cpp; compress_thumbnail returns empty buffer

**Stub headers in sysroot** (`~/ios-sysroot-sim/include/`):
- `libseqarrange/seq_interface.hpp` — Sequential types as forward-declared pointers, no Z3
- `nlopt.h` — from NLopt 2.5.0 source (header only; SLA code compiles but is never called in FDM path)
- `nanosvg/nanosvg.h` — from fltk/nanosvg fork

## Adding a New Dependency

1. Write a numbered script in `scripts/` following the existing pattern (source `common.sh`, check sentinel, build, install to `$IOS_SYSROOT`).
2. Add it to `build.sh` in the correct order.
3. If it needs a cmake package config, either install it from the build or hand-write a minimal `*Config.cmake` in `$IOS_SYSROOT/lib/cmake/<name>/`.
4. Add any headers that libslic3r or the bridge includes to `$IOS_SYSROOT/include/`.
5. Add the `.a` to `OTHER_LDFLAGS` in `app/project.yml`.
6. Run `xcodegen` and verify the app still links.

## Additional Common Failure Modes

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `file not found` for a bundled dep header | XCFramework headers dir doesn't include bundled_deps | Add the missing header to `$IOS_SYSROOT/include/` and regenerate the XCFramework |
| `MACOSX_BUNDLE` error on an executable target | iOS toolchain treats all executables as app bundles | Write a custom CMakeLists that omits the executable, or gate it with `SLIC3R_IOS` |
| Boost static runtime mismatch | Boost built with `runtime-link=static` but cmake finder not told | Ensure `Boost_USE_STATIC_RUNTIME=ON` is passed |
| `export()` call fails at cmake configure | Upstream uses `export()` which requires shared lib targets iOS doesn't have | Write a custom minimal CMakeLists (see Qhull and heatshrink scripts for examples) |

## libslic3r API Notes

Check the actual commit: `cd ~/ios-sources/PrusaSlicer && git log --oneline -1`

Key call sites in `slicer_bridge.cpp` to watch when updating PrusaSlicer:
- `Slic3r::load_stl(path, &model, nullptr)` — returns bool (STL only; 3MF/OBJ/AMF go through the format loaders in `slicer_import_model_file`)
- `print.apply(model, std::move(config))` — takes model + moved config
- `print.process()` — blocks; progress comes from `print.set_status_callback`
- `PresetBundle` — loads the vendor profiles (`slicer_presets_load`)
- `print.export_gcode(path, nullptr, nullptr)` — third arg is thumbnail callback
