#!/usr/bin/env bash
# Verifies that every direct dependency (all workspace Cargo.toml files and
# GiroCrabApp/Package.swift) is mentioned in THIRD_PARTY_NOTICES.md.
# Usage: scripts/check-third-party-notices.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTICES="$ROOT/THIRD_PARTY_NOTICES.md"
missing=()

# --- Rust: names under any [*dependencies] table of the workspace manifests ---
for manifest in "$ROOT/Cargo.toml" "$ROOT/girocrab-core/Cargo.toml" \
  "$ROOT/uniffi-bindgen/Cargo.toml" "$ROOT/tools/gen-bic-directory/Cargo.toml"; do
  [ -f "$manifest" ] || continue
  while IFS= read -r dep; do
    grep -qF "\`$dep\`" "$NOTICES" || missing+=("crate $dep ($(basename "$(dirname "$manifest")")/Cargo.toml)")
  done < <(awk '
    /^\[/ { indeps = ($0 ~ /dependencies\]$/) ; next }
    indeps && /^[A-Za-z0-9_-]+[ \t]*=/ { sub(/[ \t]*=.*/, ""); print }
  ' "$manifest")
done

# --- Swift: `.package(url: ".../Name", ...)` entries ---
while IFS= read -r pkg; do
  grep -qiF "$pkg" "$NOTICES" || missing+=("Swift package $pkg (GiroCrabApp/Package.swift)")
done < <(grep -o '\.package(url: *"[^"]*"' "$ROOT/GiroCrabApp/Package.swift" \
  | sed -E 's|.*/([^/"]+)"$|\1|; s|\.git$||')

if [ "${#missing[@]}" -gt 0 ]; then
  echo "THIRD_PARTY_NOTICES.md is out of date. Missing entries:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo "Add them (name, version, license) to THIRD_PARTY_NOTICES.md in the same commit." >&2
  exit 1
fi
echo "THIRD_PARTY_NOTICES.md covers all direct dependencies."
