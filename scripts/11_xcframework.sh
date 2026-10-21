#!/usr/bin/env bash
# Package libslic3r.a as an XCFramework.
# - Simulator-only if only ios-sysroot-sim/lib/libslic3r.a exists.
# - Dual (sim + device) if ios-sysroot-dev/lib/libslic3r.a also exists.
#
# Always run this script after rebuilding libslic3r for any platform.
# It detects which slices are available and creates the appropriate XCFramework.
source "$(dirname "$0")/common.sh"

APP_DIR="$PROJECT_ROOT/app"
XCFW="$APP_DIR/libslic3r.xcframework"

SIM_LIB="$HOME/ios-sysroot-sim/lib/libslic3r.a"
DEV_LIB="$HOME/ios-sysroot-dev/lib/libslic3r.a"
HEADERS="$HOME/ios-sysroot-sim/include"   # headers are identical for both slices

if [ ! -f "$SIM_LIB" ]; then
    log_error "libslic3r.a not found at $SIM_LIB — run 10_libslic3r.sh (SIMULATORARM64) first."
    exit 1
fi

log_step "Packaging XCFramework"

rm -rf "$XCFW"

if [ -f "$DEV_LIB" ]; then
    log_step "Device slice found — creating dual sim+device XCFramework"
    xcodebuild -create-xcframework \
        -library "$SIM_LIB" -headers "$HEADERS" \
        -library "$DEV_LIB" -headers "$HEADERS" \
        -output "$XCFW"
    log_ok "XCFramework (sim + device) → $XCFW"
else
    log_warn "No device slice found at $DEV_LIB"
    log_warn "Creating simulator-only XCFramework."
    log_warn "Run:  PLATFORM=OS64 ./build.sh --from 3  to build the device slice,"
    log_warn "then re-run this script to upgrade to a dual XCFramework."
    xcodebuild -create-xcframework \
        -library "$SIM_LIB" -headers "$HEADERS" \
        -output "$XCFW"
    log_ok "XCFramework (simulator only) → $XCFW"
fi

# xcodebuild -create-xcframework can print an error yet exit 0; verify the output.
if [ ! -f "$XCFW/Info.plist" ]; then
    log_error "XCFramework was not created at $XCFW"
    exit 1
fi
