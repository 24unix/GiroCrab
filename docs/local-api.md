# Externe Analyse: lokale, lesende Schnittstelle (#136)

GiroCrab kann ausgewählte Konten, Buchungen, Kategorien und Summen für Programme auf demselben Mac
lesbar machen, etwa für eigene Auswertungen oder einen KI-Assistenten. Die Schnittstelle ist
standardmäßig aus und strikt lesend: keine Änderungen, keine Zahlungen, keine Zugangsdaten.

## Einschalten

Einstellungen › Analyse:

1. „Lesenden Zugriff für Programme auf diesem Mac erlauben“ einschalten.
2. Unter „Geteilte Konten“ die Konten auswählen. Neue Konten sind erst geteilt, wenn sie hier
   ausgewählt werden.
3. Unter „Geteilte Felder“ festlegen, ob Empfänger/Auftraggeber, Verwendungszweck/Buchungstext,
   IBANs/Kontonummern und Notizen mitgehen. IBANs/Kontonummern und Notizen sind standardmäßig aus;
   dann werden IBANs und Ziffernfolgen ab sechs Stellen auch in Texten und Kontonamen unkenntlich
   gemacht.
4. „Zugangsschlüssel erzeugen“ und den Schlüssel im Programm eintragen. Er wird nur einmal angezeigt;
   gespeichert wird nur sein Hash. „Zugriff widerrufen“ oder ein neuer Schlüssel sperren den alten sofort.

Programme wie KI-Assistenten können geteilte Daten an einen Cloud-Dienst übertragen. Teilen Sie nur,
was dort verarbeitet werden darf.

## Wann der Zugriff besteht

Nur solange GiroCrab läuft, der eigene Tresor entsperrt ist und angezeigt wird (nie mit den
Demo-Daten), die Schnittstelle eingeschaltet ist und ein Zugangsschlüssel existiert. Beim Sperren, beim
Wechsel zur Demo und beim Beenden wird der Socket geschlossen.

## Verbindung

- Unix-Domain-Socket, kein Netzwerkport:
  `~/Library/Application Support/GiroCrab/local-api/girocrab.sock`
  (Ordner `0700`, Socket `0600`; Verbindungen anderer Benutzer werden sofort geschlossen).
- Eine JSON-Anfrage pro Zeile, eine JSON-Antwort pro Zeile; mehrere Anfragen pro Verbindung.
- Höchstens 4 Verbindungen, 64 KiB pro Anfrage, Verbindungen ohne Daten enden nach 5 Minuten.

```
→ {"v":1,"token":"gcapi_…","method":"transactions","params":{"date_from":"2026-01-01","limit":50}}
← {"v":1,"result":{"transactions":[…],"next_cursor":"2026-03-14:4711"}}
```

Fehler: `{"v":1,"error":{"code":"…","message":"…"}}` mit `disabled`, `unauthorized`, `locked`,
`unsupported_version`, `unknown_method`, `invalid_params`, `not_shared`, `busy` (zu viele
Verbindungen, später erneut versuchen), `internal`. Ohne gültigen Schlüssel antwortet der Socket immer mit
`unauthorized`, auch wenn die Freigabe ausgeschaltet ist.

## Methoden (Version 1)

| Methode | Parameter | Ergebnis |
|---|---|---|
| `info` | – | Version, Anzahl geteilter Konten, geteilte Felder, letzter Abruf |
| `accounts` | – | geteilte Konten mit Saldo, Art, Währung, letztem Abruf |
| `categories` | – | Kategorienbaum (`id`, `parent_id`, `name`, `path`, `depth`) |
| `transactions` | `account_ids`, `date_from`, `date_to`, `category_id`, `include_subcategories`, `uncategorized_only`, `direction` (`income`/`expense`/`all`), `search`, `cursor`, `limit` (1–500, Standard 100) | Buchungen, neueste zuerst, mit `next_cursor` |
| `summary` | `date_from`, `date_to` (höchstens drei Jahre), `account_ids` | Einnahmen/Ausgaben je Währung, Netto-Summen je Kategorie |

Daten im Format `YYYY-MM-DD`, Beträge in Cent (`amount_cents`, negativ = Ausgang). Buchungs-IDs bleiben
für die Lebensdauer einer Buchung gleich. Die Suche steht nur zur Verfügung, wenn Empfänger,
Verwendungszweck und Kontonummern geteilt sind, weil sie auch diese Felder durchsucht.
