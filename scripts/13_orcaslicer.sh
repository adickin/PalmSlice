#!/usr/bin/env bash
# Clone OrcaSlicer at $ORCA_TAG and apply the iOS patch + shims.
# Idempotent: skips the patch if it's already applied.
source "$(dirname "$0")/common.sh"

PATCH="$PROJECT_ROOT/patches/orcaslicer_ios.patch"

if [ ! -d "$ORCA_SRC/.git" ]; then
    log_step "Cloning OrcaSlicer $ORCA_TAG"
    mkdir -p "$IOS_SOURCES"
    git clone --depth=1 --branch "$ORCA_TAG" https://github.com/SoftFever/OrcaSlicer.git "$ORCA_SRC"
else
    log_ok "OrcaSlicer already cloned at $ORCA_SRC"
fi
# The patch only matches one release; refuse to build anything else.
if [ "$(git -C "$ORCA_SRC" rev-parse HEAD)" != "$(git -C "$ORCA_SRC" rev-parse "$ORCA_TAG^{commit}" 2>/dev/null)" ]; then
    log_error "OrcaSlicer at $ORCA_SRC is not checked out at $ORCA_TAG."
    log_error "  cd $ORCA_SRC && git fetch --depth=1 origin tag $ORCA_TAG && git checkout -- . && git checkout $ORCA_TAG"
    exit 1
fi

cd "$ORCA_SRC"
if git apply --check "$PATCH" &>/dev/null; then
    log_step "Applying iOS patch to OrcaSlicer"
    git apply "$PATCH"
    log_ok "Patch applied"
elif git apply --reverse --check "$PATCH" &>/dev/null; then
    log_ok "iOS patch already applied — skipping"
else
    log_error "$PATCH doesn't apply to $ORCA_TAG (and isn't already applied)."
    log_error "Check the tree for local edits: git -C $ORCA_SRC status"
    exit 1
fi

# openssl/md5.h → CommonCrypto shim (a new directory, so kept outside the diff)
mkdir -p src/libslic3r/ios_shims
cp -R "$PROJECT_ROOT/patches/orca/ios_shims/." src/libslic3r/ios_shims/

log_ok "OrcaSlicer ready at $ORCA_SRC"
