# GiroCrab für Windows

Die Windows-App (`GiroCrabWindows/`) nutzt denselben Rust-Kern wie die macOS-App. Sie läuft auf
Windows 10/11 (x64).

## Installation

Aus den [Releases](https://github.com/GiroCrab/GiroCrab/releases) gibt es zwei Pakete:

| Datei | Inhalt |
| --- | --- |
| `girocrab-windows-x86_64-setup.exe` | Installer: Startmenü-Eintrag, optional Desktop-Verknüpfung, Deinstallation über „Apps & Features“. Installiert ohne Administratorrechte nach `%LOCALAPPDATA%\Programs\GiroCrab` (auf Wunsch für alle Benutzer). |
| `girocrab-windows-x86_64.zip` | Portabel: `girocrab.exe`, `THIRD_PARTY_NOTICES.md`, `README-Windows.txt`. Entpacken und starten. |

`SHA256SUMS.txt` enthält die Prüfsummen; in PowerShell:
`Get-FileHash .\girocrab-windows-x86_64-setup.exe -Algorithm SHA256`.

Ein Update ist ein erneutes Ausführen des Installers (gleiche Anwendungs-ID, die alte Version wird
ersetzt). Die Deinstallation lässt deine Daten stehen (siehe unten).

## SmartScreen-Hinweis (unsignierte Builds)

Die Windows-Pakete sind derzeit nicht mit einem Code-Signing-Zertifikat signiert. Windows
SmartScreen zeigt deshalb beim ersten Start „Der Computer wurde durch Windows geschützt“:

1. „Weitere Informationen“ wählen.
2. „Trotzdem ausführen“ wählen.

Vergleiche vorher die SHA-256-Summe der Datei mit `SHA256SUMS.txt` aus dem Release. Wer lieber
selbst baut: `cargo build --release --manifest-path GiroCrabWindows/Cargo.toml`
(Rust-Toolchain, MSVC Build Tools).

## Tresor und Schlüssel

- Der Tresor ist eine mit SQLCipher verschlüsselte Datei: `%LOCALAPPDATA%\GiroCrab\vault.sqlite`.
  Der Demo-Modus nutzt `demo-vault.sqlite` im selben Ordner.
- Der Schlüssel liegt in der Windows-Anmeldeinformationsverwaltung (Credential Manager, Eintrag
  `de.girocrab.vault`) deines Benutzerkontos. Ohne diesen Eintrag lässt sich der Tresor nicht öffnen:
  Sicherungen des Ordners funktionieren daher nur zusammen mit demselben Windows-Konto.
- Bankdaten, PIN und TAN werden nie im Klartext gespeichert; PIN und TAN nur im Speicher gehalten.
- Beim Deinstallieren bleiben Tresor und Schlüssel erhalten. Zum vollständigen Entfernen den Ordner
  `%LOCALAPPDATA%\GiroCrab` löschen und den Credential-Manager-Eintrag entfernen.

## Bankabruf

- **FinTS/HBCI** (PIN/TAN): Bank über Namen oder BLZ suchen, Zugangskennung eingeben. PIN und TAN
  werden beim Abruf in einem Dialog abgefragt (Push-TAN, chipTAN, photoTAN).
- **PSD2-Anbindung über den Browser**: Die Bank öffnet sich im Standardbrowser; die Adresse oder der
  Code der Rückleitung wird in den Dialog eingefügt.
- **Import**: Umsatzdateien (CSV, XML/CAMT, MT940) über „Importieren …“ oder `Strg+I`.
- **Demo-Modus**: fiktive Konten ohne Netzwerk, zum Ausprobieren.

Welche Banken und Verfahren verfügbar sind, richtet sich nach der signierten Bankenrichtlinie
(`docs/banking-policy.md`); sie kann Anbindungen nur einschränken.

## Konten und Kategorien

- Seitenleiste: „Neues Konto“ legt ein Konto ohne Bankanbindung an, „Bearbeiten“ ändert Name und
  Farbe, archiviert oder löscht es. Gelöscht werden kann nur ein archiviertes Konto, und erst nach
  einer zweiten Bestätigung.
- „Kategorien“: anlegen (auch als Unterkategorie), umbenennen, Farbe wählen, löschen. Beim Löschen
  werden Unterkategorien und deren Regeln entfernt; die Umsätze bleiben unkategorisiert.

## Tastenkürzel

| Kürzel | Aktion |
| --- | --- |
| `Strg+F` | Suchfeld fokussieren |
| `Strg+L` | Tresor sperren |
| `Strg+R` / `F5` | Konten abrufen |
| `Strg+I` | Umsätze importieren |
| `Strg+N` | Neue SEPA-Überweisung |
| `Esc` | Offenen Dialog schließen |

## Pakete selbst bauen

Auf Windows, nach `cargo build --release --manifest-path GiroCrabWindows/Cargo.toml`:

```powershell
pwsh scripts/package-windows.ps1     # schreibt dist/: zip, Installer, SHA256SUMS.txt
```

Der Installer benötigt [Inno Setup 6](https://jrsoftware.org/isinfo.php) (`iscc`); das Skript
installiert es bei Bedarf über Chocolatey. CI baut die Pakete bei jedem Pull Request
(`windows-app`) und hängt sie bei einem Tag `v*` an den Release-Entwurf (`release.yml`).
