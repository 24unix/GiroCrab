# Changelog – GiroCrab für Linux

Die Linux-Oberfläche ist ein Community-Port der Mac-App
([#389](https://github.com/GiroCrab/GiroCrab/issues/389)). Sie folgt der Mac-App in eigenem
Tempo: Der Kern (Bankanbindungen, Tresor, Auswertungen) ist immer der aktuelle, die Oberfläche
holt Funktionen schrittweise nach. In Einstellungen › Sicherheit steht deshalb „Kern-Version“.

## Funktionsstand 0.7.0 (Kern 0.7.5)

Die Linux-Oberfläche erreicht den Funktionsumfang der Mac-App 0.7.0. Alle Texte kommen wie
bisher aus dem String-Katalog der Mac-App, Deutsch und Englisch.

### Seitenleiste
- **„Alle Konten“** als Wurzel der Kontenliste, mit Gesamtsaldo je Währung und einklappbar
  (#397). Fremdwährungen mit Summe 0 entfallen, mehrere Summen stehen untereinander.
- Konten **nach Gruppe, Bank oder Kontoart** anzeigen, auch im Menü Darstellung und in der
  Befehlspalette (#377).
- **Kontosuche** nach Name, Kontoinhaber, IBAN oder Kontonummer; Treffer zeigen Inhaber oder IBAN.
- Kontozeilen mit **Inhaber-Kürzel** und **Zähler-Blasen** für neue Buchungen (#426).
- Kontomenü mit **„Kontoart ändern …“** und **„Kontoinhaber …“** (#462, #280).
- **„Neue Umsätze“**: eine Karte je Konto mit den ungeprüften Buchungen (#352).
- **Kategorien einklappbar** (#408).
- Bedienung mit den **Pfeiltasten** (↑/↓ wechseln die Auswahl, ←/→ klappen Kategorien).

### Gruppen, Farben, Kontoauswahl
- **„Gruppen bearbeiten …“** mit Suche, Trefferzahl und Konten per Ziehen auf eine Gruppe (#377).
- **Farbwahl** mit Gelb, Braun, Schiefer und „Eigene Farben“ (mit „Entfernen“) (#466).
- Kontoauswahl in **Belegen und Regeln** gegliedert wie die Seitenleiste (#412).

### Vermögen und Sachwerte
- Neue Seite **„Vermögen“**: Nettovermögen, Zusammensetzung, Cash-Verlauf, Wertpapiere mit
  Ausschüttungen, Gebühren und Steuern; umschaltbar Alles / Cash / Wertpapiere / Sachwerte (#348).
- **Sachwerte** (Gold, Immobilien, Fahrzeuge …) als Konto ohne Bankanbindung: Bewertungen,
  Mengen, Verkauf, Goldpreise (#87, #345).

### Buchungen und Auswertungen
- **Export** der Umsätze als PDF, CSV und CAMT.053 (#401, #372).
- **Zeitraum-Menü** mit 30/90 Tagen, 12 Monaten, einzelnen Monaten, Quartalen und Jahren (#382).
- **Budgets** bearbeiten, entfernen und ganz ausblenden (#430).
- **Splitbuchung** mit Restbetrag, „Rest zuweisen“ und Hinweis, warum „Speichern“ ausgegraut ist
  (#383); Darlehen nur bei Ausgängen zuordnen.
- Eine eben geprüfte Buchung bleibt stehen, bis die Auswahl wechselt (#470).
- **Händler-Historie** zeigt alle Konten und das eigene Konto (#299).
- Eine Regel aus einer Einnahme gilt nur für Einnahmen (#295).
- **Amazon-Bestellungen**: lesbare Artikel, Drilldown und Produktlinks (#333, #349, #354).

### Einstellungen und Hilfe
- **Schriftgröße** Standard / Groß / Sehr groß, auch mit Strg+Plus, Strg+Minus, Strg+0 (#343).
- **Erscheinungsbild** System / Hell / Dunkel (#388).
- **App zurücksetzen**: Tresor, Schlüssel und Einstellungen löschen (#241).
- **Kontoauswahl beim Bankzugang**: doppelte Konten bei mehreren Zugängen überspringen (#346).
- **Hilfe › Problem melden** mit automatisch geschwärztem Screenshot; nichts wird ohne Klick
  gesendet (#301).
- **Animierte Krabbe** auf Startbild, Sperrbildschirm und Willkommenskarte. Unter Linux wirft
  sie beim Entsperren und Laden die Münze; die Animation läuft im Render-Thread.

### PSD2 (Enable Banking)
- **Revolut** und andere Banken, deren Freigabe ein zweites Fenster öffnet, funktionieren im
  GiroCrab-Anmeldefenster: neue Fenster öffnen sich als echtes Pop-up, die wartende Seite bleibt
  erhalten (#289).
- Das Anmeldefenster blieb weiß, stürzte nach der Freigabe ab und meldete sich als
  „QtWebEngine“ – alles behoben. `girocrab --debug-consent` protokolliert den Ablauf ohne
  Parameterwerte.
- „Bank hinzufügen“ bietet die **.pem-Schlüsseldatei** an; die Anleitung nennt Privacy- und
  Terms-URL.

### Korrekturen
- „Bearbeiten › Suchen“ setzt den Fokus ins Suchfeld; die Kontosuche behält beim Tippen den Fokus.
- Bankdialoge aus den Einstellungen erscheinen vorn statt hinter dem Einstellungsfenster.
- Scrollleisten im Dunkelmodus sichtbar; „Einstellungen › Allgemein“ groß genug.
- Namen in der Buchungsliste werden nicht mehr wegen Bruchteil-Pixeln gekürzt.

### Noch nicht in der Linux-Oberfläche (Mac 0.7.1 – 0.7.5)
Unter anderem: Seiten „Geplant“ (Termin- und Daueraufträge) und „Lastschriften“,
Sammelüberweisung und Umbuchung zwischen eigenen Konten, Tags, Buchungsdichte, Sicherung mit
Passwort, anpassbare rechte Seitenleiste, Seitenleiste mit Abschnitten, Regeln für mehrere Konten
(Linux wählt vorerst ein Konto), Kategorie-Ansichten je Konto, Kategorien duplizieren,
Anlageklassen. Sie folgen in den nächsten Schritten.
