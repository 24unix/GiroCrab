#!/usr/bin/env bash
# Build, Developer-ID sign, notarize and staple GiroCrab.app.
# Env: SIGN_IDENTITY (override), NOTARY_PROFILE (default notary-profile)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

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

echo "==> Signing nested code (hardened runtime)"
while IFS= read -r f; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$f"
done < <(find "$APP" -type f \( -name '*.dylib' -o -name '*.so' -o -perm +111 \) ! -path "$APP/Contents/MacOS/*" 2>/dev/null)
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
echo "==> Done: $ZIP"
