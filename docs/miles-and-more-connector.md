# Miles & More Kreditkarte (Deutsche Bank) – FinTS connector notes

<!-- sync:connector-note:start -->
> **Hinweis / Note:** Dieser Connector ist ein unabhängiges Community-Projekt und steht in keiner Verbindung zur Deutsche Bank / Miles & More. Schnittstelle: offiziell. Bei inoffiziellen Schnittstellen kann die Nutzung gegen die Nutzungsbedingungen der Bank verstoßen.
> This connector is an independent community project and is not affiliated with Deutsche Bank / Miles & More. Interface: official. Using unofficial interfaces may violate the bank's terms of service.
<!-- sync:connector-note:end -->

Living document. Update the **Status** table and the **Change log** whenever work
on this connector advances.

The Miles & More credit cards have been issued by Deutsche Bank since October 2025.
The bank serves them over FinTS 3.0 PIN/TAN under a bank code of their own. GiroCrab
reaches them through the generic FinTS connector; there is no dedicated `ConnectorKind`.

Everything in the Status table marked ✅ was verified with a real card on 2026-11-15.

## Status

| Scope | State |
| --- | --- |
| Login (two-step, TAN medium name) | ✅ |
| Card account discovery (no IBAN, no SEPA account list) | ✅ |
| Card bookings and balance (HKKKU) | ✅ 90 days without approval; two years with approval in the app |
| Approval in the banking app for requests beyond 90 days (decoupled) | ✅ works; the corrected wait for a pending approval is covered by a unit test, not yet re-run against the bank |
| Bank directory entry, search words, add-form hints, colour/monogram | ✅ |
| Automatic `SO:` prefix for the TAN medium | ⬜ implemented, never triggered (this bank takes the plain name) |
| Card balance request (HKKKS) | ⬜ not used; the balance comes with the bookings |
| Statement PDFs / mailbox | ❌ not offered over FinTS for this bank code |
| Pending (not yet booked) card payments | ⬜ unknown; only what HKKKU returns is stored |

## Access data

| Field | Value |
| --- | --- |
| Bank code (BLZ) | `50070439` – used by the bank only for these cards |
| FinTS address | `https://fints.deutsche-bank.de/` (the bank's general FinTS address) |
| Login name | the Deutsche Bank ID of the card login |
| PIN | the password of that login |
| TAN method | approval in the bank's security app (decoupled) |
| TAN medium | **required**: the device name shown in the security app's device management |

The bank code is not part of the generated FinTS directory dataset; the row in
`girocrab-core/data/fints_directory.tsv` was added by hand (see the note in the file
header). A regeneration of that file must keep it.

## What the bank sends

Bank parameters (same for every customer of this bank code):

- Card bookings `HKKKU` version 1 and card balance `HKKKS` version 1 are offered.
  `HIKKUS`: storage period 775 days, no "maximum entries", date range allowed, account
  identification required.
- Normal statements (`HKKAZ` 5/6, `HKCAZ` 1) and balances (`HKSAL` 5/6) are advertised
  too, but not allowed for the card account.
- No electronic statement request (`HKEKA`) at all.

User parameters of a card-only customer: two accounts without IBAN.

| Account type (Kontoart) | Allowed business transactions | Used by GiroCrab |
| --- | --- | --- |
| 50 (credit card) | `HKKKU`, `HKKKS` and administrative ones | yes |
| 1 | administrative ones only | no (nothing to fetch) |

The SEPA account list (`HKSPA`) is empty ("keine Einträge").

## Protocol behaviour found

1. **TAN medium name is mandatory.** Without it the two-step dialog initialisation is
   rejected with `9210 Name des TAN-Medium erforderlich`.
2. **The medium list cannot be fetched first.** The synchronisation dialog answers
   `3075` (strong authentication required) and is closed by the bank; `HKTAB` in it
   fails with `9800`. A one-step dialog that announces `HKTAN` is rejected with
   `9200`. The user therefore has to enter the device name.
3. **No strong authentication for 90 days.** Login and a 90-day `HKKKU` answer `3076`.
4. **Beyond 90 days: decoupled approval.** `HKKKU` answers `3955`. While the approval
   is outstanding, the status request (`HKTAN` process S) answers with warnings only
   (`3060`, no success code) – not with the usual `3956`. After the approval it answers
   `0010`/`0020` together with the data.
5. **`9210` is a generic code at this bank.** Besides the missing TAN medium it is also
   used for "no data for this order reference".

## Implementation

| Part | Where |
| --- | --- |
| `HIKKU` parser (bookings, balance), unit tests on invented data | `girocrab-core/src/connectors/fints/kku.rs` |
| `HKKKU` request, paging, storage-period limit, `HIKKUS` flags | `statements_card`, `card_since` in `fints/statements.rs`; `learn_bpd` in `fints/bpd.rs` |
| Card accounts count as usable; stored as credit card | `account_list` in `fints/accounts.rs`, fetch loop in `fints/mod.rs` |
| Pending approval: success code required, timeout is an error | `approval_pending`, `request` in `fints/dialog.rs` |
| `9210` without a TAN medium: message telling the user what to enter | `open_dialog` in `fints/dialog.rs` |
| `SO:` prefix tried once if the plain medium name is rejected | `open_dialog`, `has_so_prefix` in `fints/dialog.rs` |
| TAN medium editable on an existing connection | `ConnectionsUI.swift` |
| Directory row, search words | `data/fints_directory.tsv`, `bank_directory.rs` |
| Add-form hints, required TAN medium, colour and monogram | `FinTsAddForm.swift`, `Formatting.swift` |
| First-fetch period (90 days / 1 year / 2 years) in the settings | `SettingsView.swift` (core setting `sync.days_back`) |
| Bank matrix row | `catalog.rs` (`BANK_MATRIX`), README regenerated with `scripts/sync_docs.py` |

### `HIKKU` version 1 as parsed

Card number, account id, balance (`C|D : amount : currency : date`), last statement
date, next statement date, then one data element group per booking with 25 components:
card number, receipt date, booking date, statement date, value date, original amount /
currency / credit-debit mark, exchange rate, booked amount / currency / credit-debit
mark, eight description lines, country, merchant name, terminal, billed flag, booking
reference. `D` is negative. Original amount and rate are empty for payments in the
account currency; for foreign-currency payments they are appended to the purpose.

The layout was implemented from publicly available descriptions of the business
transaction, not from the official specification text. It matched the bank's answers
in the live test: every booking group returned was parsed (63 of 63 and 162 of 162).

## Known limitations

- History: at most what the bank keeps (775 days). GiroCrab only goes back further than
  the default 90 days on the **first** fetch of an account, according to the setting
  "Zeitraum beim ersten Abruf".
- Statement PDFs and the mailbox are not available over FinTS for this bank code. They
  would need a separate web-portal connector; its feasibility has not been looked at.
- The booking reference of `HIKKU` is not used as de-duplication key yet; bookings are
  de-duplicated by content like other FinTS bookings.
- A connection created before the bank code was in the directory keeps its placeholder
  name ("FinTS-Bank 50070439") until it is renamed or added again.

## Open questions

| # | Question | How to answer |
| --- | --- | --- |
| 1 | Does the corrected approval wait behave correctly when the user confirms late? | fetch beyond 90 days and confirm after 10–20 s |
| 2 | Do other banks of the same group accept the TAN medium only with the `SO:` prefix? | live test with such a bank |
| 3 | Are pending card payments part of `HIKKU`, and how are they marked? | compare with the card's app shortly after a payment |
| 4 | Do customers with a current account at the bank see the card under their branch bank code as well? | live test with such a customer |

## Change log

- 2026-11-15 – First live test and implementation: TAN medium handling, `HKKKU`
  support, directory entry and UI hints, first-fetch period setting, approval wait fix.
