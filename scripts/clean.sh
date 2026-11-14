#!/usr/bin/env bash
# Local build & temp cleanup for GiroCrab (macOS-compatible: BSD find/du, bash 3.2).
#
#   scripts/clean.sh           fast clean, keeps built dependencies + xcframework
#   scripts/clean.sh --deep    additionally cargo clean, swift package clean, GiroCrabApp/.build
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/clean.sh [--deep] [-h|--help]

Default:
  - removes dist/ and build/
  - removes stray *.tmp, *.bak and *~ files (maxdepth 4, untracked only)
  - removes GiroCrab Xcode DerivedData (~/Library/Developer/Xcode/DerivedData/GiroCrab-*)
  - removes incremental Rust caches (target/**/incremental)
  - removes files in target/tmp older than 7 days
  - deletes local branches already merged into main
  Keeps built dependencies in target/ and the xcframework (generated/) for fast incremental builds.

--deep (in addition):
  - cargo clean
  - swift package --package-path GiroCrabApp clean
  - removes GiroCrabApp/.build

Prints the freed disk space in MB.
EOF
}

DEEP=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --deep) DEEP=1 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED_GLOB="$HOME/Library/Developer/Xcode/DerivedData/GiroCrab-*"

# Size in MB of the repo plus GiroCrab DerivedData (missing paths count as 0).
used_mb() {
  local kb
  # shellcheck disable=SC2086
  kb=$( { du -sk "$ROOT" $DERIVED_GLOB 2>/dev/null || true; } | awk '{s+=$1} END {print s+0}')
  echo $((kb / 1024))
}

BEFORE=$(used_mb)

echo "==> Removing dist/ and build/"
rm -rf "$ROOT/dist" "$ROOT/build"

echo "==> Removing stray *.tmp / *.bak / *~ files (untracked only)"
find "$ROOT" -maxdepth 4 \
  \( -name .git -o -name target -o -name .build -o -name generated -o -name node_modules \) -prune -o \
  -type f \( -name '*.tmp' -o -name '*.bak' -o -name '*~' \) -print |
  while IFS= read -r f; do
    if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
      continue
    fi
    rm -f -- "$f"
  done

echo "==> Removing GiroCrab Xcode DerivedData"
for d in $DERIVED_GLOB; do
  [ -d "$d" ] && rm -rf "$d"
done

if [ -d "$ROOT/target" ]; then
  echo "==> Removing incremental Rust caches"
  find "$ROOT/target" -maxdepth 3 -type d -name incremental -prune -exec rm -rf {} +
  if [ -d "$ROOT/target/tmp" ]; then
    find "$ROOT/target/tmp" -type f -mtime +7 -delete
  fi
fi

if [ "$DEEP" -eq 1 ]; then
  echo "==> Deep clean: cargo clean"
  cargo clean
  echo "==> Deep clean: swift package clean"
  swift package --package-path GiroCrabApp clean || true
  rm -rf "$ROOT/GiroCrabApp/.build"
fi

echo "==> Pruning local branches merged into main"
if git rev-parse --verify -q main >/dev/null; then
  git branch --merged main | grep -vE '^\*|^\s*(main|master)$' | while read -r br; do [ -n "$br" ] && git branch -d "$br"; done || true
else
  echo "    (no local main branch, skipped)"
fi

AFTER=$(used_mb)
echo "==> Disk usage before: ${BEFORE} MB, after: ${AFTER} MB, freed: $((BEFORE - AFTER)) MB"
