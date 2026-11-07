#!/usr/bin/env bash
# Package OrcaSlicer's libslic3r.a as an XCFramework.
# - Simulator-only if only ios-sysroot-sim/orca/lib/libslic3r.a exists.
# - Dual (sim + device) if ios-sysroot-dev/orca/lib/libslic3r.a also exists.
#
# Always run this script after rebuilding libslic3r for any platform.
# Headers aren't packaged: the app finds them through HEADER_SEARCH_PATHS
# (app/project.yml), which must list $ORCA_PREFIX/include before the sysroot.
source "$(dirname "$0")/common.sh"

APP_DIR="$PROJECT_ROOT/app"
XCFW="$APP_DIR/libslic3r.xcframework"

SIM_LIB="$HOME/ios-sysroot-sim/orca/lib/libslic3r.a"
DEV_LIB="$HOME/ios-sysroot-dev/orca/lib/libslic3r.a"

if [ ! -f "$SIM_LIB" ]; then
    log_error "libslic3r.a not found at $SIM_LIB — run 14_orca_libslic3r.sh (SIMULATORARM64) first."
    exit 1
fi

log_step "Packaging XCFramework"

rm -rf "$XCFW"

if [ -f "$DEV_LIB" ]; then
    log_step "Device slice found — creating dual sim+device XCFramework"
    xcodebuild -create-xcframework -library "$SIM_LIB" -library "$DEV_LIB" -output "$XCFW"
    log_ok "XCFramework (sim + device) → $XCFW"
else
    log_warn "No device slice found at $DEV_LIB"
    log_warn "Creating simulator-only XCFramework."
    log_warn "Run:  ./build_device.sh  to build the device slice,"
    log_warn "then re-run this script to upgrade to a dual XCFramework."
    xcodebuild -create-xcframework -library "$SIM_LIB" -output "$XCFW"
    log_ok "XCFramework (simulator only) → $XCFW"
fi

# xcodebuild -create-xcframework can print an error yet exit 0; verify the output.
if [ ! -f "$XCFW/Info.plist" ]; then
    log_error "XCFramework was not created at $XCFW"
    exit 1
fi
