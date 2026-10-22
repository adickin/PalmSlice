#!/usr/bin/env bash
# Copy PrusaSlicer's vendor profile bundles (printer / print / filament presets)
# into the app, so libslic3r's PresetBundle can load them at runtime as the
# base every PalmSlice profile builds on.
#
# Re-run after changing PRUSA_TAG (see BUILDING.md "Updating PrusaSlicer").
# Only the .ini bundles are copied: thumbnails, bed models and textures are
# desktop-UI assets. SLA bundles and the Templates bundle are skipped
# (PalmSlice is FFF-only; Templates are filament-only "any printer" presets
# PresetBundle treats specially).
source "$(dirname "$0")/common.sh"

SRC="$PRUSA_SRC/resources/profiles"
DEST="$PROJECT_ROOT/app/PalmSlice/PrusaSlicerProfiles/vendor"

if [ ! -d "$SRC" ]; then
    log_error "$SRC not found. Run 02_prusaslicer.sh first."
    exit 1
fi

log_step "Copying PrusaSlicer vendor profiles ($PRUSA_TAG)"
rm -rf "$DEST"
mkdir -p "$DEST"
for ini in "$SRC"/*.ini; do
    name="$(basename "$ini" .ini)"
    case "$name" in
        *SLA|Templates) continue ;;
    esac
    cp "$ini" "$DEST/"
done
echo "$PRUSA_TAG" > "$DEST/../VERSION"
log_ok "$(ls "$DEST" | wc -l | tr -d ' ') vendor bundles → $DEST"
