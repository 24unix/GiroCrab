#!/usr/bin/env bash
# Signed banking policy ("Sicherheitssperre für Bankverbindungen"), see
# docs/banking-policy.md.
#
#   scripts/banking-policy.sh keygen [--account NAME]
#       first policy key: private key into the keychain, public key into
#       BankingPolicy.publicKeys (replaces the placeholder), first (empty)
#       policy into policy/ – activates the feature once committed and released
#   scripts/banking-policy.sh set --minimum X.Y.Z [--distribution d,…] [--channels c,…]
#       [--connectors id,…] [--advisory URL] [--update-not-available]
#       [--store-version X.Y.Z] [--add] [--bump N] [--dry-run DIR]
#       publish a block (replaces all rules; --add keeps the existing ones)
#   scripts/banking-policy.sh clear [--bump N] [--dry-run DIR]
#       publish an empty policy (lifts every block)
#   scripts/banking-policy.sh verify [DIR]
#       check the published files (or DIR/banking-policy.json + .sig)
#   scripts/banking-policy.sh fetch DIR
#       (notarize.sh) current published, verified policy into DIR (bundled as
#       floor). Fails if nothing is published. Exit 0 without files if inactive.
#   scripts/banking-policy.sh rotate-key [--retire-old]
#       new key pair, public key ADDED to BankingPolicy.publicKeys; with
#       --retire-old: remove every key except the current signing key
#   scripts/banking-policy.sh check-app <GiroCrab.app>
#       every compiled-in key is really in the built binary
#   scripts/banking-policy.sh status
#
# Published = policy/banking-policy.json + .sig on the main branch, served by
# raw.githubusercontent.com (fixed address, independent of releases). set and
# clear sign the new file, commit it and push it to main; they need a checkout
# of main that equals origin/main. Without push rights (branch protection) the
# commit stays local – push it as a pull request.
#
# The private key never leaves the release Mac's keychain (service "GiroCrab
# Banking Policy"). Test hooks (never needed for a real release):
#   BANKING_POLICY_KEY_DIR       throwaway private keys in <dir>/<account>.key instead of the keychain
#   BANKING_POLICY_ACCOUNT_FILE  other file for the signing account name
#   BANKING_POLICY_SOURCE_DIR    directory used instead of policy/ in the repo and instead of GitHub
#   BANKING_POLICY_APPCAST       local appcast.xml instead of the published one
#   BANKING_POLICY_SWIFT_FILE    other BankingPolicy.swift (keys)
#   BANKING_POLICY_NO_PUSH=1     never commit or push (files stay in the policy directory)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SWIFT_FILE="${BANKING_POLICY_SWIFT_FILE:-GiroCrabApp/Sources/GiroCrabUI/BankingPolicy.swift}"
ACCOUNT_FILE="${BANKING_POLICY_ACCOUNT_FILE:-scripts/banking-policy-signing-account.txt}"
REPO="${BANKING_POLICY_REPO:-GiroCrab/GiroCrab}"
BRANCH="main"
POLICY_PATH="policy"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${POLICY_PATH}"
APPCAST_URL="https://github.com/${REPO}/releases/latest/download/appcast.xml"
KEY_MARKER="// banking-policy-public-key"

die() { echo "banking-policy: $*" >&2; exit 1; }

# --- helpers -----------------------------------------------------------------

TOOL=""
tool() {
  if [ -z "$TOOL" ]; then
    TOOL="${TMPDIR:-/tmp}/girocrab-banking-policy-tool-$(id -u)"
    local src=(scripts/banking-policy-tool/main.swift GiroCrabApp/Sources/GiroCrabUI/BankingVersion.swift)
    if [ ! -x "$TOOL" ] || [ -n "$(find "${src[@]}" -newer "$TOOL" 2>/dev/null)" ]; then
      swiftc -O -o "$TOOL" "${src[@]}" >/dev/null || die "cannot build banking-policy-tool (Xcode needed)"
    fi
  fi
  "$TOOL" "$@"
}

# Quoted strings inside `publicKeys: [String] = [ … ]` of BankingPolicy.swift.
listed_keys() {
  awk '/publicKeys: \[String\] = \[/{on=1; next} on && /^[[:space:]]*\]/{exit} on' "$SWIFT_FILE" \
    | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p'
}
# Only real Ed25519 keys (the placeholder is not one).
active_keys() {
  local keys
  keys="$(listed_keys)"
  [ -n "$keys" ] || return 0
  # shellcheck disable=SC2086
  tool validkeys $keys
}
active_keys_csv() { active_keys | paste -sd, -; }
is_active() { [ -n "$(active_keys)" ]; }

signing_account() {
  if [ -n "${BANKING_POLICY_ACCOUNT:-}" ]; then echo "$BANKING_POLICY_ACCOUNT"
  elif [ -f "$ACCOUNT_FILE" ]; then tr -d '[:space:]' < "$ACCOUNT_FILE"
  else die "no signing account ($ACCOUNT_FILE missing) – run keygen first"; fi
}

json_get() {  # <file> <python expression on d>
  python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1"
}

# Current published policy into DIR (banking-policy.json + .sig). Returns 1 if
# nothing is published (404); dies on anything else that looks wrong.
download_current() {
  local dir="$1"
  mkdir -p "$dir"
  rm -f "$dir/banking-policy.json" "$dir/banking-policy.json.sig"
  if [ -n "${BANKING_POLICY_SOURCE_DIR:-}" ]; then
    [ -f "$BANKING_POLICY_SOURCE_DIR/banking-policy.json" ] || return 1
    cp "$BANKING_POLICY_SOURCE_DIR/banking-policy.json" "$BANKING_POLICY_SOURCE_DIR/banking-policy.json.sig" "$dir/" \
      || die "$BANKING_POLICY_SOURCE_DIR: .sig missing"
    return 0
  fi
  local code
  code="$(curl -sL -o "$dir/banking-policy.json" -w '%{http_code}' "$BASE_URL/banking-policy.json")"
  if [ "$code" = "404" ]; then rm -f "$dir/banking-policy.json"; return 1; fi
  [ "$code" = "200" ] || die "download of banking-policy.json failed (HTTP $code)"
  curl -fsSL -o "$dir/banking-policy.json.sig" "$BASE_URL/banking-policy.json.sig" \
    || die "banking-policy.json is published but banking-policy.json.sig is not"
}

verify_pair() {  # <dir>
  tool verify "$(active_keys_csv)" "$1/banking-policy.json" "$1/banking-policy.json.sig" >/dev/null \
    || die "INVALID signature: $1/banking-policy.json"
  local schema
  schema="$(json_get "$1/banking-policy.json" 'd["schema"]')"
  [ "$schema" = "1" ] || die "unknown schema $schema"
}

# Where the policy lives in the repo (or the test directory).
policy_dir() { echo "${BANKING_POLICY_SOURCE_DIR:-$ROOT/$POLICY_PATH}"; }
pushing() { [ -z "${DRY_RUN:-}" ] && [ "${BANKING_POLICY_NO_PUSH:-0}" != "1" ] && [ -z "${BANKING_POLICY_SOURCE_DIR:-}" ]; }

# The checkout must be main and equal origin/main, so the sequence read from
# policy/ is the published one and the push is a fast-forward.
require_main() {
  pushing || return 0
  git fetch -q origin "$BRANCH" || die "git fetch origin $BRANCH failed"
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || die "check out $BRANCH first"
  [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$BRANCH")" ] || die "$BRANCH is not equal to origin/$BRANCH – pull (or push) first"
  [ -z "$(git status --porcelain -- "$POLICY_PATH")" ] || die "$POLICY_PATH/ has local changes"
}

commit_and_push() {  # <dir with the new files> <sequence>
  if [ -n "${DRY_RUN:-}" ]; then echo "==> dry run: not committed ($1)"; return 0; fi
  local dir; dir="$(policy_dir)"
  mkdir -p "$dir"
  if [ "$1" != "$dir" ]; then cp "$1/banking-policy.json" "$1/banking-policy.json.sig" "$dir/"; fi
  if ! pushing; then echo "==> written to $dir (not committed)"; return 0; fi
  git add -- "$POLICY_PATH/banking-policy.json" "$POLICY_PATH/banking-policy.json.sig"
  git commit -q -m "chore(banking-policy): sequence $2" -- "$POLICY_PATH" || die "git commit failed"
  if ! git push -q origin "HEAD:$BRANCH"; then
    die "push to $BRANCH refused (branch protection?) – the commit is local; push it to a branch and merge it as a pull request"
  fi
  echo "==> Pushed to $BRANCH. raw.githubusercontent.com may serve the previous file for up to 5 minutes."
}

# Newest version a client of <channel> can update to (Sparkle appcast).
newest_in_appcast() {  # <appcast> <channel>
  python3 -I - "$1" "$2" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
accept = {"stable": {None}, "beta": {None, "beta"}, "nightly": {None, "beta", "nightly"}}[sys.argv[2]]
for item in ET.parse(sys.argv[1]).getroot().iter("item"):
    ch = item.findtext("sparkle:channel", namespaces=ns)
    v = item.findtext("sparkle:version", namespaces=ns)
    if v is None:
        enc = item.find("enclosure")
        v = enc.get("{%s}version" % ns["sparkle"]) if enc is not None else None
    if v and ch in accept:
        print(v)
PY
}

# Refuses a minimum version above what users of that distribution/channel can
# update to (self-lockout), unless the update is announced as not available.
check_lockout() {  # <minimum> <distributions csv> <channels csv|""> <store version|"">
  local min="$1" dists="$2" chans="${3:-stable,beta,nightly}" store="$4"
  if [[ ",$dists," == *",developer-id,"* ]]; then
    local appcast="${BANKING_POLICY_APPCAST:-}"
    if [ -z "$appcast" ]; then
      appcast="$(mktemp)"
      curl -fsSL -o "$appcast" "$APPCAST_URL" || die "no published appcast – cannot check for self-lockout (use --update-not-available)"
    fi
    local ch newest v
    for ch in ${chans//,/ }; do
      newest=""
      while read -r v; do
        [ -n "$v" ] || continue
        if [ -z "$newest" ] || [ "$(tool compare "$v" "$newest")" = "1" ]; then newest="$v"; fi
      done < <(newest_in_appcast "$appcast" "$ch")
      [ -n "$newest" ] || { echo "note: no $ch item in the appcast – skipped" >&2; continue; }
      [ "$(tool compare "$newest" "$min")" != "-1" ] \
        || die "developer-id/$ch: newest published version $newest < minimum $min – users could not update (use --update-not-available while the fix is not out)"
    done
  fi
  if [[ ",$dists," == *",mac-app-store,"* || ",$dists," == *",ios,"* ]]; then
    [ -n "$store" ] || die "mac-app-store/ios: give --store-version (the version live in the store) or --update-not-available"
    [ "$(tool compare "$store" "$min")" != "-1" ] \
      || die "store version $store < minimum $min – use --update-not-available until the fix is approved"
  fi
}

write_policy() {  # <out dir> <sequence> <rules json>
  mkdir -p "$1"
  python3 -I - "$1/banking-policy.json" "$2" "$3" <<'PY'
import json, sys, datetime
out, seq, rules = sys.argv[1], int(sys.argv[2]), json.loads(sys.argv[3])
doc = {"schema": 1,
       "issued": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "sequence": seq, "rules": rules}
open(out, "w").write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
PY
  tool sign "$(signing_account)" "$1/banking-policy.json" "$1/banking-policy.json.sig"
  verify_pair "$1"
}

KNOWN_CONNECTORS="fints comdirect paypal traderepublic enablebanking bunq scalable amazon-orders fnz quirion"
warn_unknown_connectors() {
  local id base
  for id in ${1//,/ }; do
    base="${id%%:*}"
    [[ " $KNOWN_CONNECTORS " == *" $base "* ]] || echo "warning: unknown connector id '$id' – apps will never match it" >&2
  done
}

publish() {  # <rules json> <bump>
  is_active || die "no policy key in $SWIFT_FILE yet – run keygen first"
  require_main
  local cur; cur="$(policy_dir)"
  local seq=0
  if [ -f "$cur/banking-policy.json" ]; then
    verify_pair "$cur"
    seq="$(json_get "$cur/banking-policy.json" 'd["sequence"]')"
    if [ -n "${ADD:-}" ]; then
      RULES="$(python3 -I -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["rules"] + json.loads(sys.argv[2])))' "$cur/banking-policy.json" "$1")"
      set -- "$RULES" "$2"
    fi
  fi
  local out="${DRY_RUN:-$(mktemp -d)}"
  write_policy "$out" "$((seq + $2))" "$1"
  echo "==> Signed policy, sequence $((seq + $2)):"
  cat "$out/banking-policy.json"
  commit_and_push "$out" "$((seq + $2))"
}

# Inserts/removes key lines in the publicKeys array.
add_key_line() {  # <base64 key> <replace placeholder: 1|0>
  python3 -I - "$SWIFT_FILE" "$1" "$2" "$KEY_MARKER" <<'PY'
import re, sys
path, key, replace, marker = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]
s = open(path, encoding="utf-8").read()
start = s.index("publicKeys: [String] = [")
end = s.index("\n    ]", start)
block = s[start:end]
line = f'        "{key}", {marker}'
if replace:
    new = re.sub(r'\n\s*"PLACEHOLDER[^\n]*', "\n" + line, block, count=1)
    if new == block:
        sys.exit("placeholder line not found")
else:
    new = block + "\n" + line
open(path, "w", encoding="utf-8").write(s[:start] + new + s[end:])
PY
}
keep_only_key() {  # <base64 key>
  python3 -I - "$SWIFT_FILE" "$1" <<'PY'
import sys
path, keep = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
start = s.index("publicKeys: [String] = [")
end = s.index("\n    ]", start)
lines = s[start:end].split("\n")
out = [l for l in lines if not l.strip().startswith('"') or f'"{keep}"' in l]
if not any(f'"{keep}"' in l for l in out):
    sys.exit("current signing key is not in the list")
open(path, "w", encoding="utf-8").write(s[:start] + "\n".join(out) + s[end:])
PY
}

new_account_name() {
  local base n=1 name
  base="girocrab-policy-$(date +%Y%m%d)"
  name="$base"
  while security find-generic-password -s "GiroCrab Banking Policy" -a "$name" >/dev/null 2>&1 \
     || [ -f "${BANKING_POLICY_KEY_DIR:-/nonexistent}/$name.key" ]; do
    n=$((n + 1)); name="$base-$n"
  done
  echo "$name"
}

# --- commands ----------------------------------------------------------------

cmd="${1:-}"; shift || true
DRY_RUN=""; ADD=""
case "$cmd" in
  keygen)
    account=""
    while [ $# -gt 0 ]; do case "$1" in --account) account="$2"; shift 2 ;; *) die "keygen: unknown option $1" ;; esac; done
    is_active && die "a policy key is already active – use rotate-key"
    account="${account:-$(new_account_name)}"
    pub="$(tool keygen "$account")"
    add_key_line "$pub" 1
    echo "$account" > "$ACCOUNT_FILE"
    first="$(policy_dir)"
    if [ -f "$first/banking-policy.json" ]; then
      echo "==> $first/banking-policy.json exists – kept"
    else
      write_policy "$first" 1 "[]"
    fi
    echo "==> New policy key '$account' (private key in the keychain, service \"GiroCrab Banking Policy\")."
    echo "    Public key added to $SWIFT_FILE: $pub"
    echo "    First (empty) policy, sequence 1: $first/"
    echo "    Back up the private key offline (password manager), separately from Sparkle and Developer ID."
    echo "    Next: commit $SWIFT_FILE, $ACCOUNT_FILE and $POLICY_PATH/ to $BRANCH, then release."
    echo "    The policy must be on $BRANCH before the release: notarize.sh refuses to build without it."
    ;;
  set)
    is_active || die "no policy key in $SWIFT_FILE yet – run keygen first"
    MIN=""; DISTS="developer-id,mac-app-store,ios"; CHANS=""; CONNS=""; ADVISORY=""; UPDATE_AVAILABLE=1; STORE=""; BUMP=1
    while [ $# -gt 0 ]; do
      case "$1" in
        --minimum) MIN="$2"; shift 2 ;;
        --distribution) DISTS="$2"; shift 2 ;;
        --channels) CHANS="$2"; shift 2 ;;
        --connectors) CONNS="$2"; shift 2 ;;
        --advisory) ADVISORY="$2"; shift 2 ;;
        --update-not-available) UPDATE_AVAILABLE=0; shift ;;
        --store-version) STORE="$2"; shift 2 ;;
        --add) ADD=1; shift ;;
        --bump) BUMP="$2"; shift 2 ;;
        --dry-run) DRY_RUN="$2"; shift 2 ;;
        *) die "set: unknown option $1" ;;
      esac
    done
    [ -n "$MIN" ] || die "set: --minimum X.Y.Z is required"
    for d in ${DISTS//,/ }; do [[ "$d" =~ ^(developer-id|mac-app-store|ios)$ ]] || die "unknown distribution '$d'"; done
    for c in ${CHANS//,/ }; do [[ "$c" =~ ^(stable|beta|nightly)$ ]] || die "unknown channel '$c'"; done
    [ -z "$ADVISORY" ] || [[ "$ADVISORY" == https://* ]] || die "--advisory must be an https URL"
    [ -z "$CONNS" ] || warn_unknown_connectors "$CONNS"
    [ "$UPDATE_AVAILABLE" = "1" ] && check_lockout "$MIN" "$DISTS" "$CHANS" "$STORE"
    RULE="$(python3 -I - "$MIN" "$DISTS" "$CHANS" "$CONNS" "$ADVISORY" "$UPDATE_AVAILABLE" <<'PY'
import json, sys
mn, d, ch, co, adv, upd = sys.argv[1:7]
r = {"distribution": d.split(","), "minimumVersion": mn}
if ch: r["channels"] = ch.split(",")
if co: r["connectors"] = co.split(",")
if adv: r["advisory"] = adv
if upd == "0": r["updateAvailable"] = False
print(json.dumps([r]))
PY
)"
    publish "$RULE" "$BUMP"
    ;;
  clear)
    BUMP=1
    while [ $# -gt 0 ]; do
      case "$1" in --bump) BUMP="$2"; shift 2 ;; --dry-run) DRY_RUN="$2"; shift 2 ;; *) die "clear: unknown option $1" ;; esac
    done
    publish "[]" "$BUMP"
    ;;
  verify)
    is_active || die "no active policy key in $SWIFT_FILE"
    dir="${1:-}"
    if [ -z "$dir" ]; then dir="$(mktemp -d)"; download_current "$dir" || die "nothing published at $BASE_URL"; fi
    verify_pair "$dir"
    echo "ok: sequence $(json_get "$dir/banking-policy.json" 'd["sequence"]'), $(json_get "$dir/banking-policy.json" 'len(d["rules"])') rule(s)"
    ;;
  fetch)
    dir="${1:-}"; [ -n "$dir" ] || die "fetch: target directory missing"
    if ! is_active; then
      echo "==> Banking policy inactive (placeholder key) – nothing to bundle"
      exit 0
    fi
    download_current "$dir" \
      || die "nothing published at $BASE_URL – commit $POLICY_PATH/ (created by keygen) to $BRANCH first"
    verify_pair "$dir"
    echo "==> Banking policy: sequence $(json_get "$dir/banking-policy.json" 'd["sequence"]') verified"
    ;;
  rotate-key)
    is_active || die "no active key yet – use keygen"
    if [ "${1:-}" = "--retire-old" ]; then
      pub="$(tool pubkey "$(signing_account)")"
      keep_only_key "$pub"
      echo "==> Kept only the current signing key ($(signing_account)) in $SWIFT_FILE."
      echo "    Release this build; the old key is worthless afterwards."
      exit 0
    fi
    account="$(new_account_name)"
    pub="$(tool keygen "$account")"
    add_key_line "$pub" 0
    echo "$account" > "$ACCOUNT_FILE"
    echo "==> New signing key '$account'; its public key was ADDED to $SWIFT_FILE."
    echo "    1. Commit, release over all distributions (scripts/banking-policy.sh check-app <app> verifies the build)."
    echo "       The published file stays valid: it is signed with the old key, which is still listed."
    echo "    2. Right away: scripts/banking-policy.sh clear --bump 1000   (or set …, signed with the new key)"
    echo "    3. Once most users updated: scripts/banking-policy.sh rotate-key --retire-old, release again."
    echo "    Stolen key: also publish a GitHub security advisory."
    ;;
  check-app)
    app="${1:-}"; [ -d "$app" ] || die "check-app: give the path to GiroCrab.app"
    bin="$app/Contents/MacOS/GiroCrabMac"
    missing=0
    while read -r k; do
      [ -n "$k" ] || continue
      if grep -qF "$k" "$bin"; then echo "ok: $k"; else echo "MISSING in build: $k" >&2; missing=1; fi
    done < <(active_keys)
    [ "$missing" = "0" ] || exit 1
    ;;
  status)
    if is_active; then
      echo "active keys:"; active_keys | sed 's/^/  /'
      echo "signing account: $(signing_account 2>/dev/null || echo '<none>')"
      echo "published at:    $BASE_URL/banking-policy.json"
    else
      echo "inactive (placeholder key) – the app never fetches a policy"
    fi
    ;;
  *)
    sed -n '2,40p' "$0"
    exit 2
    ;;
esac
