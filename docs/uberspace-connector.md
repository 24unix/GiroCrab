# Uberspace-Anbindung

<!-- sync:connector-note:start -->
> **Hinweis / Note:** Dieser Connector ist ein unabhängiges Community-Projekt und steht in keiner Verbindung zur Uberspace. Schnittstelle: inoffiziell. Bei inoffiziellen Schnittstellen kann die Nutzung gegen die Nutzungsbedingungen der Bank verstoßen.
> This connector is an independent community project and is not affiliated with Uberspace. Interface: unofficial. Using unofficial interfaces may violate the bank's terms of service.
<!-- sync:connector-note:end -->

Status: **verifiziert mit echtem Konto** – `ConnectorKind::Uberspace`
(Schlüssel `uberspace`), direkter HTTP-Login in `girocrab-core/src/connectors/uberspace.rs`,
kein Browserfenster, keine TAN.

Uberspace bietet für das Guthaben keine API. Der Connector liest die HTML-Seiten des
Dashboards `https://dashboard.uberspace.de`. Seitenaufbau und Element-IDs stammen aus einer
quelloffenen Community-Erweiterung (MPL-2.0, Quelle im Kopf von `uberspace.rs`); Code wurde
nicht übernommen.

## Zugang

* **Login:** E-Mail-Adresse des Dashboards, **Passwort:** Dashboard-Passwort.
* Unter einer E-Mail-Adresse können mehrere Asteroids (Hosts) liegen: jeder wird ein
  eigenes Konto (`uberspace:<asteroid>`, Kontoart „Zahlungsdienst“, EUR).

## Ablauf

| Schritt | Anfrage | Auswertung |
|---|---|---|
| 1 | `GET /login` | Formular mit Passwortfeld; versteckte Felder (z. B. CSRF-Token) und der Absende-Button werden mitgeschickt. |
| 2 | `POST <action>` | Felder `login` + `password`. Erscheint danach wieder das Login-Formular, sind die Zugangsdaten falsch. |
| 3 | `GET /meta` | Tabelle `#dotqmailtable`, erste Zelle je Zeile = Name des Asteroids. |
| 4 | `GET /dashboard/accounting?show_all_transactions=1&asteroid=<name>` | Tabelle `#transactions`: Zeilen mit drei Zellen (Datum `TT.MM.JJJJ`, Text, Betrag `-5,00 €`). Element `#total` = Guthaben. |
| 5 | `GET /logout` | best effort |

## Regeln

* Das Passwort geht nur per `POST` an `https://dashboard.uberspace.de`; ein Formular mit
  anderer Adresse, `http` oder `GET` wird abgelehnt, ebenso Weiterleitungen auf fremde Hosts.
* Zeilen ohne Datum (Summen, Überträge) werden übersprungen. Eine datierte Zeile mit
  unlesbarem Betrag oder ein fehlendes `#total` verwirft den ganzen Abruf.
* Das Dashboard liefert keine Buchungs-IDs: Buchungen bekommen Inhalts-IDs
  (`RemoteTransaction::content_id`); zwei gleiche Monatsbeiträge am selben Tag bleiben zwei Buchungen.
* Belastungen (negativ) bekommen „Uberspace“ als Gegenpartei, Einzahlungen keine.

## Offene Punkte

* Konten mit Zwei-Faktor-Anmeldung sind nicht berücksichtigt.
