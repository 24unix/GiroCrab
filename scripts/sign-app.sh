#!/usr/bin/env bash
# Sign GiroCrab.app inside-out (no --deep, as Sparkle's docs require).
#
# Usage: scripts/sign-app.sh <identity> <path/to/GiroCrab.app>
#   <identity>  "-" for ad-hoc (package-macos-app.sh, nightly CI), or a
#               "Developer ID Application: …" identity (notarize.sh). With a
#               real identity, hardened runtime + secure timestamp are used.
set -euo pipefail

IDENTITY="$1"; APP="$2"
FLAGS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
  FLAGS+=(--options runtime --timestamp)
fi

# 1. Sparkle (order from https://sparkle-project.org/documentation/sandboxing/;
#    the XPC services are removed by package-macos-app.sh – app is not sandboxed).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  for xpc in "$SPARKLE"/Versions/B/XPCServices/*.xpc; do
    [ -e "$xpc" ] || continue
    codesign "${FLAGS[@]}" --preserve-metadata=entitlements "$xpc"
  done
  codesign "${FLAGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
  codesign "${FLAGS[@]}" "$SPARKLE/Versions/B/Updater.app"
  codesign "${FLAGS[@]}" "$SPARKLE"
fi

# 2. Any other nested Mach-O outside Sparkle and the main executable.
while IFS= read -r f; do
  if file -b "$f" | grep -q "Mach-O"; then
    codesign "${FLAGS[@]}" "$f"
  fi
done < <(find "$APP/Contents" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -u+x \) \
  ! -path "$APP/Contents/MacOS/*" ! -path "$SPARKLE/*" 2>/dev/null)

# 3. The app itself (seals everything above).
codesign "${FLAGS[@]}" "$APP"
codesign --verify --deep --strict -vv "$APP"
