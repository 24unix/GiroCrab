# Auto-Updates (macOS, Sparkle)

GiroCrab bietet In-App-Updates über [Sparkle 2](https://sparkle-project.org) an –
standardmäßig **nur stabile Releases** aus GitHub, **immer signiert**, mit
Changelog. Tester können versteckt auf **Beta** oder **Nightly** wechseln.

## Wie es funktioniert

| Baustein | Wo |
|---|---|
| Updater (nur Developer-ID-Build) | `GiroCrabApp/Sources/GiroCrabMac/Updater.swift` |
| UI-Schnittstelle + Kanäle, ohne Sparkle-Import | `GiroCrabApp/Sources/GiroCrabUI/AppUpdates.swift` |
| Menü „GiroCrab › Nach Updates suchen …“ | `RootView.swift` |
| Einstellungen › Updates (eigener Tab, auch ohne Tresor bedienbar) | `SettingsView.swift` (`UpdateSettings`) |
| Framework einbetten, Info.plist-Schlüssel | `package-macos-app.sh` |
| Signieren (inside-out, ohne `--deep`) | `scripts/sign-app.sh` |
| Disk-Image bauen und signieren | `scripts/make-dmg.sh` |
| Appcast erzeugen, zusammenführen, signieren | `scripts/make-appcast.sh` (aufgerufen von `notarize.sh`) |

* **Ein Feed für alle Kanäle:** Die App liest
  `https://github.com/GiroCrab/GiroCrab/releases/latest/download/appcast.xml`
  (hängt am letzten **stabilen** Release; GitHubs „latest“ zeigt nie auf
  Pre-Releases oder Entwürfe). Der Feed enthält höchstens einen Eintrag pro
  Kanal; Sparkle filtert per `<sparkle:channel>` (siehe unten).
* **Signatur, dreifach geprüft – in jedem Kanal gleich:**
  1. EdDSA-Signatur des Disk-Images (`SUPublicEDKey`), geprüft **vor** dem
     Einhängen (`SUVerifyUpdateBeforeExtraction`).
  2. EdDSA-Signatur des Appcasts selbst (`SURequireSignedFeed`) – ein
     manipulierter Feed wird verworfen, bevor überhaupt ein Changelog erscheint.
  3. Sparkle verlangt, dass die neue App mit derselben Developer-ID (Team-ID)
     signiert ist wie die installierte; Gatekeeper prüft die Notarisierung.

  Mit dem EdDSA-Schlüssel allein lässt sich deshalb kein Code ausliefern –
  dafür bräuchte ein Angreifer zusätzlich die Developer ID.
* **Changelog:** Die Release-Notes (Markdown, wie im GitHub-Release) stehen im
  Appcast (`sparkle:format="markdown"`) und werden im Update-Fenster angezeigt.
* **Kein Schlüssel → kein Updater:** Solange `scripts/sparkle-public-ed-key.txt`
  fehlt (und `GIROCRAB_SPARKLE_PUBLIC_KEY` nicht gesetzt ist), wird Sparkle zwar
  eingebettet, aber nie gestartet; Menüpunkt und Einstellungen sind ausgeblendet.
* **Datenschutz:** kein System-Profiling (`SUEnableSystemProfiling = false`).

## Kanäle: Stabil, Beta, Nightly

| Kanal | Quelle | Tag / Release | `CFBundleVersion` | Sparkle-Kanal | sieht |
|---|---|---|---|---|---|
| **Stabil** (Standard) | `notarize.sh --upload vX.Y.Z` | `vX.Y.Z` (latest) | `X.Y.Z` | – | Stabil |
| **Beta** | `notarize.sh --upload vX.Y.Z-beta.N` | `vX.Y.Z-beta.N` (Pre-Release) | `X.Y.ZbN` | `beta` | Stabil + Beta |
| **Nightly** | `notarize.sh --nightly` | `nightly` (rollender Pre-Release) | `<letzter v*-Tag>.<UTC-Zeitstempel>` | `nightly` | alle |

**Versionsschema** (gegen Sparkles Versionsvergleich getestet):
`0.5.5 < 0.5.5.202611121530 (Nightly) < 0.6.0b1 < 0.6.0b1.202611131530 (Nightly) < 0.6.0b2 < 0.6.0`.
Nightlies setzen also auf dem letzten Tag auf und sortieren vor der nächsten
Beta bzw. stabilen Version – Nightly-Tester bekommen die automatisch.
Achtung: `0.6.0-beta.1` wäre für Sparkle **gleich** `0.6.0`; deshalb `0.6.0b1`
als Bundle-Version (Anzeige: „0.6.0-beta.1“ bzw. „0.6.0 Beta 1“).

**Feed zusammenführen:** Jeder Lauf von `notarize.sh` lädt den aktuellen Feed,
prüft dessen Signatur, ersetzt nur den Eintrag des eigenen Kanals und signiert
neu. Stabile Releases hängen den Feed an ihr eigenes Release (live, sobald es
„latest“ ist); Beta und Nightly ersetzen `appcast.xml` am aktuellen stabilen
Release. Ein Feed, der nicht mit unserem Schlüssel verifiziert, wird nie
übernommen. Neue stabile Versionen erreichen so sofort auch Beta-/Nightly-Tester.

**In der App:**
* **Einschalten:** Einstellungen › Updates öffnen und die **Wahltaste (⌥)**
  drücken – erst dann erscheint „Update-Kanal“ (Stabil / Beta / Nightly). Der
  Wechsel in einen weniger stabilen Kanal muss in einem Warnhinweis bestätigt
  werden; „Abbrechen“ ist dort die Standardtaste (Return). Alternativ: `defaults write app.girocrab.mac GiroCrabUpdateChannel beta`
  (bzw. `nightly`, `stable`).
* **Kanal des Builds:** Ohne eigene Wahl gilt der Kanal des laufenden Builds
  (`X.Y.ZbN` → Beta, 4. Versionsteil → Nightly). Wer eine Beta direkt installiert
  (z. B. per Homebrew `girocrab@beta`), bleibt also in Beta.
* **Ausschalten:** Ist ein Vorabkanal aktiv, bleibt die (orange) Auswahl sichtbar.
  Zurück zu „Stabil“ geht ohne Warnung. Es gibt kein Downgrade: Die installierte
  Version bleibt, bis eine neuere stabile erscheint.
* **Signatur:** identisch zu stabilen Releases (Developer ID, Notarisierung,
  EdDSA für Disk-Image und Feed, gleicher Schlüssel). Anders geht es nicht: Sparkle prüft
  pro App, nicht pro Kanal, und kennt nur einen öffentlichen Schlüssel. Die nur
  ad-hoc signierten CI-Builds aus `nightly.yml` werden deshalb **nie** angeboten.

## Release-Artefakt: signiertes Disk-Image

Ein einziges Artefakt für Sparkle, Homebrew und den manuellen Download:
`GiroCrab-macOS-arm64.dmg` (`scripts/make-dmg.sh`), mit Developer ID signiert,
notarisiert und gestapelt; die App darin ist ebenfalls gestapelt.

* **Warum kein ZIP:** Ein ZIP lässt sich nicht codesignieren. Mit dem signierten
  Image besteht ein Update Sparkles Ersatzprüfung vor dem Entpacken („Archiv mit
  Developer ID derselben Team-ID signiert“). Das braucht man, falls der
  EdDSA-Schlüssel je **verloren** geht – ohne Umbau im Ernstfall. Geprüft im
  Quellcode von Sparkle 2.10.1 (`AppInstaller.m`, `SUUpdateValidator.m`,
  `SUCodeSigningVerifier.m`); Sparkle meldet dann allerdings bis zu 20 Tage lang
  einen ungültig signierten Feed (`SUSignedFeedFailureExpirationInterval`),
  bevor es das Update annimmt.
* **Automatische Updates** funktionieren mit dem Image genauso: Sparkle hängt
  es unsichtbar ein, kopiert die App und wirft es wieder aus.
* **Manuelle Installation:** Fenster mit „GiroCrab → Programme ziehen“; Gatekeeper
  prüft schon das heruntergeladene Image.
* Die CI-Nightlies aus `nightly.yml` bleiben ad-hoc signierte ZIP-Artefakte und
  werden nie über Sparkle angeboten.

## Kritische Updates (Sicherheitslücken)

```bash
./scripts/notarize.sh --upload vX.Y.Z --critical                 # für alle älteren Versionen
./scripts/notarize.sh --upload vX.Y.Z --critical-below A.B.C     # nur für Versionen < A.B.C
```

Setzt `<sparkle:criticalUpdate>` im (signierten) Appcast und stellt den
Release-Notes „⚠️ Sicherheitsupdate – bitte zeitnah installieren“ voran. Sparkle
zeigt dann „Ein wichtiges Update … steht zur Installation bereit“, **ohne**
„Überspringen“/„Später erinnern“. Getestet mit Sparkle 2.10.1 (Hintergrundprüfung):

| Situation | Ergebnis |
|---|---|
| Neue kritische Version (0.0.3), ältere (0.0.2) war übersprungen | ✅ Dialog „wichtiges Update“ erscheint |
| *Dieselbe* Version (0.0.2) übersprungen, nachträglich als kritisch markiert | ❌ kein Dialog – der Nutzer erfährt nichts |

**Daher: Sicherheitsfixes immer als neue Version veröffentlichen**, nie ein
bestehendes Release nachträglich auf kritisch setzen (`notarize.sh` warnt dann).

Installiert wird weiterhin nur mit Zustimmung – bewusst: Ein stilles
Zwangsupdate könnte einen laufenden Abruf oder eine Überweisung unterbrechen. Und
wären Signierschlüssel **und** Developer ID beide kompromittiert, brächte ein
Zwangsupdate fremden Code ohne jede Rückfrage auf alle Geräte.
`--critical-below` nimmt die erste nicht betroffene Version (z. B. die, in der die
Lücke eingeführt wurde), damit Nutzer neuerer Versionen nicht unnötig gedrängt
werden. Nur für stabile Tags; Beta und Nightly können nicht kritisch markiert werden.

## Einmalige Einrichtung (Maintainer, auf dem Release-Mac)

```bash
cd GiroCrabApp && swift package resolve && cd ..
SPARKLE_BIN=GiroCrabApp/.build/artifacts/sparkle/Sparkle/bin

# 1. Schlüsselpaar erzeugen – privater Schlüssel landet im Login-Schlüsselbund
$SPARKLE_BIN/generate_keys

# 2. Öffentlichen Schlüssel ins Repo (eine Zeile) und committen
$SPARKLE_BIN/generate_keys -p > scripts/sparkle-public-ed-key.txt
git add scripts/sparkle-public-ed-key.txt

# 3. Privaten Schlüssel sichern (z. B. Passwortmanager), Datei danach löschen
$SPARKLE_BIN/generate_keys -x sparkle-private-key.txt
```

> Geht der private Schlüssel verloren, können Updates nur noch über einen
> Schlüsselwechsel mit gleicher Developer-ID-Signatur ausgeliefert werden
> (siehe [Schlüsselwechsel](#schlüsselwechsel)). Nie in GitHub Secrets oder ins
> Repo legen. Developer-ID-Zertifikat, Sparkle-Schlüssel und weitere Schlüssel
> getrennt sichern, nicht in einem gemeinsamen Export.
>
> Das ist der Schlüssel **für die Updates**. Die geplante Sperre für
> Bankverbindungen (separates Issue, `banking-policy.json`) bekommt einen
> eigenen, getrennten Schlüssel.

## Release

```bash
./scripts/notarize.sh --upload vX.Y.Z           # stabil
./scripts/notarize.sh --upload vX.Y.Z-beta.N    # Beta (GitHub-Pre-Release)
./scripts/notarize.sh --nightly                 # Nightly (rollender Pre-Release)
```

Das Skript baut, signiert und notarisiert die App, packt sie in ein
**Disk-Image** (`GiroCrab-macOS-arm64.dmg`, mit Verknüpfung zu „Programme“),
signiert und notarisiert auch das Image, prüft die Version im Bundle, lädt das
Image hoch und danach den zusammengeführten, signierten `appcast.xml`. Bleibt ein
stabiles Release ein Entwurf, ist sein Feed noch nicht live – erst beim
Veröffentlichen. `make-appcast.sh` bricht ab, wenn der Schlüssel im
Schlüsselbund nicht zu `scripts/sparkle-public-ed-key.txt` passt oder der
vorhandene Feed nicht verifiziert.

**Wichtig:** Erst Versionen *mit* eingebautem Updater können Updates empfangen.
Wer eine ältere Version nutzt, muss einmal manuell aktualisieren.

## Schlüsselwechsel

Installierte Apps kennen nur den öffentlichen Schlüssel, mit dem sie gebaut
wurden (`SUPublicEDKey`). Ein neuer Schlüssel kommt deshalb über ein
**Übergangs-Release**: Es bringt den neuen öffentlichen Schlüssel mit, ist aber
noch mit dem **alten** signiert.

| Datei (im Repo, nicht geheim) | Inhalt |
|---|---|
| `scripts/sparkle-public-ed-key.txt` | öffentlicher Schlüssel, der in die App kommt |
| `scripts/sparkle-key-account.txt` | Schlüsselbund-Konto, das signiert (fehlt: Sparkles Standard `ed25519`) |
| `scripts/sparkle-previous-key-account.txt` | nur während eines Wechsels: altes Konto, mit dem der aktuelle Feed noch signiert sein darf |
| `scripts/sparkle-previous-public-ed-key.txt` | nur während eines Wechsels: alter öffentlicher Schlüssel (für die Überwachung der Releases) |

### Vorsorglich oder bei Verdacht (alter Schlüssel noch vorhanden)

```bash
./scripts/notarize.sh --upload vX.Y.Z --rotate-key girocrab-2   # Übergangs-Release
git add scripts/sparkle-*.txt && git commit -m "chore(updates): Sparkle-Schlüssel gewechselt"
```

Alle geänderten `scripts/sparkle-*.txt` **gemeinsam** committen: Steht nur der
neue öffentliche Schlüssel im Repo, nicht aber der alte als Vorgänger, meldet eine
Überwachung der Releases den noch alt signierten Feed als Abweichung.

`--rotate-key` (nur stabile Tags – ein stabiles Release erreicht auch Beta- und
Nightly-Nutzer):

1. erzeugt den neuen Schlüssel im Schlüsselbund (Konto `girocrab-2`) und setzt
   `scripts/sparkle-public-ed-key.txt` auf den **neuen** öffentlichen Schlüssel,
2. baut das Release und signiert Disk-Image und Appcast mit dem **alten**
   Schlüssel (der Abgleich „Schlüssel = Repo“ prüft dabei gegen den alten),
3. prüft vor dem Hochladen, dass das Bundle den neuen Schlüssel enthält und Image
   und Feed mit dem alten verifizieren (`scripts/sparkle-key.sh verify-transition`),
4. trägt nach dem Upload das neue Konto als Signierer und das alte als Vorgänger
   ein. Das nächste Release signiert mit dem neuen Schlüssel und übernimmt den
   noch alt signierten Feed.

Wer das Übergangs-Release überspringt, bekommt danach kein Update mehr über
Sparkle. Deshalb das Übergangs-Release eine Weile das neueste in allen Kanälen
sein lassen. Danach:

```bash
scripts/sparkle-key.sh retire-previous   # Vorgänger vergessen, dann alten Schlüssel + Sicherung löschen
```

Bei **Verdacht auf Diebstahl** zusätzlich eine Sicherheitsmeldung (GitHub
Advisory) veröffentlichen: was möglich war, welcher Zeitraum, was Nutzer tun
müssen (in der Regel nur das Update).

### Schlüssel verloren

Ein Übergangs-Release ist dann unmöglich. Sparkle nimmt ein Update mit neuem
Schlüssel trotzdem an, wenn die Developer ID gleich bleibt – geprüft im Quellcode
von Sparkle 2.10.1 für unsere Einstellungen, **nicht praktisch getestet**:

| Stufe | Was Sparkle prüft | Folge bei neuem Schlüssel |
|---|---|---|
| Feed | Signatur gegen den alten Schlüssel | schlägt fehl; Sparkle meldet **20 Tage** „The update feed is improperly signed“ und arbeitet danach im „sicheren Modus“ (Einträge ohne Changelog) |
| Archiv vor dem Entpacken | EdDSA, sonst: Archiv selbst mit Developer ID derselben Team-ID signiert | besteht, weil das Release-Artefakt ein signiertes, notarisiertes Disk-Image ist (ein ZIP würde abgelehnt) |
| App nach dem Entpacken | EdDSA **oder** gleiche Code-Signatur | besteht über die Code-Signatur |

```bash
./scripts/notarize.sh --upload vX.Y.Z --lost-key girocrab-2
git add scripts/sparkle-*.txt && git commit -m "chore(updates): neuer Sparkle-Schlüssel (alter verloren)"
```

`--lost-key` erzeugt den neuen Schlüssel, trägt ihn ein und beginnt einen
**neuen Feed** (`GIROCRAB_DISCARD_EXISTING_APPCAST=1`; Beta-/Nightly-Einträge
fallen bis zum nächsten Lauf weg). Nutzer erhalten das Update frühestens 20 Tage
nach ihrer ersten fehlgeschlagenen Feed-Prüfung und ohne Changelog. Deshalb einen
Hinweis zum manuellen Download auf die Release-Seite setzen. Die 20-Tage-Frist
**nicht** verkürzen: In dieser Zeit schützt sie vor einem untergeschobenen Feed,
und gegen fremden Code schützt weiterhin die Developer-ID-Prüfung.

### Developer ID kompromittiert

Zertifikat bei Apple widerrufen lassen: Alle damit signierten Builds starten
nicht mehr. Ein neues Zertifikat hat für Sparkle eine andere Code-Signatur;
Developer-ID-Nutzer müssen einmal von Hand neu installieren.

## Lokaler Test (ohne echten Schlüssel)

```bash
# Wegwerf-Schlüssel
openssl genpkey -algorithm ed25519 -out k.pem
openssl pkey -in k.pem -outform DER | tail -c 32 | base64 > priv.txt
openssl pkey -in k.pem -pubout -outform DER | tail -c 32 | base64 > pub.txt

# „alte“ App mit lokalem Feed bauen
GIROCRAB_VERSION=0.0.1 GIROCRAB_SPARKLE_PUBLIC_KEY="$(cat pub.txt)" \
GIROCRAB_SPARKLE_FEED_URL=http://127.0.0.1:8765/appcast.xml ./package-macos-app.sh

# neue Versionen: Kopien mit passender CFBundleVersion, scripts/sign-app.sh - <app>,
# als (unsigniertes) Image packen, dann je Kanal einen Eintrag in denselben Feed mischen:
scripts/make-dmg.sh new/GiroCrab.app feed/stable.dmg -
export SPARKLE_ED_KEY_FILE=priv.txt
GIROCRAB_BUILD_VERSION=0.0.2 GIROCRAB_DOWNLOAD_URL=http://127.0.0.1:8765/stable.dmg \
  scripts/make-appcast.sh stable feed/stable.dmg notes.md feed/a1.xml
GIROCRAB_BUILD_VERSION=0.0.3b1 GIROCRAB_DOWNLOAD_URL=http://127.0.0.1:8765/beta.dmg \
GIROCRAB_EXISTING_APPCAST=feed/a1.xml scripts/make-appcast.sh beta feed/beta.dmg notes.md feed/appcast.xml
python3 -m http.server 8765 --bind 127.0.0.1 --directory feed
```

Für Tests die Bundle-ID der Test-Apps ändern (z. B. `app.girocrab.mac.updatetest`),
damit die Einstellungen der echten App unberührt bleiben, und in die Info.plist
der Test-Apps `LSEnvironment` = `{GIROCRAB_DEMO_SEED = 1}` eintragen (vor dem
Signieren): Dann startet auch die von Sparkle neu gestartete App mit Demo-Daten.

Schlüsselwechsel testen: zwei Wegwerf-Schlüssel (`old`, `new`), Version 1 mit
`old`, Übergangs-Release 2 mit `SUPublicEDKey` = `new`, aber mit `old` signiert
(`SPARKLE_KEY_DIR=<dir>` mit `old.key`/`old.pub`, `new.key`/`new.pub`,
`SPARKLE_KEY_ACCOUNT=old`), Version 3 mit `new` signiert. Erwartet: 1 → 2 → 3
klappt; 1 → 3 direkt wird abgelehnt.

> **Achtung:** Der Tresorpfad (`~/Library/Application Support/GiroCrab/tresor.girocrab`)
> hängt *nicht* von der Bundle-ID ab. Nach „Installieren und neu starten“ startet
> Sparkle die App **ohne** `--demo-seed` – die Test-App öffnet dann den echten
> Tresor. Tests daher in einem separaten macOS-Benutzer durchführen oder die App
> nach dem Neustart sofort beenden.

Erwartet: Update 0.0.1 → 0.0.2 mit Changelog; manipuliertes Image →
„Update ist nicht ordnungsgemäß signiert“; Appcast mit fremdem Schlüssel →
„update feed is improperly signed“; Stabil sieht nur 0.0.2, Beta „0.0.3 Beta 1“,
Nightly den Nightly-Eintrag.

## Apple-HIG

* „Nach Updates suchen …“ steht im App-Menü direkt unter „Über GiroCrab“, als
  eigene Gruppe; der Knopf in den Einstellungen heißt genauso.
* Eigener Einstellungs-Tab „Updates“ (wie „Softwareupdate“ unter macOS), nutzbar
  ohne geöffneten Tresor. Nach #108 (Tab „Allgemein“) kann der Bereich dorthin
  wandern.
* Riskante Kanalwechsel: Warnhinweis mit rotem Aktionsknopf, „Abbrechen“ als
  Standardtaste. Zurück zu „Stabil“ ohne Rückfrage.
* Vorabkanäle hinter ⌥ – die übliche Mac-Konvention für Experten-Optionen; der
  sichtbare Hinweistext verrät sie nicht. Ist ein Vorabkanal aktiv, ist er immer
  sichtbar (orange + Warnsymbol, nicht nur Farbe).
* Update-Fenster, Fortschritt und Fehlermeldungen kommen von Sparkles
  Standard-UI (AppKit, lokalisiert, inkl. Deutsch).

## Mac App Store

Sparkle steckt ausschließlich im SPM-Ziel `GiroCrabMac` (Developer-ID-Build).
`GiroCrabUI` kennt nur das Protokoll `AppUpdateBackend`. Ein App-Store-Build über
das Xcode-Ziel (`Xcode/App/GiroCrabApp.swift`) linkt Sparkle nicht und registriert
keinen Updater – Menüpunkt und Einstellungen erscheinen dort nicht.

Damit steht Sparkle einem App-Store-Build nicht im Weg. **App-Store-fähig ist die
App dadurch aber noch nicht:** Dafür fehlt unter anderem die Sandbox, die der
Developer-ID-Build bewusst nicht nutzt (deshalb sind auch Sparkles XPC-Dienste
entfernt).
