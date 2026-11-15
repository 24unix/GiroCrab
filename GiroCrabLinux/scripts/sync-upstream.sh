#!/usr/bin/env bash
# Keeps the Linux port in step with the original GiroCrab project.
#
#   GiroCrabLinux/scripts/sync-upstream.sh            report only (nothing changes)
#   GiroCrabLinux/scripts/sync-upstream.sh --merge    merge upstream, fix serde markers, build, clippy, test
#
# The report lists what the port has to follow up since the last sync:
#   1. Swift UI files that changed, with the QML files that port them (from the README table)
#   2. core API changes that dispatch.rs may need (new / changed pub fn in lib.rs and vault/)
#   3. new uniffi Records/Enums that lack the `serde` marker (the Linux bridge needs it)
# The last synced upstream commit is stored in GiroCrabLinux/UPSTREAM_SYNC.
#
# Env: UPSTREAM_REMOTE (default: origin = github.com/GiroCrab/GiroCrab), UPSTREAM_BRANCH (default: main)
set -euo pipefail

remote="${UPSTREAM_REMOTE:-origin}"
branch="${UPSTREAM_BRANCH:-main}"
repo="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$repo"
state="GiroCrabLinux/UPSTREAM_SYNC"
upstream="$remote/$branch"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }

git fetch -q "$remote" "$branch"
if [[ -f "$state" ]]; then last="$(tr -d ' \n' < "$state")"; else last="$(git merge-base HEAD "$upstream")"; fi
head_up="$(git rev-parse "$upstream")"
count="$(git rev-list --count "$last..$head_up")"
bold "Original: $count neue Commits seit $(git log -1 --format='%h (%cs)' "$last")"
[[ "$count" == 0 ]] && { echo "Nichts zu tun."; exit 0; }

# --- 1. Swift UI changes → QML files to review -------------------------------------------------
bold "1. Geänderte Swift-Ansichten → zu prüfende QML-Dateien"
python3 - "$last" "$head_up" <<'PY'
import re, subprocess, sys
last, head = sys.argv[1], sys.argv[2]
changed = subprocess.run(["git", "diff", "--name-only", f"{last}..{head}", "--",
                          "GiroCrabApp/Sources/GiroCrabUI/"], capture_output=True, text=True).stdout.split()
readme = open("GiroCrabLinux/README.md", encoding="utf-8").read()
mapping = {}
for line in readme.splitlines():
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) < 3 or not line.startswith("|") or cells[0].startswith("---"):
        continue
    for name in re.findall(r"[A-Z][A-Za-z]+", cells[0]):
        mapping.setdefault(name, set()).add(cells[1])
for path in changed:
    stem = path.rsplit("/", 1)[-1].removesuffix(".swift")
    n = subprocess.run(["git", "rev-list", "--count", f"{last}..{head}", "--", path],
                       capture_output=True, text=True).stdout.strip()
    stat = subprocess.run(["git", "diff", "--shortstat", f"{last}..{head}", "--", path],
                          capture_output=True, text=True).stdout.strip()
    key = "AppModel" if stem.startswith("AppModel") else stem   # AppModel+Sync.swift … → AppModel.qml
    qml = "; ".join(sorted(mapping.get(key, []))) or "– (keine Zuordnung in der README-Tabelle)"
    print(f"  {stem}.swift  [{n} Commits, {stat}]\n      → {qml}")
if not changed:
    print("  keine")
PY

# --- 2. core API changes --------------------------------------------------------------------------
bold "2. Kern-Schnittstelle (lib.rs, vault/): neue oder geänderte pub fn – dispatch.rs prüfen"
git diff -U0 "$last..$head_up" -- girocrab-core/src/lib.rs girocrab-core/src/vault/ \
    | grep -E '^[+-]\s*pub (async )?fn ' | sed 's/^/  /' || echo "  keine"

# --- 3. Records/Enums without serde marker (on upstream) ------------------------------------------
bold "3. Neue uniffi-Typen ohne serde-Markierung (nach dem Zusammenführen; --merge ergänzt sie)"
missing_serde() {  # $1 = git revision or "WORKTREE"
    local rev="$1"
    local files
    if [[ "$rev" == WORKTREE ]]; then files="$(git ls-files 'girocrab-core/src/*.rs')"
    else files="$(git ls-tree -r --name-only "$rev" -- girocrab-core/src | grep '\.rs$')"; fi
    for f in $files; do
        if [[ "$rev" == WORKTREE ]]; then cat "$f"; else git show "$rev:$f"; fi \
          | awk -v f="$f" '/#\[derive\(.*uniffi::(Record|Enum)/ {d=NR; next}
                           d && NR==d+1 { if ($0 !~ /cfg_attr\(feature = "serde"/) print "  " f ":" d; d=0 }'
    done
}
if merged_tree="$(git merge-tree --write-tree HEAD "$upstream" 2>/dev/null | head -1)"; then
    missing="$(missing_serde "$merged_tree")"
    echo "${missing:-  keine}" | head -40
    echo "  (Zusammenführen geht ohne Konflikte)"
else
    echo "  erst nach dem Lösen der Merge-Konflikte prüfbar (git merge-tree meldet Konflikte)"
fi

[[ "${1:-}" == "--merge" ]] || { bold "Nur Bericht. Mit --merge wird zusammengeführt."; exit 0; }

# --- merge -----------------------------------------------------------------------------------------
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "Arbeitsverzeichnis nicht sauber – erst committen." >&2; exit 1; }
bold "Zusammenführen mit $upstream"
if ! git merge --no-ff --no-edit "$upstream"; then
    echo "Konflikte – bitte lösen (git status), dann das Skript erneut mit --merge starten." >&2
    exit 1
fi

# add the serde marker to new uniffi types (one line after each derive)
fixed=0
while IFS=: read -r f line; do
    f="${f#"${f%%[![:space:]]*}"}"; [[ -n "$f" ]] || continue   # strip the report indentation
    sed -i "${line}a #[cfg_attr(feature = \"serde\", derive(serde::Serialize, serde::Deserialize))]" "$f"
    fixed=$((fixed + 1))
done < <(missing_serde WORKTREE | tac)   # bottom-up keeps line numbers valid
if (( fixed > 0 )); then
    git add girocrab-core/src
    git commit -q -m "chore(linux): serde-Markierung für $fixed neue Kern-Typen"
    echo "  $fixed serde-Markierungen ergänzt."
fi

bold "Bauen und prüfen"
cd GiroCrabLinux
export PATH="$HOME/.cargo/bin:$PATH"
nice cargo fmt --check
nice cargo clippy -q --all-targets -- -D warnings
tmp="$(mktemp -d)"
GIROCRAB_NO_KEYCHAIN=1 XDG_DATA_HOME="$tmp/d" XDG_CONFIG_HOME="$tmp/c" nice cargo test -q
rm -rf "$tmp"
cd "$repo"
echo "$head_up" > "$state"
git add "$state"
git commit -q -m "chore(linux): Abgleich mit dem Original bis $(git log -1 --format=%h "$head_up")"
bold "Fertig. Offene Punkte siehe Abschnitt 1 und 2 oben (QML von Hand nachziehen)."
