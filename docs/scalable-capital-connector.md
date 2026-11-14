# Scalable Capital connector – implementation plan

Living document. Update the **Status** table and the **Change log** whenever work
on the connector progresses. Everything below was derived from the open-source
[`ScalableCapital/scalable-cli`](https://github.com/ScalableCapital/scalable-cli)
(v1.3.0, Apache-2.0, snapshot of 2026-11-10) and from GiroCrab's own connector
layer. Nothing has been verified against the live Scalable backend yet.

## Status

| Phase | Scope | State |
| --- | --- | --- |
| 0 | Feasibility study (this document) | ✅ done 2026-11-11 |
| 1 | DPoP signing + device-code login against the real endpoints | ✅ verified live 2026-11-11 |
| 2 | Session persistence, refresh, 2FA-on-login | ✅ login + 2FA verified live; refresh/7-day re-login not yet observed |
| 3 | Account discovery (broker portfolio, Overnight, Fixed-Term) | ✅ verified live (1 portfolio, 1 Overnight, 0 Fixed-Term) |
| 4 | Transaction fetch + mapping, de-duplication | ✅ verified live 2026-11-11 (full history, signs, transfers, holdings) |
| 5 | Wiring: `ConnectorKind`, descriptor, Swift UI, demo data | ✅ done 2026-11-11 (demo seed left unchanged, see below) |
| 6 | Tests, README/CONTRIBUTING update, release notes | ✅ unit tests green; README/CONTRIBUTING list Scalable Capital as supported (2026-11-11); release notes with the next release |

Blocking dependency for phases 1–4: a Scalable Capital account with
**Profile → Security → Agentic Investing** enabled, to validate the flow live.

## Goal and scope

Add Scalable Capital (Broker, Overnight savings, Fixed-Term savings) as a native
connector in `girocrab-core`, talking **only** to Scalable's own endpoints, read-only.

In scope:

- Device-code OAuth login with DPoP-bound tokens, as the official CLI does it.
- Accounts: broker portfolio(s) as `AccountKind::Brokerage`, Overnight savings as
  `AccountKind::Savings`, Fixed-Term accounts as `AccountKind::Savings`.
- Transactions: broker cash + security transactions, Overnight cash transactions.
- Balances: portfolio valuation, cash balance, Overnight total, Fixed-Term deposit.

Out of scope (now or ever):

- Trading, savings-plan changes, watchlists, price alerts (write operations).
- Crypto transaction stream (can be added later; separate cursor and types).
- Transaction documents (not exposed by the API).

## What the CLI tells us about the API

### Endpoints and OAuth client

| Item | Value (prod channel, `src/channel.rs`) |
| --- | --- |
| GraphQL | `https://de.scalable.capital/api/cli/graphql` |
| OAuth issuer | `https://secure.scalable.capital` |
| Device code | `{issuer}/oauth/device/code` |
| Token | `{issuer}/oauth/token` |
| Revoke | `{issuer}/oauth/revoke` |
| Audience | `https://de.scalable.capital/api-gateway` |
| Client ID | `yBM3BrpRgwSTJZRdJllvtD6jJEmyxWfE` (public client, no secret) |
| Scope | `offline_access openid email` |
| User-Agent | `scalable-cli/<version>` (CLI sends it; unknown whether the server checks it) |

The issuer is an Auth0-style tenant: standard RFC 8628 device flow with
`authorization_pending`, `slow_down`, `access_denied`, `expired_token` errors.

### Login flow (`src/auth.rs::login_with_device_code`)

1. Generate or load a P-256 signing key (DPoP key).
2. `POST /oauth/device/code` with form `client_id`, `audience`, `scope` and a
   `DPoP` header (proof for `POST` + that URL, no `ath`). Response:
   `device_code`, `user_code`, `verification_uri`, `verification_uri_complete`,
   `expires_in`, `interval` (default 5 s).
3. Show the user `verification_uri_complete` (or `verification_uri` + `user_code`).
4. Poll `POST /oauth/token` every `interval` seconds with
   `grant_type=urn:ietf:params:oauth:grant-type:device_code`, `device_code`,
   `client_id`, plus a fresh `DPoP` proof per request. On `slow_down` add 2 s.
5. Success returns `access_token`, `refresh_token`, `expires_in`, `token_type`
   (`DPoP`). The CLI verifies the JWT against the issuer's JWKS; GiroCrab can
   decode the claims unverified (the token came straight from the issuer over TLS).
6. Read the person ID from the access-token claim
   `https://de.scalable.capital/person_id` (fallback `…/personId`).
7. Post-login 2FA (GraphQL, same token):
   - `query Is2faOnLoginEnabled(input:{userId})` → `{enabled, hasApprovedSession}`.
   - If enabled and not approved: `mutation Start2faOnLogin(input:{userId,
     deviceName, deviceType})` → `mfaSessionId`; then poll
     `mutation Validate2faOnLogin(input:{userId, mfaSessionId})` → `status`
     (`APPROVED` / `DENY` / `TIMEOUT_RETRY`). The user approves in the Scalable app.

### DPoP (`src/dpop/mod.rs`)

Every HTTP request to the issuer **and** to GraphQL carries a `DPoP` header: a JWS
with header `{"typ":"dpop+jwt","alg":"ES256","jwk":{kty:"EC",crv:"P-256",x,y}}`
and claims `htm` (upper-case method), `htu` (URL without query/fragment), `iat`,
`jti` (random), optional `nonce`, and for GraphQL `ath` = base64url(SHA-256(access
token)). GraphQL uses `Authorization: DPoP <access_token>`.

Nonce handling: if the server answers 400/401 with a `DPoP-Nonce` header or a body
containing `use_dpop_nonce` / `invalid_dpop_proof`, retry **once** with that nonce.
The CLI only replays queries this way, never mutations.

Access tokens are bound to the key, so the private key must be persisted together
with the refresh token. The CLI's software backend (plain P-256 key in a file)
proves the server accepts any client-generated key; Secure Enclave is optional.

### Session limits (`public-docs/automation.md`)

- Access token: 20 min, refreshed via `grant_type=refresh_token` (rotating refresh token, DPoP-signed).
- Idle timeout: 24 h without an authenticated request.
- Hard maximum: 7 days from the original login, then a new device-code login.
- Disabling "Agentic Investing" in the web profile kills the session.
- Rate limits exist but are unpublished; errors come back as `rate_limited`.

### GraphQL operations needed

All queries take `$accountId` = person ID. Operation names matter: the backend
distinguishes allowed operations by name (the CLI blocks unnamed mutations).

| Purpose | Operation (file in CLI) | Key fields |
| --- | --- | --- |
| Identity | `WhoAmI(id)` → `personOverview` (`graphql.rs`) | `id`, `personalDetails.firstName/lastName` |
| Portfolio IDs | `ResolveBrokerIds(id)` → `account{id, brokerPortfolios{id}}` (`broker_commands.rs`) | portfolio IDs |
| Valuation | `BrokerOverview(accountId, portfolioId, includeYearToDate)` (`broker_queries.rs`) | `valuation.valuation`, `securitiesValuation`, `cryptoValuation`, `timestampUtc.time` |
| Cash | cash-breakdown query (`broker_queries.rs`, `BrokerLimits`) | `cash_balance`, `buying_power…` |
| Transactions | `BrokerTransactions(accountId, portfolioId, brokerInput, cryptoInput, includeCrypto)` | see below |
| Overnight accounts | `DiscoverOvernightAccounts(accountId)` (`overnight_queries.rs`) | `savingsAccounts{id, owners, personalizations.name, state}` |
| Overnight balance | `OvernightSummary(accountId, savingsAccountId)` | `totalAmount`, `interests.*` |
| Overnight transactions | `OvernightTransactions(accountId, savingsAccountId, input)` | same shape as broker cash transactions |
| Fixed-Term | `ListFixedTermAccounts(accountId)`, `GetFixedTermAccount(...)` (`fixed_term_queries.rs`) | deposit, term, rates, maturity |

`BrokerTransactionInput` (built in `broker_queries.rs` ~line 1400):
`{pageSize, cursor, status: [..], types: [..], searchTerm, fromTime, toTime}` with
times in **epoch seconds**. Response: `moreTransactions{cursor, total, transactions[]}`.

Transaction union members and fields:

- common: `__typename, id, currency, type, status, isCancellation, lastEventDateTime, description, custodian`
- `BrokerSecurityTransactionSummary`: `isin, securityTransactionType, quantity, amount, side, limitPrice, stopPrice`
- `BrokerCashTransactionSummary`: `relatedIsin, cashTransactionType, amount`
- `BrokerNonTradeSecurityTransactionSummary`: `isin, nonTradeSecurityTransactionType, quantity, amount`
- `BrokerEltifTransactionSummary`: `isin, securityTransactionType, eltifQuantity, amount, side`

Monetary values arrive as decimal strings or numbers; never trust floats, parse to
`i64` cents (see `trade_republic.rs::amount_cents` for the rounding helper).

## Design in GiroCrab

### Identity

- `ConnectorKind::ScalableCapital`, key `"scalable"` (`models.rs::as_str/all`).
- `BankDescriptor` in `connectors/catalog.rs::descriptor()`: name "Scalable Capital",
  protocol "OAuth 2.0 Device-Flow + GraphQL (offizielle CLI-API)", `login_label`
  = e-mail (display only; the browser does the real login), `secret_label` empty,
  `required_settings: []`, note explaining the "Agentic Investing" switch and the
  7-day re-login.
- New file `girocrab-core/src/connectors/scalable.rs` (connector) and
  `girocrab-core/src/connectors/dpop.rs` (reusable DPoP signer).

### Connector phases

`begin(ctx)`:

1. If `ctx.state` holds a usable session (refresh token + DPoP key, not older than
   7 days): refresh if the access token expires within 60 s → `Phase::Ready`.
2. Otherwise start the device flow, keep `device_code`/`interval`/`expires_at` in
   memory and return `Phase::Challenge` with `ChallengeKind::DecoupledPush`,
   `redirect_url = verification_uri_complete`, `message` containing the user code,
   `poll_interval_seconds = interval`, `expires_in_seconds = expires_in`.

`respond(ctx, _)` (called by the UI poll loop):

1. Poll the token endpoint once. `Pending`/`SlowDown` → `Phase::Pending(challenge)`.
2. On success: decode person ID, run the 2FA-on-login check. If a second factor is
   required, return a second `DecoupledPush` challenge ("Freigabe in der
   Scalable-App") and keep polling `Validate2faOnLogin` on later `respond` calls.
3. → `Phase::Ready`.

`fetch(ctx)`:

1. `ResolveBrokerIds` → portfolio IDs; `DiscoverOvernightAccounts`; `ListFixedTermAccounts`.
2. Per portfolio: `BrokerOverview` + cash breakdown → `RemoteAccount` (Brokerage,
   balance = `valuation`), plus `BrokerTransactions` paged with `fromTime =
   ctx.since` at 00:00 UTC, `pageSize` 100, follow `cursor` until exhausted.
3. Per Overnight account: `OvernightSummary` → `RemoteAccount` (Savings, balance =
   `totalAmount`), `OvernightTransactions` paged the same way.
4. Per Fixed-Term account: `GetFixedTermAccount` → `RemoteAccount` (Savings,
   balance = deposit + accrued interest). No transactions.
5. Return `FetchResult` with `state = Some(updated session JSON)`.

### State JSON (persisted encrypted in the vault)

```json
{
  "dpop_key_hex": "<32-byte P-256 scalar, hex>",
  "access_token": "...",
  "access_expires_at": 1762900000,
  "refresh_token": "...",
  "login_at": 1762300000,
  "person_id": "...",
  "portfolio_ids": ["..."]
}
```

Never log any of these. The access token is kept only to avoid a refresh per sync.

### Mapping rules

| Scalable | GiroCrab `RemoteAccount` / `RemoteTransaction` |
| --- | --- |
| broker portfolio | `external_ref = "sc:portfolio:<id>"`, `kind = Brokerage`, `name = "Scalable Depot"`, `iban = ""`, `currency = "EUR"` |
| Overnight account | `external_ref = "sc:overnight:<id>"`, `kind = Savings`, name from `personalizations.name` or "Scalable Overnight" |
| Fixed-Term account | `external_ref = "sc:fixedterm:<id>"`, `kind = Savings`, name "Scalable Festgeld <term>" |
| transaction `id` | `external_id = "sc:<id>"` (stable → de-dup on re-sync) |
| `lastEventDateTime` | `booking_date` and `value_date` (date part, local to Europe/Berlin) |
| `amount` | `amount_cents`; sign: buys and withdrawals negative, sells, deposits, dividends, interest positive. Verify against live data; the CLI shows `side` for securities and `cashTransactionType` for cash |
| `description` | `purpose` |
| `securityTransactionType` / `cashTransactionType` / `nonTradeSecurityTransactionType` | `booking_text` |
| `isin` + `quantity` | appended to `purpose` ("ISIN …, 1,234 Stk") until GiroCrab has first-class security positions |
| `status` ≠ executed/settled, or `isCancellation` | skip (pending orders are not bookings) |

Open question: whether `amount` already carries the sign. The Trade Republic
connector had the same ambiguity; resolve with live data in phase 4.

### UI changes (Swift, `GiroCrabApp/Sources/GiroCrabUI`)

- `Formatting.swift`: `displayName` "Scalable Capital", `tintHex` `#0E2A47`
  (Scalable navy), `monogram` "SC".
- `ConnectionsUI.swift`: `keys` → `[]`; **not** in `usesPin`.
- `AppModel.swift` sync entry: treat `.scalableCapital` like a connector without a
  PIN that always goes through `begin()` (the connector decides whether a login is
  needed from its state). No web-login sheet.
- `TwoFactorSheet.swift`: the `.decoupledPush` branch must additionally render
  `c.redirectUrl` as an "Im Browser anmelden" button when present. Currently only
  the `.redirect` branch does that. This is the only UI feature gap.
- `BankPicker.swift`: add "Scalable Capital" to `suggestions` and to the dedicated-
  connector add form (no login input needed; the e-mail field is optional).
- `generated/` bindings: `ConnectorKind` is a UniFFI enum, so the xcframework must
  be rebuilt once (`./build-xcframework.sh`).

### Dependencies (`girocrab-core/Cargo.toml`)

- `p256 = { version = "0.13", features = ["ecdsa"] }` for ES256 signing and the
  public JWK. (`jsonwebtoken` is already present but only configured for RSA/HMAC;
  building the DPoP JWS by hand with `p256` + `base64` is ~60 lines and avoids
  pulling a second backend.)
- `rand` and `sha2` are already present. `sha2` is 0.10 here vs 0.11 in the CLI; the
  API used (`Sha256::digest`) is identical.

### Demo mode

Add a `DemoAccountSpec` for `ConnectorKind::ScalableCapital` in `demo.rs`
(one brokerage "Scalable Depot", one savings "Scalable Overnight") and make
`make_connector_for(kind, key, demo = true)` return the demo stub, as for Trade Republic.

## Implementation plan

Each step ends with `cargo check -q -p girocrab-core` (Rust) or `swift build -q`
(Swift only). Commit granularity: one commit per step.

### Phase 1 – DPoP + device-code login (Rust only, ~250 lines)

1. `connectors/dpop.rs`: `DpopKey::generate()`, `from_hex()`, `to_hex()`,
   `public_jwk()`, `proof(method, url, nonce, access_token) -> String`. Unit tests:
   header/claims shape, `ath` value for a known token, `htu` strips query.
2. `connectors/scalable.rs`: constants (endpoints, client ID, audience, scope),
   `oauth_post(form, key, nonce_retry)` helper with the single nonce retry,
   `request_device_code()`, `poll_device_token()`, `refresh_token()`.
3. `begin()` returning the `DecoupledPush` challenge; `respond()` polling.
4. Manual live test with a real account behind a feature flag / `cargo test --
   --ignored scalable_live` reading credentials from env. Record the exact
   responses (sanitised) in this document under **Live findings**.

### Phase 2 – Session, refresh, 2FA-on-login (~120 lines)

5. State struct ⇄ `ctx.state` JSON, 7-day and 24-hour expiry checks, refresh
   before every `fetch`, `FetchResult.state` round-trip.
6. 2FA-on-login: `Is2faOnLoginEnabled` → `Start2faOnLogin` → poll `Validate2faOnLogin`
   as a second `DecoupledPush` challenge. Use `deviceName = "GiroCrab"`, `deviceType = "CLI"`
   (the backend may only accept the CLI's values; verify live).
7. Error mapping: `access_denied`/`expired_token` → `CoreError::Authentication`;
   `rate_limited` → retryable error with the server's retry delay in the message.

### Phase 3 – Account discovery (~100 lines)

8. `graphql(query, operation_name, variables)` helper with DPoP + `ath` + nonce retry.
9. `ResolveBrokerIds`, `BrokerOverview`, cash breakdown → brokerage `RemoteAccount`.
10. `DiscoverOvernightAccounts` + `OvernightSummary` → savings accounts.
11. `ListFixedTermAccounts` + `GetFixedTermAccount` → savings accounts (balance only).

### Phase 4 – Transactions (~150 lines)

12. `BrokerTransactions` paging with `fromTime`, union-type parsing, mapping table above.
13. `OvernightTransactions` paging and mapping.
14. Sign/status rules confirmed with live data; unit tests from recorded JSON fixtures
    (sanitised) in `connectors/scalable.rs::tests`.

### Phase 5 – Wiring (~80 lines Rust, ~40 lines Swift)

15. `models.rs`: enum variant, `as_str`, `all`. `connectors/catalog.rs`: descriptor,
    `make_connector_for`. `connections.rs`: no login normalisation needed.
16. `demo.rs` demo accounts; `make_connector_for(.., demo = true)` stub.
17. Rebuild xcframework; Swift: `Formatting.swift`, `ConnectionsUI.swift`,
    `AppModel.swift`, `BankPicker.swift`, `TwoFactorSheet.swift` (redirect button in
    the push branch).
18. Localisation strings (DE/EN) for the descriptor note and challenge texts.

### Phase 6 – Tests and docs

19. `cargo test -q -p girocrab-core scalable` green; `swift build -q` green;
    `cargo run -- --demo-seed` shows the demo Scalable accounts.
20. README (both languages): move Scalable Capital from "Help wanted" to supported
    with status "⚠️ Unterstützt, inoffizieller Client der offiziellen CLI-API".
    CONTRIBUTING: drop from the wanted list. Release notes entry.

## Risks and open questions

| # | Risk / question | Mitigation |
| --- | --- | --- |
| R1 | Scalable may restrict the public client ID to its own binary (User-Agent, DPoP key attestation, or token claims). Nothing in the CLI source suggests this, but it cannot be excluded. | Verify in phase 1 before investing further. Send the CLI's User-Agent format initially; switch to a GiroCrab UA once confirmed irrelevant. |
| R2 | Schema or JSON changes without notice (Scalable says so explicitly). | Parse defensively, never fail the whole sync on one unknown union member; log the operation name. |
| R3 | 7-day forced re-login and 24-hour idle timeout. | Surface a clear "Erneut anmelden" state in the UI; automatic refresh on every sync keeps the idle window alive for daily users. |
| R4 | Sign convention of `amount` unknown. | Phase 4 live check; add fixtures. |
| R5 | `Start2faOnLogin` may reject non-CLI `deviceName`/`deviceType`. | Try "GiroCrab"/"CLI" first, fall back to the CLI's literal values. |
| R6 | Terms of service: using the API outside the official CLI. | Read-only use of a user's own data with the user's explicit opt-in switch; document it in the connector note like the Trade Republic disclaimer. |
| Q1 | Does `BrokerOverview.valuation` include cash, or only securities? | Compare with `cash_balance` live; choose the figure that matches the app's "Gesamtwert". |
| Q2 | Does `lastEventDateTime` reflect booking or execution time? | Compare with the Scalable app's transaction dates. |

## Implementation notes (what the code does today)

Files: `girocrab-core/src/connectors/dpop.rs` (signer, 3 unit tests),
`girocrab-core/src/connectors/scalable.rs` (connector, 5 unit tests), wiring in
`models.rs`, `connectors/catalog.rs`, `connectors/demo.rs`, `i18n.rs`; Swift in
`Formatting.swift`, `ConnectionsUI.swift`, `BankPicker.swift`, `TwoFactorSheet.swift`
and `Xcode/App/Localizable.xcstrings`.

Decisions that differ from the original plan:

- **Account layout per broker portfolio**: two accounts like the Trade Republic
  connector, `sc:cash:<pid>` "Verrechnungskonto" (Checking, balance =
  `payments.buyingPower.cashBalance`) carrying all bookings, and `sc:depot:<pid>`
  "Depot" (Brokerage, balance = `securitiesValuation + cryptoValuation`, falling
  back to `valuation`) carrying the holdings from `BrokerHoldings`.
- **User-Agent**: GiroCrab's own (`GiroCrab/<version>`), not the CLI's. Switch to
  `scalable-cli/<version>` only if the live test shows the backend rejects it.
- **Demo seed unchanged**: the curated demo (5 accounts, 50 bookings, asserted by a
  test) does not get Scalable accounts. The demo connector only simulates the
  browser login challenge for a Scalable connection added in demo mode.
- **Session refresh**: `begin()` reuses a stored session when the access token is
  still valid for more than a minute, otherwise refreshes; any OAuth error on refresh
  (idle timeout, 7-day limit, revoked) falls back to a new device-code login instead
  of failing. A 401 during fetch triggers one refresh and retry.
- **2FA-on-login**: if the state query itself fails, the connector logs it and
  continues to fetch rather than blocking (the fetch will surface a real auth problem).
- **Amount sign**: positive amounts of outflow types (`BUY`, `SAVINGS_PLAN`,
  `WITHDRAWAL`, `FEE`, `TAX`, `SWAP_OUT`, `TRANSFER_OUT`, `CASH_TRANSFER_OUT`,
  `REINVESTMENT`, or `side = BUY`) are negated; already-signed amounts are kept.
  Open statuses (`CREATED`, `REQUESTED`, `PENDING`, `PARTIAL_FILLED`, `CANCELLED`,
  `CANCEL_REQUESTED`, `EXPIRED`, `REJECTED`) and `isCancellation` rows are skipped.
- **Overnight accounts** with a `state` other than `ACTIVE` are skipped; Fixed-Term
  accounts only in `PENDING` / `ACTIVE` / `CANCELLATION_REQUESTED`.
- **Debug log**: every step logs to the depot debug log with the prefix `scalable:`;
  tokens and codes are never logged.

## Live test protocol (for the first run on a real account)

1. On scalable.capital: Profile → Security → enable "Agentic Investing".
2. GiroCrab (non-demo): add bank "Scalable Capital", any e-mail as label, "Abrufen".
3. Expected: sheet "Bei Scalable Capital im Browser anmelden" with code and a
   button "Im Browser anmelden". Complete the login in the browser; the sheet
   should close by itself within the poll interval (5 s default).
4. If 2FA-on-login is enabled, a second sheet asks for approval in the Scalable app.
5. Expected result: accounts "Verrechnungskonto" + "Depot" per portfolio, plus
   Overnight / Fixed-Term accounts if present, with bookings since the sync window.
6. Record in **Live findings**: did the device-code call succeed (R1 cleared?),
   DPoP nonce behaviour, the exact amount sign convention observed, whether
   `valuation` includes cash (Q1), status values seen.

## Live findings

First live run on 2026-11-11 (macOS, GiroCrab debug build):

- **R1 cleared**: the device-code request, token polling and all GraphQL
  operations are accepted with GiroCrab's own User-Agent and the CLI's public
  client ID. No client fingerprinting observed.
- **"Agentic Investing" switch is mandatory**: with it off, the browser shows
  "Activation denied – We are not able to activate your device" after the code is
  confirmed. The device-code request itself still succeeds, so the connector cannot
  detect this earlier; the descriptor note tells the user to enable it first.
- **Device flow**: `interval` 5 s, `expires_in` 900 s.
- **2FA-on-login**: `enabled=true, hasApprovedSession=false` on a fresh login.
  `Start2faOnLogin` accepted `deviceName = "GiroCrab"`, `deviceType = "CLI"` (R5
  cleared). `Validate2faOnLogin.status` went `PENDING` → `SUCCESS` (not `APPROVED`
  as guessed; the connector accepts both).
- **Fetch**: `ResolveBrokerIds` returned 1 portfolio; `BrokerOverview` delivered
  `valuation` and `securitiesValuation`; `BrokerLimits` delivered `cashBalance`;
  `BrokerHoldings` yielded 3 positions; `BrokerTransactions` 12 bookings in one page
  for the default 90-day window; `DiscoverOvernightAccounts` 1 account with
  `OvernightSummary.totalAmount`; `ListFixedTermAccounts` 0 accounts.
- DPoP nonce challenges: none observed (no retry needed on any call).
- **Amounts are unsigned.** Overnight withdrawals ("Internal Transfer",
  "Auszahlung" in MoneyMoney) arrived positive in the first import. The sign now
  derives from *all* kind fields (`type`, `cashTransactionType`,
  `securityTransactionType`, `nonTradeSecurityTransactionType`) with keyword rules
  (`WITHDRAW`, `_OUT`, `FEE`, `TAX`, `BUY`, `SAVINGS_PLAN`, …). The exact enum
  values are logged as counts (`broker tx kinds:` / `overnight tx kinds:`) and
  will be pinned down in the next run.
- **Titles**: the booking kind ("Einzahlung", "Auszahlung", "Zinsen", "Kauf" …) is
  now the counterparty line, the API `description` ("Internal Transfer",
  "Umbuchung Tagesgeld") the purpose – matching MoneyMoney's presentation.
- Bookings are stored with `INSERT OR IGNORE`, so rows imported with a wrong sign
  are not corrected by a re-sync: delete the connection and add it again.
- Dates matched MoneyMoney for all visible rows (3.11., 1.11., 12.10., 10.10., 5.10.).
- **Depot value**: the three holdings' `portfolioIsinPerformance.valuation` sum
  exactly to the depot balance (`securitiesValuation`), so Q1 is answered for the
  depot account: securities only. `quoteTick.midPrice` was missing for 2 of 3
  positions; the price is now derived from valuation / quantity in that case.
- **Classification**: buys arrived with an empty `description` for some rows, so
  the merchant matcher could not recognise them as investments and the app counted
  them as spending. Trades now carry the security name (looked up from the holdings
  by ISIN when the description is empty) as title and `Wertpapierkauf` /
  `Wertpapierverkauf` / `Sparplan ausgeführt` as booking text, which the matcher
  classifies as investment; cash rows whose description says "Internal Transfer" or
  "Umbuchung" get booking text `Umbuchung` and classify as transfers.
- Note for users: "Investiert" on the Verrechnungskonto only sums bookings inside
  the sync window (90 days on first sync); the depot balance is the market value of
  all positions, so the two figures are not expected to match.
- **History**: the first sync of a connection (no `login_at` in the stored state)
  now loads the complete transaction history (no `fromTime`), because the app-wide
  "Tage beim ersten Abruf" window (90 days) hides a depot's purchase history. Later
  syncs stay incremental via `ctx.since`.
- **Deposits/withdrawals are transfers**: the merchant matcher classifies on the
  German keywords `einzahlung` / `umbuchung` / `übertrag` in counterparty +
  purpose + booking text. With an English UI the translated title "Deposit" did not
  match, so reference-account deposits counted as income. Booking text now always
  carries `Einzahlung`, `Auszahlung Übertrag auf Referenzkonto` or `Umbuchung`
  regardless of UI language, so the Income tile only shows interest/dividends.
- Still open: status values seen.

## Change log

- 2026-11-11 – Initial feasibility study and plan written from scalable-cli v1.3.0 source.
- 2026-11-11 – Phases 1–5 implemented (DPoP signer, device-code login, refresh, 2FA-on-login, broker/Overnight/Fixed-Term fetch, holdings, Swift wiring). Unit tests green. Awaiting first live test.
- 2026-11-11 – Scalable Capital added to the bank search directory (was not findable in "Add Bank").
- 2026-11-11 – First live run succeeded end to end: login, 2FA, 1 portfolio, 12 bookings, 3 holdings, 1 Overnight account. See Live findings.
- 2026-11-11 – Fix: unsigned API amounts; sign now derived from every kind field; booking kind as title, description as purpose; kind statistics logged.
- 2026-11-11 – Fix: trades titled with the security name and classified as investment via German booking text; internal transfers classified as Umbuchung; holding price fallback when the quote is missing.
- 2026-11-11 – First sync loads the full history instead of the 90-day window.
- 2026-11-11 – Fix: deposits/withdrawals classified as transfers via language-independent booking text.
- 2026-11-11 – Connector merged upstream (#54). README (DE/EN) and CONTRIBUTING updated: Scalable Capital moved from "Help wanted" to supported (⚠️ unofficial client of the official CLI API, read-only, Agentic Investing required).
