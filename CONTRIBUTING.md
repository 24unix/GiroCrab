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

Database schema changes are a new migration step plus a fixture vault, see
[Schema & migrations](docs/ARCHITECTURE.md#schema--migrations).

## Adding a bank in 3 steps

1. **Copy the template.** `cp girocrab-core/src/connectors/template.rs girocrab-core/src/connectors/<bank>.rs`
   and implement `begin` (login / challenge), `respond` (TAN/poll) and `fetch` (accounts + bookings).
   Amounts are `i64` cents, debits negative; `external_id` must be stable for de-duplication.
2. **Register it.** Add a variant to `ConnectorKind` (`models.rs`), a `BankDescriptor` in
   `descriptor()` and a line in `make_connector()` (`connectors/catalog.rs`), plus `pub mod <bank>;`
   in `connectors/mod.rs`.
   Add the Swift display name/colour in `GiroCrabUI/Formatting.swift`.
3. **Test it with fake data.** Unit-test your parser with invented fixtures, then check the UI via
   `GIROCRAB_DEMO_SEED=1`. Run `cargo fmt`, `cargo clippy` and `cargo test -p girocrab-core`.
   Optional: `git config core.hooksPath .githooks` runs `cargo fmt --check` before every push, like CI does,
   and warns after a checkout, pull or rebase when the xcframework in `generated/` no longer matches
   the Rust core (`./build-xcframework.sh --check`).

Open a *New bank request* issue first if unsure – ING, N26, Scalable Capital, Consorsbank and
Santander are wanted.

## UI strings

The String Catalogs (`GiroCrabApp/Xcode/App/*.xcstrings`) are sorted by key so that parallel PRs
don't collide at the end of the file. Add keys with `GiroCrabApp/Tools/update-localizations.sh` or
by hand, then run `scripts/xcstrings.py format` (CI checks it).
`git config merge.xcstrings.driver 'scripts/xcstrings.py merge %O %A %B'` makes git merge the
catalogs per key instead of per line; the hooks in `.githooks` register it automatically.

## Adding merchants

Edit `girocrab-core/src/merchants.rs`: add an entry with `e("key", "Display Name", &["needle", …],
"domain.de", "#RRGGBB", "sf.symbol", Kind)` (or `etf(...)` for funds with ISIN/WKN). Needles are
matched against the normalised counterparty, so use lower-case fragments. Add a assertion to the
tests at the bottom of the file. Private persons (first name + surname) automatically get a monogram,
never a logo.

## Testing with demo data

`GIROCRAB_DEMO_SEED=1 cargo run` (or `cargo run -- --demo-seed`) opens a throw-away vault with
5 fictional accounts and exactly 50 invented bookings (`girocrab-core/src/demo.rs`). Change the data
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
