#!/usr/bin/env bash
# Build, Developer-ID sign, notarize, staple and verify GiroCrab.app.
# Usage: scripts/notarize.sh [--upload <TAG>]
#   --upload <TAG>  after successful verification: gh release upload <TAG> dist/GiroCrab-macOS-arm64.zip --clobber
# Env: SIGN_IDENTITY (override), NOTARY_PROFILE (default notary-profile)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UPLOAD_TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --upload)
      UPLOAD_TAG="${2:-}"
      [ -n "$UPLOAD_TAG" ] || { echo "error: --upload needs a tag (e.g. v0.5.1)" >&2; exit 2; }
      shift 2 ;;
    *) echo "usage: $0 [--upload <TAG>]" >&2; exit 2 ;;
  esac
done

PROFILE="${NOTARY_PROFILE:-notary-profile}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v \
  | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
  echo "error: no 'Developer ID Application' identity in keychain (only: $(security find-identity -p codesigning -v | grep -c '"') found)." >&2
  echo "Create one at developer.apple.com > Certificates, or set SIGN_IDENTITY." >&2
  exit 1
fi
echo "==> Identity: $IDENTITY"

echo "==> Build (xcframework + swift release + bundle) via package-macos-app.sh"
./package-macos-app.sh

rm -rf build; mkdir -p build
cp -R dist/GiroCrab.app build/GiroCrab.app
APP="build/GiroCrab.app"; ZIP="build/GiroCrab-macOS.zip"

# Hardened runtime without entitlements: the app is a plain SwiftUI/Rust binary
# (no JIT, no unsigned executable memory, no DYLD env vars, not sandboxed), so no
# entitlements are required. The launch smoke test below guards against regressions.
echo "==> Signing nested code (hardened runtime)"
while IFS= read -r f; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$f"
done < <(find "$APP" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -u+x \) ! -path "$APP/Contents/MacOS/*" 2>/dev/null)
codesign --force --options runtime --timestamp --deep --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict -vv "$APP"

echo "==> Zip + notarize"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Staple + Gatekeeper"
xcrun stapler staple "$APP"
spctl --assess -vv --type execute "$APP"
# Re-zip so the distributed archive carries the stapled ticket
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Verify final archive"
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$ZIP" "$VERIFY_DIR"
VAPP="$VERIFY_DIR/GiroCrab.app"

echo "--- codesign -dvvv"
CS_OUT="$(codesign -dvvv "$VAPP" 2>&1)"
echo "$CS_OUT"
echo "$CS_OUT" | grep -q "^Authority=Developer ID Application" \
  || { echo "error: signature is not 'Developer ID Application'" >&2; exit 1; }

echo "--- stapler validate"
xcrun stapler validate "$VAPP"

echo "--- spctl -a -vvv -t exec"
spctl -a -vvv -t exec "$VAPP"

echo "--- launch smoke test"
"$VAPP/Contents/MacOS/GiroCrabMac" >/dev/null 2>&1 &
APP_PID=$!
sleep 5
if kill -0 "$APP_PID" 2>/dev/null; then
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  echo "app started and stayed running"
else
  echo "error: signed app exited within 5s (hardened runtime / entitlements issue?)" >&2
  exit 1
fi

mkdir -p dist
cp "$ZIP" dist/GiroCrab-macOS-arm64.zip
echo "==> Verified: dist/GiroCrab-macOS-arm64.zip"

if [ -n "$UPLOAD_TAG" ]; then
  echo "==> Uploading to release $UPLOAD_TAG"
  gh release upload "$UPLOAD_TAG" dist/GiroCrab-macOS-arm64.zip --clobber
fi
echo "==> Done"
