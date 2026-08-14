#!/bin/sh
# Verify that the macOS bundle resolves HDF libraries to the copies we ship.
# This checks that three things hold:
#
#   1. The hardened runtime is disabling DYLD_*, since dyld consults
#      DYLD_LIBRARY_PATH before the install name.
#   2. No HDF dependency is an absolute path.
#   3. Every HDF library carries an @loader_path run path.
#
# Usage: verify-dylib-pinning.sh <HDFView.app> <entitlements-file>

set -eu

APP="${1:?usage: verify-dylib-pinning.sh <HDFView.app> <entitlements-file>}"
ENTITLEMENTS="${2:?usage: verify-dylib-pinning.sh <HDFView.app> <entitlements-file>}"

status=0
fail() { echo "  ✗ $1" >&2; status=1; }

# --- DYLD_* must stay disabled under the hardened runtime ----------------
if [ ! -f "$ENTITLEMENTS" ]; then
    fail "entitlements file not found: $ENTITLEMENTS"
elif grep -q 'allow-dyld-environment-variables' "$ENTITLEMENTS"; then
    fail "$ENTITLEMENTS grants allow-dyld-environment-variables;
       that lets DYLD_LIBRARY_PATH override the bundled HDF libraries"
fi

# The file only takes effect once the hardened runtime is applied, and signing
# runs on the canonical repository alone, so ask the bundle rather than infer
if ! codesign -dv "$APP" >/dev/null 2>&1; then
    echo "  warning: bundle is unsigned, so DYLD_* overrides are not blocked."
    echo "           The entitlements file is correct; nothing is enforcing it."
elif codesign -d --verbose=2 "$APP" 2>&1 | grep -q 'flags=.*runtime'; then
    granted=$(codesign -d --entitlements :- "$APP" 2>/dev/null |
              grep -c 'allow-dyld-environment-variables' || true)
    if [ "${granted:-0}" -gt 0 ]; then
        fail "the signed bundle grants allow-dyld-environment-variables;
       DYLD_LIBRARY_PATH can override the bundled HDF libraries"
    else
        echo "  ✓ hardened runtime is active and keeps DYLD_* disabled"
    fi
else
    fail "bundle is signed but the hardened runtime is not enabled;
       DYLD_* is honoured, so DYLD_LIBRARY_PATH can override the bundled libraries"
fi

# --- Every bundled HDF library resolves inside the bundle ----------
# jdk.jpackage ApplicationLayout: APP is Contents/app on macOS
APPDIR="$APP/Contents/app"
if [ ! -d "$APPDIR" ]; then
    fail "unexpected app layout: $APPDIR not found"
    exit 1
fi

checked=0
for lib in "$APPDIR"/libhdf*.dylib "$APPDIR"/libmfhdf*.dylib "$APPDIR"/libdf*.dylib; do
    [ -f "$lib" ] || continue
    checked=$((checked + 1))
    name=$(basename "$lib")

    # Anything but @rpath/... points outside the bundle
    absolute=$(otool -L "$lib" | tail -n +2 | awk '{print $1}' \
               | grep -iE '(hdf|mfhdf)' | grep -v '^@' || true)
    if [ -n "$absolute" ]; then
        fail "$name has non-relative HDF dependencies:
       $(echo "$absolute" | tr '\n' ' ')"
    fi

    # @rpath is only safe if it expands inside the bundle
    if ! otool -l "$lib" | grep -A2 LC_RPATH | grep -q '@loader_path'; then
        fail "$name has no @loader_path entry in its LC_RPATH list"
    fi
done

if [ "$checked" -eq 0 ]; then
    fail "no HDF libraries found in $APPDIR - native libraries were not staged"
fi

for wrapper in libhdf5_java libhdf_java; do
    if ! ls "$APPDIR/$wrapper"*.dylib >/dev/null 2>&1; then
        echo "  warning: $wrapper*.dylib is not in this bundle"
    fi
done

if [ "$status" -eq 0 ]; then
    echo "  ✓ $checked HDF dylibs resolve to the bundled copies"
    echo "OK: macOS bundle is pinned"
fi

exit "$status"
