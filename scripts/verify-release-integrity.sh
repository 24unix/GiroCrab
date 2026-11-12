#!/usr/bin/env bash
# Release integrity check, locally or in CI (.github/workflows/release-integrity.yml).
# Needs only public keys from the repository. See docs/release-integrity.md.
#
#   scripts/verify-release-integrity.sh [--repo owner/name] [--base URL|DIR] [--state FILE] [--report FILE]
#   scripts/verify-release-integrity.sh --report-issue FILE
#       (CI) post FILE to the one open issue labelled `release-integrity`,
#       creating issue and label if needed
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ "${1:-}" = "--report-issue" ]; then
  REPORT="${2:?report file}"
  LABEL="release-integrity"
  gh label create "$LABEL" --color B60205 \
    --description "Automatische Prüfung von appcast.xml und banking-policy.json" 2>/dev/null || true
  NUM="$(gh issue list --label "$LABEL" --state open --json number -q '.[0].number')"
  if [ -n "$NUM" ]; then
    gh issue comment "$NUM" --body-file "$REPORT"
    echo "==> Commented on issue #$NUM"
  else
    gh issue create --title "Release-Integrität: Abweichung gefunden" --label "$LABEL" --body-file "$REPORT"
  fi
  exit 0
fi

BIN="${TMPDIR:-/tmp}/girocrab-release-integrity-$(id -u)"
SRC=scripts/release-integrity/main.swift
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  swiftc -O -o "$BIN" "$SRC"
fi
exec "$BIN" --root "$ROOT" "$@"
