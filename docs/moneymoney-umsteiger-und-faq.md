# Umstieg von MoneyMoney zu GiroCrab: Schritt für Schritt und FAQ

Diese Anleitung zeigt, wie du Konten und Buchungen aus MoneyMoney übernimmst. Alle Daten bleiben dabei auf
deinem Mac (siehe `SECURITY.md`).

## Überblick: zwei Wege

| Weg | Wann | Was kommt mit |
|---|---|---|
| **Datenbank-Import** (empfohlen) | Du hast MoneyMoney auf demselben Mac | Konten, Buchungen, Kategorien, Notizen, soweit in der Datenbank vorhanden |
| **Export-Dateien** (CSV, XML, CAMT, MT940) | Datenbank nicht erreichbar oder nur einzelne Konten | Buchungen je Datei und Konto |

## Vorbereitung

1. Beende MoneyMoney und mache eine Sicherung deiner MoneyMoney-Daten (Time Machine oder Kopie des Ordners).
2. Rufe in MoneyMoney alle Konten einmal ab, damit der Bestand aktuell ist.
3. Installiere GiroCrab und lege beim ersten Start deinen Tresor an (Passwort gut merken, es gibt keine Wiederherstellung).
4. Halte das MoneyMoney-Datenbankpasswort bereit, falls du eines vergeben hast.

## Weg 1: Datenbank-Import

1. In GiroCrab: **Ablage › Importieren › MoneyMoney-Datenbank**.
2. Wähle die MoneyMoney-Datenbankdatei. Der Dialog öffnet den üblichen Ordner im Bibliotheksverzeichnis;
   bei Bedarf wählst du die Datei von Hand.
3. Gib das Datenbankpasswort ein. Es wird nur zum Öffnen der Datei verwendet und nicht gespeichert.
4. Prüfe die Vorschau: Konten, Anzahl der Buchungen, Zeitraum.
5. Ordne Konten zu. Bereits in GiroCrab vorhandene Konten (gleiche IBAN) werden zusammengeführt, neue angelegt.
6. Starte den Import. Doppelte Buchungen werden erkannt und nicht erneut angelegt, ein zweiter Lauf ist ungefährlich.

## Weg 2: Export-Dateien

1. In MoneyMoney das Konto wählen, **Konto › Umsätze exportieren…** und ein Format wählen:
   CAMT (am vollständigsten), MT940, XML oder CSV.
2. Zeitraum möglichst groß wählen (alle Umsätze).
3. In GiroCrab: **Ablage › Importieren › MoneyMoney-Export** und die Dateien auswählen.
4. Konto zuordnen, Vorschau prüfen, importieren.
5. Für jedes weitere Konto wiederholen.

## Nach dem Import

1. **Salden prüfen:** Vergleiche den Kontostand je Konto mit dem Bankstand.
2. **Kategorien und Regeln:** Prüfe die übernommenen Kategorien und lege Regeln für wiederkehrende Buchungen an.
3. **Bankabruf einrichten:** Richte unter **Einstellungen › Verbindungen** die Bankanbindung neu ein
   (Zugangsdaten werden nicht aus MoneyMoney übernommen). Der erste Abruf ergänzt Buchungen ab dem letzten Import.
4. **Wiederkehrende Zahlungen** erkennt GiroCrab aus dem Bestand.
5. Behalte die MoneyMoney-Sicherung, bis du alles geprüft hast.

## FAQ

**Wird in MoneyMoney etwas verändert?**
Nein. Die Datenbank wird nur gelesen.

**Werden meine Daten hochgeladen?**
Nein. Import und Verarbeitung laufen lokal; es gibt keine Telemetrie.

**Das Datenbankpasswort wird abgelehnt.**
Prüfe Groß-/Kleinschreibung und das Tastaturlayout. Ist die Datenbank nicht verschlüsselt oder die Datei
beschädigt, nutze Weg 2.

**Die Datenbank wird nicht gefunden.**
Beende MoneyMoney, wähle die Datei im Dateidialog von Hand oder nutze Weg 2.

**Buchungen erscheinen doppelt.**
Erneutes Importieren derselben Quelle erkennt Duplikate. Doppelte Einträge entstehen meist, wenn dieselben
Umsätze aus verschiedenen Formaten (z. B. CSV und CAMT) importiert wurden. Importiere pro Konto ein Format.

**Umlaute sind kaputt.**
GiroCrab repariert gängige Kodierungsfehler beim Import. Bleibt etwas falsch, exportiere als CAMT oder XML.

**Kategorien fehlen oder sind anders.**
Es werden nur Kategorien übernommen, die in der Quelle stehen. Passe Kategorien und Regeln in GiroCrab an;
Regeln wenden sich auch auf bestehende Buchungen an.

**Fehlen Wertpapiere oder Depots?**
Ein Depot ist ein eigenes Konto. Historische Werte lassen sich separat importieren; Details in der App-Hilfe.

**Kann ich beides parallel nutzen?**
Ja, solange du Bankabrufe nicht an zwei Stellen mit derselben Zugangskennung gleichzeitig sperrst
(zu viele fehlerhafte Versuche können die Online-Banking-Kennung sperren).

**Kann ich zurück?**
Ja. GiroCrab exportiert Buchungen in offene Formate; deine MoneyMoney-Daten bleiben unverändert.

**Wo melde ich Probleme?**
In der App unter **Hilfe › Problem melden**. Der Bericht wird bereinigt und erst nach deiner Prüfung
veröffentlicht.
