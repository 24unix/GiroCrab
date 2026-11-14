#!/usr/bin/env bash
# Every UniFFI record/enum of girocrab-core carries the optional serde derive
#   #[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
# right below its #[derive(…, uniffi::Record|Enum)]. Front ends without UniFFI bindings
# (the Linux port) exchange these types as JSON. Without the `serde` feature the
# attribute is inert, so the Swift app builds exactly as before.
set -euo pipefail
cd "$(dirname "$0")/.."
missing=0
while IFS= read -r f; do
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        echo "$f:$hit: uniffi type without #[cfg_attr(feature = \"serde\", derive(serde::Serialize, serde::Deserialize))]"
        missing=1
    # types that already derive Serialize unconditionally need no extra attribute
    done < <(awk '/#\[derive\(.*uniffi::(Record|Enum)/ { if ($0 ~ /Serialize/) next; d=NR; next}
                  d && NR==d+1 { if ($0 !~ /cfg_attr\(feature = "serde"/) print d; d=0 }' "$f")
done < <(git ls-files 'girocrab-core/src/*.rs')
if [ "$missing" -ne 0 ]; then
    echo "Add the serde attribute below each listed derive (see girocrab-core/Cargo.toml, feature \"serde\")." >&2
    exit 1
fi
