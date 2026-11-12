#!/usr/bin/env bash
# Pack GiroCrab.app into a compressed disk image with an /Applications link
# (drag-to-install window) and code-sign the image itself.
#
# Usage: scripts/make-dmg.sh <path/to/GiroCrab.app> <out.dmg> [identity]
#   identity  "Developer ID Application: …" (notarize.sh) or "-" / empty for an
#             unsigned image (local tests only).
#
# Why a signed DMG instead of a ZIP: the image itself carries a Developer ID
# signature. Gatekeeper checks it on download, and Sparkle can fall back to it
# before extraction if the EdDSA key ever has to be replaced (a ZIP cannot be
# code-signed), see docs/auto-updates.md.
set -euo pipefail

APP="$1"; OUT="$2"; IDENTITY="${3:-}"
[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/GiroCrab.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -quiet -volname "GiroCrab" -srcfolder "$STAGE" \
  -fs APFS -format ULFO -ov "$OUT"

if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$OUT"
  codesign --verify --strict -vv "$OUT"
fi
echo "==> Disk image: $OUT"
