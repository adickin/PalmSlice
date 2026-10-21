#!/usr/bin/env bash
# Shared variables and helpers for all build scripts
# Source this file at the top of each script:  source "$(dirname "$0")/common.sh"

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
export PROJECT_ROOT="$HOME/work/IosSlicer"
export IOS_SOURCES="$HOME/ios-sources"           # cloned repos live here
export IOS_SYSROOT=""   # set below based on PLATFORM
export IOS_TOOLCHAIN="$HOME/ios-toolchain/ios.toolchain.cmake"
export PRUSA_SRC="$IOS_SOURCES/PrusaSlicer"
# Pinned upstream versions. When bumping PRUSA_TAG, also set LIBBGCODE_COMMIT to
# the commit in PrusaSlicer's deps/+LibBGCode/LibBGCode.cmake for that tag, and
# re-check patches/prusaslicer_ios.patch (see BUILDING.md "Updating PrusaSlicer").
export PRUSA_TAG="version_2.9.6"
export LIBBGCODE_COMMIT="6f4ad7ce6b0e638b760199d6611039a610a5a479"

# ── Build config ─────────────────────────────────────────────────────────────
# PLATFORM can be overridden by the caller:
#   PLATFORM=OS64 ./build.sh   →  real device (arm64-apple-ios)
#   (default)                  →  simulator   (arm64-apple-ios-simulator)
export PLATFORM="${PLATFORM:-SIMULATORARM64}"
export DEPLOYMENT_TARGET="16.0"
export NCPU=$(sysctl -n hw.ncpu)

# Derive per-platform helpers from PLATFORM
if [ "$PLATFORM" = "OS64" ]; then
    export IOS_SYSROOT="$HOME/ios-sysroot-dev"
    export IOS_SDK="iphoneos"
    export IOS_TARGET_TRIPLE="arm64-apple-ios${DEPLOYMENT_TARGET}"
    export BUILD_SUFFIX="ios-dev"
else
    export IOS_SYSROOT="$HOME/ios-sysroot-sim"
    export IOS_SDK="iphonesimulator"
    export IOS_TARGET_TRIPLE="arm64-apple-ios${DEPLOYMENT_TARGET}-simulator"
    export BUILD_SUFFIX="ios-sim"
fi

export CMAKE_COMMON=(
  -G Ninja
  -DCMAKE_TOOLCHAIN_FILE="$IOS_TOOLCHAIN"
  -DPLATFORM="$PLATFORM"
  -DDEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$IOS_SYSROOT"
  -DBUILD_SHARED_LIBS=OFF
)

# ── Logging ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_step()  { echo -e "\n${BLUE}══▶${NC} $*"; }
log_ok()    { echo -e "${GREEN}  ✓${NC} $*"; }
log_warn()  { echo -e "${YELLOW}  ⚠${NC} $*"; }
log_error() { echo -e "${RED}  ✗${NC} $*"; }

# ── Guards ───────────────────────────────────────────────────────────────────
require_toolchain() {
    if [ ! -f "$IOS_TOOLCHAIN" ]; then
        log_error "Toolchain not found. Run 01_toolchain.sh first."
        exit 1
    fi
}

require_sysroot() {
    mkdir -p "$IOS_SYSROOT" "$IOS_SOURCES"
}

# Skip if already installed (pass a file that signals completion)
# Delete a CMake build dir whose cached iOS SDK no longer exists (e.g. after an
# Xcode update). A stale cache makes clang silently target Mac Catalyst.
reset_stale_cmake_build() {
    local build_dir="$1"
    local cache="$build_dir/CMakeCache.txt"
    [ -f "$cache" ] || return 0
    local sdk
    sdk=$(sed -n 's/^CMAKE_OSX_SYSROOT_INT:INTERNAL=//p' "$cache")
    if [ -n "$sdk" ] && [ ! -d "$sdk" ]; then
        log_warn "Cached SDK $sdk is gone — wiping $build_dir"
        rm -rf "$build_dir"
    fi
}

already_done() {
    local sentinel="$1"
    if [ -f "$sentinel" ]; then
        log_ok "Already built — skipping. (delete $sentinel to rebuild)"
        return 0
    fi
    return 1
}
