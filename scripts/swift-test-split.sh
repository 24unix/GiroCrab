#!/usr/bin/env bash
# Swift tests in two phases: everything in parallel except the classes marked
# `// test: serial-defaults`, then those serially (they share UserDefaults.standard).
set -euo pipefail
cd "$(dirname "$0")/../GiroCrabApp"
classes=$(grep -rl '^// test: serial-defaults' Tests \
  | xargs grep -hoE 'class [A-Za-z0-9_]+ *: *XCTestCase' \
  | sed -E 's/class ([A-Za-z0-9_]+).*/\1/' | sort -u | paste -sd'|' -)
if [ -z "$classes" ]; then exec swift test --parallel "$@"; fi
pattern="\\.(${classes})/"
swift test --parallel --skip "$pattern" "$@"
swift test --skip-build --filter "$pattern" "$@"
