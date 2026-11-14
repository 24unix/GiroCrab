# README- und Website-Sync

`scripts/sync-docs-and-website.sh` hält `README.md` (dieses Repo) und `GiroCrab/girocrab.de` mit dem
neuesten **stabilen** Release und `girocrab-core/src/connectors/catalog.rs` synchron. Die Transformationen
stehen in `scripts/sync_docs.py` (Tests: `python3 -m unittest scripts/test_sync_docs.py`).

## Was synchronisiert wird
- Versionsangaben: Download-Button (`docs/assets/download-macos.svg` bzw. `img/download-macos.svg` + Alt-Text),
  „✓ Version vX“, „Aktuelle Version / Current version“, Meta-Description der Website.
- Der Block zwischen `<!-- sync:connectors:start -->` und `<!-- sync:connectors:end -->` (README DE + EN,
  Website `#banken`): die Banken- und Funktionsmatrix aus `BANK_MATRIX` in `catalog.rs` (Schnittstelle, Funktionsumfang,
  Teststatus ✅ verifiziert / 🧪 Test gesucht / ⚠️ mit Einschränkungen, Issue-Links) plus Anzahl der Institute in
  `girocrab-core/data/fints_directory.tsv`. Neue oder geänderte Banken also in `BANK_MATRIX` pflegen (ein Test
  erzwingt eine Zeile pro `ConnectorKind`); die Website-Tabelle braucht kein JS und keine Inline-Styles (CSP).
- Alles andere (Prosa, Screenshots, „Neu in v…“) bleibt Handarbeit.

## Aufruf
```bash
scripts/sync-docs-and-website.sh --dry-run            # Standard: nur Diffs anzeigen
scripts/sync-docs-and-website.sh --push               # Website: Commit auf main; README: Branch chore/sync-docs + PR
scripts/sync-docs-and-website.sh --push --version v0.6.2 [--readme-only|--site-only]
```
Das README wird in einem temporären Worktree von `origin/main` bearbeitet (Arbeitsverzeichnis bleibt unberührt,
`BASE_REF=<ref>` überschreibt das). Ohne Diff passiert nichts.

## Automatik
- `release.yml`, Job `sync-docs-website`: bei `release: published` (nur stabile Releases). `notarize.sh --upload`
  veröffentlicht lokal mit dem eigenen `gh`-Login, das löst den Workflow aus.
- `nightly.yml`, Job `sync-docs-website`: täglich und per `workflow_dispatch` (Input `sync_docs_and_website`,
  Standard `true`).

## Einmalige Einrichtung: `WEBSITE_DEPLOY_TOKEN`
1. Fine-grained PAT erstellen (Resource owner `GiroCrab`), Repository-Zugriff auf `girocrab.de`
   (**Contents: Read and write**) und – damit der README-PR Checks auslöst – auf `GiroCrab`
   (**Contents** + **Pull requests: Read and write**).
2. Als Actions-Secret `WEBSITE_DEPLOY_TOKEN` im Repo `GiroCrab/GiroCrab` hinterlegen.
3. Ohne Secret: README-PR läuft mit `GITHUB_TOKEN` (Repo-Einstellung „Allow GitHub Actions to create pull
   requests“ nötig; Checks starten dort nicht automatisch), die Website wird mit Warnung übersprungen. Dann
   lokal: `./scripts/sync-docs-and-website.sh --push`.
