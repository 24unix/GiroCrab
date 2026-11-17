# Advanzia-Konnektor

Der Konnektor unterstützt Kreditkarten mit Zugang über `https://mein.advanzia.com/`.
Die Unterstützung richtet sich nach dem verwendeten Portal, nicht nach dem Namen
auf der Karte. Andere Advanzia-Portale sind nicht abgedeckt.

## Funktionsumfang

- Ersteinrichtung mit Benutzername, Passwort und Auswahl SMS oder Advanzia-App.
- Optionale lokale Passwortspeicherung im Apple-Schlüsselbund.
- Derselbe Hintergrundablauf bei Einrichtung und späteren Abrufen.
- Native Eingabe eines SMS-Codes beziehungsweise Hinweis auf die App-Freigabe.
- Explizit zugeordnetes Kreditkartenkonto, Bankkontostand und Kartenumsätze.
- Stabile Buchungskennungen und konservative Behandlung von Vormerkungen.

PDF-Monatsabrechnungen und mehrere Karten innerhalb eines Logins gehören nicht
zu diesem Stand. Die Browseroberfläche ist für macOS und iOS implementiert;
die übrigen Oberflächen bekommen dadurch noch keinen Advanzia-Anmeldeablauf.
Der Konnektor bleibt in der Bankmatrix als `TestingWanted` gekennzeichnet.

## Architektur und Sicherheitsgrenzen

`connectors/advanzia.rs` stellt einen Browseradapter für `BankConnector` bereit.
Der normale Rust-Anmeldepfad signalisiert `BrowserLoginRequired`. Die Swift-Oberfläche
führt die WebKit-Anmeldung aus und importiert anschließend über
`Vault.import_advanzia_capture` ausschließlich ausgewählte Umsatzfelder und einen
geprüften skalaren Bankkontostand. Ein fehlender Kontostand wird nicht geschätzt.
Ein gemeldeter Nullsaldo ist ein gültiger Bankkontostand.

`AdvanziaWorkflow` besitzt den Ablauf unabhängig vom sichtbaren Dialog. Die
WebKit-Ansicht bleibt im Hintergrund eingebettet. Die vollständige Bankseite
öffnet sich nur nach ausdrücklicher Auswahl als Ausweichmöglichkeit. Der Workflow
übernimmt Daten nach Anmeldung und Kontozuordnung automatisch; ein fehlgeschlagener
Import wird nicht in einer Schleife wiederholt.

Jeder Zugang erhält im verschlüsselten Tresor einen zufälligen Profil-Namensraum.
Dieser trennt WebKit-Sitzungen und Schlüsselbundeinträge. Ein geänderter Benutzername
wechselt den Namensraum. Tresorwechsel und Abbruch beenden den laufenden Workflow.
Passwörter bleiben lokal, sind nicht synchronisierbar und werden nicht in den
Rust-Konnektor, Umsatzdaten oder Protokolle übernommen. Tests verwenden einen
injizierten Schlüsselbund im Arbeitsspeicher.

Die Automatisierung prüft die exakten HTTPS-Ursprünge `id.advanzia.com` für die
Anmeldung und `mein.advanzia.com` für Umsätze. Ein SMS-Code wird ausschließlich
nach manueller Eingabe an ein eindeutig erkanntes Formular übergeben. Er wird
nicht ausgelesen, gespeichert oder protokolliert. Der zusätzliche Abruf innerhalb
der angemeldeten Sitzung verwendet GET und folgt keinen Weiterleitungen.

Neue Zugriffe sind die WebKit-Verbindung zu diesen Bankdiensten, ein lokaler
WebKit-Datenspeicher und der lokale Apple-Schlüsselbund. Neue Prozesse und neue
Paketabhängigkeiten werden dafür nicht eingeführt.

## Kontozuordnung, Duplikate und Vormerkungen

Das erste Bankkonto wird ausdrücklich einem neuen oder geeigneten vorhandenen
Kreditkartenkonto zugeordnet. Unterschiedliche Bankkennungen dürfen nicht
unbemerkt auf dasselbe Konto zeigen. Bekannte Konto- und Buchungskennungen aus
früheren experimentellen Versionen werden bei eindeutig bestätigter Zuordnung
erhalten. Gelöschte Buchungen und widersprüchliche Kennungen werden berücksichtigt.
Die Duplikaterkennung beruht nicht allein auf Betrag, Datum und Händler.

Vormerkungen beeinflussen einen gemeldeten Bankkontostand und dessen laufende
Salden nicht. Ein fehlender Eintrag in einem unvollständigen Umsatzfenster löscht
keine Vormerkung. Die automatische Ablösung setzt eine eindeutige Zuordnung in
beiden Richtungen voraus; Datum, Betrag und normalisierter Händler dienen hierbei
nur der konservativen Ablösung einer Vormerkung, nicht als Buchungsidentität.

Bei der Ablösung bleiben Kategorie, Notiz und Prüfmarkierung erhalten, soweit
die gebuchte Zeile noch keinen entsprechenden Wert besitzt. Tags werden
zusammengeführt. Eine bestehende Kategorie der gebuchten Zeile wird nicht
überschrieben. Splits oder Dokumente verhindern die automatische Ablösung.
Mehrdeutige Fälle bleiben zur Prüfung sichtbar. Alle Änderungen erfolgen in
derselben Importtransaktion.

## Tests ohne Bankverbindung

Alle automatisierten Advanzia-Tests verwenden erfundene Daten:

```sh
GIROCRAB_SKIP_SWIFT=1 cargo test -q -p girocrab-core advanzia
node --test scripts/test-advanzia-portal.cjs
cd GiroCrabApp
swift test -q --filter Advanzia
```

Vor Swift-Tests müssen die generierten UniFFI-Bindings zum Rust-Stand passen
(`./build-xcframework.sh --check --need-ios`). WebKit-Tests laden ausschließlich
lokale Testseiten. Abgedeckt sind unter anderem Ursprungskontrolle,
Anmeldezustände, manuelle SMS-Übergabe, App-Auswahl, automatische Übernahme,
Schlüsselbundfehler, Profiltrennung, explizite Kontozuordnung, Nullsaldo,
Kennungskompatibilität, Tombstones und Metadaten bei der Ablösung von Vormerkungen.

Die Offline-Tests beweisen keine dauerhafte Kompatibilität mit dem Bankportal.
Änderungen am Portal können Anpassungen an Erkennung und Skripten erfordern.
