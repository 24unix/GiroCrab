# Depot-, Sachwerte- und Vermögensansicht (UI-Aufbau)

Diese Seite beschreibt, wie die Ansichten für Wertpapierdepots, Sachwerte-Konten und die Vermögensübersicht
(`Vermögen › Wertpapiere` / `Sachwerte`) aufgebaut sind, welche Bausteine sie teilen und welche Regeln für
Änderungen gelten. Sie gilt für macOS und iPhone/iPad; Abschnitt „Mobile Ansicht“ beschreibt die Unterschiede.

## Grundprinzip

Alle drei Ansichten zeigen *Bestände* (Positionen mit Menge, Kurs, Marktwert), keine Buchungsliste.
Sie bestehen aus denselben Bausteinen in derselben Reihenfolge, damit sich Depot, Sachwerte-Konto und Vermögen
gleich anfühlen:

1. **Kopf** (`AssetHeaderCard` in `AssetAccountFrame.swift`; in `Vermögen` die Summenkarte, ebenfalls vollbreit mit dem Gesamtwert rechts, auf dem iPhone untereinander): Name, Bank/Status, Wert (groß) und – rechts unter dem
   Gesamtwert – der Wertverlauf. Solange es für Wertpapierdepots keine belastbare Historie gibt, steht dort ehrlich
   „Bewertungsverlauf noch nicht verfügbar“ (Hook `DepotDetailView.valuationHistory`; es wird nichts aus Buchungen geschätzt).
2. **Vier Kennzahlen** (`DepotKPITiles.swift`, `DepotKPIs.securities` / `.tangibles`):
   - Wertpapiere: Unrealisierte GuV · Tagesveränderung · Ausschüttungen · Gebühren & Steuern
   - Sachwerte: Einstandswert · Unrealisierte GuV · Tagesveränderung · Größte Position (der Gesamtwert steht schon im Kopf)
3. **Zusammensetzung** (`AssetCompositionCard`): Gruppierung (Nach Position / Anlageklasse / Instrument) ×
   Darstellung (Kreis | Balken | Kacheln). Alle Darstellungen verwenden dieselben Farben (`DepotColors`) und
   dieselbe Datenbasis (`DepotComposition`).
4. **Positionen | Aktivitäten** (nur Wertpapierdepots): eine sortierbare Positionstabelle
   (`DepotPositionsTable`) bzw. die Aktivitätenliste (`DepotActivitiesView`).

**Reihenfolge:** Kopf → Kennzahlen → Zusammensetzung → Tabelle gilt für Einzeldepot und Sachwerte-Konto. In `Vermögen › Wertpapiere / Sachwerte` steht die Zusammensetzung direkt unter dem Kopf, die Kennzahlen folgen darunter; bei Wertpapieren kommt vor der Tabelle die Depotübersicht (Karte „Wertpapiere“, jede Zeile öffnet das Depot, Chevron `›`). Im Kopf von `Wertpapiere` wählt ein Zeitraum-Picker den Zeitraum von Ausschüttungen sowie Gebühren & Steuern.

Der Seitenrahmen (`AssetAccountFrame`) gibt die Slots vor (Kopf, Kennzahlen, Analyse, Inhalt) und entscheidet
anhand der verfügbaren Breite zwischen breitem und kompaktem Layout – nicht anhand der Plattform.

## Rechenlogik (rein, getestet)

Alle Zahlen kommen aus `DepotMetrics.swift` und werden in `DepotMetricsTests` geprüft; Views rechnen nicht selbst.

| Baustein | Zweck |
|---|---|
| `HoldingFigures` | GuV, Tagesveränderung, Preisbasis (je Stück / % vom Nennwert / unbekannt), Zwischenablage-Zeile |
| `DepotPosition` | Eine Tabellenzeile; gleiche Wertpapiere in mehreren Depots werden zusammengeführt (`merged`) |
| `DepotComposition` | Gruppiert nach Position/Klasse/Instrument, faltet den Rest („Weitere (n)“), begrenzt Segmente |
| `DepotColors` | Kollisionsfreie Farben je Bestand (bis 16 Positionen unterscheidbar) |
| `Treemap` | Squarified-Layout der Kacheln; bei mehr als 4 Kacheln mehrzeilig statt Streifen |
| `TangiblePositions` | Sachwert-Objekte als Positionen (Kurs nur, wo es eine Kursquelle gibt) |

Regeln:

- Prozentwerte der GuV sind immer *Summe der GuV / Summe der Einstände*, nie ein Mittel von Prozenten.
- Positionen ohne Einstandsdaten zeigen keine GuV (kein „0 %“) und fließen nicht in Summen ein.
- Anteile beziehen sich immer auf den gesamten Bestand, auch wenn die Suche die Liste einschränkt.
- Wert und Währung gehören zusammen: Fremdwährungsbeträge werden nicht stillschweigend addiert, sondern im
  Kachel-Untertext als „nicht enthalten“ ausgewiesen.
- Keine Kursverlaufs- oder Wertverlaufsdaten erfinden. Fehlt die Quelle, sagt die Oberfläche das.

## Zusammensetzung: Darstellung und Filter

- **Kreis**: Ring mit Legende; bis zu 8 Positionen erscheinen einzeln; ab 9 bleiben die 7 größten stehen, der Rest wird zu „Weitere (n)“ gefaltet (ein einzelner Rest wäre keine Gruppe). Anlageklassen und Instrumente werden nie gefaltet.
- **Balken**: gerankte Balken mit Anteil in %; zeigt bis zu 11 Einträge einzeln; ab 12 stehen die 10 größten da, der Rest ist „Weitere (n)“. Kacheln: bis 13 einzeln, ab 14 die 12 größten plus Rest.
- **Kacheln**: Treemap, Fläche ∝ Marktwert, Farbe = Farbe der Position/Gruppe aus Kreis und Balken, Textfarbe
  nach Luminanz. Oben links Name (fett) und „Marktwert · Anteil“; bei kleinen Kacheln nur Name, dann nur Anteil,
  nie abgeschnittene Zahlen. Hover (macOS) bzw. Tippen (iOS) zeigt eine Detailkarte unten rechts
  (Name, Marktwert, Anteil, Anzahl der Positionen).
- **Filter**: Klick/Tipp auf ein Segment, einen Balken, eine Legendenzeile oder eine Kachel filtert die darunter
  stehende Positionstabelle auf die Positionen dieses Segments (`DepotSlice.memberKeys`). Nochmaliges Klicken
  oder „Alle anzeigen“ hebt den Filter auf. Wechsel von Gruppierung oder Darstellung setzt ihn zurück.
  Ein veralteter Filter (Schlüssel existieren nicht mehr) wird ignoriert, die Liste wird nie leer.
- Die Auswahl der Darstellung wird je Ansicht gemerkt (`@AppStorage`: `depotCompositionDisplay`,
  `tangibleCompositionDisplay`, `wealthSecuritiesCompositionDisplay`, `wealthTangiblesCompositionDisplay`).
- Dieselbe Karte (`SliceCompositionCard`) zeigen auch „Alles“ und „Cash“ in Vermögen, mit Kreis/Balken/Kacheln
  und Klickfilter (dort: ein Bereich bzw. ein Konto). Der Umschalter ist wie am Kontodiagramm (#634) ein kleines
  Icon-Segment. Der Cash-Verlauf nutzt ebenfalls das Diagramm des Konto-Headers (Ausblenden, Linie, Balken,
  Kreis als Anteile der Konten).

## Positionstabelle

Spalten (breit): Position | Menge / Einheit | Kurs | Marktwert ▾ | Anteil | GuV € / % und ✎ (Klassifizierung ändern),
darunter eine Summenzeile. Überschriften sortieren; die Sortierung gilt je Ansicht.
Die Tabelle ist in Depot, Sachwerte-Konto und `Vermögen` dieselbe Komponente. In `Vermögen › Wertpapiere` steht unter jeder Position, in welchem Depot sie liegt (`depotLabel`); die Depotliste darüber springt per Klick (Chevron) ins Depot.

## Mobile Ansicht (iPhone, kompakte Breite)

Die kompakte Variante ist eine **eigene Darstellung**, keine verkleinerte Desktop-Tabelle:

- **Kopf**: Name über die volle Zeile (bis zu zwei Zeilen), Wert darunter linksbündig, Statuszeilen umbrechen.
- **Kennzahlen**: zwei Spalten; bei sehr großer Schrift eine Spalte. Titel dürfen auf zwei Zeilen umbrechen.
- **Zusammensetzung**: Gruppierung als Menü („Nach Position ⌄“), Darstellung als Icon-Umschalter
  (Kreis/Balken/Kacheln); Legende unter dem Diagramm.
- **Positionen**: Listenzeilen mit Name + Unterzeile links, Marktwert + GuV/Anteil rechts; ein Tipp klappt die
  Details auf (Menge, Kurs, ISIN/WKN, Bankhinweis, ✎ und Sprung zur Buchung). Mindesthöhe 52 pt für Touch.
- **Aktivitäten**: gleiches Muster; der Filter ist ein Menü statt eines segmentierten Pickers.
- **Suche**: eigenes Feld der Ansicht; es darf Inhalte nicht transparent überlagern.
- **Dynamic Type**: geprüft in `large` und `accessibility-medium`; nichts darf mitten im Wort oder in Zahlen
  abgeschnitten werden.

Regel für plattformübergreifende Änderungen: iOS-Anpassungen dürfen auf macOS weder Spalten verdrängen noch
Funktionen verstecken noch Touch-Abstände einführen. Entscheidungen laufen über die **verfügbare Breite**
(`wide`-Schwellen mal `textScale`), nur Interaktionen (Hover vs. Tippen, Menü vs. Segment) über `#if os(...)`.

## Regeln für Änderungen

- **Schrift**: `.appFont(...)` statt `.font(...)` (`scripts/lint-fonts.sh`). Feste Breiten/Höhen mit Text mit
  `@Environment(\.textScale)` multiplizieren; kein `minimumScaleFactor` als Notlösung.
- **Datenschutz** (Problem-melden-Screenshot): Beträge, Salden, IBANs, Namen, Gegenparteien, Notizen und
  Diagramme mit `.sensitive()`; Kategorie-, Wertpapier- und Klassennamen mit `.sensitive(.labels)`; eigene
  Sachwert-Namen als `.personal`. Das gilt auch für Treemap und Detailkarte. Datumsangaben, Banknamen und
  Fehlertexte bleiben sichtbar.
- **Performance**: Kernaufrufe über 16 ms laufen über `model.vaultOffMain`; kein `list_transactions` für Zählungen
  oder Summen.
- **Texte**: keine Marken fremder Banking-/Finanzsoftware, keine Produktvergleiche; alle Strings in
  `Localizable.xcstrings` (DE + EN), danach `scripts/xcstrings.py format`.
- **Tests**: neue Rechenlogik in `DepotMetricsTests` (Reine Funktionen vor Views). Layout wird mit
  `--screenshot` geprüft, schmale Fenster mit `--window-width`, große Schrift mit `--text-size larger`,
  Datenschutz mit `--redact`.
- **Verlauf**: Zeitreihen/Historie sind bewusst ein eigener Branch (`feat/depot-value-history`); diese Ansichten
  enthalten nur den Hook dafür.

## Prüfen

```bash
cd GiroCrabApp
swift build -q && swift test -q
.build/debug/GiroCrabMac --demo-seed --select einzeltitel --screenshot /tmp/depot.png
.build/debug/GiroCrabMac --demo-seed --select einzeltitel --window-width 760 --text-size larger --screenshot /tmp/depot-schmal.png
```

iPhone: App mit `--demo-seed` im Simulator (iPhone Plus/Max) starten, Dynamic Type über
`xcrun simctl ui <udid> content_size accessibility-medium` umstellen.
