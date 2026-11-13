#!/usr/bin/env bash
# Signed project announcements ("Mitteilungen"), see docs/announcements.md.
#
#   scripts/announcements.sh check FILE
#       validate a draft (schema, unique ids, https links, texts, sequence)
#   scripts/announcements.sh publish FILE [--dry-run DIR]
#       validate, set `sequence` above the published one, sign with the
#       banking-policy key, verify and COMMIT policy/announcements.json + .sig
#       (never pushes: push the commit to main or open it as a pull request)
#   scripts/announcements.sh verify [DIR]
#       check the published files (or DIR/announcements.json + .sig)
#   scripts/announcements.sh clear [--dry-run DIR]
#       publish an empty list (withdraws everything)
#   scripts/announcements.sh status
#
# Same key and signing tool as scripts/banking-policy.sh (private key only in
# the release Mac's keychain). A draft example: policy/announcements.example.json.
# Test hooks (never needed for a real publication), like banking-policy.sh:
#   BANKING_POLICY_KEY_DIR, BANKING_POLICY_ACCOUNT, BANKING_POLICY_SWIFT_FILE,
#   ANNOUNCEMENTS_SOURCE_DIR (instead of policy/ and GitHub), ANNOUNCEMENTS_NO_COMMIT=1
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SWIFT_FILE="${BANKING_POLICY_SWIFT_FILE:-GiroCrabApp/Sources/GiroCrabUI/BankingPolicy.swift}"
ACCOUNT_FILE="scripts/banking-policy-signing-account.txt"
REPO="${BANKING_POLICY_REPO:-GiroCrab/GiroCrab}"
BASE_URL="https://raw.githubusercontent.com/${REPO}/main/policy"
NAME="announcements.json"

die() { echo "announcements: $*" >&2; exit 1; }

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

active_keys_csv() {
  local keys
  keys="$(awk '/publicKeys: \[String\] = \[/{on=1; next} on && /^[[:space:]]*\]/{exit} on' "$SWIFT_FILE" \
    | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$keys" ] || die "no policy key in $SWIFT_FILE"
  # shellcheck disable=SC2086
  tool validkeys $keys | paste -sd, -
}

signing_account() {
  if [ -n "${BANKING_POLICY_ACCOUNT:-}" ]; then echo "$BANKING_POLICY_ACCOUNT"
  elif [ -f "$ACCOUNT_FILE" ]; then tr -d '[:space:]' < "$ACCOUNT_FILE"
  else die "no signing account ($ACCOUNT_FILE missing)"; fi
}

policy_dir() { echo "${ANNOUNCEMENTS_SOURCE_DIR:-$ROOT/policy}"; }

# Validates a draft; prints problems to stderr, returns 1 if there are any.
validate() {  # <file>
  python3 -I - "$1" <<'PY'
import json, re, sys, datetime
path = sys.argv[1]
bad = []
try:
    d = json.load(open(path))
except Exception as e:
    sys.exit(f"announcements: {path}: not valid JSON ({e})")
if d.get("schema") != 1: bad.append("schema must be 1")
if not isinstance(d.get("sequence"), int) or d["sequence"] < 0: bad.append("sequence must be an integer >= 0")
items = d.get("announcements")
if not isinstance(items, list): bad.append("announcements must be a list"); items = []
seen = set()
def day(v):
    try: datetime.date.fromisoformat(v); return True
    except Exception: return False
for i, a in enumerate(items):
    w = f"announcements[{i}] ({a.get('id', '?')})"
    aid = a.get("id", "")
    if not re.fullmatch(r"[A-Za-z0-9._-]{3,80}", aid): bad.append(f"{w}: id must be 3-80 chars of A-Za-z0-9._-")
    if aid in seen: bad.append(f"{w}: duplicate id")
    seen.add(aid)
    if a.get("severity", "info") not in ("info", "important"): bad.append(f"{w}: severity must be info or important")
    t = a.get("title") or {}
    if not t.get("en") or not t.get("de"): bad.append(f"{w}: title needs de and en")
    s = a.get("summary") or {}
    if not s.get("en") or not s.get("de"): bad.append(f"{w}: summary needs de and en (the banner shows it)")
    for lang, txt in t.items():
        if len(txt.split()) > 10: bad.append(f"{w}: title[{lang}] longer than 10 words")
    for lang, txt in s.items():
        if len(re.findall(r"(?<!\d)[.!?](\s|$)", txt)) > 2: bad.append(f"{w}: summary[{lang}] longer than 2 sentences")
    for k in ("from", "until"):
        if a.get(k) and not day(a[k]): bad.append(f"{w}: {k} must be YYYY-MM-DD")
    if a.get("severity") == "important" and not a.get("until"): bad.append(f"{w}: important announcements need an until date")
    if a.get("link") and not str(a["link"]).startswith("https://"): bad.append(f"{w}: link must be https")
    for dist in a.get("distribution") or []:
        if dist not in ("developer-id", "mac-app-store", "ios"): bad.append(f"{w}: unknown distribution {dist}")
if bad:
    print("\n".join("announcements: " + b for b in bad), file=sys.stderr)
    sys.exit(1)
PY
}

json_get() { python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1"; }

published_sequence() {  # prints the sequence of the published file, or -1
  local dir f
  dir="$(policy_dir)"
  if [ -n "${ANNOUNCEMENTS_SOURCE_DIR:-}" ]; then
    f="$dir/$NAME"; [ -f "$f" ] && json_get "$f" 'd["sequence"]' || echo -1
  else
    f="$(mktemp)"
    local code; code="$(curl -sL -o "$f" -w '%{http_code}' "$BASE_URL/$NAME")"
    if [ "$code" = "200" ]; then json_get "$f" 'd["sequence"]'; else echo -1; fi
    rm -f "$f"
  fi
}

verify_pair() {  # <dir>
  tool verify "$(active_keys_csv)" "$1/$NAME" "$1/$NAME.sig" >/dev/null || die "INVALID signature: $1/$NAME"
  validate "$1/$NAME" || die "$1/$NAME does not validate"
}

publish_file() {  # <draft> <dry-run dir or empty>
  local draft="$1" dry="${2:-}"
  validate "$draft" || die "fix the draft first"
  local cur seq out
  cur="$(published_sequence)"
  seq=$((cur + 1))
  out="${dry:-$(policy_dir)}"
  mkdir -p "$out"
  python3 -I - "$draft" "$out/$NAME" "$seq" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["sequence"] = int(sys.argv[3])
open(sys.argv[2], "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
  tool sign "$(signing_account)" "$out/$NAME" "$out/$NAME.sig"
  verify_pair "$out"
  echo "==> signed and verified: $out/$NAME (sequence $seq)"
  if [ -n "$dry" ] || [ -n "${ANNOUNCEMENTS_NO_COMMIT:-}" ]; then echo "==> not committed"; return 0; fi
  git add "policy/$NAME" "policy/$NAME.sig"
  git commit -q -m "Announcements: sequence $seq" -- "policy/$NAME" "policy/$NAME.sig"
  echo "==> committed. NOT pushed: push to main, or open it as a pull request."
}

DRY=""
parse_dry() { while [ $# -gt 0 ]; do case "$1" in --dry-run) DRY="$2"; shift 2 ;; *) die "unknown option $1" ;; esac; done; }

cmd="${1:-}"; shift || true
case "$cmd" in
  check)
    [ $# -eq 1 ] || die "usage: check FILE"
    validate "$1" && echo "ok: $1"
    ;;
  publish)
    [ $# -ge 1 ] || die "usage: publish FILE [--dry-run DIR]"
    draft="$1"; shift; parse_dry "$@"
    publish_file "$draft" "$DRY"
    ;;
  clear)
    parse_dry "$@"
    empty="$(mktemp)"; echo '{"schema":1,"sequence":0,"announcements":[]}' > "$empty"
    publish_file "$empty" "$DRY"; rm -f "$empty"
    ;;
  verify)
    dir="${1:-$(policy_dir)}"
    if [ -z "${1:-}" ] && [ -z "${ANNOUNCEMENTS_SOURCE_DIR:-}" ]; then
      dir="$(mktemp -d)"
      curl -fsSL -o "$dir/$NAME" "$BASE_URL/$NAME" || die "nothing published"
      curl -fsSL -o "$dir/$NAME.sig" "$BASE_URL/$NAME.sig" || die "$NAME is published without .sig"
    fi
    verify_pair "$dir"; echo "ok: $dir/$NAME"
    ;;
  status)
    echo "published sequence: $(published_sequence)"
    echo "signing account: $(signing_account 2>/dev/null || echo '<none>')"
    ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
