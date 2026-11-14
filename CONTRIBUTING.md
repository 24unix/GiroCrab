# Contributing to GiroCrab

Thanks for helping! / Danke für die Mitarbeit! Issues and PRs may be in English or German.

**Privacy first:** never commit or attach real IBANs, account numbers, phone numbers, PINs, API keys,
bank exports (MT940/CAMT/CSV) or real people's names. Use invented data (e.g. the public example IBAN
`DE89 3704 0044 0532 0130 00`, "Max Mustermann").

## Setup

```bash
./build-xcframework.sh                 # only needed when the Rust API changes
cargo test -p girocrab-core -q
cargo run -- --demo-seed               # or GIROCRAB_DEMO_SEED=1
```

Swift-only changes: `cd GiroCrabApp && swift build -q` (no core rebuild needed).

Free disk space with `scripts/clean.sh [--deep]`: the default run removes `dist/`, `build/`, stray
temp files, GiroCrab DerivedData, incremental Rust caches and merged local branches while keeping
built dependencies and the xcframework; `--deep` also runs `cargo clean` and removes `GiroCrabApp/.build`.

Database schema changes are a new migration step plus a fixture vault, see
[Schema & migrations](docs/ARCHITECTURE.md#schema--migrations).

## Adding a bank in 3 steps

1. **Copy the template.** `cp girocrab-core/src/connectors/template.rs girocrab-core/src/connectors/<bank>.rs`
   and implement `begin` (login / challenge), `respond` (TAN/poll) and `fetch` (accounts + bookings).
   Amounts are `i64` cents, debits negative; `external_id` must be stable for de-duplication.
2. **Register it.** Add a variant to `ConnectorKind` (`models.rs`), a `BankDescriptor` in
   `descriptor()` and a line in `make_connector()` (both in `connectors/catalog.rs`), plus
   `pub mod <bank>;` in `connectors/mod.rs`. The `BankConnector` trait and its DTOs (`Phase`,
   `Challenge`, `FetchResult`, …) live in `connectors/types.rs`; the sync/transfer state machines are
   in `sync_session.rs` / `transfer_session.rs`, and storing fetched data is `persist.rs`.
   File importers (database, CSV/CAMT/MT940, portal imports) are not connectors: see
   `girocrab-core/src/importers/`.
   Add the Swift display name/colour in `GiroCrabUI/Formatting.swift`.
3. **Test it with fake data.** Unit-test your parser with invented fixtures, then check the UI via
   `GIROCRAB_DEMO_SEED=1`. Run `cargo fmt`, `cargo clippy` and `cargo test -p girocrab-core`.
   Optional: `git config core.hooksPath .githooks` runs `cargo fmt --check` before every push, like CI does,
   and warns after a checkout, pull or rebase when the xcframework in `generated/` no longer matches
   the Rust core (`./build-xcframework.sh --check`).

Unsure where to start? Pick one of the open `[Bank]` issues labelled
[`help wanted`](https://github.com/GiroCrab/GiroCrab/issues?q=is%3Aopen+label%3A%22help+wanted%22+%22%5BBank%5D%22),
or open a new `[Bank]` issue first.

## UI strings

The String Catalogs (`GiroCrabApp/Xcode/App/*.xcstrings`) are sorted by key so that parallel PRs
don't collide at the end of the file. Add keys with `GiroCrabApp/Tools/update-localizations.sh` or
by hand, then run `scripts/xcstrings.py format` (CI checks it).
`git config merge.xcstrings.driver 'scripts/xcstrings.py merge %O %A %B'` makes git merge the
catalogs per key instead of per line; the hooks in `.githooks` register it automatically.

## Texts and documentation

User-visible texts (README, docs, website, app strings, release notes) do not name brands of other banking or
finance software and contain no comparisons with other products. Describe GiroCrab's features factually and
verifiably. Internal code identifiers (module, function, test and file names) are exempt; `scripts/lint-brand-names.sh`
(CI) checks the documentation and string catalogs.

Nutzersichtbare Texte (README, docs, Website, App-Strings, Release-Notes) nennen keine Marken anderer Banking- oder
Finanzsoftware und enthalten keine Vergleiche mit Fremdprodukten. Funktionen von GiroCrab werden sachlich und
belegbar beschrieben.

## Markennamen und Quellen / Trademarks and sources

**DE**
- Andere Finanz- und Banking-Software (z. B. andere Banking-Apps) wird in nutzersichtbaren Texten nicht genannt: weder in README, Doku, Website, App-Texten noch in Release-Notes. Keine Vergleiche mit Fremdprodukten. Interne Code-Bezeichner sind davon ausgenommen. Der CI-Check `scripts/lint-brand-names.sh` prüft das.
- Banken, Broker und Zahlungsdienste, die GiroCrab anbindet, dürfen sachlich genannt werden („Connector für Konten bei der X-Bank“). Nicht erlaubt: Formulierungen, die eine Partnerschaft oder offizielle Unterstützung nahelegen, sowie Logos von Banken in Doku und Website.
- Inoffizielle Schnittstellen werden in Doku und Bank-Tabelle als „inoffiziell“ gekennzeichnet, mit Hinweis auf mögliche Verstöße gegen Nutzungsbedingungen.
- Kein Kopieren aus proprietärer Dokumentation oder fremdem Code. Fremdcode nur mit GPL-kompatibler Lizenz und Quellenangabe (Projekt, Lizenz, Link). Technische Erkenntnisse in eigenen Worten beschreiben.
- Funktionen von GiroCrab sachlich und belegbar beschreiben: keine absoluten Versprechen („verlustfrei“, „alle Banken“), keine Zeitangaben ohne Messgrundlage.

**EN**
- Other finance or banking software is not named in user-facing text (README, docs, website, app strings, release notes), and there are no comparisons with third-party products. Internal code identifiers are exempt. Enforced by `scripts/lint-brand-names.sh`.
- Banks, brokers and payment services that GiroCrab connects to may be named factually ("connector for accounts at X Bank"). Do not imply a partnership or official support, and do not use bank logos in docs or on the website.
- Mark unofficial interfaces as "unofficial" in docs and the bank table, noting possible terms-of-service issues.
- Do not copy from proprietary documentation or third-party code. Third-party code only under a GPL-compatible licence with attribution (project, licence, link). Describe technical findings in your own words.
- Describe GiroCrab's features factually and verifiably: no absolute claims ("lossless", "all banks"), no time claims without measurement.

## Adding merchants

Edit `girocrab-core/data/merchants.tsv` (parsed by `src/data_tables.rs`, matching logic in
`src/merchants.rs`). One merchant per line, tab-separated: `key`, `name`, `needles` (`|`-separated),
`kind` (a `MerchantKind` variant), `symbol` (SF Symbol), `color` (`#RRGGBB`), `domain`, and optionally
`isin`, `wkn` for funds. Rows are matched top to bottom, the first hit wins. Needles are matched
against the normalised, lower-case counterparty; short brand names carry spaces (`" dm "`) to avoid
false hits. Validate with `cargo test -q -p girocrab-core --lib data_tables` and `--lib merchants`
(unique keys, lower-case needles, valid colours). Private persons (first name + surname)
automatically get a monogram, never a logo.

## Testing with demo data

`GIROCRAB_DEMO_SEED=1 cargo run` (or `cargo run -- --demo-seed`) opens a throw-away vault with
5 fictional accounts, exactly 52 invented bookings and 2 ETF depot positions
(`girocrab-core/src/demo.rs`). Change the data
there only with invented names and amounts.

## Picking up an issue

To avoid two people building the same thing (it has happened, e.g. account groups in #31):

1. **Ask first.** Comment on the issue that you would like to work on it and wait for a maintainer
   to assign it to you. Please don't start before that, except for tiny fixes (typos, one-line bugs).
2. **One issue, one assignee.** If an issue is already assigned, talk to the assignee or a maintainer
   before starting a competing implementation.
3. **One feature per issue.** Split larger requests into separate issues, so each can be assigned
   and merged on its own.
4. **Link your PR** with `Closes #123` (or `Refs #123` if it is only part of it).
5. **Let go if plans change.** If you can't continue, say so on the issue so it can be reassigned.

## Pull requests

* Keep PRs focused; describe what and why.
* CI runs `cargo fmt --check`, `cargo clippy`, `cargo test -p girocrab-core` and a Swift build.
* By contributing you agree to license your work under GPL-3.0-or-later.
