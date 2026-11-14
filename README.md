<p align="center">
  <img src="docs/assets/app-icon.png" alt="GiroCrab – App-Icon" width="112" height="112">
</p>

<h1 align="center">GiroCrab</h1>

<p align="center"><b>🇩🇪 <a href="#-deutsch">Deutsch</a> · 🇬🇧 <a href="#-english">English</a> · 🌐 <a href="https://girocrab.de">girocrab.de</a></b></p>

<h3 align="center">Die freie, native Banking-App für Mac, iPhone &amp; iPad.</h3>

<p align="center">FinTS 3.0 · PSD2 · SEPA · MoneyMoney-Import — 100&nbsp;% lokal verschlüsselt, ohne Abo, ohne Cloud-Zwang.</p>

<p align="center">
  <a href="https://github.com/GiroCrab/GiroCrab/releases/latest/download/GiroCrab-macOS-arm64.dmg"><img src="docs/assets/download-macos.svg" alt="Für macOS laden – v0.6.3 · Apple Silicon (.dmg)" width="260" height="56"></a>
  &nbsp;
  <a href="https://testflight.apple.com/join/KBmvKVpT"><img src="docs/assets/download-ios.svg" alt="iOS &amp; iPadOS App – kostenlos via Apple TestFlight" width="260" height="56"></a>
</p>

<p align="center"><sub>✓ Offiziell von Apple notarisiert · ✓ Automatische Updates · ✓ Version v0.6.3</sub></p>

<p align="center">
  <a href="https://github.com/GiroCrab/GiroCrab/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/GiroCrab/GiroCrab?label=release&color=2ea44f"></a>
  <a href="https://github.com/GiroCrab/GiroCrab/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/GiroCrab/GiroCrab/total?color=007AFF"></a>
  <a href="https://github.com/GiroCrab/GiroCrab/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/GiroCrab/GiroCrab?style=flat"></a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/overview-dark.png">
    <img src="docs/screenshots/overview.png" alt="GiroCrab – Übersicht mit Konten, Salden und Buchungen (fiktive Demo-Daten)" width="900">
  </picture>
</p>

<p align="center"><sub>⭐ Gefällt dir GiroCrab? Ein <a href="https://github.com/GiroCrab/GiroCrab/stargazers">Stern auf GitHub</a> hilft anderen, das Projekt zu finden. · <i>A star helps others find the project.</i></sub></p>

---

## 🇩🇪 Deutsch

**MoneyMoney-Alternative für macOS und iOS: Open-Source-Online-Banking für Mac (Apple Silicon) und iPhone/iPad – lokal, verschlüsselt, ohne Abo, ohne Cloud-Zwang.**
Native SwiftUI-App auf einem Rust-Kern: verschlüsselter **SQLCipher-Banking-Tresor** (XChaCha20-Poly1305 & Argon2id), Kategorienbaum,
Regeln, Händler-Erkennung, Sparplan-Ansicht, Darlehens-Tilgungsbalken und direkte Verbindungen
zu Ihren Banken per **FinTS 3.0 / HBCI** und **PSD2 (Enable Banking)** – ohne Server, ohne Tracking.

### 🆚 Warum GiroCrab? – MoneyMoney- & Outbank-Alternative ohne Abo

| Kriterium | **GiroCrab** | MoneyMoney | Outbank |
|---|---|---|---|
| 100 % lokal, kein Cloud-Konto nötig | ✅ | ✅ | ⚠️ teils Cloud-/Konto-Funktionen |
| Kein Abo, Open Source (GPLv3) | ✅ | ❌ proprietär | ❌ proprietär |
| Direktes FinTS 3.0 / HBCI + PSD2 | ✅ | ✅ FinTS | ✅ FinTS / PSD2 |
| Natives macOS + iOS (TestFlight) + Zero-Knowledge-iCloud-Sync | ✅ | ⚠️ nur macOS | ✅ |
| Direkter MoneyMoney-Datenbank-Import (`.sqlite`) | ✅ | – | – |

*Angaben zu Drittprodukten ohne Gewähr; GiroCrab ist unabhängig von diesen Anbietern. Auch als Alternative zu Banking4, Bank X oder Pecunia gedacht, die einen lokalen Mac-Client suchen.*

### ✨ Neu in v0.6.3

- 🏦 **FinTS: Einschritt-Fallback bei Fehler 9010 (#313):** lehnt die Bank die Dialoginitialisierung mit TAN-Prozess 4 ab, versucht GiroCrab es einmalig im Einschritt-Verfahren 999 und merkt sich die Präferenz für die Verbindung.
- 🧾 **SEPA-Referenzen werden gespeichert:** End-to-End-ID, Mandatsreferenz und Gläubiger-ID landen bankunabhängig am Umsatz (Schema 12) – befüllt von comdirect, FinTS/CAMT und Enable Banking (Mandatsreferenz). Die SEPA-Rohdaten sind in der Buchung aufklappbar (#320). Vor dem Testen eine Sicherungskopie des Tresors anlegen, falls ältere Versionen ihn wieder öffnen sollen.
- 🔄 **comdirect-Paging korrigiert:** Kontoumsätze blättern bei voller Seite weiter, die PostBox lädt bis zu 500 statt 50 Dokumente.
- 🪙 **bunq:** externe Sparkonten werden als Sparkonto erkannt, Konten in Auflösung übersprungen.
- 🏷️ **Kategorien (#94):** eine manuell gesetzte Kategorie oder ein ETF-Sparplan hat Vorrang vor der Eigenkonto-IBAN-Heuristik; Umbuchungen bleiben nur bei unkategorisierten Buchungen automatisch erkannt.
- 🛡️ **Weitere Korrekturen:** MoneyMoney-Passworthinweis (#321), Symlink-Schutz beim Kontoauszug-Import (#318), iOS-Entsperrtext, Sheet-Breiten auf dem iPhone und Mindestdauer des Krabben-Splash (#317) sowie Hinweise bei lang laufenden Tresor-Zugriffen mit Zählung per SQL-Aggregat (#266).

**Highlights aus v0.6.2:**

- 🧮 **Startsaldo für Konten mit berechnetem Saldo (#212, #227):** wie in MoneyMoney lässt sich ein Startsaldo mit optionalem Stichtag festlegen und per „Kalibrieren“ aus dem letzten Kontostand ableiten; der MoneyMoney-Datenbankimport übernimmt ihn. Entfernen setzt den Saldo auf die reine Umsatzsumme zurück.
- 🗄️ **Versionierte Schema-Migrationen mit Downgrade-Schutz (#206, #232):** Tresore werden in nummerierten Schritten migriert; ein Tresor aus einer neueren Version wird nicht geöffnet. Diese Version hebt Tresore auf **Schema 10** – vor dem Testen eine Sicherungskopie anlegen, falls v0.6.1 den Tresor wieder öffnen soll.
- 🖱️ **Drag & Drop in der Seitenleiste mit Einfügelinie (#230)** wie in MoneyMoney, dazu eindeutige PSD-Bankennamen im FinTS-Verzeichnis (#145) und ein Kopieren-Menü auf iOS (Konto- und Depotpositionen).

**Highlights aus v0.6.1:**

- 📲 **iOS & iPadOS jetzt via Apple TestFlight:** Die iOS-App kann ab sofort direkt per **[TestFlight-Einladung](https://testflight.apple.com/join/KBmvKVpT)** auf iPhone und iPad installiert und automatisch aktualisiert werden – kein eigener Xcode-Build mehr nötig.
- 💿 **macOS-Installer als `.dmg` + Sparkle Auto-Updates:** Offiziell von Apple signiertes und notarisiertes Disk-Image (`GiroCrab-macOS-arm64.dmg`) inklusive integrierter Update-Funktion über Sparkle.
- ⚡ **Kategorie-Zuweisung in `< 1 ms` (#159):** Optimistisches UI-Update und neue SQLite-Covering-Indizes sorgen selbst bei Tresoren mit über 30.000 Buchungen für verzögerungsfreies Kategorisieren.
- ✅ **Buchungen automatisch als geprüft markieren (#176):** Neue Option unter *Einstellungen › Allgemein › Buchungen* – nach wählbarer Verzögerung oder nur manuell.
- 🔴 **macOS Dock-Badge (#173) & farbige Konto-Icons (#175):** Optionale Anzeige der Anzahl ungeprüfter Buchungen im Dock; Konto-Symbole in der Seitenleiste erscheinen in ihrer Kontofarbe. Dazu das gemeinsame **Icon-&-Farbe-Popover** für Konten und Gruppen (#183).
- 🧙 **Neue Assistenten nach Apple HIG:** *MoneyMoney-Import* mit Salden-Abgleich (#181) und *Bank hinzufügen* (#184).
- 🏦 **Enable Banking (PSD2) & Multi-Währungs-Konten (#164):** Finom-Geschäftskonten und Multi-Währungs-Wallets mit geteilter IBAN; Vormerkungen bei comdirect (#186) und bunq (#187).
- 📣 **Projektmitteilungen (#185):** ruhiger, signierter Hinweis-Feed – ohne Release, ohne Tracking.

**Highlights aus v0.4.0 – v0.5.5:**

- 🗄️ **Direkter MoneyMoney-Datenbank-Import:** die verschlüsselte `MoneyMoney.sqlite` (inkl. Konten, Kategorienbaum, Notizen, Depot-Beständen und PDF-Kontoauszügen) wird **nur lesend** geöffnet und übernommen.
- 📁 **Eigene Kontogruppen & Untergruppen:** frei sortierbar, mit iCloud-Synchronisation und Summenzeile.
- ☁️ **Optionale iCloud-Drive-Synchronisation** zwischen Macs und iOS-Geräten per verschlüsseltem SQLCipher-Snapshot-Merge.
- 🔒 **Händler-Logos nur per Opt-in (#38):** Online-Logos sind standardmäßig **aus**; ohne Zustimmung unter *Einstellungen → Händler-Logos* bleibt alles zu 100 % lokal.

### 🚚 Umzug von MoneyMoney in 60 Sekunden

Mehrjährige Historien, Kategorien und Notizen lassen sich verlustfrei übernehmen – ohne Abo-Bindung.

**Variante A – direkt aus der MoneyMoney-Datenbank (empfohlen, macOS):**

1. In GiroCrab: *Von MoneyMoney wechseln* (Onboarding), *MoneyMoney-Import* (Seitenleiste) oder `⌘K` → „MoneyMoney Historie & Kategorien importieren“ → Tab **MoneyMoney-Datenbank**.
2. `MoneyMoney.sqlite` auswählen und das MoneyMoney-Passwort eingeben. Die Datei wird ausschließlich **lesend** geöffnet; MoneyMoney und die Originaldatei bleiben unverändert.
3. Vorschau prüfen (Konten, Kategorien, Buchungen, Notizen), Zielkonten zuordnen, **Importieren**.

<p align="center"><img src="docs/screenshots/moneymoney-db-import.png" alt="MoneyMoney-Datenbank-Import: 6 Konten, 6.790 Buchungen, 16 Kategorien (Demo-Daten)" width="560"></p>

**Variante B – Export-Datei (CSV / XML / camt.053 / MT940):**

1. In MoneyMoney das Konto wählen, **⌘A**, **Umsätze exportieren …** → **XML** oder **CSV**.
2. In GiroCrab denselben Import-Dialog öffnen, Tab **Export-Datei (CSV/XML)** wählen und die Datei hineinziehen.
3. Zielkonto wählen (oder neues Archivkonto anlegen), Vorschau prüfen, **Importieren**.

<p align="center"><img src="docs/screenshots/moneymoney-import.png" alt="MoneyMoney-Import mit Vorschau: 4.820 Buchungen, 2012 – 2026, erkannte Kategorien" width="480"></p>

Kategorien (`Haushalt\Lebensmittel`) bleiben als Baum erhalten, Notizen stehen in der Buchungsdetail-Ansicht.
Jeder Umsatz erhält einen Fingerabdruck (Datum, Betrag, IBAN/Name, Verwendungszweck): Ein erneuter Import
oder später per FinTS abgerufene, überlappende Tage erzeugen **keine Duplikate** – vorhandene Buchungen werden
nur um Kategorie und Notiz ergänzt.
**Gewohnte Komfort-Funktionen für Umsteiger:**
* **📋 Sm@rtPaste (`⌘V` / `⇧⌘V`):** Rechnungstexte oder Bankverbindungen aus der Zwischenablage direkt ins Überweisungsfenster einfügen – Empfänger, prüfsummengültige IBAN, BIC, Betrag und Verwendungszweck werden automatisch erkannt.
* **📄 E-Rechnungen & PDF-Drop:** PDF-Rechnungen einfach auf das Überweisungsfenster ziehen (liest eingebettetes **ZUGFeRD / Factur-X XML**, **EPC-QR-Codes / GiroCode** oder den PDF-Text).
* **✅ Geprüft-Häkchen (`Space`):** Umsätze in der Liste direkt per Leertaste als „geprüft“ markieren.
* **🖱️ Rechtsklick-Workflows:** Mit einem Klick alle Buchungen desselben Empfängers filtern (*„Nach ‚…‘ suchen“*) oder eine *„Neue Überweisung aus Buchung …“* vorausfüllen lassen.

### Funktionen im Überblick

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/overview-dark.png"><img src="docs/screenshots/overview.png" alt="GiroCrab – Übersicht mit fiktiven Demo-Konten" width="900"></picture></p>

<p align="center"><img src="docs/screenshots/workflow-demo.gif" alt="Animierter Rundgang: Übersicht, Alltag &amp; Konsum, Sparpläne, Dunkelmodus" width="900"></p>

*Alle Screenshots zeigen ausschließlich erfundene Demo-Daten (`GIROCRAB_DEMO_SEED=1`).*

- 🔒 **Local-First:** Alle Bankdaten bleiben auf Ihrem Gerät – in einem verschlüsselten Tresor (XChaCha20-Poly1305), geschützt durch Schlüsselbund / Touch ID bzw. Face ID. Es gibt keinen Entwickler-Server.
- 📱 **macOS + iOS (iPhone / iPad):** Eine gemeinsame SwiftUI-Codebasis auf dem Rust-Kern. Voraussetzungen: **macOS 14+ (Apple Silicon, `arm64`)** bzw. **iOS 17+**. Für iPhone und iPad steht die App direkt über **[Apple TestFlight](https://testflight.apple.com/join/KBmvKVpT)** bereit (oder kann optional mit Xcode selbst aus dem Quellcode gebaut werden).
- ☁️ **Optionale iCloud-Drive-Synchronisation:** Wer möchte, gleicht Tresor-Daten zwischen Macs und iOS-Geräten über den eigenen iCloud-Drive-Ordner (`iCloud Drive/GiroCrab/`) ab. In die Cloud wandert der Tresor nur als **verschlüsselter SQLCipher-Snapshot** (`wal_checkpoint(TRUNCATE)`); der Abgleich erfolgt deterministisch per `ATTACH DATABASE`-Merge. Eine **laufende SQLite-Datenbank mit WAL-Dateien wird nie direkt im Cloud-Speicher geöffnet.** Die Synchronisation ist **standardmäßig ausgeschaltet** und wird erst in den Einstellungen aktiviert; danach läuft der Abgleich beim Entsperren des Tresors. Der Ordner `iCloud Drive/GiroCrab/` wird erst angelegt, wenn Sie die Synchronisation aktivieren. 🔑 **Schlüssel:** Der Tresor-Schlüssel liegt **nicht** im iCloud-Ordner (die frühere Datei `tresor.key` aus v0.4.0 wird beim nächsten Abgleich automatisch gelöscht). Stattdessen teilt GiroCrab ihn standardmäßig über den **iCloud-Schlüsselbund** (`kSecAttrSynchronizable`, abschaltbar in den Einstellungen). Alternativ kopieren Sie den Schlüssel auf dem ersten Gerät („Tresor-Schlüssel kopieren“, Zwischenablage wird nach 60 s geleert) und fügen ihn einmalig auf dem zweiten Gerät ein („Schlüssel einfügen …“). ⚠️ Wer bereits v0.4.0 mit aktivem Sync genutzt hat: Die alte `tresor.key` kann noch in iCloud-Versionen/Papierkorb liegen; eine Schlüsselrotation ist für ein späteres Update geplant.
- 🗄️ **MoneyMoney-Datenbank-Import:** lesender Import der verschlüsselten `.sqlite`-Datei inkl. Konten, Kategorien, Hierarchie und Buchungshistorie (siehe oben).
- 🏦 **FinTS 3.0 / HBCI-Client & PSD2 für macOS und iOS:** FinTS 3.0 / HBCI (CAMT.052 & MT940 mit intelligenter Latin-1/UTF-8-Erkennung), **bunq** (persönlicher API-Schlüssel), PayPal, Trade-Republic-WebSocket, comdirect-REST sowie eingebettete Web-Session-/CSV-Importe für Amex & Amazon Visa.
- 💸 **SEPA-Überweisung & Echtzeitüberweisung via FinTS 3.0 / HKCCS** inkl. Verification of Payee (VoP), inkl. PushTAN, SecureGo plus & ChipTAN/photoTAN: IBAN-Prüfung (Mod-97), SEPA-konformer Zeichensatz, Empfängervorschläge aus bisherigen Buchungen und sofort vorgemerkte Buchung.
- 🏠 **Intelligente Darlehens-Verfolgung:** Tilgungsfortschritt in Prozent und automatische Verknüpfung der monatlichen „Zins & Tilgung“-Raten vom Girokonto.
- 🏷️ **Händler-Erkennung & Logos (Opt-in):** Händler und ETFs (REWE, EnBW, DB, iShares) werden lokal erkannt; Privatpersonen (z. B. „Max Mustermann“) erhalten bewusst nur neutrale Initialen. Händler-Logos werden **standardmäßig nicht** aus dem Netz geladen – das passiert erst nach Ihrer Zustimmung in den Einstellungen.
- ✏️ **Notizen schnell bearbeiten:** Doppelklick oder Return auf die Notiz in der Buchungsdetail-Ansicht.
- 🌙 **macOS Dark Mode:** folgt automatisch dem System-Erscheinungsbild (Hell/Dunkel).
- 🌐 **Lokalisierung DE/EN:** Die App ist auf Deutsch und Englisch verfügbar und folgt der Systemsprache.

- 🧾 **Rechnung scannen:** ZUGFeRD / Factur-X, GiroCode / EPC-QR und PDF-Text füllen die Überweisung vor.
- 🌍 **Banken & Dienste auf dem Mac:** Sparkasse, Volksbank / Atruvia, DKB, ING, comdirect, Consorsbank, Trade Republic, Scalable Capital, American Express, C24, Revolut, Finom, bunq und PayPal – per FinTS, Enable Banking (PSD2) oder direktem Konnektor (siehe Tabelle unten).

| Darlehen mit Tilgungsbalken | Inspektor mit Händler-Logo |
|---|---|
| <img src="docs/screenshots/loan-progress.png" alt="Immobilien-Darlehen, 27 % getilgt"> | <img src="docs/screenshots/analytics-or-inspector.png" alt="Inspektor mit EnBW-Buchung"> |

| SEPA-Überweisung mit IBAN-Prüfung | MoneyMoney-Datenbank-Import |
|---|---|
| <img src="docs/screenshots/sepa-transfer.png" alt="Neue Überweisung an Stadtwerke München, IBAN geprüft"> | <img src="docs/screenshots/moneymoney-db-import.png" alt="MoneyMoney-Datenbank-Import: 6 Konten, 6.790 Buchungen"> |

| iOS – Übersicht | iOS – Buchungen |
|---|---|
| <img src="docs/screenshots/ios-overview.png" alt="GiroCrab auf dem iPhone – Übersicht" width="300"> | <img src="docs/screenshots/ios-transactions.png" alt="GiroCrab auf dem iPhone – Buchungen" width="300"> |

### Architektur

<p>
  <a href="https://github.com/GiroCrab/GiroCrab/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/GiroCrab/GiroCrab/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="License: GPL-3.0-or-later" src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue">
  <img alt="Rust" src="https://img.shields.io/badge/core-Rust-orange">
  <img alt="Swift" src="https://img.shields.io/badge/app-SwiftUI-F05138">
  <img alt="Platforms: macOS 14+, iOS 17+, Apple Silicon" src="https://img.shields.io/badge/macOS%2014%2B%20%C2%B7%20iOS%2017%2B%20%C2%B7%20Apple%20Silicon-lightgrey">
  <img alt="PRs welcome" src="https://img.shields.io/badge/PRs-welcome-brightgreen">
</p>

```
┌──────────────────────────┐   UniFFI    ┌────────────────────────────────────┐
│ GiroCrabApp (SwiftUI)    │ ◄─────────► │ girocrab-core (Rust)               │
│ macOS 14+ (arm64) · iOS  │  Swift-API  │  vault.rs      XChaCha20-Tresor    │
│ 17+ · Face/Touch ID      │             │  rules.rs      Kategorien-Regeln   │
└──────────────────────────┘             │  merchants.rs  Händler-Erkennung   │
   ▲ optional: iCloud Drive              │  connectors/   FinTS · REST · PSD2 │
   │ (verschlüsselter Snapshot)          └──────────────┬─────────────────────┘
                                                        │ direkt, mit Ihren Zugangsdaten
                                                        ▼
                                                  Ihre Bank(en)
```

Kurz: `girocrab-core` (Rust, per UniFFI) enthält Tresor, Regeln, Händler-Erkennung und Bank-Konnektoren; `GiroCrabApp` (SwiftUI) ist die native Oberfläche für macOS und iOS. **Mitwirken:** siehe [CONTRIBUTING.md](CONTRIBUTING.md) – bitte lassen Sie sich ein Issue **vor Arbeitsbeginn zuweisen** (Ausnahme: Kleinstkorrekturen).

### Unterstützte Banken & Schnittstellen

<!-- sync:connectors:start -->
| Bank | Schnittstelle | Umsätze | Salden | Depot | Überweisung | Dauerauftrag | PDF/Postfach | Status |
|---|---|---|---|---|---|---|---|---|
| 1822direkt | FinTS 3.0 | ✓ | ✓ | ✓ | ✓ | – | ✓ | ✅ Verifiziert |
| Consorsbank | FinTS 3.0 | ✓ | ✓ | ✓ | – | – | – | ✅ Verifiziert |
| FinTS-Bank (BLZ + URL) | FinTS 3.0 | ✓ | ✓ | ✓ | ✓ | – | ✓ | ✅ Verifiziert |
| ING | FinTS 3.0 | ✓ | ✓ | – | – | – | – | 🧪 Test gesucht [#313](https://github.com/GiroCrab/GiroCrab/issues/313) |
| Volksbank Kassel Göttingen | FinTS 3.0 | ✓ | ✓ | ✓ | ✓ | – | ✓ | ✅ Verifiziert |
| bunq | REST-API | ✓ | ✓ | – | ✓ | – | ✓ | ✅ Verifiziert |
| comdirect | REST-API | ✓ | ✓ | ✓ | – | – | ✓ | ✅ Verifiziert |
| Interactive Brokers (IBKR) | REST-API | ✓ | ✓ | ✓ | – | – | – | 🧪 Test gesucht |
| PayPal | REST-API | ✓ | ✓ | – | – | – | – | ⚠️ Mit Einschränkungen [#156](https://github.com/GiroCrab/GiroCrab/issues/156) |
| Scalable Capital | REST-API | ✓ | ✓ | ✓ | – | – | – | 🧪 Test gesucht [#45](https://github.com/GiroCrab/GiroCrab/issues/45) |
| Amazon Visa | Enable Banking (PSD2) | ✓ | ✓ | – | – | – | – | ✅ Verifiziert |
| American Express | Enable Banking (PSD2) | ✓ | ✓ | – | – | – | – | ✅ Verifiziert |
| Revolut | Enable Banking (PSD2) | ✓ | ✓ | – | – | – | – | 🧪 Test gesucht [#289](https://github.com/GiroCrab/GiroCrab/issues/289) |
| Weitere Banken per PSD2 (Enable Banking) | Enable Banking (PSD2) | ✓ | ✓ | – | – | – | – | ⚠️ Mit Einschränkungen |
| Amazon Bestellungen | Web-Portal | ✓ | – | – | – | – | – | 🧪 Test gesucht |
| FNZ Bank | Web-Portal | ✓ | ✓ | ✓ | – | – | ✓ | ✅ Verifiziert |
| quirion | Web-Portal | ✓ | ✓ | ✓ | – | – | ✓ | ✅ Verifiziert |
| Trade Republic | Web-Portal | ✓ | ✓ | – | – | – | ✓ | ⚠️ Mit Einschränkungen |

Weitere deutsche Banken mit FinTS 3.0 (PIN/TAN) lassen sich über BLZ und FinTS-URL anbinden (2.010 Institute im FinTS-Verzeichnis); europäische PSD2-Banken über Enable Banking mit einer eigenen, kostenlosen Anwendung.

<sub>✅ mit echten Konten getestet · 🧪 implementiert, Rückmeldungen aus der Praxis willkommen (Issue verlinkt) · ⚠️ bekannte Einschränkungen · ✓ umgesetzt · – nicht umgesetzt. Bei FinTS hängen Depot und PDF-Kontoauszüge vom Angebot der jeweiligen Bank ab.</sub>
<!-- sync:connectors:end -->

quirion: Einrichtung, technische Details und geprüfter Umfang stehen in [docs/quirion-connector.md](docs/quirion-connector.md).

FNZ Bank / ebase / finvesto: Einrichtung, Konto- und Depotumsätze, Fondspositionen, PDF-Archiv und Einschränkungen stehen in [docs/fnz-connector.md](docs/fnz-connector.md).

Eine neue Bank anzubinden dauert meist unter 100 Zeilen: siehe
[`connectors/template.rs`](girocrab-core/src/connectors/template.rs) und [CONTRIBUTING.md](CONTRIBUTING.md).

### Schnellstart

Voraussetzungen: **macOS 14+ auf Apple Silicon (`arm64`)**, Xcode 15+, [rustup](https://rustup.rs). iOS-Geräte benötigen **iOS 17+**.

```bash
./build-xcframework.sh          # Rust-Kern + Swift-Bindings (macOS / XCFramework)
cargo run -- --demo-seed        # App mit erfundenen Demo-Daten starten
# oder: GIROCRAB_DEMO_SEED=1 cargo run
cargo test -p girocrab-core     # Tests
```

Die Demo enthält fiktive Konten und erfundene Buchungen – keine echten Daten.

*Intel-Mac?* Der Quellcode-Build funktioniert auch dort mit Swift/Xcode; nur die fertigen Release-Binaries gibt es ausschließlich für Apple Silicon.

**iOS (iPhone / iPad):** Am einfachsten per [TestFlight](https://testflight.apple.com/join/KBmvKVpT). Die App wird (noch) nicht über den App Store verteilt; wer selbst bauen möchte:
`GiroCrabApp/Xcode/GiroCrab.xcodeproj` in Xcode öffnen, Team (persönliche Apple-ID) unter *Signing & Capabilities* wählen und auf das Gerät installieren. Mit einer persönlichen Apple-ID signierte Apps laufen nur eine begrenzte Zeit und müssen danach neu installiert werden.

### 📦 Download (macOS)

Das fertige Disk-Image [`GiroCrab-macOS-arm64.dmg`](https://github.com/GiroCrab/GiroCrab/releases/latest/download/GiroCrab-macOS-arm64.dmg) (Apple Silicon, macOS 14+) gibt es unter [GitHub Releases](../../releases) – ohne Rust oder Xcode.
Aktuelle Version: **v0.6.3**. DMG öffnen und `GiroCrab.app` nach `/Programme` ziehen – die App ist **von Apple notarisiert** und aktualisiert sich per Sparkle selbst.
**iPhone / iPad:** [TestFlight-Beta beitreten](https://testflight.apple.com/join/KBmvKVpT).

**Intel-Macs:** Die offiziellen Binaries sind nur für Apple Silicon (`arm64`). Auf Intel-Macs lässt sich GiroCrab mit Swift/Xcode selbst aus dem Quellcode bauen (siehe [Schnellstart](#schnellstart)).

### ⚖️ Rechtlicher Hinweis / Haftungsausschluss (ZAG / PSD2)

GiroCrab ist ein **kostenloses, nicht-kommerzielles Open-Source-Werkzeug zur ausschließlich eigenen Nutzung** (selbst gehostete Software).
Es ist **kein Zahlungsauslösedienst und kein Kontoinformationsdienst im Sinne des ZAG bzw. der Richtlinie (EU) 2015/2366 (PSD2)**
und wird auch nicht als solcher angeboten.

- **Rein lokal:** Alle Verbindungen laufen ausschließlich direkt zwischen **Ihrem Gerät** und **Ihrer Bank** – mit **Ihren** Zugangsdaten,
  **Ihrer** FinTS-Produktregistrierung und **Ihren** API-Schlüsseln. Die Entwickler betreiben **keinen** Server; Konto-, Buchungs- oder
  Zugangsdaten gelangen **zu keinem Zeitpunkt** an die Entwickler. Die optionale iCloud-Synchronisation nutzt ausschließlich Ihren
  eigenen iCloud-Drive-Speicher (verschlüsselter Snapshot; der Schlüssel läuft über den iCloud-Schlüsselbund, siehe oben).
- **Nutzung auf eigenes Risiko, ohne Gewährleistung** (siehe GPLv3). Das gilt insbesondere für **SEPA-Überweisungen** – prüfen Sie
  Empfänger, IBAN und Betrag vor jeder Freigabe selbst – sowie für **inoffizielle Schnittstellen** (z. B. Trade Republic), die
  jederzeit ausfallen können und gegen Nutzungsbedingungen des Anbieters verstoßen können.
- Wer GiroCrab **für Dritte** betreibt, braucht ggf. eine BaFin-Erlaubnis – das ist nicht der vorgesehene Einsatzzweck.
- Keine Anlageberatung; ISIN/WKN-Angaben sind Referenzdaten ohne Gewähr. Marken gehören ihren Inhabern und dienen nur der Wiedererkennung.

---

## 🇬🇧 English

**MoneyMoney alternative for macOS and iOS: open-source online banking for Mac (Apple Silicon) and iPhone/iPad – local-first, encrypted, no subscription, no cloud required.**
A native SwiftUI app on a Rust core: encrypted **SQLCipher banking vault** (XChaCha20-Poly1305 & Argon2id), category tree, rules, merchant
recognition, savings-plan view, loan repayment progress and direct connections to your banks via
**FinTS 3.0 / HBCI** and **PSD2 (Enable Banking)** – no server, no tracking. Money is always `i64` cents, never floats.

### 🆚 Why GiroCrab? – the MoneyMoney & Outbank alternative without a subscription

| Criterion | **GiroCrab** | MoneyMoney | Outbank |
|---|---|---|---|
| 100 % local, no cloud account required | ✅ | ✅ | ⚠️ some cloud/account features |
| No subscription, open source (GPLv3) | ✅ | ❌ proprietary | ❌ proprietary |
| Direct FinTS 3.0 / HBCI + PSD2 | ✅ | ✅ FinTS | ✅ FinTS / PSD2 |
| Native macOS + iOS (TestFlight) + zero-knowledge iCloud sync | ✅ | ⚠️ macOS only | ✅ |
| Direct MoneyMoney database import (`.sqlite`) | ✅ | – | – |

*Information about third-party products without guarantee; GiroCrab is independent of these vendors.*

### ✨ What's new in v0.6.3

- 🏦 **FinTS: single-step fallback on error 9010 (#313):** if the bank rejects dialog initialisation with TAN process 4, GiroCrab retries once with single-step method 999 and remembers the preference for that connection.
- 🧾 **SEPA references are stored:** end-to-end ID, mandate reference and creditor ID are kept per booking, independent of the bank (schema 12) – filled by comdirect, FinTS/CAMT and Enable Banking (mandate reference). Raw SEPA data can be expanded in the booking (#320). Make a vault backup first if you may want to open it in an older version again.
- 🔄 **comdirect paging fixed:** account transactions keep paging on full pages, and the PostBox loads up to 500 instead of 50 documents.
- 🪙 **bunq:** external savings accounts are recognised as savings accounts, accounts being closed are skipped.
- 🏷️ **Categories (#94):** a manually set category or an ETF savings plan takes precedence over the own-account IBAN heuristic; transfers are still detected automatically for uncategorised bookings.
- 🛡️ **More fixes:** MoneyMoney password hint (#321), symlink protection for statement import (#318), iOS unlock text, sheet widths on iPhone and minimum duration of the crab splash (#317), plus reporting of long-running vault accesses and counts via SQL aggregate (#266).

**Highlights from v0.6.2:**

- 🧮 **Opening balance for accounts with a computed balance (#212, #227):** as in MoneyMoney, set an opening balance with an optional cut-off date and derive it from the latest statement balance with “Calibrate”; the MoneyMoney database import picks it up. Removing it falls back to the plain sum of the bookings.
- 🗄️ **Versioned schema migrations with downgrade protection (#206, #232):** vaults migrate in numbered steps; a vault written by a newer version is refused. This version upgrades vaults to **schema 10** – make a backup copy first if you may want to open the vault in v0.6.1 again.
- 🖱️ **Drag & drop in the sidebar with an insertion line (#230)** like MoneyMoney, unambiguous PSD bank names in the FinTS directory (#145) and a copy menu on iOS (account and depot positions).

**Highlights from v0.6.1:**

- 📲 **iOS & iPadOS via Apple TestFlight:** install and auto-update the iOS app on iPhone and iPad through the **[TestFlight invitation](https://testflight.apple.com/join/KBmvKVpT)** – no Xcode build needed any more.
- 💿 **macOS installer as `.dmg` + Sparkle auto-updates:** a disk image signed and notarized by Apple (`GiroCrab-macOS-arm64.dmg`) with built-in updates via Sparkle.
- ⚡ **Category assignment in `< 1 ms` (#159):** optimistic UI update and new SQLite covering indexes keep categorising instant even with 30,000+ bookings.
- ✅ **Mark bookings as reviewed automatically (#176):** new option under *Settings › General › Bookings* – after a configurable delay or manual only.
- 🔴 **macOS Dock badge (#173) & coloured account icons (#175):** optional count of unchecked bookings in the Dock; sidebar account symbols show their account colour. Plus the shared **icon & colour popover** for accounts and groups (#183).
- 🧙 **New Apple-HIG wizards:** *MoneyMoney import* with balance reconciliation (#181) and *Add bank* (#184).
- 🏦 **Enable Banking (PSD2) & multi-currency (#164):** Finom business accounts and multi-currency wallets sharing one IBAN; pending bookings for comdirect (#186) and bunq (#187).
- 📣 **Project notices (#185):** a calm, signed notice feed – no release needed, no tracking.

**Highlights v0.4.0 – v0.5.5:**

- 🗄️ **Direct MoneyMoney database import:** the encrypted `MoneyMoney.sqlite` (accounts, category tree, notes, depot holdings, PDF statements) is opened **read-only**.
- 📁 **Custom account groups & subgroups:** freely sortable, synced via iCloud, with a totals row.
- ☁️ **Optional iCloud Drive sync** between Macs and iOS devices via an encrypted SQLCipher snapshot merge.
- 🔒 **Merchant logos opt-in only (#38):** online logos are **off** by default; without opt-in everything stays 100 % local.

### 🚚 Migrating from MoneyMoney

Full multi-year histories, categories and notes import seamlessly – no subscription lock-in.

**Option A – straight from the MoneyMoney database (recommended, macOS):**

1. In GiroCrab: *Switch from MoneyMoney* (onboarding), *MoneyMoney-Import* (sidebar) or `⌘K` → "MoneyMoney Historie & Kategorien importieren" → tab **MoneyMoney database**.
2. Choose `MoneyMoney.sqlite` and enter your MoneyMoney password. The file is opened strictly **read-only**; MoneyMoney and the original file stay untouched.
3. Check the preview (accounts, categories, bookings, notes), map the target accounts, hit **Import**.

<p align="center"><img src="docs/screenshots/moneymoney-db-import.png" alt="MoneyMoney database import: 6 accounts, 6,790 bookings, 16 categories (demo data)" width="560"></p>

**Option B – export file (CSV / XML):**

1. In MoneyMoney select the account, press **⌘A**, then **Export Transactions …** → **XML** or **CSV**.
2. In GiroCrab open the same import dialog, pick the **Export file (CSV/XML)** tab and drop the file in.
3. Pick the target account (or create an archive account), check the preview, hit **Import**.

Hierarchical categories (`Household\Groceries`) are kept as a tree, notes show in the booking detail view.
Every booking gets a fingerprint (date, amount, IBAN/name, purpose), so re-importing the file or overlapping days
fetched later via FinTS **never create duplicates** – existing bookings are only enriched with category and note.
**Familiar everyday workflows:**
* **📋 Sm@rtPaste (`⌘V` / `⇧⌘V`):** Paste invoice text or bank details from the clipboard straight into the transfer sheet — recipient, checksum-verified IBAN, BIC, amount and purpose are filled in automatically.
* **📄 E-Invoice & PDF Drop:** Drag & drop a PDF invoice onto the transfer sheet (parses embedded **ZUGFeRD / Factur-X XML**, **EPC QR / GiroCode**, or PDF/OCR text).
* **✅ Checked toggle (`Space`):** Mark bookings as checked directly via the Spacebar.
* **🖱️ Context menu actions:** Right-click any booking to filter all transactions by that counterparty or pre-fill a new transfer from the booking.
### Features & Screenshots

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/overview-dark.png"><img src="docs/screenshots/overview.png" alt="GiroCrab – overview with fictional demo accounts" width="900"></picture></p>

<p align="center"><img src="docs/screenshots/workflow-demo.gif" alt="Animated tour: overview, everyday spending, savings plans, dark mode" width="900"></p>

*All screenshots show purely fictional demo data (`GIROCRAB_DEMO_SEED=1`).*

- 🔒 **Local-first:** all banking data lives on your device in an encrypted vault (XChaCha20-Poly1305) protected by the Keychain / Touch ID or Face ID. There is no developer server.
- 📱 **macOS + iOS (iPhone / iPad):** one SwiftUI codebase on the shared Rust core. Requires **macOS 14+ (Apple Silicon, `arm64`)** or **iOS 17+**. On iPhone and iPad the app is available via **[Apple TestFlight](https://testflight.apple.com/join/KBmvKVpT)** (or optionally built from source with Xcode).
- ☁️ **Optional iCloud Drive sync:** if you want, sync vault data between Macs and iOS devices through your own iCloud Drive folder (`iCloud Drive/GiroCrab/`). The vault goes to the cloud only as an **encrypted SQLCipher snapshot** (`wal_checkpoint(TRUNCATE)`), and devices are reconciled with a deterministic `ATTACH DATABASE` merge. **A live SQLite database with WAL files is never opened directly in cloud storage.** Sync is **off by default** and has to be enabled in Settings; once on, it runs when the vault is unlocked. The folder `iCloud Drive/GiroCrab/` is only created once you enable sync. 🔑 **Key handling:** the vault key is **not** stored in the iCloud folder (the `tresor.key` file from v0.4.0 is deleted automatically on the next sync). By default GiroCrab shares it through **iCloud Keychain** (`kSecAttrSynchronizable`, can be turned off in Settings). Alternatively, copy the key on the first device (“Copy vault key”, clipboard is cleared after 60 s) and paste it once on the second device (“Paste key …”). ⚠️ If you used v0.4.0 with sync enabled, the old `tresor.key` may still exist in iCloud versions/trash; key rotation is planned for a later release.
- 🗄️ **MoneyMoney database import:** read-only import of the encrypted `.sqlite` file incl. accounts, categories, hierarchy and booking history (see above).
- 🏦 **FinTS 3.0 / HBCI client & PSD2 for macOS and iOS:** FinTS 3.0 / HBCI (CAMT.052 & MT940 with smart Latin-1/UTF-8 decoding), **bunq** (personal API key), PayPal, Trade Republic WebSocket, comdirect REST, and embedded web-session/CSV import for Amex & Amazon Visa.
- 💸 **Native SEPA credit transfers via FinTS 3.0 / HKCCS** incl. PushTAN, SecureGo plus & ChipTAN/photoTAN: IBAN checksum validation (Mod-97), SEPA-compliant character set, recipient suggestions from past bookings and an instant pending booking.
- 🏠 **Smart loan tracking:** automatic repayment progress (%) and cross-account linking of the monthly "Zins & Tilgung" instalments from your checking account.
- 🏷️ **Merchant recognition & logos (opt-in):** German merchants & ETFs (REWE, EnBW, DB, iShares) are recognized locally, while private individuals (e.g. "Max Mustermann") get plain monogram initials by design. Merchant logos are **not** fetched online by default – only after you opt in under Settings.
- ✏️ **Quick note editing:** double-click or press Return on the note in the booking detail view.
- 🌙 **macOS Dark Mode:** automatically follows the system appearance (light/dark).
- 🌐 **German & English localization:** the app ships in German and English and follows the system language.

- 🧾 **Scan invoices:** ZUGFeRD / Factur-X, GiroCode / EPC-QR and PDF text pre-fill the transfer.
- 🌍 **Banks & services on the Mac:** Sparkasse, Volksbank / Atruvia, DKB, ING, comdirect, Consorsbank, Trade Republic, Scalable Capital, American Express, C24, Revolut, Finom, bunq and PayPal – via FinTS, Enable Banking (PSD2) or a direct connector (see the table below).

| Loan with repayment bar | Inspector with merchant logo |
|---|---|
| <img src="docs/screenshots/loan-progress.png" alt="Immobilien-Darlehen, 27% repaid"> | <img src="docs/screenshots/analytics-or-inspector.png" alt="Inspector showing an EnBW booking"> |

| SEPA transfer with IBAN check | MoneyMoney database import |
|---|---|
| <img src="docs/screenshots/sepa-transfer.png" alt="New transfer to Stadtwerke München, IBAN validated"> | <img src="docs/screenshots/moneymoney-db-import.png" alt="MoneyMoney database import: 6 accounts, 6,790 bookings"> |

| iOS – Overview | iOS – Transactions |
|---|---|
| <img src="docs/screenshots/ios-overview.png" alt="GiroCrab on iPhone – overview" width="300"> | <img src="docs/screenshots/ios-transactions.png" alt="GiroCrab on iPhone – transactions" width="300"> |

### Architecture

<p>
  <a href="https://github.com/GiroCrab/GiroCrab/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/GiroCrab/GiroCrab/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="License: GPL-3.0-or-later" src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue">
  <img alt="Rust" src="https://img.shields.io/badge/core-Rust-orange">
  <img alt="Swift" src="https://img.shields.io/badge/app-SwiftUI-F05138">
  <img alt="Platforms: macOS 14+, iOS 17+, Apple Silicon" src="https://img.shields.io/badge/macOS%2014%2B%20%C2%B7%20iOS%2017%2B%20%C2%B7%20Apple%20Silicon-lightgrey">
  <img alt="PRs welcome" src="https://img.shields.io/badge/PRs-welcome-brightgreen">
</p>

See the diagram above: the SwiftUI app (`GiroCrabApp`, macOS and iOS) talks to `girocrab-core` (Rust) through UniFFI; the core owns the
encrypted vault, categorisation rules, merchant resolver and the bank connectors, and talks to
your bank directly. Optional iCloud sync exchanges an encrypted snapshot via your own iCloud Drive.

**Contributing:** see [CONTRIBUTING.md](CONTRIBUTING.md) – please ask to be **assigned to an issue before you start** (tiny fixes excepted).

### Supported Banks & Interfaces

<!-- sync:connectors:start -->
| Bank | Interface | Transactions | Balances | Securities | Transfers | Standing orders | PDF/post box | Status |
|---|---|---|---|---|---|---|---|---|
| 1822direkt | FinTS 3.0 | ✓ | ✓ | ✓ | ✓ | – | ✓ | ✅ Verified |
| Consorsbank | FinTS 3.0 | ✓ | ✓ | ✓ | – | – | – | ✅ Verified |
| FinTS bank (bank code + URL) | FinTS 3.0 | ✓ | ✓ | ✓ | ✓ | – | ✓ | ✅ Verified |
| ING | FinTS 3.0 | ✓ | ✓ | – | – | – | – | 🧪 Testing wanted [#313](https://github.com/GiroCrab/GiroCrab/issues/313) |
| Volksbank Kassel Göttingen | FinTS 3.0 | ✓ | ✓ | ✓ | ✓ | – | ✓ | ✅ Verified |
| bunq | REST-API | ✓ | ✓ | – | ✓ | – | ✓ | ✅ Verified |
| comdirect | REST-API | ✓ | ✓ | ✓ | – | – | ✓ | ✅ Verified |
| Interactive Brokers (IBKR) | REST-API | ✓ | ✓ | ✓ | – | – | – | 🧪 Testing wanted |
| PayPal | REST-API | ✓ | ✓ | – | – | – | – | ⚠️ Limited [#156](https://github.com/GiroCrab/GiroCrab/issues/156) |
| Scalable Capital | REST-API | ✓ | ✓ | ✓ | – | – | – | 🧪 Testing wanted [#45](https://github.com/GiroCrab/GiroCrab/issues/45) |
| Amazon Visa | Enable Banking (PSD2) | ✓ | ✓ | – | – | – | – | ✅ Verified |
| American Express | Enable Banking (PSD2) | ✓ | ✓ | – | – | – | – | ✅ Verified |
| More banks via PSD2 (Enable Banking) | Enable Banking (PSD2) | ✓ | ✓ | – | – | – | – | ⚠️ Limited |
| Revolut | Enable Banking (PSD2) | ✓ | ✓ | – | – | – | – | 🧪 Testing wanted [#289](https://github.com/GiroCrab/GiroCrab/issues/289) |
| Amazon orders | Web-Portal | ✓ | – | – | – | – | – | 🧪 Testing wanted |
| FNZ Bank | Web-Portal | ✓ | ✓ | ✓ | – | – | ✓ | ✅ Verified |
| quirion | Web-Portal | ✓ | ✓ | ✓ | – | – | ✓ | ✅ Verified |
| Trade Republic | Web-Portal | ✓ | ✓ | – | – | – | ✓ | ⚠️ Limited |

Further German banks with FinTS 3.0 (PIN/TAN) can be connected via bank code and FinTS URL (2,010 institutions in the FinTS directory); European PSD2 banks via Enable Banking with your own free application.

<sub>✅ tested with real accounts · 🧪 implemented, feedback from real accounts welcome (issue linked) · ⚠️ known limitations · ✓ implemented · – not implemented. For FinTS, securities and PDF statements depend on what the individual bank offers.</sub>
<!-- sync:connectors:end -->

Adding a bank usually takes under 100 lines – start from
[`connectors/template.rs`](girocrab-core/src/connectors/template.rs) and read [CONTRIBUTING.md](CONTRIBUTING.md).

### Download (macOS)

The pre-built disk image [`GiroCrab-macOS-arm64.dmg`](https://github.com/GiroCrab/GiroCrab/releases/latest/download/GiroCrab-macOS-arm64.dmg) (Apple Silicon, macOS 14+) is available under
[GitHub Releases](../../releases) – no Rust or Xcode required. Current version: **v0.6.3**. Open the DMG and drag `GiroCrab.app` to `/Applications` – the app is **notarized by Apple** and updates itself via Sparkle.
**iPhone / iPad:** [join the TestFlight beta](https://testflight.apple.com/join/KBmvKVpT).

**Intel Macs:** the official binaries are Apple Silicon (`arm64`) only. On Intel Macs you can build GiroCrab yourself from source with Swift/Xcode (see [Quickstart](#quickstart)).

### Quickstart

Requirements: **macOS 14+ on Apple Silicon (`arm64`)**, Xcode 15+, [rustup](https://rustup.rs). iOS devices need **iOS 17+**.

```bash
./build-xcframework.sh          # Rust core + Swift bindings (macOS / XCFramework)
cargo run -- --demo-seed        # launch the app with fictional demo data
# or: GIROCRAB_DEMO_SEED=1 cargo run
cargo test -p girocrab-core     # run the tests
```

The demo ships fictional accounts and invented bookings – no real data.

*Intel Mac?* Building from source with Swift/Xcode works there too; only the pre-built release binaries are Apple Silicon-only.

**iOS (iPhone / iPad):** easiest via [TestFlight](https://testflight.apple.com/join/KBmvKVpT). The app is not (yet) in the App Store; to build it yourself:
open `GiroCrabApp/Xcode/GiroCrab.xcodeproj` in Xcode, choose your team (personal Apple ID) under *Signing & Capabilities* and install on your device. Apps signed with a personal Apple ID expire after a limited time and have to be reinstalled.

### ⚖️ Legal notice / Disclaimer (PSD2 / ZAG)

GiroCrab is a **free, non-commercial open-source tool for your own personal use only** (self-hosted software).
It is **not a payment initiation service and not an account information service within the meaning of the German ZAG / PSD2
(Directive (EU) 2015/2366)** and is not offered as one.

- **Strictly local:** all connections run directly between **your device** and **your bank**, using **your** credentials,
  **your** FinTS product registration and **your** API keys. The authors operate **no** server, and no account, booking or
  credential data **ever** reaches the authors. Optional iCloud sync uses only your own iCloud Drive storage (encrypted snapshot; the key goes through iCloud Keychain, see above).
- **Use at your own risk, without warranty** (see GPLv3). This applies in particular to **SEPA transfers** – always verify
  recipient, IBAN and amount yourself before authorising – and to **unofficial interfaces** (e.g. Trade Republic), which can
  break at any time and may violate the provider's terms of service.
- Operating GiroCrab **for third parties** may require BaFin authorisation and is not the intended use.
- Not investment advice; ISIN/WKN data is reference information without guarantee. Trademarks belong to their owners and are used for identification only.

---

## Security / Sicherheit

XChaCha20-Poly1305 + Argon2id encrypted vault, key in the Keychain (`ThisDeviceOnly`), PINs/TANs only in memory
(`zeroize`), no telemetry. Merchant logos are **opt-in** (off by default, Settings → Merchant logos); without it, no network
request is made for logos and everything stays 100 % local. **Never attach real bank data or credentials to issues.**

DE: Händler-Logos sind **standardmäßig deaktiviert** (Opt-in in den Einstellungen) – ohne Zustimmung werden keine Logos aus dem Netz geladen, alles bleibt zu 100 % lokal.

Sachwerte (gold): only if gold items exist, GiroCrab fetches the daily `XAU/EUR` price from `api.frankfurter.dev` (at most one request a day; the request contains no personal data, quantities or values). Without gold items, no such request is made.

DE: Nur wenn Gold-Sachwerte existieren, ruft GiroCrab den Tageskurs `XAU/EUR` von `api.frankfurter.dev` ab (höchstens eine Anfrage pro Tag; die Anfrage enthält keine persönlichen Daten, Mengen oder Werte). Ohne Gold-Sachwerte findet keine solche Anfrage statt.

**Security lock for bank connections:** if a version turns out to endanger bank access (e.g. a vulnerability in a
connector), the publisher can publish a signed `banking-policy.json`; older versions then stop contacting banks until
they are updated – reading and exporting keep working. Once activated, the app downloads this small signed file from
GitHub at most every 15 minutes (no personal data). Details: [docs/banking-policy.md](docs/banking-policy.md).

DE: **Sicherheitssperre für Bankverbindungen:** Enthält eine Version eine Sicherheitslücke oder einen schweren Fehler im Bankzugang, kann der Herausgeber eine signierte `banking-policy.json` veröffentlichen. Ältere Versionen kontaktieren dann keine Bank mehr, bis sie aktualisiert sind; Lesen und Exportieren bleiben möglich. Sobald aktiviert, lädt die App diese kleine Datei höchstens alle 15 Minuten von GitHub (ohne persönliche Daten). Details: [docs/banking-policy.md](docs/banking-policy.md).

## 🤖 KI-Transparenz / AI Transparency

DE: GiroCrab entsteht in hybrider Mensch-KI-Entwicklung und ist Living Lab des Forschungsprojekts *„AI-enabled Transparency of AI Use in Software Creation Processes“*. Jeder PR bekommt automatisch eine **AI Provenance & Transparency Card**. Echte Finanzdaten kommen nie in Prompts.

EN: Every PR automatically gets an AI provenance card. Real financial data never goes into prompts.

→ **[docs/ai-transparency.md](docs/ai-transparency.md)**

---

## 🏦 Wie funktioniert der Bankabgleich? (FAQ & Technik)

### 1. Wie richte ich den Abgleich mit meinen Banken ein?
1. **Bankverbindung hinterlegen:** Klicke unten in der linken Seitenleiste (oder über die Befehlspalette `⌘K`) auf **„Bankverbindungen“** (*Connections*) → **„Bankverbindung hinzufügen“**.
   - **Klassische Banken (Sparkassen, Volksbanken, DKB, ING, Comdirect, Deutsche Bank etc.):** Wähle **FinTS / HBCI** und melde dich mit deiner BLZ/BIC sowie deiner Online-Banking-Kennung und PIN an.
   - **Neobroker & Direktbanken (Trade Republic, Scalable Capital, N26, Revolut etc.):** Wähle den jeweiligen Direkt-Konnektor aus und melde dich mit deinen regulären Zugangsdaten an.
2. **2FA bestätigen:** Bestätige die Freigabe (Push-TAN / App-Freigabe / PhotoTAN) einmalig auf deinem Smartphone. GiroCrab legt alle gefundenen Konten automatisch an.
3. **Umsätze abrufen (Rundruf):** Klicke oben in der Symbolleiste auf **Synchronisieren (`↻`)** oder drücke **`⌘R`**. GiroCrab ruft neue Umsätze und Salden ab, wendet deine Kategorien-Regeln an und verhindert über deterministische Buchungs-Fingerprints zuverlässig Duplikate (auch nach einem vorherigen CSV-/CAMT-Import aus MoneyMoney).

### 2. Läuft der Abgleich technisch über einen Drittanbieter-Service oder über Webscraping?
**Weder noch!** GiroCrab arbeitet zu **100 % direkt (Point-to-Point)** zwischen deinem Gerät und der Bank – ohne Cloud-Backend, ohne PSD2-Kontoinformationsdienst (wie FinAPI, Tink oder GoCardless) dazwischen und ohne Headless-Browser/HTML-Scraping:

* **Natives FinTS 3.0 / HBCI:** Klassische Banken werden direkt aus dem Rust-Kern (`girocrab-core`) über die offiziellen FinTS-3.0-HTTPS-Endpunkte angesprochen (inkl. starker Kundenauthentifizierung nach TAN-Prozess 996/997, Decoupled-TAN, PushTAN & PhotoTAN sowie Abruf von MT940 / CAMT.052 / CAMT.053 und SEPA-Überweisungen via HKCCS).
* **Direkte Mobile-/Web-API-Clients in Rust:** Für Banken und Broker ohne FinTS-Schnittstelle (wie Trade Republic oder Scalable Capital) nutzt GiroCrab keine fragilen Browser-Scraper, sondern spricht über `reqwest` + `rustls` direkt die nativen JSON-, GraphQL- und WebSocket-Endpunkte der Banken an (z. B. lokales ECDSA-P256-Device-Pairing und signierte Requests bei Trade Republic).
* **Zero-Knowledge Datenhaltung & iCloud-Sync (macOS & iOS):** Alle Zugangsdaten, Session-Tokens und Umsätze liegen ausschließlich lokal in deinem mit **XChaCha20-Poly1305 & Argon2id** verschlüsselten SQLCipher-Tresor (geschützt durch Touch ID / Face ID). Über den optionalen **Zero-Knowledge iCloud-Sync** lassen sich Tresore zwischen Mac und iPhone/iPad konfliktfrei auf Buchungs-Fingerprint-Ebene zusammenführen, ohne dass Klartextdaten jemals dein Gerät verlassen.


## 🤝 Contributors / Mitwirkende

Danke an alle, die GiroCrab voranbringen! / Thanks to everyone who helps move GiroCrab forward!

- **[@24unix](https://github.com/24unix)** — Direct MoneyMoney database import (#11), MoneyMoney search-expression rules (#60), Dark Mode (#2), DE/EN localisation (#4), key-unlock UX hint (#6), privacy opt-in for online merchant logos (#38), iCloud sync architecture (#10), Dock badge for unchecked bookings (#173), auto-review delay (#176), account/group icon & colour popover (#183) and Enable Banking business banks (#164).
- **[@jacboy](https://github.com/jacboy)** — User-defined account groups with conflict-free iCloud sync & UI (#39, #40), SEPA Instant transfers with explicit fallback & OutcomeUnknown safety (#29), Verification of Payee / VoP (#30), bunq personal API key connector (#12), Consorsbank FinTS preset & product ID masking (#28), inline note editing (#41), the Apple-HIG wizards for MoneyMoney import (#181) and Add bank (#184), comdirect/bunq pending bookings (#186, #187), the project-notice feed (#185), the banking-policy security lock (#127) and release-integrity monitoring (#129).
- **[@nochsoeiner](https://github.com/nochsoeiner)** — FinTS securities holdings via HKWPD / MT535 (#23), interactive balance chart with hover readout & click-to-jump (#20), period-aware KPI tiles (#19), account & category markers in the booking stream (#26), and DKB FinTS URL preset fix (#25).
- **[@sebastianmattar](https://github.com/sebastianmattar)** — MoneyMoney depot balances & securities positions import (#51) Trade Republic 8-digit bank code recognition (#52), category assignment without waiting time (#159), paged booking list (#141), logo loading off the main thread (#151) and Swift tests in CI (#163).
- **[@martinhering](https://github.com/martinhering)** — Scalable Capital connector supporting Baader Bank and Scalable broker GraphQL with 2FA (#54).
- **[@andre68723](https://github.com/andre68723)** — FNZ Bank balances, depot values and PDF inbox (#104), smooth booking scope selection (#63) and a reducible main window height on macOS (#62).
- **[@HansWurst90](https://github.com/HansWurst90)** — Build script cleanup (#14) and testing & feedback on MoneyMoney and depot imports.

## License / Lizenz

GPL-3.0-or-later – see [LICENSE](LICENSE).

---

## ☕ Projekt unterstützen (Freiwillige Zuwendung)

**GiroCrab** ist ein freies Open-Source-Projekt. Wenn dir die App im Alltag hilft und du die Weiterentwicklung mit einer kleinen **freiwilligen Zuwendung** (ohne Gegenleistung) für die Kaffeekasse unterstützen möchtest:

[![PayPal](https://img.shields.io/badge/PayPal-Freiwillige%20Zuwendung-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/aprinz)

*English:* If you enjoy using GiroCrab and would like to support its development with a **voluntary contribution / tip** (no consideration expected): **[paypal.me/aprinz](https://paypal.me/aprinz)**

---

📄 **Open-Source-Lizenzen / Third-Party Notices:** Eine Übersicht aller im Rust-Kern verwendeten Open-Source-Bibliotheken und ihrer Lizenzen befindet sich in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
