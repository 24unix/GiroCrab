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

echo "==> Building Rust core + UniFFI bindings (release)"
./build-xcframework.sh --macos-only

echo "==> Building Swift app (release)"
(cd GiroCrabApp && swift build -c release --product GiroCrabMac)
BIN_DIR="$(cd GiroCrabApp && swift build -c release --product GiroCrabMac --show-bin-path)"

echo "==> Assembling $APP"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GiroCrabMac" "$APP/Contents/MacOS/GiroCrabMac"

# App icon: build AppIcon.icns from the asset catalog PNGs, if available.
ICON_SET="GiroCrabApp/Xcode/App/Assets.xcassets/AppIcon.appiconset"
ICON_KEY=""
if [ -d "$ICON_SET" ]; then
  ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET_DIR"
  for base in 16 32 128 256 512; do
    cp "$ICON_SET/icon-$base.png" "$ICONSET_DIR/icon_${base}x${base}.png" 2>/dev/null || true
    cp "$ICON_SET/icon-$((base * 2)).png" "$ICONSET_DIR/icon_${base}x${base}@2x.png" 2>/dev/null || true
  done
  if iconutil -c icns "$ICONSET_DIR" -o "$APP/Contents/Resources/AppIcon.icns"; then
    ICON_KEY="    <key>CFBundleIconFile</key><string>AppIcon</string>"
  else
    echo "warning: iconutil failed - bundle will have no icon" >&2
  fi
fi

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
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSFaceIDUsageDescription</key><string>GiroCrab nutzt Face ID / Touch ID, um Ihren verschlüsselten Tresor zu entsperren.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
${ICON_KEY}
</dict>
</plist>
PLIST

# UI translations: the SwiftUI code looks strings up in Bundle.main (this bundle).
echo "==> Compiling localisations"
xcrun xcstringstool compile GiroCrabApp/Xcode/App/Localizable.xcstrings --output-directory "$APP/Contents/Resources"
# InfoPlist: only English; German stays the Info.plist value above.
xcrun xcstringstool compile GiroCrabApp/Xcode/App/InfoPlist.xcstrings --language en --output-directory "$APP/Contents/Resources"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> Zipping"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Done: $ZIP"
