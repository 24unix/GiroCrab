#!/usr/bin/env bash
# Write and EdDSA-sign the Sparkle appcast – ONE feed for all channels.
#
# Usage: scripts/make-appcast.sh <stable|beta|nightly> <zip> <notes.md> <out.xml>
#
# The feed lives as `appcast.xml` on the latest stable GitHub release; apps
# read .../releases/latest/download/appcast.xml. It holds at most one item per
# channel: stable (no <sparkle:channel>), `beta`, `nightly`. Each run replaces
# the item of its own channel and keeps the others from the current feed
# (GIROCRAB_EXISTING_APPCAST) – but only if that feed verifies against our key,
# because the result is re-signed. Sparkle then filters by channel: stable
# users only see the stable item, beta users stable+beta, nightly users all.
#
# Required env:
#   GIROCRAB_BUILD_VERSION   CFBundleVersion of the archive
#                              stable  X.Y.Z
#                              beta    X.Y.ZbN               (tag vX.Y.Z-beta.N)
#                              nightly <last tag's version>.YYYYMMDDhhmm
#   GIROCRAB_TAG             release that hosts the zip (vX.Y.Z, vX.Y.Z-beta.N,
#                            nightly) – or GIROCRAB_DOWNLOAD_URL instead
# Optional env:
#   GIROCRAB_SHORT_VERSION   display version (default derived from the above)
#   GIROCRAB_EXISTING_APPCAST current feed to merge (missing/empty = new feed)
#   GIROCRAB_REPO            owner/name (default GiroCrab/GiroCrab)
#   GIROCRAB_DOWNLOAD_URL    full enclosure URL (tests)
#   SPARKLE_ED_KEY_FILE      private key file instead of the login keychain (tests)
# Critical (security) updates, stable only – set by notarize.sh --critical:
#   GIROCRAB_CRITICAL=1           <sparkle:criticalUpdate/>: no "Skip"/"Remind me
#                                 later". Never installs without consent. Only
#                                 reaches users who did not skip this very
#                                 version – ship fixes as a NEW version.
#   GIROCRAB_CRITICAL_BELOW=X.Y.Z critical only for installs older than X.Y.Z
set -euo pipefail

CHANNEL="$1"; ZIP="$2"; NOTES="$3"; OUT="$4"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${GIROCRAB_REPO:-GiroCrab/GiroCrab}"
BUILD_VERSION="${GIROCRAB_BUILD_VERSION:?GIROCRAB_BUILD_VERSION is required}"

case "$CHANNEL" in
  stable)  RE='^[0-9]+\.[0-9]+\.[0-9]+$';                      CHANNEL_XML="" ;;
  beta)    RE='^[0-9]+\.[0-9]+\.[0-9]+b[0-9]+$';               CHANNEL_XML="      <sparkle:channel>beta</sparkle:channel>" ;;
  nightly) RE='^[0-9]+\.[0-9]+\.[0-9]+(b[0-9]+)?\.[0-9]{12}$'; CHANNEL_XML="      <sparkle:channel>nightly</sparkle:channel>" ;;
  *) echo "error: channel must be stable, beta or nightly (got '$CHANNEL')" >&2; exit 2 ;;
esac
if [[ ! "$BUILD_VERSION" =~ $RE ]]; then
  echo "error: $CHANNEL build version '$BUILD_VERSION' does not match $RE" >&2
  exit 2
fi

case "$CHANNEL" in
  stable)  DEFAULT_SHORT="$BUILD_VERSION" ;;
  beta)    DEFAULT_SHORT="${BUILD_VERSION%b*} Beta ${BUILD_VERSION##*b}" ;;
  nightly) STAMP="${BUILD_VERSION##*.}"
           DEFAULT_SHORT="Nightly ${STAMP:0:4}-${STAMP:4:2}-${STAMP:6:2}" ;;
esac
SHORT_VERSION="${GIROCRAB_SHORT_VERSION:-$DEFAULT_SHORT}"

if [ -n "${GIROCRAB_DOWNLOAD_URL:-}" ]; then
  URL="$GIROCRAB_DOWNLOAD_URL"
else
  TAG="${GIROCRAB_TAG:?GIROCRAB_TAG (or GIROCRAB_DOWNLOAD_URL) is required}"
  URL="https://github.com/${REPO}/releases/download/${TAG}/$(basename "$ZIP")"
fi

CRITICAL_XML=""
if [ -n "${GIROCRAB_CRITICAL_BELOW:-}" ] || [ "${GIROCRAB_CRITICAL:-0}" = "1" ]; then
  [ "$CHANNEL" = "stable" ] || { echo "error: only stable releases can be marked critical" >&2; exit 2; }
  if [ -n "${GIROCRAB_CRITICAL_BELOW:-}" ]; then
    [[ "$GIROCRAB_CRITICAL_BELOW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || { echo "error: GIROCRAB_CRITICAL_BELOW must be X.Y.Z (got '$GIROCRAB_CRITICAL_BELOW')" >&2; exit 2; }
    CRITICAL_XML="      <sparkle:criticalUpdate sparkle:version=\"${GIROCRAB_CRITICAL_BELOW}\"></sparkle:criticalUpdate>"
  else
    CRITICAL_XML="      <sparkle:criticalUpdate></sparkle:criticalUpdate>"
  fi
  echo "==> Marking ${BUILD_VERSION} as CRITICAL update${GIROCRAB_CRITICAL_BELOW:+ for versions < $GIROCRAB_CRITICAL_BELOW}"
fi

SPARKLE_BIN="$ROOT/GiroCrabApp/.build/artifacts/sparkle/Sparkle/bin"
if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
  (cd "$ROOT/GiroCrabApp" && swift package resolve >/dev/null)
fi
KEY_ARGS=()
[ -n "${SPARKLE_ED_KEY_FILE:-}" ] && KEY_ARGS=(--ed-key-file "$SPARKLE_ED_KEY_FILE")

# The key that signs must be the one baked into the app – catch a wrong
# keychain entry before publishing an appcast no client would accept.
PUBKEY_FILE="$ROOT/scripts/sparkle-public-ed-key.txt"
if [ -z "${SPARKLE_ED_KEY_FILE:-}" ] && [ -f "$PUBKEY_FILE" ]; then
  KC_PUB="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null | tr -d '[:space:]' || true)"
  if [ "$KC_PUB" != "$(tr -d '[:space:]' < "$PUBKEY_FILE")" ]; then
    echo "error: keychain EdDSA key does not match scripts/sparkle-public-ed-key.txt" >&2
    exit 1
  fi
fi

# Existing feed: only merge it if its signature verifies with our key.
EXISTING=""
if [ -n "${GIROCRAB_EXISTING_APPCAST:-}" ] && [ -s "$GIROCRAB_EXISTING_APPCAST" ]; then
  if "$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} --verify "$GIROCRAB_EXISTING_APPCAST" >/dev/null 2>&1; then
    EXISTING="$GIROCRAB_EXISTING_APPCAST"
  else
    echo "error: existing appcast $GIROCRAB_EXISTING_APPCAST does not verify with our key – refusing to merge" >&2
    exit 1
  fi
fi

# EdDSA signature of the archive -> 'sparkle:edSignature="…" length="…"'
ENCLOSURE_SIG="$("$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$ZIP")"
echo "$ENCLOSURE_SIG" | grep -q 'sparkle:edSignature=' \
  || { echo "error: sign_update produced no signature" >&2; exit 1; }

PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
NOTES_MD="$(sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES")"

ITEM="$(mktemp)"; trap 'rm -f "$ITEM"' EXIT
cat > "$ITEM" <<XML
<item xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <title>GiroCrab ${SHORT_VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
${CHANNEL_XML}
${CRITICAL_XML}
      <sparkle:version>${BUILD_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <sparkle:fullReleaseNotesLink>https://github.com/${REPO}/releases</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[${NOTES_MD}]]></description>
      <enclosure url="${URL}" type="application/octet-stream" ${ENCLOSURE_SIG} />
    </item>
XML

mkdir -p "$(dirname "$OUT")"
python3 -I - "$ITEM" "$CHANNEL" "$REPO" "$OUT" "$EXISTING" <<'PY'
import sys, xml.etree.ElementTree as ET
SP = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SP)
item_path, channel, repo, out, existing = sys.argv[1:6]

def channel_of(item):
    c = item.find(f"{{{SP}}}channel")
    return (c.text or "").strip() if c is not None else "stable"

new_item = ET.parse(item_path).getroot()
kept = []
if existing:
    for it in ET.parse(existing).getroot().findall("./channel/item"):
        ch = channel_of(it)
        if ch != channel and ch in ("stable", "beta", "nightly") and all(channel_of(k) != ch for k in kept):
            kept.append(it)

order = {"stable": 0, "beta": 1, "nightly": 2}
items = sorted([new_item] + kept, key=lambda i: order[channel_of(i)])
rss = ET.Element("rss", {"version": "2.0"})
chan = ET.SubElement(rss, "channel")
ET.SubElement(chan, "title").text = "GiroCrab"
ET.SubElement(chan, "link").text = f"https://github.com/{repo}/releases"
ET.SubElement(chan, "language").text = "de"
chan.extend(items)
ET.indent(rss, space="  ")
ET.ElementTree(rss).write(out, encoding="utf-8", xml_declaration=True)
for it in items:
    print(f"    {channel_of(it):8} {it.find(f'{{{SP}}}version').text}")
PY

xmllint --noout "$OUT"
# Embed the feed signature (required by SURequireSignedFeed in the app).
"$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$OUT"
"$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} --verify "$OUT"
echo "==> Signed appcast ($CHANNEL): $OUT"
