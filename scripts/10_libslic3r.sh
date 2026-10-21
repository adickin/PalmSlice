#!/usr/bin/env bash
# Build libslic3r from the full PrusaSlicer source tree.
# Uses -DSLIC3R_GUI=OFF to skip all wxWidgets/GUI targets.
source "$(dirname "$0")/common.sh"
require_toolchain; require_sysroot

SENTINEL="$IOS_SYSROOT/lib/libslic3r.a"
already_done "$SENTINEL" && exit 0

if [ ! -d "$PRUSA_SRC/.git" ]; then
    log_error "PrusaSlicer not cloned. Run 02_prusaslicer.sh first."
    exit 1
fi

log_step "Building libslic3r"
BUILD="$IOS_SOURCES/libslic3r-build-$BUILD_SUFFIX"
reset_stale_cmake_build "$BUILD"
mkdir -p "$BUILD"

# Gather all Boost library paths for explicit passing
BOOST_LIBS=""
for lib in atomic chrono date_time filesystem iostreams log log_setup \
           program_options regex system thread; do
    f="$IOS_SYSROOT/lib/libboost_${lib}.a"
    [ -f "$f" ] && BOOST_LIBS="$BOOST_LIBS;$f"
done

cmake -S "$PRUSA_SRC" -B "$BUILD" \
    "${CMAKE_COMMON[@]}" \
    -DCMAKE_PREFIX_PATH="$IOS_SYSROOT" \
    -DCMAKE_FIND_ROOT_PATH="$IOS_SYSROOT" \
    \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DSLIC3R_GUI=OFF \
    -DSLIC3R_IOS=ON \
    -DSLIC3R_BUILD_TESTS=OFF \
    -DSLIC3R_OPENEXR=OFF \
    -DSLIC3R_ENABLE_FORMAT_STEP=OFF \
    -DSLIC3R_STATIC=ON \
    -DSLIC3R_PCH=OFF \
    \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_CXX_FLAGS="-I$IOS_SYSROOT/include -Wno-missing-template-arg-list-after-template-kw" \
    -DCMAKE_C_FLAGS="-I$IOS_SYSROOT/include" \
    \
    -DBoost_NO_SYSTEM_PATHS=ON \
    -DBoost_USE_STATIC_LIBS=ON \
    -DBoost_USE_STATIC_RUNTIME=ON \
    -DBOOST_ROOT="$IOS_SYSROOT" \
    -DBoost_INCLUDE_DIR="$IOS_SYSROOT/include" \
    -DBoost_LIBRARY_DIR="$IOS_SYSROOT/lib" \
    \
    -DEIGEN3_INCLUDE_DIR="$IOS_SYSROOT/include/eigen3" \
    -DZLIB_ROOT="$IOS_SYSROOT" \
    -DPNG_ROOT="$IOS_SYSROOT" \
    -DEXPAT_ROOT="$IOS_SYSROOT" \
    \
    -DTbb_DIR="$IOS_SYSROOT/lib/cmake/TBB" \
    \
    -DCGAL_DIR="$IOS_SYSROOT/lib/cmake/CGAL" \
    -Dnlohmann_json_DIR="$IOS_SYSROOT/lib/cmake/nlohmann_json" \
    \
    2>&1 | tee "$IOS_SOURCES/libslic3r_cmake.log"

# Remove any previous output so a failed build can't install a stale library.
find "$BUILD" -name 'liblibslic3r.a' -delete

log_step "Compiling libslic3r (this takes several minutes)..."
# Clang 19+ (Xcode 16.3+) makes -Wmissing-template-arg-list-after-template-kw an
# error by default; the Boost and CGAL 5.6.2 headers trip it. Disabled above.
set +e
cmake --build "$BUILD" -j"$NCPU" \
    --target libslic3r slic3r-arrange slic3r-arrange-wrapper \
    > "$IOS_SOURCES/libslic3r_build.log" 2>&1
BUILD_STATUS=$?
set -e
grep -E '(error:|FAILED)' "$IOS_SOURCES/libslic3r_build.log" | head -40 || true
if [ $BUILD_STATUS -ne 0 ]; then
    log_error "libslic3r build failed (exit $BUILD_STATUS). See $IOS_SOURCES/libslic3r_build.log"
    exit 1
fi

# Find and install the library + headers
LIB=$(find "$BUILD" -name 'liblibslic3r.a' | head -1)
if [ -z "$LIB" ]; then
    log_error "libslic3r.a not found after build. Check $IOS_SOURCES/libslic3r_build.log"
    exit 1
fi

mkdir -p "$IOS_SYSROOT/lib"
cp "$LIB" "$IOS_SYSROOT/lib/libslic3r.a"

# Also install libslic3r_cgal
CGAL_LIB=$(find "$BUILD" -name 'liblibslic3r_cgal.a' | head -1)
[ -n "$CGAL_LIB" ] && cp "$CGAL_LIB" "$IOS_SYSROOT/lib/libslic3r_cgal.a"

# Install headers: copy src/libslic3r into sysroot include
mkdir -p "$IOS_SYSROOT/include/libslic3r"
cp -R "$PRUSA_SRC/src/libslic3r/." "$IOS_SYSROOT/include/libslic3r/"

# Install slic3r-arrange and slic3r-arrange-wrapper (built as part of libslic3r)
for arrange_lib in libslic3r-arrange.a libslic3r-arrange-wrapper.a; do
    FOUND=$(find "$BUILD" -name "$arrange_lib" | head -1)
    [ -n "$FOUND" ] && cp "$FOUND" "$IOS_SYSROOT/lib/$arrange_lib"
done

# Install bundled dep static libs built by libslic3r (admesh, miniz, etc.)
for bundled_lib in libadmesh.a libminiz_static.a liblocalesutils.a \
                   libsemver.a libglu-libtess.a libqoi.a libclipper.a \
                   libprusa_fdm_mixer.a libsla_time_estimate.a; do
    FOUND=$(find "$BUILD" -name "$bundled_lib" | head -1)
    [ -n "$FOUND" ] && cp "$FOUND" "$IOS_SYSROOT/lib/$bundled_lib"
done

# Install cmake-generated libslic3r_version.h into sysroot
VERSION_H=$(find "$BUILD" -name 'libslic3r_version.h' | head -1)
[ -n "$VERSION_H" ] && cp "$VERSION_H" "$IOS_SYSROOT/include/libslic3r/libslic3r_version.h"

log_ok "libslic3r installed"
log_ok "  Library  → $IOS_SYSROOT/lib/libslic3r.a"
log_ok "  Headers  → $IOS_SYSROOT/include/libslic3r/"
