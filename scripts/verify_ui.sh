#!/usr/bin/env bash
# Captures key views on macOS (native) and iOS (simulator) for release verification.
# Usage: scripts/verify_ui.sh [alltag|belege|sparplaene]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Inside the repo (git-ignored build/), not a predictable path in the shared /tmp.
OUT="${GIROCRAB_UI_OUT:-$ROOT/build/ui-verification}"
BIN="$ROOT/GiroCrabApp/.build/debug/GiroCrabMac"
BUNDLE_ID=de.girocrab.app
DEFAULT_UDID=595E93A5-3BBC-4313-8964-CC2384318858
VIEWS=(alltag belege sparplaene)
[ $# -ge 1 ] && VIEWS=("$1")

mkdir -p "$OUT"
fail=0

UDID=$(xcrun simctl list devices booted | grep -Eo '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1)
UDID=${UDID:-$DEFAULT_UDID}

window_id() { # pid -> CoreGraphics window id (largest on-screen window of the pid)
  swift - "$1" <<'SW' 2>/dev/null
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var best: (Int, Double) = (0, 0)
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
  let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
  let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
  if area > best.1, let n = w[kCGWindowNumber as String] as? Int { best = (n, area) }
}
if best.0 != 0 { print(best.0) }
SW
}

for view in "${VIEWS[@]}"; do
  echo "== $view: macOS"
  if [ ! -x "$BIN" ]; then echo "missing binary $BIN (run swift build in GiroCrabApp)"; fail=1
  else
    GIROCRAB_DEMO_SEED=1 "$BIN" --view "$view" >/dev/null 2>&1 &
    pid=$!; disown "$pid" 2>/dev/null
    wid=""
    for _ in $(seq 1 20); do
      sleep 0.5
      wid=$(window_id "$pid")
      [ -n "$wid" ] && break
    done
    if [ -n "$wid" ]; then
      sleep 1.5
      screencapture -x -o -l "$wid" "$OUT/macos_$view.png" || fail=1
    else
      echo "no window found for $view"; fail=1
    fi
    kill "$pid" 2>/dev/null
    for _ in 1 2 3 4 5 6; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$pid" 2>/dev/null
  fi

  echo "== $view: iOS ($UDID)"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  SIMCTL_CHILD_GIROCRAB_DEMO_SEED=1 xcrun simctl launch "$UDID" "$BUNDLE_ID" --view "$view" >/dev/null || fail=1
  sleep 1.5
  xcrun simctl io "$UDID" screenshot "$OUT/ios_$view.png" >/dev/null 2>&1 || fail=1
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
done

echo; ls -l "$OUT"/*.png
exit $fail
