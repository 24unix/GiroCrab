#!/usr/bin/env bash
# Free functions reach the UniFFI front ends only through girocrab-core/src/ffi.rs.
# Elsewhere `#[uniffi::export]` may only mark an `impl` block of an exported object
# or a callback trait, so internal helpers don't end up in the Swift bindings.
set -euo pipefail
cd "$(dirname "$0")/.."
bad=$(git ls-files 'girocrab-core/src/*.rs' ':!girocrab-core/src/ffi.rs' | xargs awk '
    # The item after the attribute: on the same line, or the next line that is
    # neither another attribute nor a comment. Multi-line attributes end at ")]".
    /#\[.*uniffi::export/ {
        at = FNR; rest = $0
        if (!sub(/.*uniffi::export[^]]*\]/, "", rest)) { open = 1; next }
        if (rest !~ /^[[:space:]]*$/) { check(rest) }
        next
    }
    open { if (/\)\]/) open = 0; next }
    at && /^[[:space:]]*(#\[|\/\/)/ { next }
    at { check($0) }
    function check(item) {
        if (item !~ /^[[:space:]]*(pub )?(impl|trait)[[:space:]<]/) print FILENAME ":" at ": " item
        at = 0
    }
')
if [ -n "$bad" ]; then
    echo "$bad" >&2
    echo "Export free functions from girocrab-core/src/ffi.rs instead (a wrapper that forwards to the function)." >&2
    exit 1
fi
