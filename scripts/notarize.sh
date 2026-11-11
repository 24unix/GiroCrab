#!/usr/bin/env bash
# Build, Developer-ID sign, notarize, staple and verify GiroCrab.app (macOS),
# and optionally archive & upload the iOS build to TestFlight / App Store Connect.
#
# Usage: scripts/notarize.sh [--upload <TAG> | --nightly] [--ios]
#   --upload <TAG>  create/update GitHub release <TAG> with structured changelog and upload macOS zip
#   --nightly       move 'nightly' tag to HEAD, create/update rolling GitHub pre-release and upload macOS zip
#   --ios           also bump iOS build number, archive for iOS, and upload to TestFlight
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
      [ -n "$UPLOAD_TAG" ] || { echo "error: --upload needs a tag (e.g. v0.5.5)" >&2; exit 2; }
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

# Helper: Generate structured Markdown release notes between previous v* tag and target ref
generate_release_notes() {
  local target_tag="$1"
  local prev_tag
  prev_tag="$(git tag --list 'v*' --sort=-version:refname | grep -vxF "$target_tag" | head -1 || true)"

  local range="HEAD"
  [ -n "$prev_tag" ] && range="${prev_tag}..HEAD"

  local feats fixes perfs others
  feats="$(git log "$range" --no-merges --pretty=format:'- %s (%h)' --grep='^feat' -i || true)"
  perfs="$(git log "$range" --no-merges --pretty=format:'- %s (%h)' --grep='^perf' -i || true)"
  fixes="$(git log "$range" --no-merges --pretty=format:'- %s (%h)' --grep='^fix' -i || true)"

  # Also ask GitHub API for PR-based release notes (includes @authors and PR links)
  local gh_notes=""
  local repo
  repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  if [ -n "$repo" ]; then
    if [ -n "$prev_tag" ]; then
      gh_notes="$(gh api "repos/${repo}/releases/generate-notes" \
        -f tag_name="$target_tag" \
        -f target_commitish="main" \
        -f previous_tag_name="$prev_tag" \
        -q .body 2>/dev/null || true)"
    else
      gh_notes="$(gh api "repos/${repo}/releases/generate-notes" \
        -f tag_name="$target_tag" \
        -f target_commitish="main" \
        -q .body 2>/dev/null || true)"
    fi
  fi

  {
    if [ -n "$gh_notes" ]; then
      echo "$gh_notes"
      echo ""
    fi

    echo "### Commit-Übersicht (${prev_tag:-initial} → ${target_tag})"
    if [ -n "$feats" ]; then
      echo -e "\n#### ✨ Neue Funktionen\n$feats"
    fi
    if [ -n "$perfs" ]; then
      echo -e "\n#### ⚡ Performance\n$perfs"
    fi
    if [ -n "$fixes" ]; then
      echo -e "\n#### 🐛 Fehlerbehebungen\n$fixes"
    fi
    echo -e "\n---\n**macOS (Apple Silicon):** Signiert mit Developer ID & von Apple notarisiert (\`GiroCrab-macOS-arm64.zip\`)."
  }
}

# If releasing a version tag (e.g. v0.5.5), sync MARKETING_VERSION in Xcode before building
if [ -n "$UPLOAD_TAG" ]; then
  CLEAN_VER="${UPLOAD_TAG#v}"
  PBXPROJ="GiroCrabApp/Xcode/GiroCrab.xcodeproj/project.pbxproj"
  if [ -f "$PBXPROJ" ]; then
    echo "==> Setting MARKETING_VERSION = ${CLEAN_VER} in project.pbxproj"
    sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${CLEAN_VER};/g" "$PBXPROJ"
  fi
fi

PROFILE="${NOTARY_PROFILE:-notary-profile}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v \
  | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
  echo "error: no 'Developer ID Application' identity in keychain." >&2
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
done < <(find "$APP" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -u+x \) ! -path "$APP/Contents/MacOS/*" 2>/dev/null)
codesign --force --options runtime --timestamp --deep --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict -vv "$APP"

echo "==> Zip + notarize"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Staple + Gatekeeper"
xcrun stapler staple "$APP"
spctl --assess -vv --type execute "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Verify final archive"
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$ZIP" "$VERIFY_DIR"
VAPP="$VERIFY_DIR/GiroCrab.app"

CS_OUT="$(codesign -dvvv "$VAPP" 2>&1)"
echo "$CS_OUT" | grep -q "^Authority=Developer ID Application" \
  || { echo "error: signature is not 'Developer ID Application'" >&2; exit 1; }
xcrun stapler validate "$VAPP"
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
  echo "error: signed app exited within 5s" >&2
  exit 1
fi

mkdir -p dist
cp "$ZIP" dist/GiroCrab-macOS-arm64.zip
echo "==> Verified: dist/GiroCrab-macOS-arm64.zip"

if [ -n "$UPLOAD_TAG" ]; then
  NOTES="$(generate_release_notes "$UPLOAD_TAG")"
  if ! git rev-parse "$UPLOAD_TAG" >/dev/null 2>&1; then
    echo "==> Creating and pushing git tag $UPLOAD_TAG"
    git tag -a "$UPLOAD_TAG" -m "Release $UPLOAD_TAG"
    git push origin "$UPLOAD_TAG"
  fi
  if gh release view "$UPLOAD_TAG" >/dev/null 2>&1; then
    echo "==> Updating existing release $UPLOAD_TAG"
    gh release upload "$UPLOAD_TAG" dist/GiroCrab-macOS-arm64.zip --clobber
    gh release edit "$UPLOAD_TAG" --notes "$NOTES"
  else
    echo "==> Creating GitHub release $UPLOAD_TAG"
    gh release create "$UPLOAD_TAG" dist/GiroCrab-macOS-arm64.zip \
      --title "GiroCrab $UPLOAD_TAG" \
      --notes "$NOTES"
  fi
elif [ "$NIGHTLY" -eq 1 ]; then
  SHORT_SHA="$(git rev-parse --short HEAD)"
  BUILD_DATE="$(date -u +%Y-%m-%d)"
  NOTES="$(generate_release_notes "nightly")"
  TITLE="Nightly Build (${BUILD_DATE}, ${SHORT_SHA})"

  git tag -f nightly HEAD
  git push origin refs/tags/nightly --force

  if gh release view nightly >/dev/null 2>&1; then
    gh release edit nightly --prerelease --latest=false --title "$TITLE" --notes "$NOTES"
    gh release upload nightly dist/GiroCrab-macOS-arm64.zip --clobber
  else
    gh release create nightly dist/GiroCrab-macOS-arm64.zip \
      --prerelease --latest=false --title "$TITLE" --notes "$NOTES"
  fi
fi

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

  xcodebuild archive \
    -project GiroCrabApp/Xcode/GiroCrab.xcodeproj \
    -scheme GiroCrab \
    -destination "generic/platform=iOS" \
    -archivePath "$IOS_ARCHIVE" \
    -allowProvisioningUpdates

  cp scripts/ExportOptions.plist "$IOS_PLIST"
  /usr/libexec/PlistBuddy -c "Add :destination string upload" "$IOS_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :destination upload" "$IOS_PLIST"

  xcodebuild -exportArchive \
    -archivePath "$IOS_ARCHIVE" \
    -exportOptionsPlist "$IOS_PLIST" \
    -exportPath "$IOS_EXPORT" \
    -allowProvisioningUpdates

  echo "==> iOS Build ${NEXT_BUILD} uploaded to TestFlight"
fi

echo "==> Done"