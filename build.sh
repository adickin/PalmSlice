#!/usr/bin/env bash
# Master build script — runs all steps in order.
# Each step is idempotent: delete the sentinel file to force a rebuild.
#
# Usage:
#   ./build.sh           # run all steps
#   ./build.sh --from 7  # start from step 7 (Boost)
#   ./build.sh --only 3  # run only step 3 (Clipper2)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/scripts" && pwd)"

START_STEP=0
ONLY_STEP=-1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from) START_STEP="$2"; shift 2 ;;
        --only) ONLY_STEP="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

run_step() {
    local num="$1"
    local script="$2"
    local desc="$3"
    if [ "$ONLY_STEP" -ne -1 ] && [ "$ONLY_STEP" -ne "$num" ]; then return; fi
    if [ "$num" -lt "$START_STEP" ]; then return; fi
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Step $num: $desc"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    bash "$SCRIPT_DIR/$script"
}

# ── Toolchain & source ────────────────────────────────────────────────────────
run_step  0 "00_prerequisites.sh"  "Install build tools (cmake, ninja, xcodegen)"
run_step  1 "01_toolchain.sh"      "Download iOS CMake toolchain"
run_step  2 "13_orcaslicer.sh"     "Clone OrcaSlicer + apply iOS patch"

# ── Core C deps ───────────────────────────────────────────────────────────────
run_step  3 "05_zlib.sh"           "Build zlib"
run_step  4 "06_libpng.sh"         "Build libpng"

# ── Boost ─────────────────────────────────────────────────────────────────────
run_step  5 "07_boost.sh"          "Build Boost (longest step ~20-40 min)"
run_step  6 "07b_boost_nowide.sh"  "Build boost::nowide"

# ── Threading / parsing ───────────────────────────────────────────────────────
run_step  7 "08_tbb.sh"            "Build oneTBB"
run_step  8 "09_expat.sh"          "Build libexpat"

# ── Exact arithmetic (CGAL deps) ──────────────────────────────────────────────
run_step  9 "09b_gmp.sh"           "Build GMP (exact arithmetic, no assembly)"
run_step 10 "09c_mpfr.sh"          "Build MPFR (multi-precision float)"
run_step 11 "09d_cgal.sh"          "Install CGAL 5.6.2 headers + cmake config"

# ── Serialization / geometry ──────────────────────────────────────────────────
run_step 12 "09e_cereal.sh"        "Install cereal (header-only serialization)"
run_step 13 "09f_qhull.sh"         "Build Qhull (convex hull)"
run_step 14 "13b_orca_deps.sh"     "Build Eigen 5, NLopt, libnoise, draco, libjpeg-turbo"

# ── libslic3r + packaging ─────────────────────────────────────────────────────
run_step 15 "14_orca_libslic3r.sh" "Build OrcaSlicer libslic3r"
run_step 16 "11_xcframework.sh"    "Package as XCFramework"
run_step 17 "15_orca_profiles.sh"  "Copy OrcaSlicer profiles into the app"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  All steps complete."
echo ""
echo "  Next: generate and open the Xcode project:"
echo "    cd app && xcodegen && open PalmSlice.xcodeproj"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
