#!/usr/bin/env bash
# Keeps README.md (this repo) and GiroCrab/girocrab.de in lockstep with the latest stable release
# and girocrab-core/src/connectors/catalog.rs. Transforms live in scripts/sync_docs.py.
#
#   scripts/sync-docs-and-website.sh [--dry-run] [--push] [--version vX.Y.Z] [--readme-only|--site-only]
#
#   --dry-run  (default) print the diffs for README.md / website, change nothing remote
#   --push     website: commit + push to main of girocrab.de; README: branch chore/sync-docs + PR
#              (main is protected). Nothing to commit => skipped cleanly.
#   --version  override the version (default: latest stable GitHub release)
#
# Auth: WEBSITE_DEPLOY_TOKEN (CI; fine-grained PAT, Contents: write on girocrab.de) else local `gh` login.
# README PR in CI uses GH_TOKEN (workflow passes WEBSITE_DEPLOY_TOKEN or GITHUB_TOKEN).
# Your working tree is never touched: README is edited in a temporary worktree of origin/main.
set -euo pipefail

MODE=dry; VERSION=""; DO_README=1; DO_SITE=1
SITE_REPO="${SITE_REPO:-GiroCrab/girocrab.de}"
BASE_REF="${BASE_REF:-origin/main}"         # README is taken from this ref (override to test unmerged changes)
SITE_CLONE_URL="${SITE_CLONE_URL:-}"       # override (e.g. a local path) for tests
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry ;;
    --push) MODE=push ;;
    --version) VERSION="${2:?--version needs a value}"; shift ;;
    --readme-only) DO_SITE=0 ;;
    --site-only) DO_README=0 ;;
    -h|--help) sed -n 2,15p "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PY="$HERE/sync_docs.py"
TMP="$(mktemp -d)"
cleanup() { git -C "$ROOT" worktree remove --force "$TMP/repo" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

if [ -z "$VERSION" ]; then
  VERSION="$(gh api repos/GiroCrab/GiroCrab/releases/latest --jq .tag_name)"
fi
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: not a stable version: '$VERSION'" >&2; exit 1; }
echo "==> Sync target version: $VERSION (mode: $MODE)"

# --- README (+ docs/assets) ------------------------------------------------------------------
if [ "$DO_README" -eq 1 ]; then
  echo "==> README.md"
  git -C "$ROOT" fetch -q origin main
  git -C "$ROOT" worktree add -q --detach "$TMP/repo" "$BASE_REF"
  python3 -I "$PY" readme "$TMP/repo" --version "$VERSION"
  if git -C "$TMP/repo" diff --quiet; then
    echo "    README.md already up to date"
  else
    git -C "$TMP/repo" --no-pager diff --stat
    git -C "$TMP/repo" --no-pager diff
    if [ "$MODE" = push ]; then
      git -C "$TMP/repo" checkout -q -B chore/sync-docs
      git -C "$TMP/repo" commit -q -am "docs: README an Release $VERSION und Konnektor-Katalog angleichen

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
      git -C "$TMP/repo" push -q --force origin chore/sync-docs
      if [ -n "$(gh pr list --head chore/sync-docs --state open --json number --jq '.[].number')" ]; then
        echo "    PR chore/sync-docs already open – branch updated"
      else
        (cd "$TMP/repo" && gh pr create --base main --head chore/sync-docs \
          --title "docs: README an Release $VERSION angleichen" \
          --body "Automatisch erzeugt von \`scripts/sync-docs-and-website.sh\`: Versionsangaben und Konnektor-Liste (aus \`catalog.rs\`) im README.

🤖 Generated with [Claude Code](https://claude.com/claude-code)")
      fi
    fi
  fi
fi

# --- Website ---------------------------------------------------------------------------------
if [ "$DO_SITE" -eq 1 ]; then
  echo "==> $SITE_REPO"
  SITE="$TMP/site"
  if [ -n "${WEBSITE_DEPLOY_TOKEN:-}" ]; then
    AUTH="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$WEBSITE_DEPLOY_TOKEN" | base64 | tr -d '\n')"
    GITC=(git -c "http.https://github.com/.extraheader=$AUTH")
    "${GITC[@]}" clone -q --depth 1 "${SITE_CLONE_URL:-https://github.com/$SITE_REPO.git}" "$SITE"
  elif [ -n "${CI:-}" ]; then
    echo "warning: WEBSITE_DEPLOY_TOKEN is not set – skipping the website (see docs/docs-website-sync.md)." >&2
    exit 0
  else
    GITC=(git)
    if [ -n "$SITE_CLONE_URL" ]; then git clone -q "$SITE_CLONE_URL" "$SITE"; else gh repo clone "$SITE_REPO" "$SITE" -- -q --depth 1; fi
  fi
  python3 -I "$PY" site "$ROOT" "$SITE" --version "$VERSION"
  if git -C "$SITE" diff --quiet; then
    echo "    website already up to date"
  else
    git -C "$SITE" --no-pager diff --stat
    git -C "$SITE" --no-pager diff
    if [ "$MODE" = push ]; then
      git -C "$SITE" -c user.name="girocrab-sync" -c user.email="noreply@girocrab.de" \
        commit -q -am "chore: Website an Release $VERSION und Konnektor-Katalog angleichen"
      "${GITC[@]}" -C "$SITE" push -q origin HEAD:main
      echo "    pushed to $SITE_REPO main"
    fi
  fi
fi

[ "$MODE" = dry ] && echo "==> Dry run: nothing pushed. Use --push to apply."
exit 0
