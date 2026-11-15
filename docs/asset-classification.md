# Anlageklassen

Die Vermögensübersicht bietet **Nach Konto** und **Nach Anlageklasse**, auswählbar
über den Umschalter an der Zusammensetzungsgrafik (in den Tabs Wertpapiere und
Sachwerte heißt die erste Option **Nach Position**, weil dort die einzelnen
Positionen aufgeschlüsselt werden). Im Tab Wertpapiere gibt es zusätzlich
**Nach Instrument**: Einzeltitel, ETFs, Fonds und weitere Instrumente werden
getrennt ausgewiesen, unabhängig von ihrer Anlageklasse; die Zeile nennt dort die
Anlageklasse. Donut, Legendenfilter und Zuordnung arbeiten wie in der Klassensicht.
Die Karte „Erträge und Kosten“ bleibt im Tab Wertpapiere in jeder Gruppierung
sichtbar; unter „Alles“ steht sie in der Klassensicht nach den Anlageklassen.
Der Donut filtert in jedem Tab und jeder Gruppierung: unter „Alles“ nach Konto
blendet ein Segment die übrigen Abschnitte aus, in den Tabs zeigt es das gewählte
Konto oder die gewählte Position; „Sonstige“ steht für alle nicht einzeln
genannten Einträge. **Nach Konto** ist die
Voreinstellung und zeigt weiterhin Cash-Verlauf, Erträge und die Positionen mit
Gewinn und Verlust; die Klassensicht ersetzt diese Karten durch die Anlageklassen. Die Tabs
Cash, Wertpapiere und Sachwerte filtern weiterhin nach Kontoart. In der
Klassensicht werden beispielsweise ein Gold-ETC im Depot und ein Goldbarren bei
den Sachwerten gemeinsam unter „Rohstoffe & Edelmetalle“ ausgewertet.
Ein Klick auf ein Donutsegment oder einen Eintrag der Legende filtert die
Positionsliste. Ein erneuter Klick auf dieselbe Klasse, die Donutmitte oder
**Alle anzeigen** hebt den Filter auf. Die Grafik behält dabei alle Klassen und
ihre Anteile, damit die Auswahl im Verhältnis zum gesamten Vermögen sichtbar bleibt.
Im Cash-Tab werden die Konten gezeigt; dort entfällt die Klassenumschaltung.
Anlageklassen im Tab Wertpapiere beziehen sich ausschließlich auf Depotbestände,
auch wenn etwa ein Geldmarkt-ETF zur Klasse Liquidität gehört.
Auch der Summenblock oben links folgt dem Tab: Nettovermögen einschließlich der
gewählten Kreditoption unter „Alles“, ansonsten der Gesamtwert der ausgewählten
Kontoart ohne pauschalen Abzug anderer Konten oder Kredite.

**Direkt gehaltene Immobilien ausblenden** nimmt Positionen mit Anlageklasse
Immobilien und Instrument Direktbesitz aus der gesamten Vermögensansicht heraus:
aus Kontosummen, Brutto- und Nettovermögen, Diagramm und Positionslisten. Die
gespeicherten Daten bleiben erhalten. Immobilienfonds und Immobilienaktien werden
dadurch nicht ausgeschlossen. Kredite werden keiner Immobilie automatisch
zugeordnet und bleiben über **Kredite und Karten abziehen** unabhängig gesteuert.
Sind die Immobilien ausgeblendet, heißt die Summe „Nettovermögen ohne Immobilien“;
solange Kredite abgezogen werden, weist ein Hinweis darauf hin, dass die Kredite
der ausgeblendeten Immobilien weiterhin enthalten sind. Der Schalter erscheint,
wo er wirken kann: unter „Alles“ und „Sachwerte“, sobald Sachwerte vorhanden sind,
im Tab Wertpapiere nur bei direkt gehaltenen Immobilien im Depot.
Ohne passend klassifizierte Positionen weist die Ansicht auf die notwendige
Zuordnung hin. Das Demo-Haus hat dafür eine ausdrücklich gesetzte Beispielzuordnung.

**Nicht klassifizierte im Diagramm ausblenden** betrifft dagegen nur Grafik und
deren Prozentanteile. Summen und Positionsliste bleiben vollständig; die Grafik
kennzeichnet ihre eingeschränkte Bezugsgröße. Die Karte „Nicht klassifiziert“
bietet für Positionen mit einer stabilen Kennung **Jetzt zuordnen** an: Der Dialog
führt mit **Speichern & weiter** nacheinander durch alle offenen Positionen;
dasselbe Wertpapier aus mehreren Depots erscheint dabei einmal.

## Inhaber

Haben die Konten mindestens zwei verschiedene Inhaber, zeigt die Vermögensübersicht
oben eine Auswahl **Alle**, je Inhaber und gegebenenfalls **Ohne Inhaber**, jeweils
mit dem Anteil an der gezeigten Summe: unter „Alles“ das Nettovermögen, in den Tabs
der Wert dieser Kontoart, jeweils mit den gewählten Optionen für Kredite und
Immobilien. Die Auswahl filtert die Konten vor allen weiteren
Auswertungen: Summen, Diagramm, Klassen und Positionen beziehen sich dann auf die
Konten dieses Inhabers. Der Inhaber wird je Konto in der Seitenleiste gesetzt.
Positionen selbst tragen keinen Inhaber; maßgeblich ist das Konto.
Die Demodaten haben dafür zwei Inhaber und ein Konto ohne Inhaber.

## Bedienung und Zuordnung

Im Depot stehen Anlageklasse und Instrument direkt in der Detailzeile der
Position; in der Vermögensübersicht stehen Stückzahl, ISIN/Ticker, Konto und Instrument kompakt unter
dem Positionsnamen. In der Klassensicht das Stift-Symbol verwenden oder im Depot über
das Kontextmenü **Klassifizierung bearbeiten** öffnen. Zwei Merkmale lassen sich
unabhängig zuordnen:

| Merkmal | Werte |
| --- | --- |
| Anlageklasse | Aktien, Anleihen, Immobilien, Rohstoffe & Edelmetalle, Krypto, Liquidität & Geldmarkt, Mischanlagen / Multi-Asset, Sonstiges |
| Instrument | Einzeltitel, ETF, Fonds, ETC/ETN, Derivat / strukturiertes Produkt, Direktbesitz, Sonstiges |

Ein Aktien-ETF und ein Renten-ETF haben dasselbe Instrument, aber unterschiedliche
Anlageklassen. Jede Position zählt zu genau einer Klasse; Mischanlagen werden
nicht prozentual aufgeteilt. „Nicht klassifiziert“ bezeichnet fehlende Angaben und
ist deshalb nicht wählbar: **Automatisch** steht für „keine eigene Auswahl“,
„Sonstiges“ für eine bewusste Zuordnung.

Je Merkmal gilt: **eigene Auswahl → eindeutige Importangabe → lokales
ISIN-Wörterbuch/Namensregel → nicht klassifiziert**. Der Bearbeitungsdialog zeigt die
Herkunft als „Eigene Zuordnung“, „Importiert“ oder „Automatisch ermittelt“.
**Automatisch** entfernt nur die eigene Auswahl des jeweiligen Merkmals.
Eigene Zuordnungen überstehen erneute Depotabrufe und gelten bei gleicher gültiger
ISIN in allen Depots desselben Tresors. Beide Bestände zählen weiterhin mit ihrem
jeweiligen Wert.

Die Verarbeitung erfolgt offline. Allgemeine Fonds-/ETF-Bezeichnungen oder der
Depotanbieter bestimmen keine Anlageklasse. Geldmarktfonds zählen zur Liquidität,
Goldminenaktien zu Aktien und offene Immobilienfonds zu Immobilien;
Immobilienaktien-ETFs zählen zu Aktien. Komplexe oder widersprüchliche Produkte
bleiben bei unklarer Anlageklasse nicht klassifiziert.

Positionen ohne gültige ISIN haben keine gemeinsame manuelle Zuordnung. Ausgenommen
sind ausdrücklich als Direktbesitz bestätigte Kryptowährungen mit unterstütztem
Ticker. Eine beliebige WKN wird nicht als Coin interpretiert. Sachwerte verwenden
stattdessen ihre eigene stabile Identität. Automatisch bepreiste Edelmetalle
werden als Rohstoffe erkannt; andere Sachwerte können selbst zugeordnet werden.

Kontoguthaben und Kartenguthaben zählen zur Liquidität. Nicht zugeordnete Werte
und Differenzen zwischen Kontosaldo und Positionssumme bleiben sichtbar unter
„Nicht klassifiziert“. Die Klassen ergeben denselben Bruttowert wie die
Kontoansicht. Negative Differenzen bleiben in den Summen; der Donut zeigt nur
positive Klassenwerte. Verbindlichkeiten werden separat ausgewiesen.
Die Klassen sind als Bruttowerte gekennzeichnet; eine Erklärung bei den
Verbindlichkeiten verbindet sie mit dem darüber gezeigten Nettovermögen.

## Importquellen

Connectoren können mit `RemoteHolding` Anlageklasse und Instrument getrennt
liefern. Der Quirion-Connector übernimmt explizite Aktien-/Anleihenangaben.
Fehlende Angaben werden durch lokale Regeln ergänzt, ohne aus dem Anbieter eine
Klasse abzuleiten.
Die Demo-Coins sind ausdrücklich als Krypto-Direktbesitz modelliert. Für echte
Bankbestände ist eine solche Bestätigung weiterhin erforderlich; eine Krypto-
Anlageklasse allein bestimmt keine Verwahrungs- oder Instrumentart.

Der direkte Datenbankimport (`moneymoney_db.rs`) verwendet folgendes Mapping von
`securities.asset_class`, lokal gegen benannte Exporte der Quellversion 2.5.4 geprüft:

| Zahlenwert | Quellklasse | Übernommenes Merkmal |
| --- | --- | --- |
| 1 | Aktien | Anlageklasse Aktien |
| 2 | Fonds | Instrument Fonds |
| 3 | Anleihen | Anlageklasse Anleihen |
| 4 | Immobilien | Anlageklasse Immobilien |
| 5 | Rohstoffe | Anlageklasse Rohstoffe & Edelmetalle |
| 6 | ETFs | Instrument ETF |
| 7 | Kryptowährungen | Anlageklasse Krypto |

Für „Sonstige“ wurde kein Zahlenwert bestätigt. NULL, 0, unbekannte Werte und
fehlende Spalten setzen kein Importmerkmal; eigene Zuordnungen und lokale Regeln
können weiterhin greifen. Die Klasse „Kryptowährungen“ bestätigt keinen
Krypto-Direktbesitz. Das Mapping gilt für den Datenbankimport; es ist keine
Zuordnung der `assetClassUuid` aus dem Portfolio-Export.

## Speicherung und Synchronisation

Schema **16** ergänzt zwei Tabellen; die bestehende Tabelle `holdings` bleibt
unverändert:

- `security_classifications`: eigene Anlageklasse und eigenes Instrument mit
  getrennten Änderungszeitstempeln. Schlüssel sind gültige ISINs, unterstützte
  Ticker für bestätigten Krypto-Direktbesitz oder die UUID eines Sachwerts.
- `holding_classifications`: importierte Angaben an der konkreten Bestandszeile.
  Sie werden beim Ersetzen der Bestände ebenfalls ersetzt.

Zurücksetzen auf „Automatisch“ speichert einen datierten NULL-Wert. Beim
Tresor-Sync gewinnt je Merkmal die neuere Änderung; bei gleichem Zeitstempel wird
deterministisch entschieden, wobei ein Reset Vorrang hat. So kann ein älterer
Stand eine zurückgesetzte Auswahl nicht wiederherstellen. Importmetadaten bleiben
lokal und werden mit dem nächsten Abruf erneuert.

Tests decken Quellenrangfolge, unabhängige Korrekturen und Resets, erneute Importe,
mehrere Depots, Sachwerte, Synchronisation, Schema-Upgrades und Summenerhaltung
bei fehlenden oder negativen Positionswerten ab. Historische Schema-Fixtures
bleiben unverändert; neue Fixtures prüfen Schema 16.
