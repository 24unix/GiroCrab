#!/usr/bin/env bash
# Builds a distributable GiroCrab.app (ad-hoc signed) and zips it:
#   dist/GiroCrab.app
#   dist/GiroCrab-macOS-arm64.zip
#
# Requirements: macOS 14+, Xcode 15+, rustup (aarch64-apple-darwin)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP="dist/GiroCrab.app"
ZIP="dist/GiroCrab-macOS-arm64.zip"
VERSION="${GIROCRAB_VERSION:-$(sed -n 's/^version *= *"\(.*\)"/\1/p' Cargo.toml | head -1)}"
VERSION="${VERSION:-0.0.0}"
# CFBundleVersion: what Sparkle compares. Stable releases use the plain version;
# notarize.sh passes X.Y.ZbN for betas (sorts before X.Y.Z) and
# <last tag's version>.<UTC timestamp> for nightlies (sorts after that tag and
# before the next beta/stable) – verified against Sparkle's version comparator.
BUILD_VERSION="${GIROCRAB_BUILD_VERSION:-$VERSION}"

# In-app updates (Sparkle). Enabled only when the EdDSA public key is known:
# env GIROCRAB_SPARKLE_PUBLIC_KEY or scripts/sparkle-public-ed-key.txt (one line,
# from Sparkle's generate_keys). Without it the updater stays off entirely.
SPARKLE_PUBLIC_KEY="${GIROCRAB_SPARKLE_PUBLIC_KEY:-}"
if [ -z "$SPARKLE_PUBLIC_KEY" ] && [ -f scripts/sparkle-public-ed-key.txt ]; then
  SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < scripts/sparkle-public-ed-key.txt)"
fi
# One signed feed for all channels, attached to the latest stable release
# (GitHub's "latest" never points at a pre-release or draft). Beta/nightly
# items are filtered by Sparkle channel in the app.
SPARKLE_FEED_URL="${GIROCRAB_SPARKLE_FEED_URL:-https://github.com/GiroCrab/GiroCrab/releases/latest/download/appcast.xml}"

# Skip the Rust build when generated/ already matches sources, release profile and
# FinTS product ID (e.g. notarize.sh --ios built it just before).
if ./build-xcframework.sh --check --strict-env 2>/dev/null; then
  echo "==> XCFramework is up to date — skipping rebuild"
else
  echo "==> Building Rust core + UniFFI bindings (release)"
  ./build-xcframework.sh --macos-only
fi

echo "==> Building Swift app (release)"
(cd GiroCrabApp && swift build -c release --product GiroCrabMac)
BIN_DIR="$(cd GiroCrabApp && swift build -c release --product GiroCrabMac --show-bin-path)"

echo "==> Assembling $APP"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GiroCrabMac" "$APP/Contents/MacOS/GiroCrabMac"

echo "==> Embedding Sparkle.framework"
SPARKLE_SRC=""
for c in "$BIN_DIR/Sparkle.framework" "$BIN_DIR/PackageFrameworks/Sparkle.framework" \
         GiroCrabApp/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework; do
  if [ -d "$c" ]; then SPARKLE_SRC="$c"; break; fi
done
[ -n "$SPARKLE_SRC" ] || { echo "error: Sparkle.framework not found next to $BIN_DIR" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
# The XPC services are only for sandboxed apps; GiroCrab is not sandboxed.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/GiroCrabMac"

# App icon: rendered on every build from the master artwork into the macOS
# squircle grid (transparent outside, verified by the script), so the bundle and
# the disk image never ship a stale icon or one macOS puts on a grey plate.
ICON_MASTER="GiroCrabApp/Branding/AppIcon-master.png"
echo "==> Rendering AppIcon.icns from $ICON_MASTER"
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
swift scripts/make-app-icon.swift "$ICON_MASTER" "$ICON_TMP/AppIcon.iconset" --iconset
iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
ICON_KEY="    <key>CFBundleIconFile</key><string>AppIcon</string>"

SPARKLE_KEYS=""
if [ -n "$SPARKLE_PUBLIC_KEY" ]; then
  echo "==> In-app updates enabled (feed: $SPARKLE_FEED_URL)"
  SPARKLE_KEYS="    <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SURequireSignedFeed</key><true/>
    <key>SUEnableSystemProfiling</key><false/>
    <key>SUEnableInstallerLauncherService</key><false/>"
else
  echo "==> In-app updates disabled (no Sparkle public key configured)"
fi

# Build time (UTC). The banking policy bundled below counts for 90 days
# from here on devices that never reached GitHub (docs/banking-policy.md).
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>GiroCrab</string>
    <key>CFBundleDisplayName</key><string>GiroCrab</string>
    <key>CFBundleIdentifier</key><string>app.girocrab.mac</string>
    <key>CFBundleExecutable</key><string>GiroCrabMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>de</string>
    <key>CFBundleLocalizations</key><array><string>de</string><string>en</string></array>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSFaceIDUsageDescription</key><string>GiroCrab nutzt Face ID / Touch ID, um Ihren verschlüsselten Tresor zu entsperren.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>GiroCrabDistribution</key><string>developer-id</string>
    <key>GiroCrabBuildDate</key><string>${BUILD_DATE}</string>
${ICON_KEY}
${SPARKLE_KEYS}
</dict>
</plist>
PLIST

# Banking policy floor (docs/banking-policy.md): notarize.sh downloads the
# current signed policy into build/banking-policy before packaging. It is
# only a lower bound for fresh installs; the app still checks online.
POLICY_DIR="${GIROCRAB_BANKING_POLICY_DIR:-build/banking-policy}"
if [[ -f "$POLICY_DIR/banking-policy.json" && -f "$POLICY_DIR/banking-policy.json.sig" ]]; then
  echo "==> Bundling banking policy (floor)"
  cp "$POLICY_DIR/banking-policy.json" "$POLICY_DIR/banking-policy.json.sig" "$APP/Contents/Resources/"
fi

# UI translations: the SwiftUI code looks strings up in Bundle.main (this bundle).
echo "==> Compiling localisations"
xcrun xcstringstool compile GiroCrabApp/Xcode/App/Localizable.xcstrings --output-directory "$APP/Contents/Resources"
# InfoPlist: only English; German stays the Info.plist value above.
xcrun xcstringstool compile GiroCrabApp/Xcode/App/InfoPlist.xcstrings --language en --output-directory "$APP/Contents/Resources"

echo "==> Ad-hoc signing"
scripts/sign-app.sh - "$APP"

echo "==> Zipping"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Done: $ZIP"
