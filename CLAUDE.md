# GiroCrab – agent efficiency rules

Rust core (`girocrab-core`, UniFFI) + SwiftUI app (`GiroCrabApp`). Root = this dir (`app/`).

## File map (go here first; don't `find`/`grep` to locate code)
- `girocrab-core/src/lib.rs` – crate root, UniFFI exports
- `girocrab-core/src/models.rs` – domain types
- `girocrab-core/src/vault.rs` – encrypted storage
- `girocrab-core/src/connectors/mod.rs` – bank connector trait/dispatch (impls alongside: `fints/`, `comdirect.rs`, `trade_republic.rs`, …)
- `girocrab-core/src/connectors/` – all connector impls: `fints/`, `comdirect.rs`, `trade_republic.rs`, `enable_banking.rs`, `paypal.rs`, `portal_import.rs` (Amex/Amazon Visa web + CSV/PDF import)
- `girocrab-core/src/merchants.rs` – merchant matching
- `girocrab-core/src/documents.rs` – booking documents / PDF text extraction
- `girocrab-core/src/text.rs` – text helpers (mojibake repair etc.)
- `GiroCrabApp/Sources/GiroCrabUI/AppModel.swift` – app state / core bridge
- `GiroCrabApp/Sources/GiroCrabUI/RootView.swift` – top-level UI
- `GiroCrabApp/Sources/GiroCrabUI/BookingListView.swift` – booking list
- `GiroCrabApp/Sources/GiroCrabUI/ConnectionsUI.swift` – bank connections UI

Other UI files live in the same `GiroCrabUI/` dir. Ignore `cashcrab-core/` and `CashCrabApp/` (legacy).

## Builds
- **Swift-only change** (only `GiroCrabApp/**/*.swift`): NEVER rebuild `girocrab-core` or run `./build-xcframework.sh`. Run only `swift build -q` (in `GiroCrabApp/`) or `xcodebuild -quiet`.
- Rust change: `cargo check -q -p girocrab-core`; rebuild the xcframework only if the UniFFI API changed.
- Always pass `-q`/`--quiet` to `cargo check`, `cargo test`, `xcodebuild`. If output is still long, pipe through `tail -n 40`.

## Don't read into context
- Generated bindings: `generated/**/girocrab_core.swift` (6k lines), the xcframework, `target/`, `.build/`.
- Data/large tables: `girocrab-core/src/merchant_dict.rs`, icon/merchant SVG/JSON, `feed.json`, `craft.json`, `*.log`, `agent-session.jsonl`.
- For any file > 200 lines use `grep -n` or `Read` with `offset`/`limit`; never read it whole.
