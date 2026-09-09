#!/bin/bash
# Called from the Xcode "Embed pam_glance" build phase.
# Builds pam_glance.so and copies it + install.sh into the app Resources
# folder (as resources, never linked into the binary).
set -euo pipefail

DEST="${1:?usage: embed-resources.sh <ResourcesDir>}"
ROOT="$(cd "$(dirname "$0")" && pwd)"

make -C "$ROOT" pam_glance.so

mkdir -p "$DEST"
cp "$ROOT/pam_glance.so" "$DEST/pam_glance.so"
cp "$ROOT/install.sh" "$DEST/pam_glance_install.sh"
chmod 755 "$DEST/pam_glance.so" "$DEST/pam_glance_install.sh"

# Prefer the app's signing identity when Xcode provides one.
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
  codesign -f -s "${EXPANDED_CODE_SIGN_IDENTITY}" "$DEST/pam_glance.so" 2>/dev/null || true
else
  codesign -f -s - "$DEST/pam_glance.so" 2>/dev/null || true
fi

echo "note: embedded pam_glance into $DEST"
