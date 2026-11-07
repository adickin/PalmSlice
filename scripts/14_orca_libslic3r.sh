#!/usr/bin/env bash
# Build OrcaSlicer's libslic3r (GUI off, SLIC3R_IOS on) into $ORCA_PREFIX.
source "$(dirname "$0")/common.sh"
require_toolchain; require_sysroot

SENTINEL="$ORCA_PREFIX/lib/libslic3r.a"
already_done "$SENTINEL" && exit 0

if [ ! -f "$ORCA_SRC/src/libslic3r/ios_shims/openssl/md5.h" ]; then
    log_error "OrcaSlicer not cloned/patched. Run 13_orcaslicer.sh first."
    exit 1
fi

log_step "Building OrcaSlicer libslic3r"
BUILD="$IOS_SOURCES/orca-libslic3r-build-$BUILD_SUFFIX"
# Configure from scratch every time (see 10_libslic3r.sh: re-configuring with
# -DCMAKE_CXX_FLAGS drops the toolchain's -fvisibility=hidden).
rm -rf "$BUILD"
mkdir -p "$BUILD"
LOG="$IOS_SOURCES/orca_libslic3r"
# Must match the defines 07_boost.sh compiled Boost with: they change the layout
# of Boost's refcounts, and a mismatch crashes inside Boost.Log/Filesystem.
BOOST_ABI_DEFINES="-DBOOST_AC_USE_PTHREADS -DBOOST_SP_USE_PTHREADS"

cmake -S "$ORCA_SRC" -B "$BUILD" \
    "${CMAKE_COMMON[@]}" \
    -DCMAKE_INSTALL_PREFIX="$ORCA_PREFIX" \
    -DCMAKE_PREFIX_PATH="$ORCA_PREFIX;$IOS_SYSROOT" \
    -DCMAKE_FIND_ROOT_PATH="$ORCA_PREFIX;$IOS_SYSROOT" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DSLIC3R_GUI=OFF \
    -DSLIC3R_IOS=ON \
    -DBUILD_TESTS=OFF \
    -DSLIC3R_STATIC=ON \
    -DSLIC3R_PCH=OFF \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_CXX_FLAGS="-idirafter $ORCA_PREFIX/include -idirafter $IOS_SYSROOT/include -Wno-missing-template-arg-list-after-template-kw -Wno-deprecated-declarations $BOOST_ABI_DEFINES" \
    -DCMAKE_C_FLAGS="-idirafter $IOS_SYSROOT/include" \
    -DBoost_NO_SYSTEM_PATHS=ON \
    -DBoost_USE_STATIC_LIBS=ON \
    -DBoost_USE_STATIC_RUNTIME=ON \
    -DBOOST_ROOT="$IOS_SYSROOT" \
    -DEigen3_DIR="$ORCA_PREFIX/share/eigen3/cmake" \
    -DNLopt_DIR="$ORCA_PREFIX/lib/cmake/nlopt" \
    -Ddraco_DIR="$ORCA_PREFIX/share/cmake/draco" \
    -DJPEG_INCLUDE_DIR="$ORCA_PREFIX/include" \
    -DJPEG_LIBRARY="$ORCA_PREFIX/lib/libjpeg.a" \
    -DZLIB_ROOT="$IOS_SYSROOT" \
    -DPNG_ROOT="$IOS_SYSROOT" \
    -DEXPAT_ROOT="$IOS_SYSROOT" \
    -DTBB_DIR="$IOS_SYSROOT/lib/cmake/TBB" \
    -DCGAL_DIR="$IOS_SYSROOT/lib/cmake/CGAL" \
    > "$LOG"_cmake.log 2>&1 || { grep -B2 -A12 'CMake Error' "$LOG"_cmake.log | head -60; exit 1; }

log_step "Compiling libslic3r (this takes several minutes)..."
set +e
cmake --build "$BUILD" -j"$NCPU" --target libslic3r -- -k 0 > "$LOG"_build.log 2>&1
BUILD_STATUS=$?
set -e
if [ $BUILD_STATUS -ne 0 ]; then
    grep -E '(error:|FAILED)' "$LOG"_build.log | head -40
    log_error "Build failed — full log: ${LOG}_build.log"
    exit 1
fi

# ── Install libs + headers into $ORCA_PREFIX ─────────────────────────────────
mkdir -p "$ORCA_PREFIX/lib" "$ORCA_PREFIX/include"
cp "$BUILD/src/libslic3r/liblibslic3r.a"      "$ORCA_PREFIX/lib/libslic3r.a.tmp"
cp "$BUILD/src/libslic3r/liblibslic3r_cgal.a" "$ORCA_PREFIX/lib/libslic3r_cgal.a"
# Orca's bundled deps (its clipper/admesh/etc. differ from PrusaSlicer's, so
# they must not be mixed with the copies in $IOS_SYSROOT/lib)
for lib in $(find "$BUILD/deps_src" "$BUILD/lib" -name '*.a'); do
    cp "$lib" "$ORCA_PREFIX/lib/"
done

rm -rf "$ORCA_PREFIX/include/libslic3r" "$ORCA_PREFIX/include/orca_deps"
cp -R "$ORCA_SRC/src/libslic3r" "$ORCA_PREFIX/include/libslic3r"
cp "$BUILD/src/libslic3r/libslic3r_version.h" "$ORCA_PREFIX/include/libslic3r/"
# Header-only/bundled deps, laid out like deps_src. The app adds
# orca_deps/{,admesh,clipper,clipper2/Clipper2Lib/include,glu-libtess/include,
# libigl,libnest2d/include,miniz,semver} to its header search paths.
cp -R "$ORCA_SRC/deps_src" "$ORCA_PREFIX/include/orca_deps"
mkdir -p "$ORCA_PREFIX/include/openssl"
cp "$ORCA_SRC/src/libslic3r/ios_shims/openssl/md5.h" "$ORCA_PREFIX/include/openssl/"

# Sentinel last, so an interrupted install re-runs
mv "$ORCA_PREFIX/lib/libslic3r.a.tmp" "$SENTINEL"
log_ok "OrcaSlicer libslic3r → $ORCA_PREFIX"
