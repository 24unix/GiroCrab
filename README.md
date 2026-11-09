<p align="center">
  <img src="GiroCrabApp/Assets/girocrab-icon.svg" alt="GiroCrab" width="128" height="128">
</p>

<h1 align="center">GiroCrab</h1>

<p align="center">
  <a href="https://github.com/girocrab/girocrab/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/girocrab/girocrab/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="License: GPL-3.0-or-later" src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue">
  <img alt="Rust" src="https://img.shields.io/badge/core-Rust-orange">
  <img alt="Swift" src="https://img.shields.io/badge/app-SwiftUI-F05138">
  <img alt="Platforms" src="https://img.shields.io/badge/macOS%2014%2B%20%7C%20iOS%2017%2B-lightgrey">
  <img alt="PRs welcome" src="https://img.shields.io/badge/PRs-welcome-brightgreen">
</p>

<p align="center"><b>🇩🇪 <a href="#-deutsch">Deutsch</a> · 🇬🇧 <a href="#-english">English</a></b></p>

---

## 🇩🇪 Deutsch

**Open-Source-Banking für macOS 14+ und iOS 17+ – selbst gehostet, verschlüsselt, ohne Cloud.**
Native SwiftUI-App auf einem Rust-Kern: verschlüsseltes Kassenbuch (SQLCipher), Kategorienbaum,
Regeln, Händler-Erkennung, Sparplan-Ansicht, Darlehens-Tilgungsbalken und direkte Verbindungen
zu Ihren Banken – ohne Server, ohne Tracking.

### Funktionen im Überblick

<p align="center"><img src="docs/screenshots/overview.png" alt="GiroCrab – Übersicht mit fiktiven Demo-Konten" width="900"></p>

*Alle Screenshots zeigen ausschließlich erfundene Demo-Daten (`GIROCRAB_DEMO_SEED=1`).*

- 🔒 **Local-First & Zero-Cloud:** Alle Bankdaten bleiben auf Ihrem Gerät – in einem verschlüsselten SQLCipher-Tresor, geschützt durch macOS-Schlüsselbund / Touch ID.
- 🏦 **Native deutsche Bank-Protokolle:** FinTS 3.0 / HBCI (CAMT.052 & MT940 mit intelligenter Latin-1/UTF-8-Erkennung), Trade-Republic-WebSocket, comdirect-REST sowie eingebettete Web-Session-/CSV-Importe für Amex & Amazon Visa.
- 🏠 **Intelligente Darlehens-Verfolgung:** Tilgungsfortschritt in Prozent und automatische Verknüpfung der monatlichen „Zins & Tilgung“-Raten vom Girokonto.
- 🏷️ **Markenlogos vs. private Monogramme:** Händler und ETFs (REWE, EnBW, DB, iShares) werden sofort erkannt; Privatpersonen (z. B. „Max Mustermann“) erhalten bewusst nur neutrale Initialen.

| Darlehen mit Tilgungsbalken | Inspektor mit Händler-Logo |
|---|---|
| <img src="docs/screenshots/loan-progress.png" alt="Immobilien-Darlehen, 27 % getilgt"> | <img src="docs/screenshots/analytics-or-inspector.png" alt="Inspektor mit EnBW-Buchung"> |

### Architektur

```
┌──────────────────────────┐   UniFFI    ┌────────────────────────────────────┐
│ GiroCrabApp (SwiftUI)    │ ◄─────────► │ girocrab-core (Rust)               │
│ macOS / iOS              │  Swift-API  │  vault.rs      SQLCipher-Tresor    │
│ Keychain + Face/Touch ID │             │  rules.rs      Kategorien-Regeln   │
└──────────────────────────┘             │  merchants.rs  Händler-Erkennung   │
                                         │  connectors/   FinTS · REST · PSD2 │
                                         └──────────────┬─────────────────────┘
                                                        │ direkt, mit Ihren Zugangsdaten
                                                        ▼
                                                  Ihre Bank(en)
```

### Bank-Unterstützung

| Institut | Verfahren | Status |
|---|---|---|
| Volksbanken (Atruvia) / 1822direkt | FinTS 3.0 PIN/TAN (HKCAZ/camt, HKKAZ/MT940, Darlehen) | ✅ Unterstützt |
| comdirect | Offizielle REST-API | ✅ Unterstützt |
| PayPal | Transaction-Search-API | ✅ Unterstützt |
| Trade Republic | WebSocket (inoffiziell) | ⚠️ Unterstützt, kann brechen |
| American Express / Amazon Visa | PSD2 via Enable Banking | ✅ Unterstützt |
| ING, DKB, N26, Scalable Capital, Consorsbank, Santander | – | 🙋 **Help Wanted** |

Eine neue Bank anzubinden dauert meist unter 100 Zeilen: siehe
[`connectors/template.rs`](girocrab-core/src/connectors/template.rs) und [CONTRIBUTING.md](CONTRIBUTING.md).

### Schnellstart

Voraussetzungen: macOS 14+, Xcode 15+, [rustup](https://rustup.rs).

```bash
./build-xcframework.sh          # Rust-Kern + Swift-Bindings (macOS, iOS, Simulator)
cargo run -- --demo-seed        # App mit erfundenen Demo-Daten starten
# oder: GIROCRAB_DEMO_SEED=1 cargo run
cargo test -p girocrab-core     # Tests
```

Die Demo enthält 5 fiktive Konten und 50 erfundene Buchungen – keine echten Daten.

### ⚖️ Rechtlicher Hinweis (ZAG / PSD2)

GiroCrab ist **selbst gehostete Software zur ausschließlich eigenen Nutzung**. Sie läuft auf Ihrem
Gerät und verbindet sich direkt – mit **Ihren** Zugangsdaten, **Ihrer** FinTS-Produktregistrierung
und **Ihren** API-Schlüsseln – mit Ihren Banken. Die Entwickler betreiben **keinen** Server, erhalten
**keine** Kontodaten und erbringen **keinen** Kontoinformations- (AISP) oder Zahlungsauslösedienst
(PISP) im Sinne des ZAG bzw. der Richtlinie (EU) 2015/2366 (PSD2). Wer GiroCrab für **Dritte**
betreibt, braucht ggf. eine BaFin-Erlaubnis – das ist nicht der vorgesehene Einsatzzweck.
Nutzung auf eigenes Risiko, keine Gewähr (siehe GPLv3). Inoffizielle Schnittstellen
(Trade Republic) können gegen Nutzungsbedingungen verstoßen. Keine Anlageberatung; ISIN/WKN-Angaben
sind Referenzdaten ohne Gewähr. Marken gehören ihren Inhabern und dienen nur der Wiedererkennung.

---

## 🇬🇧 English

**Open-source banking for macOS 14+ and iOS 17+ – self-hosted, encrypted, no cloud.**
A native SwiftUI app on a Rust core: encrypted ledger (SQLCipher), category tree, rules, merchant
recognition, savings-plan view, loan repayment progress and direct connections to your banks –
no server, no tracking. Money is always `i64` cents, never floats.

### Features & Screenshots

<p align="center"><img src="docs/screenshots/overview.png" alt="GiroCrab – overview with fictional demo accounts" width="900"></p>

*All screenshots show purely fictional demo data (`GIROCRAB_DEMO_SEED=1`).*

- 🔒 **Local-first & zero-cloud privacy:** all banking data lives on your device in an encrypted SQLCipher vault protected by the macOS Keychain / Touch ID.
- 🏦 **Native German banking protocols:** FinTS 3.0 / HBCI (CAMT.052 & MT940 with smart Latin-1/UTF-8 decoding), Trade Republic WebSocket, comdirect REST, and embedded web-session/CSV import for Amex & Amazon Visa.
- 🏠 **Smart loan tracking:** automatic repayment progress (%) and cross-account linking of the monthly "Zins & Tilgung" instalments from your checking account.
- 🏷️ **Brand signets vs. private monograms:** instant recognition for German merchants & ETFs (REWE, EnBW, DB, iShares), while private individuals (e.g. "Max Mustermann") get plain monogram initials by design.

| Loan with repayment bar | Inspector with merchant logo |
|---|---|
| <img src="docs/screenshots/loan-progress.png" alt="Immobilien-Darlehen, 27% repaid"> | <img src="docs/screenshots/analytics-or-inspector.png" alt="Inspector showing an EnBW booking"> |

### Architecture

See the diagram above: the SwiftUI app talks to `girocrab-core` through UniFFI; the core owns the
encrypted vault, categorisation rules, merchant resolver and the bank connectors, and talks to
your bank directly.

### Bank support matrix

| Bank | Protocol | Status |
|---|---|---|
| Volksbanken (Atruvia) / 1822direkt | FinTS 3.0 PIN/TAN (camt, MT940, loans) | ✅ Supported |
| comdirect | Official REST API | ✅ Supported |
| PayPal | Transaction Search API | ✅ Supported |
| Trade Republic | WebSocket (unofficial) | ⚠️ Supported, may break |
| American Express / Amazon Visa | PSD2 via Enable Banking | ✅ Supported |
| ING, DKB, N26, Scalable Capital, Consorsbank, Santander | – | 🙋 **Help wanted** |

Adding a bank usually takes under 100 lines – start from
[`connectors/template.rs`](girocrab-core/src/connectors/template.rs) and read [CONTRIBUTING.md](CONTRIBUTING.md).

### Download (macOS)

Pre-built `GiroCrab-macOS-arm64.zip` binaries (Apple Silicon, macOS 14+) are available under
[GitHub Releases](../../releases) – no Rust or Xcode required. Unzip and move `GiroCrab.app` to `/Applications`.

The open-source builds are not notarized. If macOS refuses to open the app, run
`xattr -cr /Applications/GiroCrab.app` or Right-Click → Open.

### Quickstart

Requirements: macOS 14+, Xcode 15+, [rustup](https://rustup.rs).

```bash
./build-xcframework.sh          # Rust core + Swift bindings (macOS, iOS, simulator)
cargo run -- --demo-seed        # launch the app with fictional demo data
# or: GIROCRAB_DEMO_SEED=1 cargo run
cargo test -p girocrab-core     # run the tests
```

The demo ships 5 fictional accounts and 50 invented bookings – no real data.

### ⚖️ Legal notice (PSD2 / ZAG)

GiroCrab is **self-hosted software for your own personal use only**. It runs on your device and
connects directly to your banks with **your** credentials, **your** FinTS product registration and
**your** API keys. The authors operate **no** server, receive **no** account data and provide **no**
account-information (AISP) or payment-initiation (PISP) service under the German ZAG / PSD2
(Directive (EU) 2015/2366). Operating GiroCrab for **third parties** may require BaFin authorisation
and is not the intended use. Use at your own risk, no warranty (see GPLv3). Unofficial interfaces
(Trade Republic) may violate terms of service. Not investment advice. Trademarks belong to their
owners and are used for identification only.

---

## Security / Sicherheit

SQLCipher (AES-256) vault, key in the Keychain (`ThisDeviceOnly`), PINs/TANs only in memory
(`zeroize`), no telemetry. **Never attach real bank data or credentials to issues.**

## License / Lizenz

GPL-3.0-or-later – see [LICENSE](LICENSE).

---

## ☕ Projekt unterstützen (Freiwillige Zuwendung)

**GiroCrab** ist ein freies Open-Source-Projekt. Wenn dir die App im Alltag hilft und du die Weiterentwicklung mit einer kleinen **freiwilligen Zuwendung** (ohne Gegenleistung) für die Kaffeekasse unterstützen möchtest:

[![PayPal](https://img.shields.io/badge/PayPal-Freiwillige%20Zuwendung-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/aprinz)

*English:* If you enjoy using GiroCrab and would like to support its development with a **voluntary contribution / tip** (no consideration expected): **[paypal.me/aprinz](https://paypal.me/aprinz)**
