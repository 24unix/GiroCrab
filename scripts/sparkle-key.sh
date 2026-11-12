#!/usr/bin/env bash
# Sparkle EdDSA key: status, rotation and the "key lost" emergency.
# Used by scripts/notarize.sh --rotate-key / --lost-key; see docs/auto-updates.md
# ("Schlüsselwechsel").
#
#   scripts/sparkle-key.sh status
#   scripts/sparkle-key.sh prepare-rotation <new account>
#       new key in the keychain (or reuse it), scripts/sparkle-public-ed-key.txt
#       := NEW public key; prints `export …` lines for notarize.sh so the
#       transition release is still signed with the OLD key
#   scripts/sparkle-key.sh verify-transition <GiroCrab.app> <archive> <appcast.xml>
#       the build ships the NEW key, archive and feed verify with the OLD key
#   scripts/sparkle-key.sh finish-rotation <new account> <old account>
#       after the upload: new key signs from now on, the old one may still have
#       signed the current feed (scripts/sparkle-previous-key-account.txt)
#   scripts/sparkle-key.sh retire-previous
#       after the transition period: forget the old key (delete it yourself)
#   scripts/sparkle-key.sh prepare-lost <new account>
#       key LOST: new key, new public key, new feed (prints `export …` lines)
#
# Files (committed, not secret): scripts/sparkle-public-ed-key.txt,
# scripts/sparkle-key-account.txt (signing account; default "ed25519"),
# scripts/sparkle-previous-key-account.txt and scripts/sparkle-previous-public-ed-key.txt
# (only during a transition).
# Tests: SPARKLE_KEY_DIR=<dir> with <account>.key / <account>.pub instead of
# the keychain.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PUB_FILE="scripts/sparkle-public-ed-key.txt"
ACCOUNT_FILE="scripts/sparkle-key-account.txt"
PREV_FILE="scripts/sparkle-previous-key-account.txt"
PREV_PUB_FILE="scripts/sparkle-previous-public-ed-key.txt"   # read by the release-integrity check
SPARKLE_BIN="${SPARKLE_BIN:-GiroCrabApp/.build/artifacts/sparkle/Sparkle/bin}"

die() { echo "sparkle-key: $*" >&2; exit 1; }
need_bin() {
  if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
    (cd GiroCrabApp && swift package resolve >/dev/null) || die "Sparkle tools missing (swift package resolve in GiroCrabApp)"
  fi
}
valid_account() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid account name '$1'"; }
read_file() { [ -f "$1" ] && tr -d '[:space:]' < "$1" || true; }
current_account() { local a; a="$(read_file "$ACCOUNT_FILE")"; echo "${a:-ed25519}"; }

# Public key of <account>; creates the key if it does not exist (keychain mode).
pub_of() {
  if [ -n "${SPARKLE_KEY_DIR:-}" ]; then
    [ -f "$SPARKLE_KEY_DIR/$1.pub" ] || die "test key $SPARKLE_KEY_DIR/$1.pub missing"
    tr -d '[:space:]' < "$SPARKLE_KEY_DIR/$1.pub"; return
  fi
  need_bin
  local p
  p="$("$SPARKLE_BIN/generate_keys" --account "$1" -p 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -z "$p" ]; then
    [ "${2:-}" = "create" ] || die "no Sparkle key for account '$1' in the keychain"
    "$SPARKLE_BIN/generate_keys" --account "$1" >/dev/null
    p="$("$SPARKLE_BIN/generate_keys" --account "$1" -p | tr -d '[:space:]')"
    echo "==> New Sparkle key '$1' created in the login keychain – back it up offline now" >&2
  fi
  echo "$p"
}
key_args() {  # sets ARGS for sign_update
  if [ -n "${SPARKLE_KEY_DIR:-}" ]; then ARGS=(--ed-key-file "$SPARKLE_KEY_DIR/$1.key")
  else ARGS=(--account "$1"); fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  status)
    echo "public key in the app: $(read_file "$PUB_FILE")"
    echo "signing account:       $(current_account)"
    prev="$(read_file "$PREV_FILE")"
    [ -n "$prev" ] && echo "previous account:      $prev (transition – retire-previous once most users updated)"
    ;;
  prepare-rotation)
    new="${1:-}"; valid_account "$new"
    old="$(current_account)"
    [ "$new" != "$old" ] || die "new account must differ from the current one ('$old')"
    [ -f "$PUB_FILE" ] || die "$PUB_FILE missing – in-app updates are not set up"
    old_pub="$(read_file "$PUB_FILE")"
    [ "$(pub_of "$old")" = "$old_pub" ] || die "current key '$old' does not match $PUB_FILE – cannot sign a transition release (key lost? use --lost-key)"
    new_pub="$(pub_of "$new" create)"
    [ "$new_pub" != "$old_pub" ] || die "new key equals the old one"
    echo "$new_pub" > "$PUB_FILE"
    echo "==> $PUB_FILE now holds the NEW key; this release is signed with the OLD key '$old'" >&2
    # notarize.sh evals this line: %q keeps every value a single shell word.
    printf 'export SPARKLE_KEY_ACCOUNT=%q SPARKLE_SIGNING_PUBLIC_KEY=%q SPARKLE_ROTATION_OLD=%q SPARKLE_ROTATION_NEW=%q\n' \
      "$old" "$old_pub" "$old" "$new"
    ;;
  verify-transition)
    app="${1:-}"; archive="${2:-}"; feed="${3:-}"
    [ -d "$app" ] && [ -f "$archive" ] && [ -f "$feed" ] || die "usage: verify-transition <app> <archive> <appcast>"
    old="${SPARKLE_ROTATION_OLD:?}"; new="${SPARKLE_ROTATION_NEW:?}"
    in_app="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")"
    [ "$in_app" = "$(pub_of "$new")" ] || die "the build does not ship the new key '$new' (SUPublicEDKey = $in_app)"
    need_bin
    key_args "$old"
    "$SPARKLE_BIN/sign_update" "${ARGS[@]}" --verify "$feed" >/dev/null || die "appcast does not verify with the OLD key '$old'"
    sig="$(python3 -I - "$feed" "$(basename "$archive")" <<'PY'
import sys, xml.etree.ElementTree as ET
SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
for enc in ET.parse(sys.argv[1]).getroot().iter("enclosure"):
    if enc.get("url", "").endswith("/" + sys.argv[2]):
        print(enc.get(SP + "edSignature")); break
PY
)"
    [ -n "$sig" ] || die "no appcast item for $(basename "$archive")"
    "$SPARKLE_BIN/sign_update" "${ARGS[@]}" --verify "$archive" "$sig" >/dev/null \
      || die "archive does not verify with the OLD key '$old'"
    echo "ok: build ships '$new', archive and appcast verify with '$old'"
    ;;
  finish-rotation)
    new="${1:-}"; old="${2:-}"; valid_account "$new"; valid_account "$old"
    echo "$new" > "$ACCOUNT_FILE"
    echo "$old" > "$PREV_FILE"
    echo "${SPARKLE_SIGNING_PUBLIC_KEY:-$(pub_of "$old")}" > "$PREV_PUB_FILE"
    cat <<EOF
==> Rotation done. Commit $PUB_FILE, $ACCOUNT_FILE, $PREV_FILE, $PREV_PUB_FILE.
    From now on releases are signed with '$new'; the feed signed with '$old' is still merged.
    Users who skip this transition release can no longer update in-app – keep it as the
    newest release in every channel for a while before the next one.
    Later: scripts/sparkle-key.sh retire-previous, then delete '$old' from the keychain and its backup.
EOF
    ;;
  retire-previous)
    prev="$(read_file "$PREV_FILE")"
    [ -n "$prev" ] || die "no previous key recorded"
    rm -f "$PREV_FILE" "$PREV_PUB_FILE"
    echo "==> Forgot '$prev'. Commit the removal of $PREV_FILE and $PREV_PUB_FILE, then delete the key:"
    echo "    security delete-generic-password -s 'https://sparkle-project.org' -a '$prev'   (and its offline backup)"
    ;;
  prepare-lost)
    new="${1:-}"; valid_account "$new"
    [ "$new" != "$(current_account)" ] || die "use a new account name"
    new_pub="$(pub_of "$new" create)"
    echo "$new_pub" > "$PUB_FILE"
    echo "$new" > "$ACCOUNT_FILE"
    rm -f "$PREV_FILE" "$PREV_PUB_FILE"
    cat >&2 <<EOF
==> KEY LOST: '$new' signs from now on; $PUB_FILE and $ACCOUNT_FILE updated (commit them).
    Installed apps reject the new feed for 20 days ("improperly signed"), then accept the
    update without changelog – only because the disk image is Developer-ID signed and
    notarized. Announce a manual download on the release page.
EOF
    printf 'export SPARKLE_KEY_ACCOUNT=%q SPARKLE_SIGNING_PUBLIC_KEY=%q GIROCRAB_DISCARD_EXISTING_APPCAST=1\n' "$new" "$new_pub"
    ;;
  *)
    sed -n '2,26p' "$0"; exit 2 ;;
esac
