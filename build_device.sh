#!/usr/bin/env bash
# Build all deps + libslic3r for real iOS device (arm64-apple-ios, PLATFORM=OS64).
# Installs into ~/ios-sysroot-dev (separate from the simulator sysroot).
#
# Run the simulator build first (./build.sh) so that step 0-2 have already
# run (tools, toolchain, OrcaSlicer source). This script starts at step 3
# by default since deps 0-2 are platform-independent.
#
# Usage:
#   ./build_device.sh             # build device deps + package dual XCFramework
#   ./build_device.sh --from 9    # re-run from GMP onwards
#   ./build_device.sh --only 15   # rebuild libslic3r only

set -euo pipefail
export PLATFORM=OS64

# Delegate to the main build.sh, which reads $PLATFORM from the environment.
# Steps 0-2 (tools, toolchain, OrcaSlicer clone) are shared; skip them if
# a device-only rebuild is all that is needed. Default: start at step 3.
ARGS=("$@")
if [ ${#ARGS[@]} -eq 0 ]; then
    ARGS=(--from 3)
fi

exec "$(dirname "$0")/build.sh" "${ARGS[@]}"
