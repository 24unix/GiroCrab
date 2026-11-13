# Alte-Leipziger-Anbindung (fin4u-Kundenportal)

<!-- sync:connector-note:start -->
> **Hinweis / Note:** Dieser Connector ist ein unabhängiges Community-Projekt und steht in keiner Verbindung zur Alte Leipziger. Schnittstelle: inoffiziell. Bei inoffiziellen Schnittstellen kann die Nutzung gegen die Nutzungsbedingungen der Bank verstoßen.
> This connector is an independent community project and is not affiliated with Alte Leipziger. Interface: unofficial. Using unofficial interfaces may violate the bank's terms of service.
<!-- sync:connector-note:end -->

Status: **verifiziert mit echtem Konto** – `ConnectorKind::AlteLeipziger`
(Schlüssel `fin4u`), direkter HTTP-Zugriff in `girocrab-core/src/connectors/fin4u.rs`,
kein Browserfenster, keine TAN. Issue: [#586](https://github.com/GiroCrab/GiroCrab/issues/586).

Die Alte Leipziger Bausparkasse (BLZ 50012800) bietet keine API für Kundinnen und Kunden.
Bausparverträge und Darlehen sind im Kundenportal fin4u (`https://app.fin4u.de`) zu sehen,
dessen Web-App eine JSON-Schnittstelle nutzt. Der Connector spricht diese Schnittstelle mit
den eigenen Zugangsdaten an. Unten stehen nur Pfade, Feldnamen und Regeln, keine echten Werte.

## Zugang

* **Login:** fin4u-Benutzername (E-Mail-Adresse), **Passwort:** fin4u-Passwort.
* Im Assistenten „Bank hinzufügen“ per Name, „Bausparvertrag“, „fin4u“, BLZ oder IBAN zu finden.

## Ablauf

| Schritt | Anfrage | Auswertung |
|---|---|---|
| 1 | `POST /auth/realms/fin4u/protocol/openid-connect/token` | Passwort-Grant mit der Client-ID der Web-App. Das Passwort ist wie in der Web-App verschlüsselt (siehe unten). Antwort: Zugriffstoken. |
| 2 | `GET /api/20210906/bankaccounts/bank-account` | Konten und Salden. |
| 3 | `GET /api/20210906/bankaccounts/bank-account/{id}` | Kontodetails (`additionalAttributes`): IBAN, Vertragsnummer und Inhaber, wenn die Kontoliste sie nicht liefert, sowie die Liste der Dokumente. |
| 4 | `GET /api/20210906/bankaccounts/bank-account/{id}/transaction` | Buchungen, seitenweise mit `?offset=`, bis `total` erreicht ist. |
| 5 | `GET /api/20210906/insurances/insurance/document/{referenceId}` | PDF als Base64-Text. |
| 6 | `POST /auth/realms/fin4u/protocol/openid-connect/logout` | best effort |

## Regeln

* **Passwort:** Die Web-App verschlüsselt das Passwort vor dem Login mit ihrem öffentlichen
  RSA-Schlüssel (RSA-OAEP, SHA-256, MGF1 mit SHA-1). Der Connector macht es genauso; der
  öffentliche Schlüssel steht in `fin4u.rs`. Anfragen gehen nur an `https://app.fin4u.de`.
* **Nur Verträge der Alte Leipziger:** Konten, die in fin4u über Dritte verknüpft sind
  (andere Banken), werden übersprungen; sie kämen sonst doppelt neben GiroCrabs eigenen
  Verbindungen vor.
* **Kontoarten:** Bausparvertrag, Tagesgeld, Spar- und Festgeld → Sparkonto; Kreditkonto →
  Darlehen; Kartenkonten → Kreditkarte; alles andere → Girokonto.
* **Buchungs-IDs:** fin4us eigene Buchungs-ID wechselt, sobald fin4u das Konto neu lädt.
  Buchungen bekommen deshalb Inhalts-IDs aus den Rohfeldern (Datum, Betrag, Verwendungszweck,
  Gegenpartei); zwei gleiche Buchungen am selben Tag bleiben zwei.
* **Zeitraum:** Der erste Abruf holt die ganze Historie, weil Bausparverträge selten buchen.
* **Dokumente:** Bereits geladene Dokumente merkt sich die Verbindung und lädt sie nicht erneut.
* **Fehler:** Antwortet die Schnittstelle unerwartet (keine JSON-Antwort, HTTP 404), meldet
  der Connector eine mögliche Änderung des Portals, statt still „keine Buchungen“ zu zeigen.

## Offene Punkte

* Konten mit Zwei-Faktor-Anmeldung in fin4u sind nicht berücksichtigt.
