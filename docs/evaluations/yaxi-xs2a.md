# Evaluierung: YAXI (XS2A) als konfigurationsfreie Bankanbindung

Issue: #144 – „YAXI Open Banking XS2A als konfigurationsfreie Alternative evaluieren“.
Interne Entscheidungsgrundlage, kein Code und keine Zusage.

> **Quellenlage.** Diese Evaluierung beruht auf dem öffentlichen Selbstbild des Anbieters
> (`yaxi.tech`), auf den gemeldeten Erfahrungen im Issue (Berliner Sparkasse) und auf dem
> Stand von GiroCrab selbst. Es gab **keinen Testzugang und keinen Probelauf**. Alles, was
> unten mit ⚠️ markiert ist, muss vor einer Umsetzung gegen die aktuelle Dokumentation und
> mit einem Sandbox-Zugang geprüft werden. Preise, Limits und Vertragsbedingungen sind
> bewusst nicht genannt.

## Ergebnis in Kürze

| Frage | Antwort |
|---|---|
| Passt YAXI zum Zero-Middleman-Prinzip? | **Nein, nicht als Standardweg.** Der Anbieter wäre als zugelassener Zahlungsdienstleister (TPP) Gegenstelle aller Bankdaten und Sitzungen. Das ist ein zusätzlicher Dritter zwischen Nutzer und Bank. |
| Löst es das Einrichtungsproblem? | **Teilweise.** Es entfiele die eigene App-Registrierung des Nutzers, aber nur, wenn GiroCrab selbst einen Vertrag mit dem Anbieter hält und dessen Schlüssel ausliefert (siehe §1). |
| Deckt es mehr Konten ab? | **Nein, eher weniger.** XS2A liefert in der Regel nur Zahlungskonten (§2). |
| Empfehlung | **Kein Connector, kein Umbau.** FinTS bleibt Standard, Enable Banking bleibt der PSD2-Weg. YAXI höchstens als später prüfbare, ausdrücklich zuschaltbare Option (§4). |

## 1. API- und Sitzungsmodell im Vergleich zum Zero-Middleman-Prinzip

### Was GiroCrab heute garantiert

GiroCrab hat keinen eigenen Server (README: „no server, no tracking“). Zugangsdaten,
Sitzungen und Umsätze liegen verschlüsselt im lokalen Tresor. Das Gerät des Nutzers spricht
direkt mit der Bank (FinTS) oder, bei PSD2, direkt mit der Enable-Banking-Schnittstelle
unter der **eigenen** Anwendungs-ID des Nutzers (Schlüssel im Tresor, siehe
`docs/plans/enable-banking-psd2.md`). GiroCrab als Projekt sieht keine Nutzerdaten und hält
keine Verträge über Nutzerdaten.

### Was ein XS2A-Aggregator grundsätzlich bedeutet

XS2A ist die PSD2-Schnittstelle der Bank für zugelassene Drittanbieter. Eine Anwendung kann
sie nicht ohne Zulassung (AISP/TPP, Zertifikat) selbst ansprechen. Ein Aggregator stellt
diese Zulassung bereit. Daraus folgt, unabhängig von Details des Anbieters:

| Aspekt | Folge |
|---|---|
| Datenpfad | Bank → Aggregator → App. Der Aggregator sieht Kontostände und Umsätze im Klartext, auch wenn er sie nicht speichert. |
| Sitzung / Einwilligung | Die Einwilligung wird beim Aggregator geführt und läuft nach PSD2-Regeln ab (üblicherweise bis zu 180 Tage, danach neue starke Kundenauthentifizierung). Wer sie widerruft oder sperrt, ist der Aggregator. |
| Identität | Der Nutzer erteilt die Einwilligung an den Aggregator, nicht an GiroCrab. Eine datenschutzrechtliche Rolle (Auftragsverarbeitung bzw. eigener Verantwortlicher) entsteht für das Projekt. |
| Ausfall / Abschaltung | Fällt der Dienst oder der Vertrag weg, funktionieren alle so angebundenen Konten nicht mehr. Der Tresor bliebe lesbar, die Synchronisierung nicht. |
| Schlüssel | Eine „konfigurationsfreie“ Lösung bedeutet, dass ein **gemeinsamer** Projekt-Schlüssel in jeder App-Kopie steckt (oder ein Relay-Server dazwischen liegt). Ein ausgeliefertes Geheimnis ist auslesbar; ein Relay-Server verletzt das Prinzip „kein Server“ direkt. |

⚠️ Zu klären gegen die aktuelle Anbieter-Dokumentation: genaue Sitzungsdauer und
Erneuerung, ob die Daten beim Anbieter zwischengespeichert werden, Region der Verarbeitung,
Auftragsverarbeitungsvertrag, und ob ein reiner Client-Modus ohne Relay des Projekts
überhaupt vorgesehen ist.

### Gegenüberstellung der Wege

| | FinTS 3.0 | Enable Banking (PSD2) | YAXI (XS2A) ⚠️ |
|---|---|---|---|
| Wer ist Gegenstelle? | Die Bank selbst | Enable Banking (TPP), mit eigener App-Registrierung des Nutzers | Der Aggregator (TPP) |
| Vertrag / Registrierung | Produktregistrierung des Projekts bei der DK (siehe §3) | Jeder Nutzer registriert kostenlos seine eigene App im Restricted Mode | Vertrag des Projekts mit dem Anbieter oder Registrierung je Nutzer (offen) |
| Server des Projekts nötig? | Nein | Nein | Nur wenn der Schlüssel nicht in der App liegen soll |
| Sichtbarkeit der Daten für Dritte | Keine | Enable Banking | Aggregator |
| Zugangsdaten der Bank | Lokal, verschlüsselt | Nur beim Bank-Login im Browser/Fenster der Bank | Nur beim Bank-Login |
| Einrichtungsaufwand für Nutzer | Mittel (Bankkennung, TAN-Verfahren) | Hoch (App anlegen, `.pem` importieren; durch Phase 3 geführt) | Niedrig, falls gemeinsamer Schlüssel |

Der einzige echte Vorteil von YAXI ist der niedrige Einrichtungsaufwand. Dieser Vorteil
wird mit genau dem erkauft, was GiroCrab abgrenzt.

## 2. Kontotyp-Einschränkung

Im Issue wurde berichtet, dass bei der Berliner Sparkasse nur ein Teil der Konten ankommt.
Das deckt sich mit der Natur von XS2A:

- **PSD2 verpflichtet Banken nur für Zahlungskonten**, also Girokonten. Tagesgeld,
  Kreditkarten, Darlehen und Depots sind im Pflichtumfang nicht enthalten. Ob eine Bank sie
  über XS2A freigibt, ist freiwillig und schwankt von Institut zu Institut.
- Sparkassen betreiben mit ihrer Plattform eine eigene Schnittstelle; welche Kontoarten
  dort über XS2A sichtbar sind, ist institutsabhängig. ⚠️ Für Berliner Sparkasse nicht von
  uns nachgemessen, nur aus dem Issue übernommen.
- Depotdaten gibt es über XS2A praktisch nicht; bei GiroCrab kommen sie aus FinTS-Segmenten
  oder aus eigenen Broker-Anbindungen (siehe `docs/DEPOT_DATENMODELL.md`).
- Die Auswirkung auf den Tresor: Konten würden **unvollständig** erscheinen. Ein Nutzer, der
  Giro- und Tagesgeld-Konto derselben Bank verbindet, sähe nur eines und müsste das zweite
  anders anbinden oder von Hand führen. Das widerspricht dem Anspruch, Vermögen
  vollständig abzubilden.

Zum Vergleich: Enable Banking hat dieselbe PSD2-Grundlage und damit dieselbe Grenze. Der
bestehende Connector gleicht das über `cash_account_type` (CACC, SVGS, CARD, LOAN) aus, soweit
die Bank mehr liefert. FinTS liefert dagegen, was die Bank über ihren eigenen Online-Zugang
anbietet, und ist bei Tagesgeld und Depot meist vollständiger.

⚠️ Zu prüfen: ob YAXI Kontoarten über die Pflichtkonten hinaus normalisiert oder nur
durchreicht.

## 3. Vergleich mit FinTS-Produktregistrierung und Enable Banking

### FinTS mit integrierter Produktregistrierung (seit v0.8.0)

GiroCrab liefert eine eigene, bei der Deutschen Kreditwirtschaft registrierte Produkt-ID
mit (`docs/fints-registrierung.md`). Nutzer müssen nichts registrieren; ohne die ID im Build
fragt die App nach der eigenen (kostenlos, 10–15 Werktage).

- **Konfigurationsfrei:** ja, für Nutzer der offiziellen Builds.
- **Zero-Middleman:** ja, direkte Verbindung zur Bank.
- **Kontoumfang:** der der Bank-eigenen Schnittstelle, in der Regel am vollständigsten.
- **Schwäche:** nicht jede Bank bietet FinTS noch an; manche haben es abgeschaltet oder
  verlangen Verfahren, die schwer abzubilden sind.

Das ist exakt das Ziel, das YAXI erreichen würde, ohne den Preis eines Dritten.

### Enable Banking (PSD2)

Deckt Banken ab, die kein FinTS anbieten (z. B. reine Mobilbanken). Die Einrichtung ist
dank Phase 3 geführt, bleibt aber mit eigener App-Registrierung und Schlüsseldatei
aufwendiger. Der Nutzer hält den Vertrag selbst; GiroCrab bleibt unbeteiligt.

### Einordnung von YAXI

YAXI würde als dritter Weg dasselbe Feld wie Enable Banking besetzen (PSD2-Banken ohne
FinTS), mit demselben Kontoumfang, aber mit niedrigerer Einrichtungshürde und höherer
Abhängigkeit. Gegenüber FinTS bringt es für Banken mit FinTS-Zugang keinen Gewinn.
Neu wäre nur: Banken, die Enable Banking nicht listet, aber der Aggregator bedient.
⚠️ Abdeckung nicht verglichen; dafür wäre ein Abgleich der Bankliste beider Anbieter nötig.

## 4. Empfehlung

1. **Keinen YAXI-Connector bauen.** Der Mehrwert (weniger Einrichtung) rechtfertigt weder
   den Dritten im Datenpfad noch einen Projekt-Vertrag mit Nutzerdatenbezug.
2. **Das Einrichtungsproblem dort lösen, wo es entsteht:** FinTS bleibt Standardweg und ist
   seit v0.8.0 für Nutzer konfigurationsfrei. Für Enable Banking die geführte Einrichtung
   weiter glätten (Phase 3 und Folgearbeiten), statt den Weg zu ersetzen.
3. **Kontoumfang bei PSD2 sichtbar machen:** in der Anbindung klar sagen, dass über PSD2
   nur Zahlungskonten garantiert sind und Tagesgeld, Karten und Depot bei Bedarf über FinTS
   oder einen eigenen Connector kommen. Das beantwortet die Beschwerde aus dem Issue ohne
   neuen Anbieter.
4. **Neubewertung nur unter drei Bedingungen:**
   - der Anbieter erlaubt einen Betrieb **ohne** Relay des Projekts und ohne Klartextzugriff
     des Projekts auf Nutzerdaten,
   - jeder Nutzer kann ihn mit **eigenem** Zugang betreiben (Muster Enable Banking), nicht
     über einen gemeinsamen Schlüssel in der App,
   - er deckt nachweislich Banken ab, die weder FinTS noch Enable Banking erreichen.
5. **Falls doch:** nur als ausdrücklich zuschaltbare Option mit eigener Einwilligung und
   deutlichem Hinweis auf den zusätzlichen Dritten, nie als Voreinstellung. Technisch
   hinter dem bestehenden `BankConnector`-Trait (`connectors/types.rs`), ohne UniFFI-Änderung.

## 5. Offene Punkte zum Nachprüfen

- Betriebsmodus: Schlüssel in der App, Relay oder Nutzer-eigener Zugang?
- Datenhaltung und Verarbeitungsregion beim Anbieter, Auftragsverarbeitung.
- Echte Kontoarten bei Berliner Sparkasse und zwei weiteren Instituten (Sandbox oder
  Testkonto), nicht nur aus dem Issue.
- Bankabdeckung gegenüber Enable Banking (Liste abgleichen).
- Sitzungsdauer und Erneuerung ohne erneutes TAN-Verfahren.

Diese Datei enthält keine echten Zugangsdaten, IBANs oder Schlüssel und soll auch keine
aufnehmen.
