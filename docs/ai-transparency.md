# 🦀 AI Transparency in GiroCrab · KI-Transparenz in GiroCrab

> **Living Lab:** *AI-enabled Transparency of AI Use in Software Creation Processes*
>
> DE: GiroCrab ist ein Open-Source-Finanzprogramm, das zum großen Teil in **hybrider Mensch-KI-Entwicklung** entsteht. Wir legen offen, *wo*, *wie* und *unter wessen Kontrolle* KI an einem Beitrag mitgewirkt hat, und werten das wissenschaftlich aus.
>
> EN: GiroCrab is largely built through **hybrid human–AI development**. We make transparent *where*, *how* and *under whose control* AI contributed to each change, and study this as research data.

---

## 1. Konzept: AI-for-AI-Transparency

**AI-for-AI-Transparency** heißt: Wir nutzen automatisierte (und optional KI-gestützte) Analyse, um sichtbar zu machen, wie KI an der Software beteiligt war. Die Transparenz entsteht dabei **nebenbei**, aus Signalen, die es ohnehin gibt (Commits, Git-Trailer, PR-Beschreibung, geänderte Dateien, Reviews). Niemand muss zusätzlich Formulare ausfüllen.

So sieht der Entwicklungsprozess von GiroCrab aus:

| Rolle / Role | Beispiel | Aufgabe |
|---|---|---|
| **Problem owner** | Nutzer:in (Issue), Maintainer | beschreibt das Problem und das gewünschte Verhalten |
| **Orchestration AI** | z. B. Gemini, Chat-Assistenten | zerlegt Aufgaben, schreibt Spezifikationen und Prompts |
| **Execution agent** | z. B. Claude Code | liest den Code, schreibt Code und Tests, führt Build und Tests aus |
| **Human steering** | Maintainer, Reviewer | gibt Architektur und Security vor, reviewt, entscheidet über den Merge |
| **Automated audit** | CI: `cargo fmt`, `clippy -D warnings`, `cargo test`, `swift build` | prüft maschinell |
| **Reality check** | Maintainer:in | testet von Hand gegen echte Bankportale (FinTS, Trade Republic, Amex …) |

Der Mensch behält die Verantwortung für Architektur, Sicherheit und den Merge. KI-Agenten arbeiten innerhalb dieser Leitplanken.

## 2. Taxonomie: 4 Stufen pro Beitrag (4-stage contribution taxonomy)

Jeder PR und jeder Commit wird diesen vier Stufen zugeordnet. Die **Transparency Card** zeigt pro Stufe, welche Evidenz es dafür gibt (✅) und wo keine gefunden wurde (⚪️).

| # | Stufe / Stage | Wer? | Evidenz, die automatisch erkannt wird |
|---|---|---|---|
| 1 | **Problem Framing & Intent** | User Issue / Maintainer | verknüpfte Issues (`Fixes #n`, `#n`), Abschnitt *Problem / Motivation / Kontext* im PR-Body, orchestrierende KI (`AI-Orchestrator:`) |
| 2 | **Architectural & Security Steering** | Mensch (Leitplanken) | PR-Kommentare von Menschen (keine Bots), verknüpfte Issues mit Diskussion, Abschnitte wie `## Entscheidung` / `## Abzustimmen` / `## Offene Fragen` im PR-Body, formale Reviews, `Human-Steering:`-Trailer, Commits nach dem ersten Feedback. Berührt ein PR die Security-Oberfläche, weist die Card darauf hin. Das ist eine Anforderung, keine Evidenz. |
| 3 | **Code & Test Generation** | AI Agent / Human-in-the-loop | `Co-Authored-By:` (z. B. Claude), `AI-Agent:` / `AI-Model:`-Trailer, Footer „Generated with Claude Code“, Branch-Präfix (`claude/`, `copilot/` …); keine Signale bedeutet *rein manuell* |
| 4 | **Verification & Audit** | CI + Mensch | geänderte Testdateien, neue `#[test]` / `@Test` / `func test…` im Diff, Test-Abschnitt im PR-Body, `Verification:`-Trailer (z. B. manueller Test gegen echtes Bankportal) |

**Security-Oberfläche** (sie verlangt immer ein menschliches Review):

| Tag | Pfade |
|---|---|
| `vault` | `girocrab-core/src/vault.rs` |
| `crypto-secrets` | `secret.rs`, `*crypto*`, `*cipher*`, `argon`, `zeroize` |
| `keychain` | `*Keychain*`, `VaultKeyManager.swift` |
| `connectors` | `girocrab-core/src/connectors/*` (Bank-Login, TAN, Tokens) |
| `cloud-sync` | `CloudSyncManager.swift`, `user_groups*` |
| `supply-chain` | `Cargo.toml`, `Cargo.lock`, `Package.swift`, `Package.resolved` |
| `ci-pipeline` | `.github/workflows/*` |
| `entitlements` | `*.entitlements`, `Info.plist` |

Die **Schichten (layers)** sind `core`, `core-connectors`, `ui` (`GiroCrabApp/`), `ci`, `build-packaging`, `scripts-tools`, `docs`, `legacy`, `other`.

## 3. Provenance-Format (Git-Trailer & PR-Metadaten)

Wir werten **nur strukturierte Signale** aus. Wenn in einem Text bloß das Wort „Gemini“ vorkommt, zählt das nicht als KI-Beteiligung, denn ein PR *über* Gemini ist kein PR *mit* Gemini.

### Git-Trailer (am Ende der Commit-Nachricht, optional auch im PR-Body)

```text
feat(connectors): Amex-Portal erkennt Fremdwährungsbuchungen

<Beschreibung>

AI-Orchestrator: Gemini 3 Pro (Aufgabenzerlegung, Prompt)
AI-Agent: Claude Code (Opus 5.5)
Human-Steering: Architektur – Parser bleibt in portal_import.rs, kein neuer HTTP-Client
Human-Steering: Security – keine Tokens im Log
Verification: cargo test; clippy -D warnings; manuell gegen echtes Amex-Portal (2026-11-12)
AI-Data-Policy: masked-schema-only
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

| Trailer | Stufe | Bedeutung |
|---|---|---|
| `Co-Authored-By:` | 3 | Standard-Trailer von Git/GitHub; KI-Agenten setzen ihn selbst |
| `AI-Agent:` / `AI-Model:` / `AI-Assisted:` / `Assisted-By:` / `Generated-By:` | 3 | ausführendes KI-Werkzeug bzw. -Modell |
| `AI-Orchestrator:` | 1+2 | orchestrierende KI (Planung, Prompts, Spezifikation), z. B. `AI-Orchestrator: Google Gemini` |
| `AI-Agency:` / `Review-Focus:` | Reflexion | Selbstauskunft der KI: was sie selbst entschieden hat, was ein Reviewer zuerst prüfen sollte |
| `Human-Steering:` | 2 | menschliche Vorgaben zu Architektur und Security |
| `Verification:` | 4 | wie geprüft wurde, z. B. Tests oder manueller Test gegen ein echtes Bankportal |
| `AI-Data-Policy:` | – | Bestätigung der Datenschutz-Garantie (siehe Abschnitt 4) |

**Erkannte KI-Werkzeuge:** Claude Code, Google Gemini, OpenAI Codex/ChatGPT, GitHub Copilot, Cursor, Windsurf, Cline, Aider, Perplexity, DeepSeek, Mistral, Llama/Ollama, Devin. Die Erkennung trennt zwei Rollen: **Orchestrierung/Framing** (Stufe 1+2: `AI-Orchestrator:` oder eine ausdrückliche Aussage im PR-Body wie „erstellt mit Hilfe von ChatGPT“) und **Code-Generierung** (Stufe 3: `Co-Authored-By`, `AI-Agent:`, `AI-Model:`, Footer, Branch-Präfix). Ein Werkzeug kann beide Rollen haben. Das bloße Nennen eines Namens im Text zählt weiterhin nicht.

Alle Trailer sind **freiwillig**. Ohne sie funktioniert die Erkennung über `Co-Authored-By`, den Footer, Branch-Präfixe, Reviews und Pfade trotzdem.

### PR-Metadaten

Die GitHub Action [`ai-transparency.yml`](../.github/workflows/ai-transparency.yml) schreibt für jeden PR:

1. die **🦀 AI Provenance & Transparency Card** in die Job-Zusammenfassung (`$GITHUB_STEP_SUMMARY`), und zwar immer, auch bei Fork-PRs,
2. einen PR-Kommentar. Er wird über den Marker `<!-- girocrab-ai-transparency -->` gefunden und bei jedem Push oder jeder Bearbeitung **aktualisiert**, nicht neu angelegt. Bei Fork-PRs mit schreibgeschütztem Token wird dieser Schritt still übersprungen.
3. Im Kommentar steht zusätzlich ein maschinenlesbarer Block `<!-- ai-provenance-json: {…} -->` mit den Features des PRs (Schema unten).

**Audit-Integrität („Trusted Verifier from main“):** Die Action läuft als `pull_request_target`, damit der Kommentar auch bei Fork-PRs erscheint. Sie checkt deshalb **nur den vertrauenswürdigen Basis-Commit** aus und führt nie Code aus dem PR aus. Titel, Body, Commits und Dateipfade liest sie über die GitHub-API als reine Daten. Ein PR kann also nicht beeinflussen, wie seine eigene Provenance bewertet wird. Änderungen am Workflow oder Skript wirken erst nach dem Merge.

### Drei Säulen der Transparenz

| Ebene | Inhalt | Quelle |
|---|---|---|
| **1 · Deterministische Telemetrie** | Trailer, KI-Werkzeuge mit Rolle, berührte Schichten, Security-Oberfläche, Test-Delta | Skript, ohne KI |
| **2 · KI-Selbstreflexion** | `### 🤖 AI Process Reflection` mit `- **Human-Steering:**`, `- **AI-Agency:**`, `- **Review-Focus:**` (oder gleichnamige Trailer) | PR-Body / Commits; **Selbstauskunft, ungeprüft** |
| **3 · Unabhängiger Prozess-Auditor (Meta-KI)** | 2–3 Sätze „🔍 KI-Prozess-Analyse (Meta-Audit)“: wie Mensch und Modelle zusammenwirkten, was die KI selbst entschied, was ein Reviewer prüfen sollte | LLM, optional |

**Ebene 3 (Provider, in dieser Reihenfolge):** `GEMINI_API_KEY` → Google Gemini (`gemini-2.5-flash`); sonst `GITHUB_TOKEN` → GitHub Models (`openai/gpt-4o-mini`, Workflow-Recht `models: read`); sonst `OPENAI_API_KEY` oder `ANTHROPIC_API_KEY`. Timeout 8 s. Ohne Schlüssel, offline, bei Fehlern oder mit `card --no-llm` entfällt der Abschnitt, und die Card erscheint wie sonst.

Das Modell bekommt **nur bereinigte Metadaten**: PR-Titel und -Body, Commit-Nachrichten, Dateipfade, Statistik und erkannte Werkzeuge. E-Mail-Adressen, URLs, IBANs, Token-artige Zeichenfolgen und HTML-Kommentare werden vorher entfernt, Diffs nie gesendet. Weil der PR-Text nicht vertrauenswürdig ist, behandelt der Prompt ihn als Daten, und die Antwort wird auf reinen Text ohne HTML, Links und @-Erwähnungen reduziert. Das Ergebnis ist eine KI-Einschätzung und kein Beweis. Fork-PRs bekommen Gemini nur, wenn das Repo-Secret `GEMINI_API_KEY` existiert, sonst greift GitHub Models.

## 4. Datenschutz-Garantie (Privacy guarantee)

GiroCrab verarbeitet Bankdaten. Deshalb gilt für **jede** KI-Nutzung im Projekt:

- **Keine echten Finanzdaten in Prompts.** Kontonummern/IBANs, Umsätze, Salden, Namen, Zugangsdaten, PINs/TANs, Session-Tokens und Kontoauszüge gelangen nie in einen Prompt, ein Issue, einen PR oder ein Log, das eine KI liest.
- **Maskierte Schema-Dumps statt Rohdaten.** Um unbekannte Bank-APIs zu verstehen, nutzen wir die eingebauten Diagnose-Dumps. Sie enthalten nur die *Struktur*. Ein Beispiel ist `value_hints` in [`portal_import.rs`](../girocrab-core/src/importers/portal_import.rs): Es gibt nur die Werte von Code-Feldern wie `…Code`, `…Status` oder `…Type` wörtlich aus, und auch nur bei Buchungscodes aus `[A-Z0-9_-]`. Datumsfelder erscheinen als maskierte Form, Beträge nur als Vorzeichen-Zählung. Felder aus dem Kundenprofil werden ganz weggelassen.
- **Demo-Daten** (`GIROCRAB_DEMO_SEED=1`) für Screenshots, Reproduktionen und Tests.
- **Die Transparenz-Werkzeuge** schicken keine Diffs an Dritt-Dienste. Nur der optionale Meta-Audit (Ebene 3) sendet bereinigten PR-Text und Metadaten an den konfigurierten Provider. Der Datensatz enthält nur abgeleitete Features: keine PR- oder Commit-Texte, keine Diffs, keine E-Mail-Adressen. `--pseudonymize` ersetzt auch Logins und Namen durch gesalzene Hashes.

## 5. Datensatz / Dataset (`tools/export-ai-provenance.py`)

```bash
tools/export-ai-provenance.py export                  # -> provenance-dataset.jsonl + Statistik
tools/export-ai-provenance.py export --pseudonymize   # Logins/Namen gehasht (Salt: $PROVENANCE_SALT)
tools/export-ai-provenance.py export --fetch-diffs    # Diffs nicht gemergter PRs per `gh pr diff`
tools/export-ai-provenance.py card --pr 125           # Card lokal ansehen
```

Voraussetzungen sind Python ≥ 3.9 (nur die Standardbibliothek), `git` und ein angemeldetes `gh`. Die Action und das Skript nutzen **denselben Klassifikator**, deshalb stimmen Card und Datensatz immer überein.

Jede Zeile der JSONL-Datei ist ein Datensatz mit `"schema": 2` und einem der folgenden Typen (`"schema": 2` ergänzt `ai.roles{orchestration,codegen}` und `reflection{present,section,human_steering,ai_agency,review_focus}`; im Datensatz nur als Wahrheitswerte, nie als Text):

- `"kind": "pr"`: `number`, `title`, `state`, `author`, `from_fork`, `created_at`, `merged_at`, `hours_to_merge`, `size{additions,deletions,files,commits}`, `ai{involved,tools{name:[evidence…]},ai_coauthored_commits,human_only_commits}`, `scope{layers,security_surface,security_files}`, `tests{test_files_changed,tests_added,tests_removed,pr_body_test_section}`, `steering{issue_refs,pr_body_framing_section,reviews,review_states,reviewers,comments,commenters,comments_by_others,linked_issues_with_discussion,pr_body_decision_section,commits_after_first_feedback,human_steering_trailers,human_steering_signal}`, `verification{trailers}`
- `"kind": "commit"`: alle Commits der First-Parent-Historie von `HEAD` mit `sha`, `author`, `authored_at`, `pr`, `ai`, `scope`, `tests`, `verification`

**Grenzen (limitations):**

- `tests_added` zählt neue Testfunktionen im Diff. Bei gemergten PRs kommt der Diff aus dem lokalen Klon (`merge^1..merge`), sonst ist der Wert `null`.
- Die Pfadanalyse berücksichtigt maximal 100 Dateien und 100 Commits pro PR (`files_truncated`).
- Lokale oder manuelle Tests gegen echte Bankportale sind nur sichtbar, wenn sie als `Verification:`-Trailer oder im Test-Abschnitt des PRs stehen.
- KI-Beteiligung ohne Trailer oder Footer, etwa Code aus einem Chatfenster, ist nicht erkennbar. Dafür gibt es den `AI-Agent:`-Trailer.

---

### EN summary

Every PR gets an automatic, key-less **AI Provenance & Transparency Card**. It maps the change onto four stages: *Problem Framing & Intent → Architectural & Security Steering → Code & Test Generation → Verification & Audit*. Detection relies only on structured signals: `Co-Authored-By` and the `AI-*`, `Human-Steering` and `Verification` trailers, the Claude Code footer, branch prefixes, reviews and file paths. No real financial data ever enters prompts; schema questions are answered with masked dumps (`value_hints`). `tools/export-ai-provenance.py export` turns the whole PR and commit history into a JSONL research dataset.
