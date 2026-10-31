#!/usr/bin/env bash
# Clone PrusaSlicer, initialise submodules, and apply iOS patches.
#
# Patches live in $PROJECT_ROOT/patches/ and are applied idempotently
# (git apply --check first; skip if already applied).
source "$(dirname "$0")/common.sh"

PATCHES_DIR="$PROJECT_ROOT/patches"

clone_and_patch() {
    # ── Clone ─────────────────────────────────────────────────────────────
    if [ ! -d "$PRUSA_SRC/.git" ]; then
        log_step "Cloning PrusaSlicer"
        mkdir -p "$IOS_SOURCES"
        git clone --depth=1 --branch "$PRUSA_TAG" https://github.com/prusa3d/PrusaSlicer.git "$PRUSA_SRC"
    else
        log_ok "PrusaSlicer already cloned at $PRUSA_SRC"
    fi
    # The patch only matches one release; refuse to build anything else.
    if [ "$(git -C "$PRUSA_SRC" rev-parse HEAD)" != "$(git -C "$PRUSA_SRC" rev-parse "$PRUSA_TAG^{commit}" 2>/dev/null)" ]; then
        log_error "PrusaSlicer at $PRUSA_SRC is not checked out at $PRUSA_TAG."
        log_error "  cd $PRUSA_SRC && git fetch --depth=1 origin tag $PRUSA_TAG && git checkout -- . && git checkout $PRUSA_TAG"
        exit 1
    fi

    # Ensure submodules are initialised
    cd "$PRUSA_SRC"
    git submodule update --init --recursive --depth=1

    # ── Apply CMakeLists patch ─────────────────────────────────────────────
    PATCH="$PATCHES_DIR/prusaslicer_ios.patch"
    if [ -f "$PATCH" ]; then
        # Check if already applied (git apply --check passes when patch is clean;
        # fails if already applied or conflict)
        if git apply --check "$PATCH" &>/dev/null; then
            log_step "Applying iOS patch to PrusaSlicer"
            git apply "$PATCH"
            log_ok "Patch applied"
        else
            # --check fails: either already applied or conflict.
            # Verify by checking if one of the patched symbols exists.
            if grep -q 'SLIC3R_IOS' CMakeLists.txt 2>/dev/null; then
                log_ok "iOS patch already applied — skipping"
            else
                log_error "Patch failed to apply and SLIC3R_IOS not found."
                log_error "The cloned PrusaSlicer version may be incompatible."
                log_error "Check $PATCH against HEAD and update the patch file."
                exit 1
            fi
        fi
    else
        log_warn "Patch file not found at $PATCH"
        log_warn "If building libslic3r fails, re-generate the patch:"
        log_warn "  cd ~/ios-sources/PrusaSlicer && git diff HEAD > $PATCH"
    fi

    # ── Install stub source files ──────────────────────────────────────────
    # These are new files (not in PrusaSlicer) so they're not in the diff patch.
    for stub_src in ArrangeHelper_ios_stub.cpp; do
        DST="$PRUSA_SRC/src/libslic3r/$stub_src"
        SRC="$PATCHES_DIR/$stub_src"
        if [ -f "$SRC" ] && ! cmp -s "$SRC" "$DST"; then
            cp "$SRC" "$DST"
            log_ok "Installed $stub_src"
        elif [ ! -f "$DST" ] && [ ! -f "$SRC" ]; then
            log_error "Stub file missing: $SRC"
            log_error "Commit the stub files to $PATCHES_DIR/ and re-run."
            exit 1
        fi
    done

    for stub_src in Thumbnails_ios_stub.cpp; do
        DST="$PRUSA_SRC/src/libslic3r/GCode/$stub_src"
        SRC="$PATCHES_DIR/$stub_src"
        if [ -f "$SRC" ] && ! cmp -s "$SRC" "$DST"; then
            cp "$SRC" "$DST"
            log_ok "Installed $stub_src"
        elif [ ! -f "$DST" ] && [ ! -f "$SRC" ]; then
            log_error "Stub file missing: $SRC"
            log_error "Commit the stub files to $PATCHES_DIR/ and re-run."
            exit 1
        fi
    done

    log_ok "PrusaSlicer ready at $PRUSA_SRC"
}

clone_and_patch
