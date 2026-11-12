# Release-Integrität (Überwachung)

Ein geplanter Workflow (`.github/workflows/release-integrity.yml`, alle 6 Stunden
und manuell startbar) prüft, ob das, was unter
`https://github.com/<repo>/releases/latest/download/` (Appcast, Disk-Images) und
unter `https://raw.githubusercontent.com/<repo>/main/policy/` (Sicherheitssperre)
veröffentlicht ist, noch echt ist. Er braucht **keine Geheimnisse**, nur die öffentlichen Schlüssel aus dem
Repo, und läuft deshalb auch in Forks (gegen deren eigene Releases).

## Was geprüft wird

| Datei | Prüfung |
|---|---|
| `appcast.xml` | erreichbar; eingebettete Sparkle-Signatur gegen `scripts/sparkle-public-ed-key.txt` (während eines Schlüsselwechsels auch `scripts/sparkle-previous-public-ed-key.txt`); höchstens ein Eintrag pro Kanal |
| jeder Appcast-Eintrag | zeigt auf ein Release-Asset **dieses** Repos (stabiles Release, Beta-Pre-Release oder `nightly`), das existiert; Länge und `sparkle:edSignature` passen zum heruntergeladenen Disk-Image |
| `banking-policy.json` + `.sig` | erreichbar; Signatur gegen `BankingPolicy.publicKeys`; `sequence` nie kleiner als beim letzten Lauf (gemerkt im Actions-Cache) |

Prüfsummen eignen sich nicht: Jeder Beta- und Nightly-Lauf schreibt den Feed neu.
Geprüft werden deshalb Signaturen und der Bezug auf echte Releases.

Ein Teil wird übersprungen, solange sein Schlüssel nicht eingetragen ist
(Sparkle: `scripts/sparkle-public-ed-key.txt` fehlt; Banking-Policy: Platzhalter in
`BankingPolicy.publicKeys` oder Datei nicht vorhanden).

Wurde eine Datei **noch nie** veröffentlicht (kein Release mit In-App-Updates,
Policy noch nicht aktiviert), ist ein 404 nur ein Hinweis. Sobald ein Lauf sie
einmal gesehen hat (gemerkt im Actions-Cache), ist ein späteres 404 ein Fund.

## Meldungen

Abweichungen landen in **einem** offenen Issue mit dem Label `release-integrity`
(wird bei Bedarf angelegt). Weitere Funde kommen als Kommentar dazu, statt bei
jedem Lauf ein neues Issue zu öffnen. Der Workflow-Lauf schlägt dann fehl. Das
Issue schließt man von Hand, sobald die Ursache geklärt ist.

Typische Ursachen und was zu tun ist:

* **Signatur stimmt nicht / Asset fehlt oder passt nicht:** Release-Assets
  wurden ersetzt. Audit-Log der Organisation prüfen (wer hat Assets geändert?).
  Bei Manipulation: Schlüsselwechsel und Sicherheitsmeldung, siehe
  `docs/auto-updates.md` („Schlüsselwechsel“) und `docs/banking-policy.md`.
* **`banking-policy.json` nicht erreichbar:** `policy/` wurde auf `main`
  gelöscht oder verschoben. Mit `git log -- policy/` den letzten Stand finden
  und wiederherstellen.
* **`sequence` gesunken:** Jemand hat eine ältere, korrekt signierte Datei
  eingespielt. Apps nehmen sie nicht an, aber der Commit selbst ist verdächtig
  (`git log -- policy/`).
* **Direkt nach einem Sparkle-Schlüsselwechsel:** Bis
  `scripts/sparkle-public-ed-key.txt` und `scripts/sparkle-previous-public-ed-key.txt`
  committet sind, meldet die Prüfung den alt signierten Feed. Erst committen,
  dann veröffentlichen.

## Lokal ausführen

```bash
scripts/verify-release-integrity.sh                         # gegen GiroCrab/GiroCrab
scripts/verify-release-integrity.sh --repo jacboy/GiroCrab  # gegen einen Fork
scripts/verify-release-integrity.sh --base http://127.0.0.1:8766 --state /tmp/s.json   # Testdaten
```

`--base` ersetzt `…/releases/latest/download`, die Policy-Adresse und das
erlaubte Präfix der Disk-Images durch einen lokalen Server oder Ordner. Ausgabe: `ok: …`-Zeilen,
`FINDING: …` bei Abweichungen; Exit-Code 1 bei Funden.

## Grenzen

* Die Prüfung erkennt Manipulationen **nach** dem Veröffentlichen, sie verhindert
  sie nicht. Davor schützen die Signaturen in der App selbst.
* Ein Angreifer mit Schreibzugriff auf das Repo könnte auch die öffentlichen
  Schlüssel im Repo ändern. Deshalb: geschützte Branches und Tags (Rulesets), 2FA,
  und Änderungen an `scripts/sparkle-*.txt` und `BankingPolicy.swift` im Review
  besonders prüfen.
* Jede Änderung an Release-Assets erscheint zusätzlich im Audit-Log der
  Organisation.
