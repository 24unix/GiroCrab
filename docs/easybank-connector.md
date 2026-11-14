# easybank-Anbindung (ehemals Barclays Deutschland)

<!-- sync:connector-note:start -->
> **Hinweis / Note:** Dieser Connector ist ein unabhängiges Community-Projekt und steht in keiner Verbindung zur easybank. Schnittstelle: inoffiziell. Bei inoffiziellen Schnittstellen kann die Nutzung gegen die Nutzungsbedingungen der Bank verstoßen.
> This connector is an independent community project and is not affiliated with easybank. Interface: unofficial. Using unofficial interfaces may violate the bank's terms of service.
<!-- sync:connector-note:end -->

Status: **funktioniert** (live getestet 2026-11-14: Login, SMS-TAN, Karten, Umsätze) –
`ConnectorKind::Easybank` (Schlüssel `easybank`), direkter HTTP-Login in
`girocrab-core/src/connectors/easybank.rs`, kein Browserfenster.
Issue: [#209](https://github.com/GiroCrab/GiroCrab/issues/209). Kein PSD2-Zugang verfügbar.

Alle Angaben unten stammen aus der Analyse des Web-Portals `https://banking.easybank.de`
(Stand 2026-11). Es sind ausschließlich Feldnamen und Regeln notiert, keine echten Werte.

## Plattform

* Angular-SPA auf **VeriBranch** (VeriPark), JS mit Jscrambler verschleiert.
* Zwei Endpunktfamilien (alle `POST`, JSON):
  * `/services/flow/<Flow>` startet einen Flow, `/services/flow/<flow>/<schritt>/next` geht weiter.
  * `/call/directive/<Controller>/<Aktion>` und `/call/flow/<Flow>/<Aktion>` für Datenabrufe.
* Antwort-Hülle: `{ "Item": { … }, "Result": { "IsSuccess": bool, "Error": { "Code", "DisplayMessage" } } }`.
  Generischer Fehler: `VINZ_PV_001`.

## Pflicht-Header (sonst HTML oder `VINZ_PV_001`)

| Header | Quelle |
|---|---|
| `Content-Type: application/json` | |
| `X-Requested-With: XMLHttpRequest` | |
| `Accept-Language` | `VeriBranch.Config.Culture` (`de-DE`) |
| `UniqueKey` | aus dem HTML von `GET /Login` (`VeriBranch.Config.UniqueKey = '…'`), nach dem Login `Item.Response.UniqueKey` |
| `X-XSRF-TOKEN` | Cookie `XSRF-TOKEN` |
| `Request-Id` | **muss** `<traceID>.2.<UUID>` sein (traceID = eine UUID pro Sitzung, `2` = fester ParentID, danach eine neue UUID v4). Eine beliebige ID wird mit `VINZ_PV_001` abgelehnt. |
| `pcid` (optional) | `VeriBranch.Config.PCID` |

Alle Werte lassen sich ohne Browser erzeugen: `GET /Login` setzt die Cookies (`XSRF-TOKEN`,
Sitzung) und enthält den `UniqueKey`.

## Login

1. `POST /services/flow/LoginTransaction` (Body `{}`) → `StepName: FirstLevel`.
2. `POST /services/flow/logintransaction/firstlevel/next` mit einem **flachen** Objekt
   (`UserName`, `Password`, `OTPPassword: ""`, `IsCaptchaRequired: true`, … – keine `Item`-Hülle)
   → `Item.Response.NextFlowItemType`: `OTPSecurity` (SMS nötig, `OTPRequirementReason:
   UnrecognizedBrowser`) oder `SuccessfulAuthentication` (Client wiedererkannt).
3. Bei `OTPSecurity`: `POST /call/directive/VbOtpboxDirective/SendOTP` → SMS (mTAN), dann
   `POST /services/flow/logintransaction/otpsecurity/next` mit dem zurückgegebenen `Item.Request`
   plus `OTPPassword`.
4. `POST /call/flow/Login/AfterLogin` (best effort). Die Web-App öffnet danach `RetailLanding`;
   das liefert ohne passenden Body „Account configuration not found for
   transactionName:RetailLanding“ und wird nicht gebraucht.

**TAN nur einmal:** Nach dem ersten Login mit TAN schickt der Server bei weiteren Logins ein
`BrowserTrackingToken` (aus einem HttpOnly-Cookie) und überspringt die SMS. Der Connector speichert
alle dauerhaften Cookies (ohne Sitzungs-, XSRF- und ARR-Cookies) im Verbindungszustand.
Captcha möglich (`Request.NeedCaptcha`), dann Fehlermeldung mit Hinweis auf einen Login im Portal.
Sitzungen enden nach kurzer Inaktivität (`/login?logoutReason=AutoLogout`).

## Konten

`POST /services/flow/AccountTransactionHistory` (Body `{}`) öffnet den Umsatz-Flow (setzt den
Server-Kontext für `GetTransactions`) und liefert die Karten unter
`Item.InitialCallResponses[Config.Url = CustomAccount/GetAccountList].Response.Item.AccountList[]`
(Rückfall: `POST call/directive/CustomAccount/GetAccountList`). Je Karte u. a.:
`Number`, `IBAN`, `AccountName`/`ProductName`, `AccountType` (`Card`), `HostID`, `AccountStatus`,
`CurrentBalance{Value,Currency.Code}`, `AvailableCreditLimit`, `CurrentCreditLimit`,
`NextPaymentDate`, `NextPaymentAmount`, `TotalAmountDue`.
Mapping: `AccountKind::CreditCard`, `external_ref` = `Number`, Saldo = `CurrentBalance.Value` (negativ = Schuld).

## Umsätze

`POST call/directive/TransactionViewDirective/GetTransactions`, Body (alle Felder nötig):

```json
{ "SelectedApprovalRule": 0, "SelectedApprovalSubRule": 0, "DisableNonStp": false,
  "IsSourceFutureDated": false, "OpenCaseAndExecuteTransaction": false, "OpenConditionalCase": false,
  "OpenCaseAndNotExecute": false, "Account": { …ein Eintrag aus AccountList unverändert… },
  "StartDate": "<ISO>", "EndDate": "<ISO>", "HasStartAmountValue": false, "HasEndAmountValue": false,
  "TransactionFlag": "All", "TransactionTypeIndicator": 0, "Status": "ALL", "OTPAlreadyChecked": false,
  "IsExporting": false, "hasOptionDetail": false, "CardNetwork": "Undefined", "IsDisputeOnly": false,
  "IsStatementDateSelected": false, "StatementDate": "0001-01-01T00:00:00+00:00", "FetchAll": false,
  "HasFilters": false, "HasSorting": false, "PageSize": 50, "PageIndex": 0, "SortingOrder": "Ascending",
  "IncludeTotalCount": false, "Take": 50, "Skip": 0, "IsDisputeCategorySelection": false,
  "TwoFactorAuthentication": { "Password": "" }, "Currency": "EUR", "Description": "" }
```

* Antwort: `Item.Transactions[]`, `Item.HasMore`, `Item.OTPRequired`. Blättern: `PageIndex`+1,
  `Skip` = `PageIndex*50`, solange `HasMore`. Sortierung: neueste zuerst (trotz `Ascending`).
* **TAN für lange Zeiträume:** Die Web-App verlangte bei „180 Tage“ eine SMS-TAN
  (`OTPRequired: true` → `SendOTP` → erneut mit `TwoFactorAuthentication.Password = <mTAN>`).
  Zeitraum wie bei allen Banken: erster Abruf `sync.days_back` (Standard 90 Tage), danach ab der
  neuesten Buchung − 10 Tage; Obergrenze 730 Tage (Portal). Bei `OTPRequired` fällt der Connector
  auf 89 Tage zurück.

### Felder je Buchung → `RemoteTransaction`

| easybank | GiroCrab | Regel |
|---|---|---|
| `LocalCurrencyAmount.Value` | `amount_cents` | **immer positiv**; Vorzeichen aus `TransactionNature` (`Debit` → negativ, `Credit` → positiv). `Amount` ist Originalwährung und kann `0` mit leerer Währung sein → nie `Amount` verwenden. |
| `PostingDate` | `booking_date` | `BookingDate` ist immer `0001-01-01` |
| `TransactionDate` / `ValueDate` | `value_date` | enthält Uhrzeit |
| `Description` | `counterparty` | bereinigter Händlername; Roh-Text in `MerchantName` |
| `MerchantName` | `purpose` | |
| `TransactionCodeDescription` / `TransactionCode` | `booking_text` | Codes z. B. `6107` Kauf, `6124` Gutschrift, `6550` Lastschrift-Gutschrift |
| `Amount.Value` + `Amount.Currency.Code` | (Fremdwährung) | bei Nicht-EUR Originalbetrag, z. B. in `purpose` anhängen |
| – | `external_id` | leer → Inhalts-ID aus `store_fetch`. `InternalID` wird **bei jedem Login neu vergeben** (Live-Test: zweiter Abruf verdoppelte alle Buchungen); `ReferenceNumber`/`TransactionReferenceNumber` sind nicht eindeutig. |
| `TransactionType` | | `Billed` (abgerechnet, `StatementDate` gesetzt) / `Unbilled` |
| `IsPending` | | vorgemerkte Umsätze – werden übersprungen |
| `MCCCode`, `CountryCode`, `MerchantData.Name` | | optional für Händlerzuordnung |

## Offene Punkte

- [x] `InternalID` ist nicht stabil (neu pro Login) → Inhalts-ID.
- [ ] Bleiben Datum/Händler/Zweck beim Wechsel `Unbilled` → `Billed` gleich? (Sonst Dublette nach
      der Abrechnung.)
- [ ] Ab welchem Zeitraum ist die SMS-TAN nötig, und wie lange gilt sie?
- [x] PDF-Abrechnungen: `services/flow/GetStatementsTransaction` (Liste als InitialCall
      `GetAccountStatementList`, weitere Seiten per `call/flow/GetStatementsTransaction/GetAccountStatementList`
      mit `{Account, PageIndex}`), Download nach `services/export/CheckAuthorization` als Formular-POST
      an `call/flow/GetStatementsTransaction/DownloadStatement` (`options.exportRequest = {Account,
      StatementDocument}`) – live getestet.
- [ ] XLSX-Export (`/services/export/ExportAsExcel`) wird nicht gebraucht, die JSON-API reicht.
- [ ] Mehrere Karten / Zusatzkarten testen.

## Wartung

* Tests: `cargo test -q -p girocrab-core --lib easybank` (nur erfundene Daten).
* Ändert easybank das Portal, zuerst Login-HTML (`UniqueKey`) und `Request-Id`-Prüfung kontrollieren.
