# Volkswagen-Bank-Anbindung

<!-- sync:connector-note:start -->
> **Hinweis / Note:** Dieser Connector ist ein unabhängiges Community-Projekt und steht in keiner Verbindung zur Volkswagen Bank. Schnittstelle: inoffiziell. Bei inoffiziellen Schnittstellen kann die Nutzung gegen die Nutzungsbedingungen der Bank verstoßen.
> This connector is an independent community project and is not affiliated with Volkswagen Bank. Interface: unofficial. Using unofficial interfaces may violate the bank's terms of service.
<!-- sync:connector-note:end -->

Status: **pushTAN umgesetzt, noch nicht live getestet** – `ConnectorKind::VolkswagenBank` (Schlüssel
`volkswagenbank`), Modul `girocrab-core/src/connectors/volkswagen_bank.rs`. Grundlage ist ein
Browser-Mitschnitt (HAR) von zwei pushTAN-Anmeldungen. photoTAN fehlt noch.

Portal: `https://banking.volkswagenbank.de/#/login` (React-Single-Page-App) über die JSON-API
`https://services.banking.volkswagenbank.de`. Kein PSD2- und kein FinTS-Zugang belegt.

## Ablauf (nach Mitschnitt)

| Schritt | Aufruf | Ergebnis |
|---|---|---|
| 1 | `POST AuthenticationService/authentication/check` `{UserName, Password}` | `Status: SecondFactorAuthenticationRequired`, Header `X-CHALLENGES` (`PhotoTan`, `PushTan`), `X-REQUEST-KEY` |
| 2 | `POST TransactionAuthorizationService/pushtan/transaction/authorize` `{RequestKey, WaitForUserInteraction:false}` | `AuthorizationPending` |
| 3 | `POST …/pushtan/transaction/checkstate` `{RequestKey}` (alle paar Sekunden) | `AuthorizationPending`, dann `TransactionConfirmed` |
| 4 | `POST AuthenticationService/authentication/execute` (Header `X-REQUEST-KEY`, leerer Body) | `Status: Success` |
| 5 | `GET AccountListService/accountlist` | Konten mit IBAN, Kontonummer, Saldo, `Features.CashFlow` |
| 6 | `POST CashFlowService/cashflow/list/get` `{accountNumber, dateFrom, dateTo}` (`YYYY-MM-DDZ`) | `CashflowList` mit `CreditAmount`/`DebitAmount`, `PaymentNotes`, `ReferenceAccount` |

- Jede Antwort enthält einen neuen Header `Authorization: bearer …`; der jeweils neueste wird beim
  nächsten Aufruf zurückgeschickt. **Annahme:** Der Mitschnitt zeigt keine Anfrage-Header mit
  Zugangsdaten, daher ist das Zurücksenden als `Authorization` noch nicht bestätigt.
- Datumswerte sind UTC und bezeichnen einen Berliner Kalendertag (`2026-10-22T22:00:00Z` = 23.10.);
  der Connector rechnet nach Europe/Berlin um (Sommerzeit inklusive).
- Beträge sind Dezimalstrings, die ungenutzte Seite (Soll/Haben) ist leer. Soll wird negativ.
- Der Connector wählt pushTAN, sobald `X-CHALLENGES.PushTan` vorhanden ist. Ohne pushTAN meldet er,
  dass photoTAN noch nicht unterstützt wird. Beim zweiten Mitschnitt verlangte die Bank den zweiten
  Faktor erneut (kein „bekanntes Gerät“), deshalb wird kein Zustand gespeichert.
- Kontoarten: `CallMoneyAccount` (Tagesgeld) und `SavingAccount` (Sparbrief) → Sparkonto. Weitere
  Kategorien sind erraten (Giro, Kreditkarte, Darlehen) und fallen sonst auf Sparkonto zurück.
- `external_id` bleibt leer (Inhalts-ID aus `store_fetch`), weil `DocumentNumber` nicht je Buchung
  eindeutig sein muss.

## Offen

- [ ] Live-Test mit echtem Konto (Anmeldung, Zurücksenden des Bearer-Tokens, Umsätze)
- [ ] photoTAN: Mitschnitt einer photoTAN-Anmeldung (Code-Eingabe) und Erzeugung der Grafik aus
      `X-CHALLENGES.PhotoTan.ImageCreationChallenge` (die Portal-JavaScript baut sie)
- [ ] Statuswerte bei falschen Zugangsdaten, abgelehnter oder abgelaufener pushTAN (bisher nur
      `AuthorizationPending` und `TransactionConfirmed` belegt; alles andere gilt als Ablehnung)
- [ ] Abmelden (im Mitschnitt nicht enthalten, der Connector meldet sich nicht ab)
- [ ] Weitere Kontoarten (Girokonto, Kreditkarte, Darlehen), Konten ohne `CashFlow`
- [ ] Kontoauszüge: `MailboxService/archivedocumentinfos` liefert die Liste, der Download-Aufruf fehlt
- [ ] Danach: `Status` in `BANK_MATRIX` auf `TestingWanted`/`Verified` setzen und die README-Matrix
      per `scripts/sync-docs-and-website.sh` aktualisieren

## Mitschnitt (HAR) für photoTAN und Fehlerfälle

Im Browser (Entwicklertools → Netzwerk, „Log beibehalten“) aufzeichnen und vor dem Teilen
schwärzen: Passwort, Benutzername, Cookies/Tokens (`Authorization`, `Set-Cookie`), IBANs, Namen,
Beträge. Endpunkte, Feldnamen, Methoden, Statuscodes und Header-*Namen* müssen bleiben. Beim
Schwärzen darauf achten, dass das JSON gültig bleibt (ein Wert wie `\"Balance\":\"1.00\"` darf keine
Anführungszeichen verlieren).

1. Anmeldung mit photoTAN, inklusive Code-Eingabe und der Anfrage, die das Bild liefert.
2. Falsche TAN, falsches Passwort und abgelaufene pushTAN (je ein Mitschnitt).
3. Abmelden.
4. Ein Kontoauszug als PDF herunterladen.
