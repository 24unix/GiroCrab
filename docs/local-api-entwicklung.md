# Externe Analyse und MCP-Adapter: Entwicklung (#136)

Für Entwicklerinnen und Entwickler: wie die lesende Schnittstelle und der MCP-Adapter zusammenhängen, wie der
Adapter in die App kommt und wie man alles lokal testet. Protokoll, Methoden und Einrichtung für Nutzer stehen
in [local-api.md](local-api.md).

## Aufbau

```
MCP-Client (KI-Assistent)
   │  startet als Kindprozess, JSON-RPC 2.0 über stdin/stdout (eine Nachricht pro Zeile)
   ▼
girocrab-mcp  (eigener Prozess, ohne Core, ohne Tresorzugriff)
   │  je Tool-Aufruf eine neue Verbindung, eine Anfrage {"v":1,"token":…,"method":…,"params":…}
   ▼
~/Library/Application Support/GiroCrab/local-api/girocrab.sock   (Unix-Socket, 0600, Ordner 0700)
   ▼
LocalApiServer im Core (läuft im App-Prozess)  →  Vault::local_api_socket_request  →  Tresor
```

- **Core** (`girocrab-core/src/local_api.rs`): Freigabeumfang (`ShareScope`), Schlüssel (nur SHA-256 gespeichert),
  die Methoden `info`, `accounts`, `categories`, `transactions`, `summary` und die Maskierung (`shared_text`).
- **Socket-Server** (`girocrab-core/src/local_api/server.rs`): `LocalApiServer` mit Lock-Datei
  (`girocrab.sock.lock`), Peer-UID-Prüfung, Grenzen (4 Verbindungen, 64 KiB, 10 s je Anfrage, 60 s Leerlauf) und
  Takt. Hält den Tresor nur `Weak`; nach `stop()` geht keine Antwort mehr raus.
- **App** (`GiroCrabApp/Sources/GiroCrabUI/AppModel+LocalApi.swift`): startet und stoppt den Server.
  `localApiTarget` legt fest, wann er laufen darf: eigener Tresor, entsperrt, angezeigt, nur macOS.
  Ausgelöst durch die `didSet` von `ownVault`, `demoActive` und `vaultState` (`reconcileLocalApiServer`). Alle
  Einstellungs- und Schlüsselaufrufe laufen über eine Warteschlange (`localApiJob`). Oberfläche:
  `ExternalAccessSettings.swift` (Einstellungen › Analyse).
- **MCP-Adapter** (`girocrab-mcp/`): eigenes Crate, hängt zur Laufzeit nur von `serde_json` ab (der Core ist
  nur Dev-Abhängigkeit für Tests).
  - `src/lib.rs`: Protokoll (`initialize`, `ping`, `tools/list`, `tools/call`), die fünf Tools mit
    Eingabeschemas (`TOOLS`), Fehlerarten (`Problem`), Verbindung zum Socket (`exchange`, Wiederholung bei
    `busy` und abgebrochener Verbindung).
  - `src/main.rs`: stdio-Schleife, Argumente, Schlüssel aus `GIROCRAB_API_TOKEN` oder `--token-file`, `--check`.

| Tool | Socket-Methode |
|---|---|
| `get_info` | `info` |
| `list_accounts` | `accounts` |
| `list_categories` | `categories` |
| `list_transactions` | `transactions` |
| `get_summary` | `summary` |

Fehler des Sockets (`locked`, `disabled`, `unauthorized`, `busy`, …) werden zu Tool-Ergebnissen mit `isError`
und einem Text, den der Assistent weitergeben kann. Ein unbekanntes Tool ist ein JSON-RPC-Fehler (-32602).
Unterstützte MCP-Versionen: 2025-06-18, 2025-03-26, 2024-11-05. Aktuelle Clients bieten zusätzlich 2025-11-25
an und akzeptieren 2025-06-18 als Antwort. Ein Client, der zuerst `server/discover` probiert (MCP 2026-07-28),
bekommt „method not found“ und fällt auf `initialize` zurück.

**Wenn sich das Socket-Protokoll ändert:** `girocrab-mcp/tests/against_the_app.rs` bindet den Adapter an den
Core. Die API-Version, jedes in den Schemas beworbene Argument und die Fehlercodes werden gegen den echten
Server geprüft. Ein umbenannter Parameter im Core lässt diesen Test scheitern, bis `TOOLS` in `lib.rs`
angepasst ist.

### Verbindungstest der App (`--check`)

`girocrab-mcp --check` fragt `info` ab und beendet sich mit einem Exit-Code je Ursache (siehe
`girocrab-mcp --help`). Mit `--json` druckt er eine Zeile `{"problem": …, "message": …}`; die Namen kommen aus
`Problem::name` in `lib.rs`. Ohne Schlüssel fragt er ohne Schlüssel an und meldet nur die Erreichbarkeit.

Die Schaltfläche „Verbindung testen“ startet das mitgelieferte Hilfsprogramm mit `--check --json`, so wie es ein
Client tut. Sie nutzt den Standard-Socket-Pfad des Hilfsprogramms und, solange er angezeigt wird, den gerade
erzeugten Schlüssel. Die App liest den Namen (`checkLocalApiConnection` → `LocalApiCheck`); ein unbekannter
Name zeigt die Meldung des Hilfsprogramms. Ein Abbruch (neuer Schlüssel, Einstellungen geschlossen) beendet den
Prozess.

## Bündelung

`package-macos-app.sh` baut das Hilfsprogramm und legt es nach `GiroCrab.app/Contents/Helpers/girocrab-mcp`:

1. `scripts/rust-toolchain.sh` wählt dieselbe Toolchain wie für den Core: rustups `cargo`/`rustc` statt eines
   Homebrew-Rust, die Architektur des Macs als Ziel (`MAC_TARGET`) und `MACOSX_DEPLOYMENT_TARGET=14.0`.
   `build-xcframework.sh` bindet dasselbe Skript ein.
2. `cargo build --release -p girocrab-mcp --target "$MAC_TARGET" --target-dir target/apple`
3. Kopie nach `Contents/Helpers/`.
4. `scripts/sign-app.sh` signiert jedes eingebettete Mach-O außerhalb von `Contents/MacOS` (mit Developer ID:
   Hardened Runtime und Zeitstempel), also auch das Hilfsprogramm. `scripts/notarize.sh` notarisiert es mit
   der App.

Die App findet das Hilfsprogramm über `AppModel.localApiHelperURL`. Zuerst sucht sie im Bundle, in
Entwickler-Builds (`DEBUG`) dann das neuere von `target/release/girocrab-mcp` und `target/debug/girocrab-mcp`
im Repository (`localApiDevelopmentHelper`, über `#filePath`). Builds ohne Hilfsprogramm zeigen in den
Einstellungen „nicht enthalten“. Das gilt etwa für das Xcode-Projekt, das `Contents/Helpers` nicht befüllt.
Läuft die App aus einer vorübergehenden Kopie (App Translocation), weist die Seite darauf hin, weil der Pfad
im Eintrag dann nach einem Neustart nicht mehr gilt.

Paketierung prüfen:

```
./package-macos-app.sh
file dist/GiroCrab.app/Contents/Helpers/girocrab-mcp          # arm64
codesign --verify --deep --strict dist/GiroCrab.app
dist/GiroCrab.app/Contents/Helpers/girocrab-mcp --version
```

## Lokal testen

### Automatische Tests

```
cargo test -q -p girocrab-mcp                 # Protokoll, Fehlerfälle, Ende-zu-Ende gegen den echten Socket-Server
cargo test -q -p girocrab-core --lib local_api # Methoden, Maskierung, Socket-Server
cd GiroCrabApp && swift test -q --filter LocalApiServerTests
```

- `girocrab-mcp/tests/protocol.rs`: der Adapter gegen eine Ersatz-App und das gebaute Programm über stdio
  (ungültiges UTF-8, unlesbare Schlüsseldatei).
- `girocrab-mcp/tests/against_the_app.rs`: gegen den echten `LocalApiServer` mit einem Demo-Tresor, inklusive
  ausgeschöpftem Verbindungslimit und den `--check`-Exit-Codes.
- `LocalApiServerTests`: Lebenszyklus in der App (Start, Sperren, Demo, Entsperren, Schlüssel). Die
  Zuordnung von `--check --json` wird mit einem Ersatz-Skript getestet und läuft auch in CI.
  `testTheConnectionTestRunsTheHelperAgainstTheSocket` braucht ein gebautes Hilfsprogramm
  (`cargo build -p girocrab-mcp`) und wird sonst übersprungen. Im Swift-Job von CI ist das immer der Fall.

Sockets in Tests liegen unter `/tmp/gc-…` bzw. `/tmp/gcm-…`, weil `sun_path` unter macOS nur 104 Byte fasst
und das übliche Temp-Verzeichnis zu tief liegt.

### Mit der laufenden App

1. Hilfsprogramm und App bauen und starten:
   ```
   cargo build --release -p girocrab-mcp
   cd GiroCrabApp && swift build -q && .build/debug/GiroCrabMac
   ```
   `--fresh-vault` startet mit einem leeren, eigenen Wegwerf-Tresor (Demo-Daten werden nie geteilt). Für Daten
   dort ein Konto anlegen oder eine Datei importieren. Mit dem eigenen Tresor nur Konten teilen, die ein
   KI-Assistent sehen darf.
2. Einstellungen › Analyse: Zugriff einschalten, Konten wählen, „Zugangsschlüssel erzeugen“. Unter „Für
   KI-Assistenten“ steht der Eintrag mit dem Pfad aus `target/`; „Verbindung testen“ sollte „Die Verbindung
   funktioniert“ melden.
3. Von der Kommandozeile:
   ```
   GIROCRAB_API_TOKEN=gcapi_… target/release/girocrab-mcp --check
   printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
     '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_info"}}' \
     | GIROCRAB_API_TOKEN=gcapi_… target/release/girocrab-mcp
   ```
   Den Socket ohne Adapter ansprechen (`-w 1` beendet `nc` nach der Antwort; sonst wartet es, bis der Server
   die ruhende Verbindung nach einer Minute schließt):
   ```
   printf '{"v":1,"token":"gcapi_…","method":"info"}\n' | nc -U -w 1 "$HOME/Library/Application Support/GiroCrab/local-api/girocrab.sock"
   ```

### Mit einem echten MCP-Client

Das offizielle MCP-Python-SDK (Paket `mcp`; getestet mit 2.3.0) in einer Wegwerf-Umgebung:

```
python3 -m venv /tmp/mcp-venv && /tmp/mcp-venv/bin/pip install -q mcp
```

```python
import asyncio, json, os
from mcp import Client, StdioServerParameters

async def main():
    server = StdioServerParameters(command="target/release/girocrab-mcp",
                                   env={"GIROCRAB_API_TOKEN": os.environ["GIROCRAB_API_TOKEN"]})
    async with Client(server) as c:          # mode="auto": probiert server/discover, dann initialize
        print([t.name for t in (await c.list_tools()).tools])
        r = await c.call_tool("get_summary", {"date_from": "2026-01-01", "date_to": "2026-12-31"})
        print(r.is_error, json.loads(r.content[0].text))

asyncio.run(main())
```

Oder den Eintrag aus den Einstellungen in die MCP-Konfiguration des eigenen Agenten übernehmen. Was ein
KI-Assistent abruft, geht an dessen Anbieter, deshalb dafür einen Tresor mit Testdaten nehmen.

### Fehlersuche

- **„nicht erreichbar“**: App läuft nicht, ist gesperrt, zeigt die Demo oder der Zugriff ist aus. Steht der
  Status auf „Nicht gestartet: …“, nennt er die Ursache (z. B. eine zweite GiroCrab-Instanz am selben Socket).
- **Schlüssel abgelehnt**: Der Schlüssel wird nur direkt nach dem Erzeugen angezeigt; ein neuer ersetzt den alten.
- **Socket-Pfad zu lang**: `--socket` bzw. `GIROCRAB_API_SOCKET` auf einen kurzen Pfad legen.
- Der Adapter schreibt Hinweise nur nach stderr, stdout gehört dem Protokoll. Viele Clients zeigen stderr im
  Log ihres MCP-Servers.
- Nach einem Absturz kann die Socket-Datei liegen bleiben. Der nächste Start erkennt sie über
  `girocrab.sock.lock` als verwaist und ersetzt sie.
