# quirion browser connector

Sign in through **Add bank → quirion** (also searchable as Quirin Privatbank,
BLZ 10110600 or its German IBAN). Login and any approval happen in the embedded
browser. After login, choose **Depot und Konten abrufen**. PDF archive downloads
are optional; already stored document IDs are skipped on subsequent syncs.

The connector uses the portal's internal API, not FinTS or Enable Banking.
It creates separate accounts for each portfolio's securities and liquidity,
and for the business partner's clearing account. The external reference account
is not imported. This avoids counting portfolio totals and their components twice.
Each position includes quantity, current price, purchase price and position value.
The UI calculates unrealized gain/loss and its percentage from these existing
fields and labels the result as calculated. No vault schema change is needed.
Realized gains and tax calculations are outside this connector's scope.

## Browser flow and technical validation

Validated in Safari on 2026-11-13, then repeated with the actual JavaScript
embedded in `QuirionUI.swift`. Authorization is captured from the portal's
successful API requests and remains in a JavaScript closure. Swift receives
only selected account, position, transaction and document fields. Passwords,
tokens and the personal profile returned by `/user` are not exported or logged.
The generic portal traffic recorder is disabled for this connector.

Base URL: `https://api.it-aws-prod.quirion.de/legacy/v1`.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/user` | Enumerate open business partners |
| GET | `/business-partners/{id}` | Clearing account and portfolio list |
| GET | `/business-partners/{id}/products/{id}` | Liquidity and securities positions |
| POST | `/transactions` | Read booked transaction history |
| GET | `/postbox` | List document metadata |
| POST | `/postbox/download` | Read a base64 PDF, body `{"doc":"document-id"}` |

Requests use the portal's Authorization header, `credentials: 'omit'` and
`redirect: 'error'`. Adding cross-origin cookies caused a Safari load failure.
No `PUT /postbox/status` is sent, so the connector does not mark documents read.

`/transactions` takes `businessPartnerId`, `range` (days), `status: CLOSED`,
and `type: ALL`. Adding `ipsId` selects portfolio liquidity; omitting it selects
the clearing account. The implementation requests at least 3,000 days, expanding
to the account's creation date plus a one-year margin for older accounts.
Setting `transactions=true` on a product request still returned only the recent
19 entries; that field is not used as a complete history source.

Observed results for the tested login (counts only; no personal data stored):

- 1 business partner, 1 portfolio, 3 separate accounts/depots.
- 11 securities positions; position values matched the reported depot value,
  and depot plus liquidity matched the portfolio total.
- 893 booked portfolio transactions, starting in October 2019.
- 18 booked clearing-account transactions, also starting in October 2019.
- 320 listed PDFs, September 2019 through October 2026. Downloads of the oldest
  and newest document both had valid PDF signatures; all files were not fetched
  during the preliminary validation.

## Validation and limitations

The vault remains on schema 11. No extra holdings columns or tables are added.
Calculated gain is position value minus quantity × purchase price, with the
cost basis rounded to cents. Its percentage uses that cost basis. Missing or
invalid purchase prices/quantities suppress the gain display. Existing per-unit
prices are stored in cents, so calculated gains can differ from quirion's reported
figures due to rounding. The connector does not persist quirion's separate
`notRealGUV` or `notRealGUVPercentage` fields.

The Rust parser validates the complete snapshot before writing: IDs, dates,
required fields, EUR currency, exchange rates, position totals and cash totals.
Unsupported foreign-exchange positions are rejected instead of guessing their
price currency. Monetary float artefacts are rounded to cents once; quantities
are preserved. `liquid.balanceDate` proved stale, so the product valuation date
is used for its cash balance. Explicitly empty inventories remove old positions.

The API supplies no transaction IDs. GiroCrab's existing content IDs and occurrence
counters keep repeated imports stable while preserving identical real bookings.
The API's full historical coverage is not independently guaranteed: the oldest
returned transaction even predates the date stated by the portal's UI. For an
audit, compare with original statements. Document listing uses status ALL and
the date range 2000-01-01 through today; no pagination metadata was observed.
PDF metadata identifies a business partner, not a specific portfolio: documents
are attached to that partner's clearing account, falling back to a depot.
Archived/closed products and realized performance are not imported in this version.

Backend tests cover idempotency, duplicate transactions, cost-price mapping, empty
depots, malformed snapshots, PDF validation and repeated downloads. Browser
tests follow the FNZ precedent and execute the actual embedded scripts with mock
responses, including expired sessions and authorization host checks:

```sh
cargo test -p girocrab-core
node --test scripts/test-quirion-portal.cjs
```

The archived [homebanking_data_importer](https://github.com/lkwg82/homebanking_data_importer)
provided context for the browser approach. No source was copied from it; the
connector uses the portal API observed in Safari and the supplied MoneyMoney log.
