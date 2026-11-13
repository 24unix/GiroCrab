#!/usr/bin/env bash
# Adds new UI strings of GiroCrabUI to the String Catalog and lists entries
# that still lack an English translation.
#
#   GiroCrabApp/Tools/update-localizations.sh          sync + check
#   GiroCrabApp/Tools/update-localizations.sh --check  check only (exit 1 if a translation is missing)
#
# German is the source language: the keys are the German texts as written in
# the Swift code (Text("…"), String(localized: "…"), …). The compiler extracts
# them (-emit-localized-strings), xcstringstool merges them into
# Xcode/App/Localizable.xcstrings. Translate new entries in Xcode's catalog
# editor or directly in the JSON. Entries are kept as "manual" so Xcode builds
# of the app target (whose own sources contain no strings) don't mark them stale.
# The catalog is written sorted by key, in the form scripts/xcstrings.py checks in CI.
set -euo pipefail

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$PKG/Xcode/App/Localizable.xcstrings"

if [ "${1:-}" != "--check" ]; then
  OUT="$(mktemp -d)"
  trap 'rm -rf "$OUT"' EXIT
  # Touch the sources so every file is recompiled and emits its .stringsdata.
  touch "$PKG"/Sources/GiroCrabUI/*.swift
  (cd "$PKG" && swift build -q -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT")
  rm -f "$OUT"/girocrab_core.stringsdata   # generated bindings, no UI strings
  xcrun xcstringstool sync "$CATALOG" --stringsdata "$OUT"/*.stringsdata
fi

python3 - "$CATALOG" <<'PY'
import json, sys
path = sys.argv[1]
d = json.load(open(path))
d["strings"].pop("", None)
missing = []
for key, entry in d["strings"].items():
    entry["extractionState"] = "manual"
    if "en" not in entry.get("localizations", {}):
        missing.append(key)
json.dump(d, open(path, "w"), ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
open(path, "a").write("\n")
print(f"{len(d['strings'])} entries, {len(missing)} without English")
for key in missing:
    print("  missing en:", repr(key))
sys.exit(1 if missing else 0)
PY
