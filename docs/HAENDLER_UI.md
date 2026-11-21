# Händler (UI-Aufbau)

Diese Seite beschreibt den Bereich **Einstellungen › Händler** (`MerchantRecognitionSettings`) und den Editor eines
eigenen Händlers (`CustomMerchantEditor`), was sie zeigen, was sie nicht tun und welche Regeln für Änderungen gelten
(#1373). Sie gilt für macOS und iPhone/iPad. Der Kern dazu: `merchants.rs` (`MerchantRules`) und `merchants/custom.rs`.

## Grundprinzip

Die eingebaute Händlerliste (`girocrab-core/data/merchants.tsv`) bleibt, wie sie ausgeliefert wird, und kann mit Updates
wachsen. Was der Nutzer ändert, liegt daneben im Tresor und wird per iCloud mit seinen anderen Geräten abgeglichen
(neueste Änderung gewinnt, ein gelöschter eigener Händler bleibt gelöscht):

- **Hauptschalter „Händlererkennung“.** Aus zeigen Buchungen ihre Gegenseite (ohne Gegenseite den Anfang des
  Verwendungszwecks), ohne Händlernamen, Markenfarbe und Logo, auch ohne eine im Inspektor gesetzte Logo-Domain.
- **Eingebaute Händler**, jeder mit eigenem Schalter. Ein ausgeschalteter wird nicht mehr erkannt; die Buchung zeigt den
  nächsten passenden Händler oder ihre Gegenseite.
- **Eigene Händler** mit Name und Suchwörtern. Sie gehen den eingebauten vor; gesucht wird zuerst in der Gegenseite,
  passen dort mehrere, gewinnt das längste Suchwort. „Bearbeiten“ eines eingebauten Händlers legt eine Kopie als eigenen Händler an (mit Logo, Farbe und Art des
  Originals), die das Original ersetzt, solange es sie gibt. Das wird beim Laden abgeleitet und nicht als Schalter
  gespeichert: Wird die letzte Kopie gelöscht, wird das Original wieder erkannt, es sei denn, der Nutzer hat es selbst
  ausgeschaltet. Eine Kopie eines Zahlungsdienstes schaut weiter dahinter, eine Kopie einer Untermarke (fraenk,
  congstar) schlägt weiter den Konzern, und eine Kopie des Konzerns lässt seinen Untermarken den Vortritt. Eine Kopie
  von „Sparkasse“ oder „Volksbank“ nennt dagegen jede Mitgliedsbank nach der Kopie (der Name der einzelnen Bank aus der
  Gegenseite gilt nur für den eingebauten Eintrag).

Die Einstellungen ändern nur die **Anzeige**: Name und Zeichen in Liste und Inspektor, die Händler-Historie und Belege.
Was als Konsum oder Investition zählt, wiederkehrende Zahlungen, die Sparpläne im Investment-Dashboard und
Kategorievorschläge lesen weiter die eingebaute Liste (`BundledMerchant`): Ein ETF-Kauf bleibt eine Investition, auch
wenn sein Eintrag ausgeschaltet ist, und eine Abo-Serie oder ein Sparplan zerfällt nicht und verschmilzt nicht, wenn
der Händler umbenannt wird.

## Bereich „Händler“

Ein eigener Reiter der Einstellungen (macOS: Fenster, iPhone/iPad: Blatt), von oben nach unten:

| Abschnitt | Inhalt |
| --- | --- |
| Händlererkennung | Hauptschalter „Händler erkennen“, darunter ein Satz, was aus bedeutet |
| Händler-Logos | „Logos aus dem Internet laden“ und „Logo-Cache leeren“ (zogen aus „Allgemein“ hierher); aus, solange die Erkennung aus ist |
| Suchfeld | Filtert beide Listen: eigene Händler nach Name und Suchwort, eingebaute nach Name, Schlüssel und Suchwort |
| Eigene Händler | Je Zeile Zeichen, Name, Suchwörter und ggf. „Kopie von …“, rechts Bearbeiten und Löschen (beides auch im Kontextmenü); darunter „Eigenen Händler hinzufügen …“ |
| Eingebaute Händler | Je Zeile Zeichen, Name, Suchwörter, Art, Bearbeiten und der Schalter. Ein von einer Kopie ersetzter Händler zeigt „Ersetzt durch eigenen Händler“, sein Schalter ist gesperrt. Ausgeschaltete und ersetzte stehen oben, sonst nach Name |

Die beiden Listen sind ausgegraut, solange die Erkennung aus ist. Ein Schalter steht sofort in der neuen Stellung; die
Änderung läuft im Hintergrund, nach den Änderungen davor (`settingsWriteTask`). Danach lädt alles, was Händlernamen
zeigt, im Hintergrund neu (`AppModel.changeMerchants`: Liste, Inspektor mit Händler-Historie, Dashboard); bei mehreren
schnellen Änderungen nur einmal, nach der letzten. Die gezeigten Daten bleiben bis dahin stehen; danach folgen die
Händler-Historie der gewählten Buchung und eine außerhalb der Seite festgehaltene Buchung. Konsum, Summen,
wiederkehrende Zahlungen und die Seitenleiste hängen nicht an den Einstellungen und laden nicht neu. Ein aktiver
Händlerfilter (Händler-Historie) wird verlassen, wenn sein Schlüssel keine Buchung mehr nennt (eine Kopie hat einen
eigenen Schlüssel, ausgeschaltet gelten `x:`-Schlüssel); dasselbe nach einem iCloud-Merge.

Die Buchungssuche im Hauptfenster findet Buchungen auch über den angezeigten Händlernamen, also über den Namen
eines eigenen Händlers („Supermarkt Ecke“) und eingebaute Namen, die in keinem Buchungstext stehen („Amazon“ für
„AMZN Mktp“). Die Namen kommen aus den zwischengespeicherten Buchungsklassen des Kerns und werden nur gelesen,
wenn das Suchwort in einem dieser Namen vorkommt.

Die Reihenfolge der eingebauten Liste wird beim Öffnen und bei jeder neuen Suche festgelegt, nicht nach jedem Schalter:
Eine Zeile springt nicht unter dem Mauszeiger weg. Nach einer eigenen Änderung, einem Merge oder einem Abruf
(`merchantSettingsRevision`) liest der Bereich die Liste neu, ohne umzusortieren; ein Tresorwechsel (Demo ↔ eigene
Daten) liest und sortiert neu. Scheitert das Lesen, bleiben die zuletzt gelesenen Zeilen stehen, mit „Erneut
versuchen“. Scheitert eine Änderung, springt der Schalter zurück und der Bereich sagt oben, warum (ein Hinweisfenster
des Hauptfensters läge auf dem Mac hinter dem Einstellungsfenster). Löschen fragt nach und sagt, ob das Original danach
wieder erkannt wird.

Ohne geöffneten Tresor ist der ganze Reiter deaktiviert. Mit `--demo-settings merchants` (auch `logos`) öffnet die App
diesen Reiter für Bildschirmfotos.

## Editor

Ein Blatt (`capturableSheet`) mit Name und Suchwörtern (mehrere mit Komma getrennt), unten Abbrechen und Anlegen bzw.
Sichern. Der Kern prüft und vereinheitlicht die Suchwörter wie die Buchungstexte (Kleinschreibung, Rechtsformen wie
„GmbH“ und Trennzeichen fallen weg, doppelte und solche mit weniger als zwei Buchstaben oder Ziffern entfallen); seine
Meldung (kein Name, kein Suchwort, zu lang) steht unter den Feldern, das Blatt bleibt offen. Bei einer Kopie sagt ein
Satz, dass sie Logo, Farbe und Art des Originals behält und es ersetzt, solange es sie gibt.

Gesucht wird wie bei den eingebauten Händlern: zuerst in der Gegenseite, ohne Gegenseite im Verwendungszweck (dort nur
Suchwörter ab vier Zeichen), bei Zahlungsdiensten auch dahinter („PayPal … Ihr Einkauf bei …“). Ziffernfolgen zählen
ganz („123456“ trifft nicht „123459“). Ein Suchwort passt nur als ganzes Wort (auch mehrere Wörter): „dm“ trifft nicht „Dmitri“, und die Kopie von „TIER“ nicht „Tierarzt“ (in der
eingebauten Liste begrenzen Leerzeichen solche Wörter, die Kopie zeigt sie ohne).

## Regeln

- Die Symbol-Knöpfe (Bearbeiten, Löschen) nennen für VoiceOver den Händler.
- Namen und Suchwörter eigener Händler, das Suchfeld und die Felder des Editors tragen `.sensitive()`; das Zeichen eines
  eigenen Händlers zählt als unbekannt (`known = false`) und wird abgedeckt, das Logo einer Kopie nicht. Eingebaute
  Händler sind Marken und bleiben im Bild „Problem melden“ sichtbar.
- Logo, Farbe und Art lassen sich hier noch nicht ändern; die Logo-Domain eines eigenen Händlers wird wie bei jedem
  anderen im Inspektor gesetzt (sein Schlüssel `u:<uuid>` bleibt beim Umbenennen gleich).
- Neue Regeln für das Erkennen gehören in den Kern (`MerchantRules`), damit Mac, iPhone und Linux dieselben Namen zeigen.
