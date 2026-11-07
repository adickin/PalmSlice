#!/usr/bin/env bash
# Copy OrcaSlicer's vendor profiles (printer / process / filament JSON) and the
# data files libslic3r reads while slicing (info/, flush/) into the app, so the
# bridge can load them at runtime as the base every PalmSlice profile builds on.
#
# Re-run after changing ORCA_TAG. Only the JSON is copied: bed models,
# textures and cover images are desktop-UI assets. The output is generated
# (≈12,000 files), so it's git-ignored rather than committed.
source "$(dirname "$0")/common.sh"

SRC="$ORCA_SRC/resources"
DEST="$PROJECT_ROOT/app/PalmSlice/OrcaResources"

if [ ! -d "$SRC/profiles" ]; then
    log_error "$SRC/profiles not found. Run 13_orcaslicer.sh first."
    exit 1
fi

log_step "Copying OrcaSlicer profiles ($ORCA_TAG)"
rm -rf "$DEST"
mkdir -p "$DEST"
rsync -a --include='*/' --include='*.json' --exclude='*' --prune-empty-dirs "$SRC/profiles" "$DEST/"
cp -R "$SRC/info" "$SRC/flush" "$DEST/"
echo "$ORCA_TAG" > "$DEST/VERSION"
log_ok "$(ls "$DEST/profiles"/*.json | wc -l | tr -d ' ') vendors → $DEST"
