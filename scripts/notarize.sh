#!/usr/bin/env bash
# Build, Developer-ID sign, notarize, staple and verify GiroCrab.app (macOS),
# and optionally archive & upload the iOS build to TestFlight / App Store Connect.
#
# Usage: scripts/notarize.sh [--upload <TAG> | --nightly] [--ios]
#   --upload <TAG>  upload macOS zip to GitHub release <TAG>
#   --nightly       move 'nightly' tag to HEAD, create/update rolling GitHub pre-release and upload macOS zip
#   --ios           also bump iOS build number, archive for iOS, and upload to TestFlight
# Env: SIGN_IDENTITY (override), NOTARY_PROFILE (default notary-profile)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UPLOAD_TAG=""
NIGHTLY=0
BUILD_IOS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --upload)
      UPLOAD_TAG="${2:-}"
      [ -n "$UPLOAD_TAG" ] || { echo "error: --upload needs a tag (e.g. v0.5.1)" >&2; exit 2; }
      shift 2 ;;
    --nightly)
      NIGHTLY=1
      shift ;;
    --ios)
      BUILD_IOS=1
      shift ;;
    *) echo "usage: $0 [--upload <TAG> | --nightly] [--ios]" >&2; exit 2 ;;
  esac
done

if [ -n "$UPLOAD_TAG" ] && [ "$NIGHTLY" -eq 1 ]; then
  echo "error: --upload and --nightly cannot be combined" >&2
  exit 2
fi

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
elif [ "$NIGHTLY" -eq 1 ]; then
  SHORT_SHA="$(git rev-parse --short HEAD)"
  BUILD_DATE="$(date -u +%Y-%m-%d)"
  LAST_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo "")"
  if [ -n "$LAST_TAG" ]; then
    CHANGES="$(git log --oneline "${LAST_TAG}..HEAD" | sed 's/^/- /')"
    HEADER="Automated nightly build from \`main\` (\`${SHORT_SHA}\`, ${BUILD_DATE}). Changes since \`${LAST_TAG}\`:"
  else
    CHANGES="$(git log -n 15 --oneline | sed 's/^/- /')"
    HEADER="Automated nightly build from \`main\` (\`${SHORT_SHA}\`, ${BUILD_DATE}). Recent commits:"
  fi
  NOTES="$(printf "%s\n\n%s\n\n---\n**macOS (Apple Silicon):** Signed with Developer ID & notarized (\`GiroCrab-macOS-arm64.zip\`)." "$HEADER" "$CHANGES")"
  TITLE="Nightly Build (${BUILD_DATE}, ${SHORT_SHA})"

  echo "==> Moving tag 'nightly' to HEAD (${SHORT_SHA})"
  git tag -f nightly HEAD
  git push origin refs/tags/nightly --force

  if gh release view nightly >/dev/null 2>&1; then
    echo "==> Updating existing 'nightly' pre-release"
    gh release edit nightly --prerelease --latest=false --title "$TITLE" --notes "$NOTES"
    gh release upload nightly dist/GiroCrab-macOS-arm64.zip --clobber
  else
    echo "==> Creating new 'nightly' pre-release"
    gh release create nightly dist/GiroCrab-macOS-arm64.zip \
      --prerelease \
      --latest=false \
      --title "$TITLE" \
      --notes "$NOTES"
  fi
fi

# Optional iOS TestFlight Archive & Upload
if [ "$BUILD_IOS" -eq 1 ]; then
  PBXPROJ="GiroCrabApp/Xcode/GiroCrab.xcodeproj/project.pbxproj"
  CURRENT_BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\);.*/\1/p' "$PBXPROJ" | head -1)"
  NEXT_BUILD=$((CURRENT_BUILD + 1))
  echo "==> Bumping iOS CURRENT_PROJECT_VERSION: ${CURRENT_BUILD} -> ${NEXT_BUILD}"
  sed -i '' "s/CURRENT_PROJECT_VERSION = ${CURRENT_BUILD};/CURRENT_PROJECT_VERSION = ${NEXT_BUILD};/g" "$PBXPROJ"

  IOS_ARCHIVE="build/GiroCrab-iOS.xcarchive"
  IOS_EXPORT="build/ios-export"
  IOS_PLIST="build/ExportOptions-upload.plist"
  rm -rf "$IOS_ARCHIVE" "$IOS_EXPORT"

  echo "==> Archiving iOS app (Build ${NEXT_BUILD})"
  xcodebuild archive \
    -project GiroCrabApp/Xcode/GiroCrab.xcodeproj \
    -scheme GiroCrab \
    -destination "generic/platform=iOS" \
    -archivePath "$IOS_ARCHIVE" \
    -allowProvisioningUpdates

  # Create upload ExportOptions.plist based on scripts/ExportOptions.plist with destination=upload
  cp scripts/ExportOptions.plist "$IOS_PLIST"
  /usr/libexec/PlistBuddy -c "Add :destination string upload" "$IOS_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :destination upload" "$IOS_PLIST"

  echo "==> Uploading iOS Archive (Build ${NEXT_BUILD}) to App Store Connect / TestFlight"
  xcodebuild -exportArchive \
    -archivePath "$IOS_ARCHIVE" \
    -exportOptionsPlist "$IOS_PLIST" \
    -exportPath "$IOS_EXPORT" \
    -allowProvisioningUpdates

  echo "==> iOS Build ${NEXT_BUILD} uploaded to TestFlight"
fi

echo "==> Done"