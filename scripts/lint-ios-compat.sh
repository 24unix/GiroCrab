#!/usr/bin/env bash
# GiroCrabUI is also built for iOS. CI has no iOS Simulator job (too slow), so macOS-only
# Foundation APIs are caught here by grep instead: a use outside `#if os(macOS)` fails.
#
#   scripts/lint-ios-compat.sh      exits 1 and lists offending lines
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# macOS-only APIs (unavailable on iOS). Extend when another one bites.
PATTERN='homeDirectoryForCurrentUser|NSWorkspace\.shared|NSOpenPanel|NSSavePanel'

bad=$(find GiroCrabApp/Sources/GiroCrabUI -name '*.swift' -print0 | xargs -0 awk -v pat="$PATTERN" '
    FNR == 1 { depth = 0; mac = 0 }
    /^[[:space:]]*#if / { depth++; if ($0 ~ /os\(macOS\)/ && !mac) mac = depth }
    /^[[:space:]]*#endif/ { if (mac == depth) mac = 0; depth-- }
    !mac && $0 !~ /^[[:space:]]*\/\// && $0 ~ pat { print FILENAME ":" FNR ": " $0 }
')
if [[ -n "$bad" ]]; then
    echo "macOS-only API outside #if os(macOS) (breaks the iOS build):" >&2
    echo "$bad" >&2
    exit 1
fi
