# Plan: generic PSD2 banking via Enable Banking (C24, N26, Revolut, …)

Goal: any bank on Enable Banking's list syncs into GiroCrab as properly typed
accounts (Giro, savings/Pockets, cards). Syncing runs on its own without a TAN
until the consent expires, about every 180 days. C24 is the first bank to
verify, then N26 and the rest of the curated list.

Payments are out of scope: they need a PISP licence. The approach matches the
FinTS product ID (bring your own): each user registers their own free
Enable Banking app in restricted mode and links their own accounts.

## Status (2026-11-11)

| Phase | State |
|---|---|
| 1 – correct generic connector | ✅ merged (GiroCrab/GiroCrab#66) |
| 2 – consent visibility, scheduled sync, account changes | ✅ merged (#66) |
| GiroCode for read-only accounts (not in the original plan) | ✅ merged (GiroCrab/GiroCrab#67) |
| 3 – smoother setup | ✅ implemented on `feat/enable-banking-setup`: bank login inside GiroCrab (redirect caught, no pasting), guided setup with `.pem` import (application ID from the file name) and `GET /application` check, dialog starts in Downloads. Verified with a real C24 account from an empty vault. |
| 4 – per-bank verification | C24 ✅ (see below); other banks still need a real account each |

## 1. What already exists

| Piece | Where | State |
|---|---|---|
| Generic connection type, key `enablebanking:<CC>:<ASPSP>` | `models.rs` `ConnectorKind::EnableBanking`, `enable_banking_key/target` | ✅ works |
| Connector for any bank | `connectors/enable_banking.rs` `EnableBankingConnector::for_aspsp` | ⚠️ written for Amex, see §2 |
| Bank picker: curated PSD2 list (C24, N26, Revolut, Tomorrow, Vivid, Wise, …) plus live `GET /aspsps` | `connectors/bank_directory.rs` | ✅ works |
| Exact ASPSP spelling at connect time | `enable_banking.rs` `pick_aspsp_name` | ✅ (curated "C24 Bank" vs live name "C24": confirm it resolves) |
| JWT (RS256, kid = app id), settings for app id / key / redirect URL | `enable_banking.rs` `make_jwt_for`, `ConnectionsUI.swift` | ✅ works |
| Bank login: open URL, paste the redirect URL, `POST /sessions` | `begin` / `respond` / `extract_code` | ✅ works, but the paste step is clunky |
| Session stored encrypted and reused until `valid_until` | `PsdState` | ✅ works |

## 2. Problems in the current connector (Amex assumptions)

1. **Every account becomes `AccountKind::CreditCard`**, so a C24 Giro account
   or a Pocket shows up as a card.
2. **Account identity is the session `uid`.** The vault matches accounts by
   `(connection_id, external_ref)` (`vault.rs:104`), and `uid` is only valid
   for one session. After the ~180-day re-consent every account would be
   **duplicated**. The API provides `identification_hash`, which is meant to be
   stable across sessions.
3. **Consent length is hardcoded to 90 days**
   (`enable_banking.rs:298`). The bank reports its maximum as
   `maximum_consent_validity` (in seconds) via `GET /aspsps`, usually 180 days.
4. **Card-only lookback and balance logic:** a fixed 180-day lookback floor
   and "add pending sum to balance". Wrong for current accounts.
5. **Expired consent and rate limits aren't handled.**
   `EXPIRED_SESSION` / `REVOKED_SESSION` / `CLOSED_SESSION` /
   `ASPSP_PSU_ACTION_REQUIRED` arrive as generic errors.
   `ASPSP_RATE_LIMIT_EXCEEDED` (bank limit, often 4 background requests per
   day) is not told apart from other errors.
6. **No `access` flags** (`balances`, `transactions`,
   `transactions_extended_history`) are sent, so behaviour depends on the bank.
7. **No scheduled sync.** I found only manual sync in `AppModel.swift`
   (`syncNextInQueue`), no timer.

## 3. Plan

### Phase 1: correct generic connector (Rust only, no UniFFI change)
`girocrab-core/src/connectors/enable_banking.rs`

1. **Account model.** Extend `PsdState.accounts` from a tuple to a struct:
   `{uid, identification_hash, iban, name, product, currency, cash_account_type, usage}`.
   Use `serde(default)` and keep reading the old tuple form for stored Amex
   state.
2. **Account kind** from `cash_account_type`: `CACC`→Checking,
   `SVGS`→Savings, `CARD`→CreditCard, `LOAN`→Loan, `OTHR`/missing→Checking.
   The Amex and Amazon Visa kinds keep forcing CreditCard.
3. **Stable `external_ref`.** Use IBAN when present, otherwise
   `identification_hash`, otherwise `uid`. Keep a `uid ↔ external_ref` map in
   `PsdState` for API calls. Migration for existing Amex/Amazon Visa
   connections: on first fetch, if the vault has an account whose
   `external_ref` is the old uid, rewrite it to the new key. This needs a
   small vault helper (`rekey_account(connection_id, old, new)`).
4. **Consent length.** Before `POST /auth`, read the ASPSP entry from
   `GET /aspsps?country=…` (already called by `pick_aspsp_name`; keep the
   object). Set `valid_until = now + min(maximum_consent_validity, 180 days) − 1 h`.
   Send `access: {valid_until, balances: true, transactions: true, transactions_extended_history: true}`,
   `psu_type: "personal"`, `language: "de"`.
5. **Transaction fetch for current accounts:**
   - First sync: `strategy=longest` (one extra confirmation only if the bank
     needs it for history older than 90 days; the user is present anyway).
   - Later syncs: `date_from = last booking − 10 days` (overlap for late
     bookings). Keep the 180-day floor for card kinds only.
   - Dedupe key: `entry_reference`, which the API guarantees is stable for
     the same `identification_hash`. Never use `transaction_id`, which "may
     change". Content hash stays the fallback.
6. **Pending bookings** (`PDNG`, for non-card accounts): import them as
   provisional bookings under a `hold_prefix` (the bunq card-hold mechanism)
   instead of adding them into the balance.
7. **Balance pick** for Checking/Savings: `CLBD` → `ITBD` → `XPCD` →
   `ITAV`. `ITAV`/`CLAV` is "available" and is not stored as the account
   balance.
8. **Error mapping:**
   - `EXPIRED_SESSION`, `REVOKED_SESSION`, `CLOSED_SESSION`,
     `WRONG_SESSION_STATUS`, `ASPSP_PSU_ACTION_REQUIRED`: clear the session and
     return `CoreError::Authentication("Zustimmung abgelaufen – bitte neu verbinden")`.
     The next `begin` starts a new consent.
   - `ASPSP_RATE_LIMIT_EXCEEDED`: a distinct error ("Tageslimit der Bank
     erreicht – nächster Abruf später"). Keep already fetched data and don't
     retry.
   - Per-account `ASPSP_ACCOUNT_NOT_ACCESSIBLE`: skip that account, sync the
     rest.
9. **Unit tests** in `enable_banking.rs` tests, using JSON fixtures from the
   API reference: kind mapping, external_ref choice and migration, old-state
   deserialisation, error-code mapping, pagination with `continuation_key`,
   `PDNG` handling.

### Phase 2: consent visibility and scheduled sync (Rust + Swift)
1. Expose `consent_valid_until` per connection to the app. This is a small
   UniFFI addition (e.g. on the connection record), so rebuild the
   xcframework.
2. `ConnectionsUI.swift`: show "Zustimmung gültig bis …", a warning badge
   from 14 days before expiry, and a "Neu verbinden" button.
3. **Scheduled sync** (`AppModel.swift`): while the app runs, sync PSD2
   connections on launch and then every 6 h. That's 4 per day, within the
   usual bank limit. Skip connections that need user action. The setting goes
   in Settings (off / 6 h / 12 h / 24 h). The same mechanism could later serve
   bunq and other connections that need no TAN.
4. Local notification when a consent expires within 7 days, or has expired.
5. **Account changes are shown, never applied silently.**
   - *Observed on a real C24 account (2026-11-11):* unlinking accounts in the
     Enable Banking Control Panel does **not** affect an existing consent.
     The unlinked savings and shared accounts were still delivered without
     error. The account list only really changes on a new consent
     (reconnect, or expiry and renewal) or when the bank refuses access.
   - **On reconnect:** compare the previous accounts with the new session's
     (`carry_over` already matches them by IBAN / identification hash).
     Accounts that are new get named in the sync notice ("Neu: …"). Accounts
     that are no longer included get the status "Zugriff entzogen" and a
     notice, and are no longer fetched.
   - **When the bank refuses an account** (`ASPSP_ACCOUNT_NOT_ACCESSIBLE` /
     `ACCOUNT_DOES_NOT_EXIST`, currently only logged and skipped): same
     status and notice.
   - **Never delete automatically.** A marked account keeps its bookings and
     balance; the user chooses to hide or remove it. If a later consent
     includes it again, the status clears and syncing resumes under the same
     account (same stable key).
   - Needs: per-account status in the vault (e.g. `accounts.access_state`),
     returned via `FetchResult` from the connector, exposed through UniFFI;
     a badge on the account in the sidebar and a line in the sync toast.

### Phase 3: smoother setup
1. **Redirect without pasting.** Check whether Enable Banking accepts a
   loopback (`http://127.0.0.1:<port>/callback`) or custom-scheme redirect URL
   for restricted apps. If it does, catch the redirect with
   `ASWebAuthenticationSession` or a one-shot local listener. Otherwise keep
   pasting.
2. **Guided onboarding** in `BankPicker.swift`:
   - generate the RSA key in-app (Keychain / vault) and export the
     certificate for upload;
   - explain the Control Panel step "Activate by linking accounts" and that
     **every account (joint account, each Pocket) must be linked there**, or
     the API won't return it.
3. **Live bank list** stays the source of truth. Curated entries only
   provide nice names and icons.

### Phase 4: per-bank verification
For each bank, link your real account, sync, re-sync the next day without a
TAN, and record the results in the bank's entry in `bank_directory.rs`:

| Bank | Check |
|---|---|
| C24 | Giro, joint account, Pockets (with and without own IBAN), consent days, PDNG support |
| N26 | Spaces show up as accounts? consent days |
| Revolut, Tomorrow, Vivid, Wise | multi-currency accounts, `cash_account_type` values |
| Amex / Amazon Visa | still correct after the Phase 1 changes (regression) |

## 4. Order of work and testing
1. Phase 1 with unit tests: `cargo test -q -p girocrab-core`.
2. Enable Banking **sandbox** app (mock ASPSPs) for an end-to-end run without
   real accounts.
3. Real C24 account (Phase 4), then Phase 2, then Phase 3.

### Phase 4 results

**C24** (real account, 2026-11-11), recorded in `bank_directory.rs` and
shown in the bank picker:
- Current account (`CACC`, product "C24 Smartkonto"), joint account and the
  savings Pocket all come through. The Pocket has **no IBAN** (BBAN only) and
  comes as `CACC` with product "C24 PocketZINS Smart" → typed as savings by
  the product label.
- Consent: 180 days (`maximum_consent_validity`); later syncs run without a
  TAN, also the next day.
- Unlinking accounts in the Enable Banking Control Panel only takes effect on
  the next consent; "Neu verbinden" then returns only the linked accounts and
  the others are marked "Zugriff entzogen".
- The ASPSP name is "C24" (the catalog said "C24 Bank", so C24 appeared twice
  once the live list was loaded – fixed).
- No `PDNG` bookings seen so far.

## 5. Open questions
- ~~Does C24 return Pockets without their own IBAN?~~ Yes (BBAN, see above).
- ~~Does the C24 joint account need to be linked separately by each account
  holder?~~ It comes through for the holder who links it.
- ~~Can a restricted Enable Banking app use a loopback or custom-scheme
  redirect URL?~~ Not needed: GiroCrab's own login window catches the
  `https://localhost/girocrab/callback` redirect.
- PSU headers (`Psu-Ip-Address` etc.) mark a request as user-present and so
  aren't counted against the daily limit. Sending them for manual syncs needs
  the public IP, which means an external lookup. Probably not worth it.
