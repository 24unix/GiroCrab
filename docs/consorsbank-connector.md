# Consorsbank connector – research and plan

Living document. Update the **Status** table and the **Change log** whenever work
on this connector advances.

Research date: 2026-11-11. Nothing below has been verified against a live
Consorsbank account yet unless the Status table says so.

## Status

| Phase | Scope | State |
| --- | --- | --- |
| 0 | Research: which interfaces exist, what the FinTS code already covers | ✅ done 2026-11-11 |
| 1 | Live test of the existing FinTS preset (login, cash account, Tagesgeld, depot) | 🟡 2026-11-14: login, account list, HKSAL, HKKAZ (MT940, v7, 90 days, no TAN) and HKWPD (depot, 1 position) work; history is limited to 90 days by the bank (BPD `HIKAZS … 90:J:N`, `3997` beyond) |
| 2 | Consorsbank-specific FinTS fixes (see Gap analysis) | 🟡 security profile + forced HKTAN done 2026-11-14 (both confirmed live); full KTI for BLZ 76030080 only (confirmed live 2026-11-14); typed TAN on fetch open |
| 3 | Bank entry (name, tint, monogram, preset note, user-ID hint, search words) | ✅ done 2026-11-14 – without a dedicated `ConnectorKind`, see Change log |
| 4 | README/CONTRIBUTING: move from "Help wanted" to supported | ✅ done 2026-11-14: `BANK_MATRIX` status `Verified`, README matrix regenerated (website `../girocrab.de` still to be synced) |

---

## Summary

Consorsbank (BNP Paribas S.A. Niederlassung Deutschland, BLZ 76030080) offers
three machine interfaces. Only one is usable for a local personal-finance app:

| Interface | Usable by GiroCrab? | Why |
| --- | --- | --- |
| **FinTS 3.0 PIN/TAN** at `https://brokerage-hbci.consorsbank.de/hbci` | **Yes** – the repo already has a preset and directory entry | Customer credentials, no registration. Cash account + depot holdings. Known quirks, see below. |
| PSD2 XS2A (`xs2a.consorsbank.de`, NextGenPSD2, redirect SCA) | No | Requires a licensed TPP. Enable Banking coverage of Consorsbank could not be confirmed (bank list is JS-rendered). No depot data in any case. |
| Trading API (REST/HAL, OAuth 2.0 FAPI, `api.consorsbank.de/trading/v1`) | No | Client registration with Consorsbank (certificate, signing key, redirect URI), mutual TLS on every token call, partner onboarding via `api-support@consorsbank.de`. Exposes depot positions, per-WKN position history, orders/executions, but **no cash-account bookings**. |
| ActiveTrader gRPC API (protobuf, `Dokumentation Java.zip`) | No | Separate product for the ActiveTrader desktop application; login by shared secret; trading-oriented. |
| Web scraping (kairichard/consorsbank) | No | Author states it stopped working after MFA was introduced. Not acceptable for GiroCrab anyway. |

**Decision:** Consorsbank = FinTS. No new connector module. The work is a live
test of the existing FinTS connector plus bank-specific fixes and a proper
bank entry.

---

## FinTS facts

Sources: Hibiscus wiki (changed 2026-10-25), python-fints PR #218 (June 2026,
tested live), homebanking-hilfe.de threads 2022–2025, fino help page (Oct 2025),
Banking4 bank table. Marked *(anecdotal)* where only one forum user reports it.

### Access data

| Field | Value |
| --- | --- |
| BLZ | `76030080` (also `70120400` "BNP Paribas S.A. Niederlassung Deutschland-Consorsbank" in the directory – former DAB) |
| URL | `https://brokerage-hbci.consorsbank.de/hbci` (the old `consors.de` host broke at Easter 2023) |
| Version | FinTS 3.0 only ("HBCI 2.2 ist auf jeden Fall falsch") |
| Benutzerkennung | **10-digit account number of the Verrechnungs-/Girokonto, zero-padded, + `001`**, e.g. `0001234567001` (Hibiscus wiki). fino says "9-digit account number + 3-digit user ID (usually 001)"; former DAB customers: 10-digit account number + 001. Zero-padding to 10 digits covers both. |
| Kundenkennung | same as Benutzerkennung |
| PIN | online-banking PIN (≥ 8 characters) |
| Activation | No source says FinTS must be switched on in the portal (other banks' wiki sections do say so; Consors' does not). Banking4 only has the generic "ggf. explizite Freischaltung durch Ihre Bank". To be checked live. |

### TAN methods (HITANS)

| Code | Name | Login | Orders / fetch |
| --- | --- | --- | --- |
| `901` | "Consorsbank/myPrivateBank App" (`zka_id` Decoupled) | **Typed 9-digit TAN generated in the app** – bank answers `0030` without `3955` (python-fints PR #218, live). Hibiscus wiki: "Push-TAN oder manuell generierte TAN per Consorsbank App". | Orders: decoupled push approval, bank returns **both `0030` and `3955`** on the order segment. |
| `900` | "SecurePlus TAN Generator" (`zka_id` photoTAN, hardware device from KOBIL, 19,95 €) | No SCA, bank answers `3076`. | Order-bound photoTAN QR as `challenge_matrix` (MIME + image), user types TAN. |
| – | SecurePlus **App** | Shut down (fino: replaced by the Consorsbank App since August 2025; PR #218: shut down 2026-04-25). Any TAN it produces is rejected with **`9941 TAN ungültig`**. | – |

A Hibiscus user (Dec 2025) reported `9941 TAN ungültig (DialogInitSCA.TAN2Step6)` +
`9050` during dialog init even though they could approve logins in the app.
Unresolved; probably the wrong TAN source (old app). *(anecdotal)*

### Business transactions

| Segment | Works? | Notes |
| --- | --- | --- |
| HKSAL, HKKAZ on the Verrechnungskonto / Girokonto | Yes (several reports, PR #218 compared the result with hbci4j output) | **HIPINS says `HKKAZ:N`, but HKKAZ without HKTAN is rejected with `9075`**; python-fints forces HKTAN process 4 for `HKKAZ`, `HKSAL`, `HKCCS` at this bank. |
| HKCAZ (camt) | Unknown | Not mentioned anywhere. |
| Tagesgeldkonto | Contradictory | Hibiscus wiki: "Klappt sowohl mit dem Verrechnungskonto, Girokonto und Tagesgeldkonto" (but its account number differs and the user ID stays that of the Verrechnungskonto). Forum 2023: "nur das sog. Verrechnungskonto … (nicht z. B. das Tagesgeldkonto)". *(both anecdotal)* |
| HKWPD depot holdings (MT535) | Probably | Banking4: "Depot: ja". UPD of the depot account allows `HKWPD` and `HKPRO` (python-fints issue #51, 2019). The failure in that issue (`9380 Keine Berechtigung für diese Auftragsart mit diesem Konto`) most likely came from sending HKWPD for the giro account instead of the depot. Hibiscus users report "Depot-Abrufe klappen nicht, noch nie", but Hibiscus needs a plugin for depots. |
| Depot transaction history | **No** | FinTS has no such segment; GiroCrab shows holdings only (same as every FinTS depot). |
| HKEKA electronic statements | No | Banking4: "Kontoauszüge: nein". |
| Standing orders (HKCSB/HKCDB) | No | Hibiscus wiki: "Abrufen oder erstellen von Daueraufträgen funktioniert nicht." |
| Credit card | No | Banking4: "Kreditkarte: nein". |

### Protocol quirks found by python-fints (PR #218, all confirmed live there)

1. **Login SCA codes hang on HKIDN, not HKTAN.** The `0030`/`3955` reply to the
   dialog-init HKTAN process 4 references the HKIDN segment. Clients that only
   look at codes attached to HKTAN miss the challenge and then get `9800`/`9120`.
2. **Decoupled = `3955` present, regardless of order.** Orders come back with
   `0030` *and* `3955`; the first code is not decisive.
3. **HNSHK security profile** must be `PIN:2` for two-step methods.
4. **KTI must be complete**: IBAN, BIC *and* account number, sub-account and
   bank identifier (country from BIC chars 4–6 + BLZ). Consorsbank rejected
   the IBAN:BIC-only form.
5. **`9075` on HKKAZ without HKTAN** although HIPINS lists it as not TAN-bound.

---

## Gap analysis against `girocrab-core/src/connectors/fints/mod.rs`

| Quirk | GiroCrab today | Action |
| --- | --- | --- |
| 1. codes on HKIDN | `BankReply::has`/`code` match over **all** HIRMG/HIRMS codes, not per segment reference | none |
| 2. 3955 + 0030 together | `request()` checks `3955`/`3956` **before** `0030`; `challenge_from` likewise | none |
| 3. PIN:2 | **Was wrong for the sync dialog:** `PIN:2` was sent with security function `999` too. First live attempt (2026-11-14) failed with `9800` / `9010 Ungültiger Signaturaufbau: Fehler im Segmentaufbau` at message level. | ✅ `security_profile()`: `PIN:1` for `999`, `PIN:2` for two-step (as hbci4j does) |
| 4. full KTI | `kti()` sends `IBAN:BIC` when an IBAN exists | ✅ `kti()` sends the full form `IBAN:BIC:Konto:Unterkonto:280:BLZ` for BLZ 76030080 only (other banks unchanged until verified). Live: HKKAZ+HKTAN with IBAN:BIC got `9050` + `9010` on the HKKAZ segment. |
| 5. 9075 on HKKAZ | `request()` adds HKTAN process 4 only when `tan_required[seg] == true` from HIPINS | ✅ `needs_hktan()`: per-BLZ override `{HKKAZ, HKSAL}` for 76030080 (the set python-fints confirmed live). HKCAZ/HKWPD follow HIPINS until the live test says otherwise. |
| Login with typed app TAN (`0030`, no image) | `challenge_from` builds a `Code` challenge | none, but UI wording: "TAN aus der Consorsbank App eingeben" |
| **Fetch needs a typed TAN** (`0030` on HKKAZ with method 901) | `request()` returns an **error** on `0030` ("bitte Push-Verfahren verwenden") | **Open question.** If Consorsbank answers HKKAZ+HKTAN with `0030` (typed TAN) rather than `3955` (push), fetch cannot complete today. Needs the live test. If so: support a mid-fetch `Code` challenge, or rely on the 90-day window ("Tage beim ersten Abruf" ≤ 90, PSD2 exemption) which the error message already suggests. |
| Depot (Kontoart 30–39) | HKWPD page loop + MT535 parser exist | live test only |
| Tagesgeld | generic UPD handling | live test only |
| User ID format | preset has no note | add preset note + bank-directory hint "Kontonummer 10-stellig mit führenden Nullen + 001" |

Nothing in the TAN handling has to change for the login. The one real risk is
the typed-TAN-on-fetch case.

---

## Plan

### Phase 1 – Live test (requires a Consorsbank login)

1. Add Bank → "Consorsbank" (preset `consorsbank`), user ID `000…<Kontonummer>001`, PIN.
2. Record from the depot debug log (no account data): HITANS methods offered, codes
   on dialog init, whether HKKAZ returns `9075`, whether HKKAZ+HKTAN returns
   `0030` or `3955`, Kontoart of each UPD account, HKWPD result for the depot,
   HKSAL/HKKAZ result for the Tagesgeld.
3. Note the first-sync window the bank accepts without TAN (90 days?).

### Phase 2 – Fixes (driven by phase 1)

4. Full KTI form (`kti()`), regression-checked with the existing FinTS unit tests.
5. `9075` → retry with HKTAN process 4 (generic), plus per-BLZ default for
   76030080 if the retry costs a second TAN.
6. If fetch needs a typed TAN: mid-fetch `Code` challenge through the existing
   `Phase::Challenge` machinery (the Swift side already renders `Code`).
7. Unit tests from recorded HIRMS/HITANS fixtures.

### Phase 3 – Bank entry

8. `ConnectorKind::Consorsbank` → key `fints:76030080` (like `Direkt1822`),
   `Formatting.swift` display name "Consorsbank", tint, monogram "CB".
9. Preset note (DE/EN): user ID format, SecurePlus App no longer valid, use the
   Consorsbank App or the SecurePlus generator.
10. Bank directory search words: consors, consorsbank, dab, bnp.

### Phase 4 – Docs

11. README (both languages): row "Consorsbank | FinTS 3.0 PIN/TAN | ✅ Unterstützt"
    with a note "Depot: nur Bestände"; drop from "Help wanted"; CONTRIBUTING.

---

## Open questions

| # | Question | How to answer |
| --- | --- | --- |
| 1 | Does HKKAZ (+HKTAN) with method 901 need a typed TAN (`0030`) or a push (`3955`)? | live test |
| 2 | Is there a 90-day no-TAN window for HKKAZ? | live test with "Tage beim ersten Abruf" 90 vs. 365 |
| 3 | Does FinTS need activation in the Consorsbank portal? | live test; if login fails with a permission error, look in Einstellungen |
| 4 | Is the Tagesgeldkonto in the UPD, and does HKSAL/HKKAZ work for it? | live test |
| 5 | Does HKWPD return MT535 for the depot? Which HKWPD version does HIWPDS list? | live test |
| 6 | Does Enable Banking list Consorsbank (fallback if FinTS fails)? | open `enablebanking.com/open-banking-apis?country=DE` in a browser |

## Sources

- Hibiscus wiki, section "Consors: PIN/TAN": https://www.willuhn.de/wiki/doku.php?id=support:list:banken:misc:pintan
- python-fints PR #218 "Consorsbank: detect login SCA on HKIDN and decoupled 0030+3955 app approval": https://github.com/raphaelm/python-fints/pull/218
- python-fints issue #51 "Consorsbank Depot": https://github.com/raphaelm/python-fints/issues/51
- homebanking-hilfe.de: "Depot-Abruf bei Consors scheitert" (t=25359), "consorsbank nicht abrufbar" (t=25762), "Consorsbank – Fehler beim Umsatzabruf" (t=23128)
- fino help "Consorsbank – Notes on Account Integration and Login (as of September 2025)": https://kws.help.fino.digital/en/support/solutions/articles/80000616990-consorsbank-formerly-dab-bnp-paribas-
- Banking4 bank table: https://banking4.de/knowhow.html
- Consorsbank developer portal (Trading API, OAuth, OpenAPI 3.1 spec): https://developer.consorsbank.de/
- Consorsbank XS2A: https://www.consorsbank.de/web/Service/XS2A and the NextGenPSD2 YAML (2020)
- Consorsbank SecurePlus generator: https://www.consorsbank.de/web/Service/SecurePlus
- Enable Banking Germany market page (no Consorsbank mention): https://enablebanking.com/docs/markets/de/
- Miguel0888/consorsbank (ActiveTrader gRPC), kairichard/consorsbank (scraper, dead)

## Change log

- 2026-11-11 – Research written: FinTS is the only viable route; gap analysis against the existing FinTS connector; phased plan.
- 2026-11-14: First live attempt failed during login with `9800` / `9010 Ungültiger
  Signaturaufbau: Fehler im Segmentaufbau` (message level). Fix: HNSHK/HNVSK security
  profile `PIN:1` for the one-step sync dialog (`999`), `PIN:2` otherwise. Also forced
  HKTAN process 4 for HKKAZ/HKSAL at BLZ 76030080 (quirk 5). Added a step trace
  (`fints msg: …`, segment names + codes only) to the `GIROCRAB_DEPOT_DEBUG=1` log.
  Not yet re-tested live.
- 2026-11-14: Live results. Login needs the user ID `<10-digit account number>001`
  (anything else → `9942 PIN ungültig`). With `PIN:1` the sync dialog passes; dialog
  init with method 901 answered `3076` (no SCA) on HKIDN. HKSPA, HKWPD (depot, MT535,
  1 position) and HKSAL+HKTAN (`3076`) work. HKKAZ+HKTAN was rejected with `9050` +
  `9010` on the HKKAZ segment → full KTI for BLZ 76030080. Trace now also logs segment
  versions and the bank's error texts.
- 2026-11-14: Full KTI confirmed live: HKKAZ v7 + HKTAN answers `0020` / `3076` (no SCA)
  for the default 90-day window; bookings arrive. A request reaching further back (tried
  with a temporary one-off backfill, since removed) gets no TAN request either, but
  `3997 Der Auftrag wurde nur teilweise ausgeführt.` and nothing older than about 90 days.
  Answers open questions 1 and 2. The sync reports such a partial delivery per account.
- 2026-11-14: The 90-day limit is the bank's: BPD `HIKAZS` v6/v7 advertise a storage
  period of 90 days (`90:J:N`). Activating the Personal-Finance-Manager in online banking
  made no difference for FinTS.
- 2026-11-14: Phase 3 and 4. No dedicated `ConnectorKind`: FinTS banks are generic
  `fints:<blz>` connections today (a test pins `fints:76030080` to `FinTsGeneric`), so the
  entry is data on top of that: preset note and add-form hint for the user ID
  (`<10-digit account number>001`), "tested" note in the bank search, search words
  `dab` / `bnp paribas`, tint and monogram "CB" by BLZ (`BankConnection.tint` /
  `.monogram`). `BANK_MATRIX` lists Consorsbank as verified (README DE/EN regenerated
  with `scripts/sync_docs.py`).
- Still open: login with a typed app TAN (`0030`) and transfers have not been exercised
  live; today every login was SCA-exempt (`3076`).
