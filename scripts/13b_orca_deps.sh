#!/usr/bin/env bash
# Build the libraries OrcaSlicer's libslic3r needs on top of the PrusaSlicer
# deps: Eigen 5 (headers), NLopt, libnoise, draco and libjpeg-turbo. Versions
# match OrcaSlicer's own deps/ recipes. Everything installs into $ORCA_PREFIX.
source "$(dirname "$0")/common.sh"
require_toolchain; require_sysroot

SENTINEL="$ORCA_PREFIX/lib/libjpeg.a"
already_done "$SENTINEL" && exit 0
mkdir -p "$ORCA_PREFIX"

ORCA_CMAKE=("${CMAKE_COMMON[@]}" -DCMAKE_INSTALL_PREFIX="$ORCA_PREFIX"
            -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_PREFIX_PATH="$ORCA_PREFIX;$IOS_SYSROOT")

# fetch <name> <url>  → unpacked source dir in $IOS_SOURCES/orca-deps/<name>
fetch() {
    local name="$1" url="$2" dir="$IOS_SOURCES/orca-deps/$1"
    if [ ! -d "$dir" ]; then
        mkdir -p "$IOS_SOURCES/orca-deps/tmp-$name"
        curl -fsSL "$url" -o "$IOS_SOURCES/orca-deps/$name.archive"
        case "$url" in
            *.zip) unzip -q "$IOS_SOURCES/orca-deps/$name.archive" -d "$IOS_SOURCES/orca-deps/tmp-$name" ;;
            *)     tar -xf "$IOS_SOURCES/orca-deps/$name.archive" -C "$IOS_SOURCES/orca-deps/tmp-$name" ;;
        esac
        mv "$IOS_SOURCES/orca-deps/tmp-$name"/* "$dir"
        rm -rf "$IOS_SOURCES/orca-deps/tmp-$name" "$IOS_SOURCES/orca-deps/$name.archive"
    fi
    echo "$dir"
}

# build <name> <src> [cmake args...]
build() {
    local name="$1" src="$2"; shift 2
    local build_dir="$IOS_SOURCES/orca-deps/build-$name-$BUILD_SUFFIX"
    log_step "Building $name"
    rm -rf "$build_dir"
    cmake -S "$src" -B "$build_dir" "${ORCA_CMAKE[@]}" "$@" > "$build_dir.log" 2>&1 \
        || { tail -30 "$build_dir.log"; exit 1; }
    cmake --build "$build_dir" -j"$NCPU" --target install >> "$build_dir.log" 2>&1 \
        || { grep -E 'error|FAILED' "$build_dir.log" | head -30; exit 1; }
    log_ok "$name → $ORCA_PREFIX"
}

EIGEN=$(fetch eigen https://gitlab.com/libeigen/eigen/-/archive/5.0.1/eigen-5.0.1.zip)
build eigen "$EIGEN" -DBUILD_TESTING=OFF -DEIGEN_BUILD_DOC=OFF -DEIGEN_BUILD_PKGCONFIG=OFF \
    -DEIGEN_BUILD_BLAS=OFF -DEIGEN_BUILD_LAPACK=OFF

NLOPT=$(fetch nlopt https://github.com/stevengj/nlopt/archive/v2.5.0.tar.gz)
build nlopt "$NLOPT" -DNLOPT_PYTHON=OFF -DNLOPT_OCTAVE=OFF -DNLOPT_MATLAB=OFF \
    -DNLOPT_GUILE=OFF -DNLOPT_SWIG=OFF -DNLOPT_TESTS=OFF

NOISE=$(fetch libnoise https://github.com/SoftFever/Orca-deps-libnoise/archive/refs/tags/1.0.zip)
build libnoise "$NOISE"

DRACO=$(fetch draco https://github.com/google/draco/archive/refs/tags/1.5.7.zip)
build draco "$DRACO" -DDRACO_TRANSCODER_SUPPORTED=OFF -DDRACO_JS_GLUE=OFF

# No SIMD: libjpeg-turbo's NEON asm needs gas-preprocessor quirks on iOS and
# JPEG is only used for thumbnails.
JPEG=$(fetch jpeg https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/3.0.1.zip)
build jpeg "$JPEG" -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_SIMD=OFF -DWITH_TURBOJPEG=OFF \
    -DWITH_JPEG8=ON

log_ok "Orca deps installed in $ORCA_PREFIX"
