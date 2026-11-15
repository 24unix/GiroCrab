#!/usr/bin/env bash
# Regenerates cargo-sources.json (the offline crate list of the Flatpak build) from
# GiroCrabLinux/Cargo.lock. Run it after every change to that lock file and commit the
# result together with it; CI (flatpak.yml, job "cargo-sources") fails while they differ.
#
#   GiroCrabLinux/packaging/flatpak/update-cargo-sources.sh          # rewrite the file
#   GiroCrabLinux/packaging/flatpak/update-cargo-sources.sh --check  # only compare
#
# Needs `uv` (runs the generator with its pinned Python dependencies) or python3 with
# aiohttp, tomlkit and PyYAML installed.
set -euo pipefail

# flatpak-builder-tools, cargo/flatpak-cargo-generator.py (MIT), pinned commit + checksum
gen_rev=9d86d336a39b9af38b86f114b6ce5820fe260f91
gen_sha256=0a2db6be87d75910facef28ab46d4d6460802e8419ab850d0caa6a364d26b380
gen_url="https://raw.githubusercontent.com/flatpak/flatpak-builder-tools/$gen_rev/cargo/flatpak-cargo-generator.py"

here="$(cd "$(dirname "$0")" && pwd)"
lock="$(cd "$here/../.." && pwd)/Cargo.lock"
out="$here/cargo-sources.json"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -sSfL -o "$tmp/flatpak-cargo-generator.py" "$gen_url"
echo "$gen_sha256  $tmp/flatpak-cargo-generator.py" | sha256sum -c --quiet -

if command -v uv >/dev/null; then
    run=(uv run --quiet --script "$tmp/flatpak-cargo-generator.py")
else
    run=(python3 "$tmp/flatpak-cargo-generator.py")
fi
"${run[@]}" "$lock" -o "$tmp/cargo-sources.json"

if [[ "${1:-}" == "--check" ]]; then
    if ! cmp -s "$tmp/cargo-sources.json" "$out"; then
        echo "cargo-sources.json is out of date: run GiroCrabLinux/packaging/flatpak/update-cargo-sources.sh" >&2
        exit 1
    fi
    echo "cargo-sources.json matches Cargo.lock"
else
    mv "$tmp/cargo-sources.json" "$out"
    echo "$out"
fi
