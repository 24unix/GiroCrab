# EquatePlus

Inoffizielle, nur lesende Anbindung für Mitarbeiteraktien und Vergütungsprogramme.
Portaländerungen und Einschränkungen durch die Nutzungsbedingungen sind möglich.

## Anmeldung

Unter **Bankzugänge** nach **EquatePlus** suchen, einen Zugang anlegen und den Abruf
starten. Im eingebetteten Browser anmelden und mit EquateAccess oder der vom Portal
angebotenen Alternative bestätigen. Anschließend **Programme und Bestände abrufen**.
Cookies bleiben im lokalen Browserprofil; Zugangsdaten und Sitzungstoken werden
nicht in den Bestands-Snapshot übernommen oder protokolliert. Abrufe bleiben auf
dem angemeldeten Produktionsstandort (`www.equateplus.com`,
`www.emea.equateplus.com` oder `www.na.equateplus.com`).

## Bestände

Jedes Programm erhält ein eigenes Depot mit stabiler Programm-ID. Verfügbare,
gesperrte und performancegebundene Bestände erscheinen getrennt; unklare
Verfügbarkeit wird ausdrücklich gekennzeichnet. RSUs bleiben auch ohne Einstandskurs sichtbar.

Die Programmdetails enthalten historische Mengenbewegungen. Positive und negative
Stückzahlen werden je Instrument und Verfügbarkeit saldiert; leere Beschreibungs-
und Beitragszeilen sind keine Depotpositionen. Mengen und Werte müssen mit den
aktuellen Programmsummen (`TOTAL`, `AVAILABLE`, `LOCKED`) übereinstimmen, abgesehen
von Cent-Rundungen. Fehlerhafte Snapshots werden vor dem Speichern abgewiesen.
Explizit leere Programme entfernen alte Positionen; fehlende Programme werden
nicht automatisch gelöscht. Nach historischen Verkäufen wird kein verbleibender
Einstandskurs aus Verkaufspreisen erfunden.

Sperrbestände zählen zum geschätzten Bruttowert, sind aber kein frei verfügbares
Guthaben. Umsätze und Vesting-Termine werden derzeit nicht importiert; PDFs nur auf Wunsch
(siehe unten).
Abweichende Kurswährungen ohne verifizierten Wechselkurs werden abgewiesen.

## Dokumente (optional)

Im EquatePlus-Fenster lädt **Dokumente laden …** die PDFs der Bibliothek des Portals
(Bestätigungen, Auszüge, Steuerbescheinigungen u. a.). Das gehört nicht zum normalen Abruf der
Programme und kann jederzeit später angefordert werden:

- Es werden nur Dokumente geladen, die noch nicht gespeichert sind; ein erneuter Aufruf ergänzt
  fehlende. Ein einzelnes Dokument, das das Portal nicht liefert, stoppt die übrigen nicht; der
  Ablauf bricht nur bei verlorener Sitzung oder nach 15 Fehlern in Folge ab. Die Meldung nennt
  die Gründe (z. B. „HTTP 404“ oder „kein PDF (text/html, 4568 B)“) und die Dokumentart.
- Ein Dokument wird nicht über die IDs des Portals erkannt (sie wechseln bei jeder Anmeldung),
  sondern über Art, Datum, Beschreibung, Programm und Sprache. Mehrere gleiche Einträge (z. B. drei
  Auftragsbestätigungen am selben Tag) bilden eine Gruppe; sie ist vollständig, wenn so viele PDFs
  gespeichert sind, wie das Portal auflistet. Sonst werden alle Einträge der Gruppe geladen, und
  jedes PDF belegt den Platz, dessen gespeicherter Inhalt es ist, sonst einen freien. Die
  Reihenfolge der Portalliste spielt dabei keine Rolle, auch nicht nach einem Teilerfolg.
- Das Portal bereitet manche Dateien erst vor und meldet zunächst „In Bearbeitung“; GiroCrab
  wartet kurz und fragt erneut.
- **Wo die Dokumente landen:** unter **Belege & PostBox** (dort per Suche „equateplus“ alle auf einmal). Sie werden nicht automatisch Umsätzen oder Aktivitäten zugeordnet.
- Ein Dokument wird dem Programm-Depot zugeordnet, wenn der im Dokument genannte Programmname
  zu genau einem Programm dieses Zugangs passt, sonst keinem Konto. Eine Zuordnung zu Umsätzen
  oder Aktivitäten gibt es nicht.
- Abgerufen werden nur die beiden Download-Dienste des Portals, nur mit einer Dokument-ID,
  nur auf den bekannten Portal-Servern; die Datei muss eine PDF-Kennung (`%PDF-`) in den ersten
  1024 Bytes haben, wie es das Format erlaubt (manche Dateien haben Vorspann-Bytes).
- Das Tempo bestimmt das Portal: kleine Bestätigungen kommen in Zehntelsekunden, größere
  Auszüge und Korrespondenz brauchen etwa 1 bis 2 Sekunden je Datei (ein Lauf mit 314 Dokumenten
  dauerte unter zwei Minuten). Im App-Log steht je Dokument eine Zeile mit Dokumentart,
  Dauer und Größe (ohne Namen oder Inhalte).

## Mehrere Programme: Auswahl und Abwahl

Beim ersten Abruf werden **alle** Programme als Depots übernommen. Welche Programme
dieser Zugang künftig abruft, steht unter **Einstellungen › Banken › Zugang bearbeiten ›
Kontenauswahl** (dieselbe Auswahl wie bei anderen Zugängen, #346):

- **Abgerufen** (Standard): Das Programm wird bei jedem Abruf aktualisiert.
- **Übersprungen**: Das Programm wird **archiviert und ausgeblendet** (nicht in der Seitenleiste, nicht
  in der Summe, nicht mehr abgerufen, keine Regeln). Bereits gespeicherte Positionen und
  Dokumente bleiben erhalten. Das Archiv-Symbol in der Seitenleiste zeigt archivierte Programme
  wieder an; wieder angewählt wird das Programm reaktiviert.
- Ein Programm, das erst später im Portal erscheint, wird beim nächsten Abruf standardmäßig
  übernommen.
- Die Programmsummen aller Programme werden weiterhin gemeinsam geprüft; ein fehlerhafter
  Snapshot wird auch dann als Ganzes abgewiesen, wenn einzelne Programme übersprungen sind.

## Prüfung

Schema und saldierte Mengen/Werte wurden gegen authentifizierte Portalantworten
von drei Programmen abgeglichen. Der Abruf der Bestände, die Auswahl der Programme und der Dokumentenimport
(314 PDFs, ein zweiter Aufruf meldet „Keine neuen Dokumente“) wurden in der App geprüft.
Automatisierte Tests verwenden ausschließlich erfundene Daten:

```sh
GIROCRAB_SKIP_SWIFT=1 cargo test -q -p girocrab-core --lib equateplus
node GiroCrabApp/Tools/test-equateplus.mjs
```
