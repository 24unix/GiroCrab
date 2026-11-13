# FinTS-Produktregistrierung

GiroCrab hat eine eigene Produktregistrierung bei der Deutschen Kreditwirtschaft (DK).
Die ID geht nur im Segment HKVVB an die Bank. Sie steht **nie** im Quellcode.

## Woher die ID kommt (Rangfolge)

| Einstellung `fints.product_id_mode` | Verhalten |
|---|---|
| `builtin` | GiroCrabs eingebaute ID; fehlt sie im Build, die eigene |
| `own` | nur die eigene ID (Einstellung `fints.product_id`) |
| leer (noch nicht entschieden) | die eigene, falls vorhanden, sonst die eingebaute |

Die eigene ID bleibt beim Wechsel immer im Tresor. Lehnt eine Bank die benutzte ID ab,
bietet die App die jeweils andere an. Es gibt keinen stillen Rückfall.

## Release-Builds (Maintainer)

Der Schlüssel liegt im Schlüsselbund des Release-Macs (Service „GiroCrab FinTS Product ID“):

```bash
scripts/fints-registrierung.sh set      # einmalig, Eingabe verdeckt
scripts/fints-registrierung.sh status   # "available" oder "missing", nie der Wert
```

`scripts/notarize.sh` liest ihn und kompiliert ihn über `girocrab-core/build.rs` ein
(maskiert, damit er nicht per `strings` auffindbar ist; das ist Verschleierung, kein
Schutz gegen Auslesen). Danach prüft `fints-registrierung.sh check-app`, dass die ID im
Binary steckt und nicht als Klartext lesbar ist.

- **Stable:** bricht ohne ID ab (nur für Testläufe: `ALLOW_NO_PRODUCT_ID=1`).
- **Beta und Nightly:** bauen ohne ID mit Warnung; die App weist darauf hin.
- Beta, Nightly und Stable werden lokal gebaut. Die CI baut ohne ID und braucht kein Secret.
- Die ID in Logs ausgeben (`set -x`, `echo`) ist tabu. `fints-registrierung.sh scan` (Hook
  `pre-push` und CI) schlägt an, wenn eine ID-förmige Zuweisung eingecheckt wird.

## Entwickler und Forks

Ohne die Variable baut alles wie bisher; die App fragt dann nach der eigenen Registrierung.
Eigene ID: kostenlos über fints.org › Hersteller › Produktregistrierung (10–15 Werktage),
in den Einstellungen eintragen. Für Debug-Builds gibt es zusätzlich einen Override zur
Laufzeit:

```bash
GIROCRAB_FINTS_PRODUCT_ID_OVERRIDE=<eigene ID> swift run
```

Der Override wirkt nur in Debug-Builds und ersetzt die Einstellung, ohne sie zu ändern.

## Schlüsselwechsel

Die DK kann eine neue ID ausstellen. `fints-registrierung.sh set`, neu bauen, releasen:
Nutzer im Modus „builtin“ erhalten sie mit dem Update. Bei einem Leak vorher die DK informieren.
