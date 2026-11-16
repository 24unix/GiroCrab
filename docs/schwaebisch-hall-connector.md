# Schwäbisch-Hall-Anbindung („Mein Konto“)

<!-- sync:connector-note:start -->
> **Hinweis / Note:** Dieser Connector ist ein unabhängiges Community-Projekt und steht in keiner Verbindung zur Schwäbisch Hall. Schnittstelle: inoffiziell. Bei inoffiziellen Schnittstellen kann die Nutzung gegen die Nutzungsbedingungen der Bank verstoßen.
> This connector is an independent community project and is not affiliated with Schwäbisch Hall. Interface: unofficial. Using unofficial interfaces may violate the bank's terms of service.
<!-- sync:connector-note:end -->

Status: **Rückmeldungen mit echten Verträgen erwünscht** – `ConnectorKind::SchwaebischHall`
(Schlüssel `schwaebischhall`), Anmeldung im Browserfenster, Auswertung in
`girocrab-core/src/connectors/schwaebisch_hall.rs`, Abruf-Skripte in
`GiroCrabApp/Sources/GiroCrabUI/SchwaebischHallUI.swift` (Linux:
`GiroCrabLinux/qml/SchwaebischHallWebLoginFlow.qml`, Skripte per
`scripts/gen-schwaebisch-hall-qml.py` aus der Swift-Datei übernommen).
Issue: [#290](https://github.com/GiroCrab/GiroCrab/issues/290).

Die Bausparkasse Schwäbisch Hall (BLZ 62220000) bietet keine API für Kundinnen und Kunden.
Bausparverträge, Umsätze und das Postfach sind im Kundenportal „Mein Konto“ auf
`https://www.schwaebisch-hall.de` zu sehen. Der Connector liest dieselben JSON-Antworten,
die das Portal selbst lädt. Unten stehen nur Pfade, Feldnamen und Regeln, keine echten Werte.

## Zugang

* Im Assistenten „Bank hinzufügen“ per „Schwäbisch Hall“, „Bausparvertrag“, „BSH“ oder BLZ zu finden.
* Der Name der Verbindung ist frei wählbar. Zugangsdaten speichert GiroCrab nicht: Die Anmeldung
  (Benutzername, Passwort und gegebenenfalls ein zweiter Faktor) läuft im eingebetteten Browser
  auf den Seiten der Bausparkasse.
* Die Sitzungs-Cookies bleiben wie bei den anderen Portal-Anbindungen im Browser-Datenspeicher
  der App; das Portal beendet die Sitzung nach einiger Zeit selbst. „Web-Sitzung (Cookies)
  löschen …“ in den Einstellungen der Verbindung entfernt sie sofort.

## Ablauf

| Schritt | Anfrage | Auswertung |
|---|---|---|
| 1 | `GET /bin/bshweb/authentication` | Startet die Anmeldung: Weiterleitung zu `login.schwaebisch-hall.de` (Azure AD B2C, Policy `B2C_1A_SEAMLESSMIGRATION_SIGNUPORSIGNIN`, Code-Flow mit PKCE). Nach der Anmeldung setzt das Portal die Sitzungs-Cookies. |
| 2 | `GET /bin/bshweb/accountcontracts` | Verträge: `type`, `bsn`, `accountBalance`, `vtn`. Ohne Sitzung kommt `{"status":"error", …"code":"timeout"}`; daran erkennt das Fenster, ob man angemeldet ist. |
| 3 | `GET …/myaccount_accounts.account_details.json?vtn={vtn}` | Je Vertrag: `contracttype`, `contractphase`, `transactions` (nach Jahr und Monat gruppiert, je Buchung `day`, `subject`, `amount`). |
| 4 | `GET …/nachrichten.bin.postboxmessage?command=getmessages` | Postfach (nur wenn „PDF-Dokumente aus dem Postfach“ an ist): `data.messages` mit `id`, `date`, `title`, `type`, `typeName`, `text`. Nachrichten mit `type: "data"` (z. B. `typeName: "jahreskontoauszug"`) haben einen Anhang, dessen ID die Nachrichten-ID ist; `type: "message"` sind reine Textnachrichten. Eine ausdrückliche Anhang-ID (Download-Formular oder Link im `text`) geht vor. |
| 5 | `GET /bin/bshweb/postbox/attachment?id={id}` | PDF-Anhang. |

Die Abrufe laufen als Skript in der angemeldeten Seite (gleiche Herkunft, `credentials:
same-origin`, keine Weiterleitungen), und zwar in einer eigenen JavaScript-Welt der App
(`WKContentWorld.defaultClient`): Skripte Dritter auf der Portalseite (z. B. ein Tag-Manager)
können ihr `fetch` nicht umleiten und die Daten nicht mitlesen. An die App gehen nur die oben
genannten Vertragsfelder und die PDFs, keine Cookies, Namen, Adressen oder Lastschriftkonten.
Die Skripte lesen nur (GET); ob das Portal eine Nachricht beim Laden des Anhangs als gelesen
markiert, ist nicht bekannt.
Fehler melden die Skripte nur als feste Codes (`bsh:session`, `bsh:timeout`, `bsh:http:<Status>`,
`bsh:too-large`, `bsh:not-pdf`, `bsh:invalid`); App und Linux-Frontend zeigen dafür feste,
übersetzte Meldungen, nie Text aus dem Browser oder von der Portalseite. PDFs werden in
Stücken gelesen und beim Überschreiten von 25 MB sofort abgebrochen.

## Regeln

* **Konten:** ein Konto je Vertrag, Kennung `bsh:{vtn}`, Name aus Vertragsart ohne Phase und
  Vertragsnummer (`bsn`), z. B. „Bausparvertrag 217111 D 01“. Sparphase → Sparkonto; Verträge
  mit „Darlehen“ in Art oder Phase → Darlehen mit negativem Saldo. Wechselt ein Vertrag in die
  Darlehensphase, wird das bestehende Konto zum Darlehen; der Name bleibt.
* **Vollständige Liste:** Die Vertragsliste gilt als vollständig. Ein Vertrag, der nicht mehr
  geliefert wird (z. B. ausgezahlt), wird als „nicht mehr geliefert“ markiert, statt seinen
  letzten Saldo zu behalten.
* **Beträge:** formatierte Zeichenketten wie `&#43; 1.234,56`; HTML-Entities werden dekodiert,
  Rechnen nur in Cent. Erlaubt sind nur Vorzeichen vorn, Ziffern, Trennzeichen und `€`/`EUR`;
  ein Soll/Haben-Kennzeichen (`S`/`H`) oder ein nachgestelltes Minus verwirft den Abruf, statt
  das Vorzeichen zu verlieren.
* **Buchungsstruktur** (laut anonymisiertem Beispiel aus #290): die Detailantwort steckt in
  `{status, data}`; `contracttype`/`contractphase` sind Zahlen (Bausparvertrag `1`/`1`,
  Tilgungsaussetzungsdarlehen `3`/`1`); `transactions` ist eine Liste von Jahren
  `{year, saldo, month: [{name: "Nov", fullname: "November", entries: [{amount, subject, day}]}]}`.
* **Datum:** Jahr und Monat kommen aus der Gruppierung (Schlüssel wie `2025`/`Dezember`/`03`
  oder Felder `year`/`month`, beim Monat auch `fullname`/`name`), der Tag aus `day`. Steht im Tag ein volles Datum, gilt dieses.
  Monatsnamen gelten nur exakt (keine Wortanfänge), Zahlen als Schlüssel nur zweistellig.
* **Summen:** `saldo`, `summe`, `total` werden übersprungen. Ein Eintrag mit Betrag und Datum,
  aber ohne `subject`, verwirft den Abruf.
* **Buchungs-IDs:** Das Portal liefert keine. Buchungen bekommen Inhalts-IDs (Datum, Betrag,
  Buchungstext); zwei gleiche Buchungen am selben Tag bleiben zwei.
* **Unvollständige Antworten:** Eine Buchung ohne erkennbares Datum oder mit unlesbarem Betrag
  verwirft den ganzen Abruf, statt Teildaten zu speichern.
* **Dokumente:** Ein PDF wird dem Vertrag zugeordnet, dessen Nummer in der Nachricht steht
  (genau einer), sonst dem ersten Vertrag der Verbindung. Ist der genannte Vertrag nicht
  übernommen (Kontoauswahl offen, abgewählt, archiviert), wird das PDF nicht geladen und nie
  einem anderen Vertrag zugeordnet. Die Kontoauswahl wird deshalb vor dem Postfach abgefragt.
  Bereits geladene Anhänge werden nicht erneut geladen. Nur PDFs bis 25 MB werden gespeichert.
* Hintergrund-Abrufe sind nicht möglich: Die Anmeldung braucht das Browserfenster.

## Geklärt und offen

Geklärt mit anonymisierten Beispielen des Issue-Autors (#290): die Buchungsstruktur (siehe
„Buchungsstruktur“), Anhänge bei `type: "data"` mit der Nachrichten-ID als Anhang-ID, und
Darlehen melden ihren Saldo negativ (`"- 1111,11"`, Vertragsart z. B.
„Tilgungsaussetzungsdarlehen“).

Ebenfalls bestätigt: Der Download eines `data`-Anhangs liefert `Content-Type: application/pdf`;
andere Dateitypen sind bisher nicht aufgetreten.

Noch offen: ein vollständiger Abruf mit echtem Vertrag in GiroCrab, und ob schon das Laden eines
Anhangs die Nachricht im Portal als gelesen markiert (ließ sich mangels ungelesener Nachrichten
noch nicht prüfen).

## Tests

```bash
cargo test -q -p girocrab-core --lib schwaebisch
node --test scripts/test-schwaebisch-hall-portal.cjs
```
