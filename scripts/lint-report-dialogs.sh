#!/usr/bin/env bash
# Sheets and popovers go through `.capturableSheet` / `.capturablePopover`
# (GitHub #384, `GiroCrabUI/ReportDialogs.swift`): "Problem melden" captures
# them with the main window, redacted like it, so their content must mark
# personal data with `.sensitive()` (see "Sensitive UI" in CLAUDE.md).
# A presentation that must never be captured (the report itself) carries
# `// report: not captured (<why>)` on the same line.
#
#   scripts/lint-report-dialogs.sh      exits 1 and lists offending lines
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

hits=$(grep -rnE "\.(sheet|popover|fullScreenCover)\(" GiroCrabApp/Sources/GiroCrabUI --include='*.swift' \
    | grep -v '^GiroCrabApp/Sources/GiroCrabUI/ReportDialogs\.swift:' \
    | grep -v 'report: not captured' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)

if [[ -n "$hits" ]]; then
    echo "Sheet/popover outside the bug report capture; use .capturableSheet / .capturablePopover and mark personal data with .sensitive(), see scripts/lint-report-dialogs.sh:" >&2
    echo "$hits" >&2
    exit 1
fi
echo "lint-report-dialogs: ok"
