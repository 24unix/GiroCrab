# Datenmodell der Wertpapierdepots

Stand: Schema 29. Regeln für Schemaänderungen: `docs/ARCHITECTURE.md`.

## Überblick

```
accounts (kind = 'brokerage')
  ├── holdings                 aktueller Bestand, bei jedem Abruf ersetzt
  │     └── holding_classifications   Klasse/Instrument je Position (Schritt 16)
  ├── security_transactions    Käufe, Verkäufe, Ausschüttungen, Gebühren, Steuern
  ├── depot_observations       gemeldete Werte von Depot und Positionen (Rohdaten)
  └── depot_values             Wert des Depots je Tag und Quelle (abgeleitet)

security_classifications       Nutzerwahl je Wertpapier (security_key), unabhängig vom Konto
```

Sachwerte (`kind` mit `assets::is_tangible`) haben ein eigenes Modell: `asset_items`, `asset_quantities`,
`asset_values`, `asset_prices`, `asset_price_fetch` (Schritt 13, `girocrab-core/src/assets.rs`).

## Tabellen

### `holdings` (Basis, Schritt 14 ergänzt Spalten)
Positionen eines Depots **zum Zeitpunkt des letzten Abrufs**.
- Schlüssel: `id`; `account_id` verweist auf `accounts` (`ON DELETE CASCADE`).
- Kennung: `isin`, `wkn` (leer = unbekannt), `name`.
- Zahlen: `quantity` (REAL), `current_price_cents`, `purchase_price_cents`, `value_cents` (alle in Cent der
  Kontowährung). Ab Schritt 14 zusätzlich `prev_day_price_cents`, `prev_day_value_cents`,
  `profit_loss_purchase_cents`/`_rel`, `profit_loss_prev_day_cents`/`_rel` (jeweils NULL = nicht geliefert) und
  `custody_type`.
- **Wird bei jedem Abruf vollständig ersetzt** (`connectors/persist.rs`, ebenso beim Import). Es gibt
  keine Historie, und die Zeilen-ID ist nicht stabil. Beziehungen auf eine Position laufen deshalb über ISIN oder
  `security_key`, nicht über `holdings.id`.
- Gehört nicht zum Tresor-Abgleich (`vault/merge.rs` übernimmt sie nicht); jedes Gerät holt sie selbst.

### `security_transactions` (Schritt 14)
Umsätze eines Depots, getrennt von den Geldbuchungen (`transactions`).
- Eindeutig je Depot: `UNIQUE(account_id, external_id)`.
- `booking_date`, `settlement_date`, `isin`, `wkn`, `name`.
- `direction`: `buy | sell | dividend | fee | tax | other`.
- `quantity`, `price_cents`, `currency`, `value_cents`, `fees_cents`, `taxes_cents`, `accrued_interest_cents`,
  `fx_rate` (NULL = keine Fremdwährung), `booking_text`.
- `cash_transaction_id` verweist (`ON DELETE SET NULL`) auf die zugehörige Geldbuchung (`link_cash_bookings`).
- Abgleich: `changed_ms` (neuester Stand gewinnt), `deleted_ms` als weiches Löschen. Indizes auf
  `(account_id, booking_date, deleted_ms)` und `(isin, deleted_ms)`.
- Aus ihr lässt sich die **Menge zu einem Tag** zurückrechnen (Käufe/Verkäufe), soweit der Umsatzverlauf reicht.

### Klassifizierung (Schritt 16)
`security_classifications(security_key, asset_class_override, instrument_override, …_ms)` hält die Nutzerwahl
je Wertpapier, `holding_classifications(holding_id, asset_class, instrument, direct_crypto)` das berechnete Ergebnis
je Position. Details: `docs/asset-classification.md`.
`security_key` ist der **gemeinsame Schlüssel eines Wertpapiers** und wird für alles verwendet, was sich auf ein
Wertpapier statt auf eine Position bezieht.

### Depotwert aus dem Konto
`accounts.balance_cents` und `balance_date` tragen den vom Anbieter gemeldeten Depotwert und sein Stichtag. Das ist der
aktuelle Gesamtwert des Kontos. Die historischen Werte stehen getrennt davon in `depot_observations` / `depot_values`.

## Wer schreibt und wer liest

| Daten | Schreibt | Liest |
|---|---|---|
| `holdings` | `connectors/persist.rs` (`store_fetch`), Datenbank-Importer (`importers/`) | Depotansicht, Vermögen, Klassifizierung |
| `security_transactions` | `connectors/persist.rs` (`security_transactions::upsert` beim Abruf); ein Import schreibt keine Umsätze | Aktivitäten im Depot, Kennzahlen |
| `security_classifications` | `set_asset_class_override`, `set_instrument_override` (Kontextmenü) | Zusammensetzung (`classified_assets`) |

## Wertverlauf eines Depots (`depot_observations` → `depot_values`, Schritt 28)

**Umfang:** Gespeichert werden die **Werte** von Depots und ihren Positionen, so wie eine Quelle sie gemeldet hat:
keine Kurse je Stück (außer Menge und Kurs eines Abrufs), keine berechneten Werte. Ein Depot hat keine Buchungen, über
die man den Wert zurückrechnen könnte, und die angebundenen Banken melden nur den aktuellen Wert. Der Verlauf entsteht
deshalb aus Punkten: je Abruf der gemeldete Depotwert mit seinem Stichtag, dazu die Historie eines Datenbank-Imports.
Eine Kursquelle gibt es nicht und ist nicht geplant (ein Verlauf aus Kursen bräuchte Kursserien je Handelsplatz und
Währung, die Menge je Tag und eine Weitergabe von Kennungen an Dritte).

Zwei Schichten (`girocrab-core/src/depot_values.rs`, `depot_values/`):

```
accounts (kind = 'brokerage')
  └── depot_observations   was ein Abruf oder Import geliefert hat (Rohdaten, abgeglichen)
        └── depot_values   je Depot, Tag und Quelle ein Wert (abgeleitet, je Gerät)
```

### `depot_observations` (Rohdaten)

```
depot_observations(
  account_id   INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  kind         TEXT    NOT NULL,             -- total | position
  position     TEXT    NOT NULL DEFAULT '',  -- '' (total) | ISIN | 'cash' | 'name:<normalisiert>'
  currency     TEXT    NOT NULL,
  source       TEXT    NOT NULL,             -- fetch | import
  value_date   TEXT    NOT NULL,             -- YYYY-MM-DD, Bewertungstag der Bank
  observed_ms  INTEGER NOT NULL,             -- Abrufzeit; Import: Zeitstempel der Quelle
  source_ref   TEXT    NOT NULL DEFAULT '',  -- Import: Zeile der Position in der Quelle
  date_assumed INTEGER NOT NULL DEFAULT 0,   -- 1 = kein Bewertungstag, der Abruftag
  value_cents  INTEGER NOT NULL,
  confirmed    INTEGER NOT NULL DEFAULT 0,   -- 1 = Bestand geliefert: eine 0 ist echt
  quantity     REAL,                         -- nur Abruf
  price_cents  INTEGER,                      -- nur Abruf
  name         TEXT    NOT NULL DEFAULT '',  -- Name der Position zu diesem Zeitpunkt
  PRIMARY KEY (account_id, kind, position, currency, source, value_date, observed_ms, source_ref)
) WITHOUT ROWID;
```

- Eine Zeile ist ein Wert, den eine Quelle gemeldet hat: der Depotwert (`total`) oder eine Position. Zeilen werden
  **nie geändert**. Der Tresor-Abgleich vereinigt sie (`INSERT OR IGNORE` je Konto), danach wird `depot_values` der
  betroffenen Depots neu abgeleitet.
- Die Tabelle liegt in der Reihenfolge, in der sie gelesen wird (eine Reihe nach Quelle, Tag und Zeit): eine Reihe
  und alle Positionen eines Depots sind je ein Bereich.
- Positionen werden über ihren Schlüssel gefunden (ISIN, `cash` für die Liquidität im Depot, sonst
  `name:<normalisierter Name>`), nicht über `holdings.id`: verkaufte Positionen behalten ihren Verlauf.
- **Abruf** (`observations::record_fetch`, aus `connectors/persist.rs` nach allen Saldo-Änderungen): der Kontostand als
  Depotwert (0 neben Positionen = deren Summe) und jede Position, in der Kontowährung. Geschrieben wird nur bei einer
  Änderung gegenüber der letzten Abruf-Zeile oder an einem neuen Bewertungstag. Kam der Bestand (auch ein leerer), ist
  eine 0 bestätigt, und eine Position des bisherigen Bestands, die fehlt, bekommt eine 0 (Verkauf), sofern ihr letzter
  Wert von einem Abruf stammt: eine Position, die nur ein Import kennt, schließt der Abruf nicht. Ist der Kontostand als
  unbekannt markiert, entstehen nur die Positionen (mit dem Abruftag) und kein Depotwert. Bewertungstag:
  `accounts.balance_date`, bei fehlendem, ungültigem oder künftigem Datum der Abruftag (`date_assumed`).
- Positionsschlüssel: eine gültige ISIN (`normalized_isin`), sonst `cash` oder der normalisierte Name.
- Wird ein importiertes Konto mit dem Bankkonto zusammengeführt (Zwilling) oder ein doppeltes Konto aufgelöst, ziehen
  seine Beobachtungen mit (`depot_values::move_account`). Ändert sich die Kontoart, wird `depot_values` neu abgeleitet.
- **Import** (`observations::record_import`, Datenbank-Import `portfolio_chart`): je Tag der Depotwert und der Wert
  jeder Position, verkaufte eingeschlossen, unverändert mit eigener Währung und Quellzeile. Nullwerte gelten als
  bestätigt. Ein zweiter Lauf fügt nichts hinzu.

### `depot_values` (abgeleitet)

```
depot_values(
  account_id  INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  value_date  TEXT    NOT NULL,                    -- YYYY-MM-DD
  source      TEXT    NOT NULL DEFAULT 'fetch',    -- fetch | import | prices
  quality     TEXT    NOT NULL DEFAULT 'observed', -- observed | reconstructed | estimated
  value_cents INTEGER NOT NULL,
  observed_ms INTEGER NOT NULL DEFAULT 0,          -- die Beobachtung, aus der der Wert stammt
  PRIMARY KEY (account_id, value_date, source)
) WITHOUT ROWID;
```

- Nur Depotwerte, nicht abgeglichen: `depot_values::rebuild` leitet sie nach einem Abruf (nur dieser Tag), einem
  Import und einem Tresor-Abgleich (ganze Depots) aus `depot_observations` ab.
- **Regeln je Tag und Quelle** (`observations::day_values`, dieselben für die Reihen einzelner Positionen):
  - `fetch`: die letzte Beobachtung des Tages; eine 0 nur, wenn sie bestätigt ist.
  - `import`: der größte Wert ungleich 0 des Tages (eine Quelle kann eine ISIN in mehreren Zeilen führen, etwa nach
    Verkauf und Neukauf); eine 0 nur nach einem Wert und nur die erste einer Folge (ein geschlossenes Depot meldet
    weiter 0).
  - Werte in einer anderen Währung als der des Depots bleiben draußen.
- `prices` und die Güten `reconstructed` / `estimated` sind für berechnete Werte reserviert; heute entsteht nur
  `observed`. Mehrere Quellen für denselben Tag liegen nebeneinander. Angezeigt wird je Tag die beste: erst nach Güte,
  dann `fetch` vor `import` vor `prices`.
- Ein weiches Löschen eines Imports (damit andere Geräte ihn nicht zurückbringen) gibt es noch nicht.

**Regeln der Reihe** (`depot_values::series`, `Vault::depot_value_history`)
- Vor dem ersten Punkt eines Depots ist sein Wert **unbekannt**: nicht 0 und nicht der erste Wert.
- Ein **bestätigter Nullwert** (Depot vollständig verkauft) ist ein Punkt und zählt als abgedeckt. Eine 0 ohne
  Bestätigung (die Bank hat den Bestand nicht geliefert) hinterlässt keinen Punkt.
- Bekannte Werte gelten vorwärts weiter, es wird nicht interpoliert.
- Je Tag liefert die Abfrage `covered_depots` und `total_depots` (`DepotValuePoint`). Die Abdeckung wird berechnet,
  nicht gespeichert. Die Reihe beginnt am ersten Tag, an dem mindestens ein Depot einen Wert hat. Eine Summe über mehrere
  Depots ist eine Teilsumme, solange nicht alle abgedeckt sind („2 von 3 Depots“); wo ein weiteres Depot erstmals
  hinzukommt, darf der Sprung nicht als Wertzuwachs gezeigt werden. Summiert werden nur Depots in EUR.
- Der Wert ist der gemeldete Depotwert und **keine Rendite**: Käufe, Verkäufe und Übertragungen verändern ihn.

**Wer liest**
- `Vault::depot_value_history(account_ids, days)`: Diagramm der Depotansicht und von Vermögen › Wertpapiere
  (`DepotValueChart`, zugeschnitten auf den Zeitraum durch `DepotValueHistory`). Mehrere Depots: nur EUR, das
  Diagramm nennt ausgelassene Depots in anderer Währung; ein einzelnes Depot in seiner Währung.
- `balance_history` (Gesamtverlauf ohne Teilsummen-Hinweis) nimmt die Depotwerte direkt. Vor seinem ersten Wert läuft
  ein Depot über seine eigenen Buchungen von diesem Wert zurück (ohne Buchungen bleibt es bei ihm), damit es nicht als
  Zuwachs in die Summe springt.
- `Vault::depot_value_positions(account_id)`: Positionen mit Verlauf, verkaufte eingeschlossen (`held`), mit erstem und
  letztem Tag. `Vault::position_value_history(account_id, position)`: Tageswert einer Position aus `depot_observations`
  ab ihrem ersten Wert, bis heute oder bis zum Verkauf (`PositionHistorySheet`). Eine Reihe in anderer Währung wird in
  ihrer eigenen gezeigt.

**Demo** (`--demo-seed`): Das Welt-Depot hat ein Jahr lückenloser Abruf-Werte mit Positionen und einer vor 60 Tagen
verkauften Position, das Einzeltitel-Depot beginnt erst vor 120 Tagen (Teilsumme in der Summe), das Krypto-Depot hat
Lücken von ein bis drei Tagen und eine ältere importierte Strecke, an deren Überlappung der Abruf gewinnt.
