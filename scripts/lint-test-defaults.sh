#!/usr/bin/env bash
# Tests touching UserDefaults.standard must be marked serial; suites need a unique name.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
for f in $(grep -rlE 'UserDefaults\.standard|UserDefaults\(\)' GiroCrabApp/Tests || true); do
  grep -q '^// test: serial-defaults' "$f" || { echo "$f: uses UserDefaults.standard without '// test: serial-defaults'"; fail=1; }
done
if grep -rnE 'suiteName: *"[^"\\]*"' GiroCrabApp/Tests; then
  echo "fixed suiteName above: append \\(UUID().uuidString)"; fail=1
fi
exit $fail
