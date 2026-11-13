# Mitteilungen (Announcements)

News from the project that do not depend on a release: a new bank, a change in
how GiroCrab is distributed, a survey. They appear **without a new release or
update**: the app reads a signed file from the repository.

## What users see (Apple HIG)

- One quiet **banner** above the booking list. No alert, no sheet at launch,
  nothing that blocks the window.
- **At most one** banner at a time; none while a security lock (banking
  policy) is shown.
- Always **dismissible** (`xmark`, VoiceOver: "Mitteilung ausblenden"). A
  dismissed announcement never returns.
- "Mehr erfahren" opens a **sheet** with the full text (OK = default button,
  Esc closes). Links open only on an explicit click.
- Everything that applies stays readable in **Hilfe › Mitteilungen …**, also
  what was dismissed.
- **Settings › Mitteilungen**: one switch (on by default) turns the feature
  and its network request off. Security locks are not announcements and are
  unaffected.
- No red, no sound, no Dock bounce, no badge, no notification.

## Privacy

A plain HTTPS GET of `policy/announcements.json` and `.sig` from
raw.githubusercontent.com, at most every 6 hours, without cookies, cache,
identifier or User-Agent (same fetcher as the banking policy). Failures stay
silent. No tracking, no counting who read what.

## File format (schema 1)

`policy/announcements.json` plus detached Ed25519 signature
`policy/announcements.json.sig` over the exact bytes (same keys as
`banking-policy.json`, see `banking-policy.md`).

```json
{
  "schema": 1,
  "sequence": 7,
  "announcements": [{
    "id": "2026-11-example",
    "severity": "info",
    "from": "2026-11-15", "until": "2027-01-31",
    "distribution": ["developer-id", "mac-app-store"],
    "minVersion": null, "maxVersion": "0.9.99",
    "title":   { "de": "Titel", "en": "Title" },
    "summary": { "de": "Ein bis zwei Sätze.", "en": "One or two sentences." },
    "body":    { "de": "Langer Text, nur **fett**, *kursiv*, [Links](https://…)", "en": "…" },
    "link": "https://github.com/GiroCrab/GiroCrab/discussions/…"
  }]
}
```

| Field | Meaning |
|---|---|
| `id` | Stable; the "dismissed" state is stored per `id`. Never reuse. |
| `severity` | `info` (default) or `important` (accent-coloured symbol only). Unknown = `info`. |
| `from` / `until` | UTC dates, optional. |
| `distribution` | Optional: `developer-id`, `mac-app-store`, `ios`. Use it for anything that must not be shown in the App Store build (e.g. payment or donation hints, Guideline 3.1.1). |
| `minVersion` / `maxVersion` | Optional, compared like Sparkle. |
| `title`, `summary`, `body` | Language code → text. Fallback `en`. Inline Markdown only. |
| `link` | Optional, https only. |

The first applicable, not yet dismissed entry is the banner, so put the most
important one first. `sequence` must only increase (anti-rollback).

The file contains text and links only, no code, and cannot unlock or add
functions (App Review Guidelines 2.5.2 / 2.4.5 (iv)).

## Writing guidelines (so we do not nag)

- Only things users need or clearly want to know. No "rate us", no sales
  pressure, no repeats under a new `id`.
- Title ≤ 8 words (`check` allows 10), summary ≤ 2 sentences, sentence case, no exclamation marks.
- Set `until` for everything time-bound.

## Publishing

Draft in a file of your own (start from `policy/announcements.example.json`;
the example is never loaded by the app, only `announcements.json` is).

```bash
scripts/announcements.sh check my-draft.json     # validate only
scripts/announcements.sh publish my-draft.json   # sequence+1, sign, verify, commit
scripts/announcements.sh verify                  # check what is published
scripts/announcements.sh clear                   # withdraw everything
```

`publish` uses the banking-policy key from the release Mac's keychain, sets
`sequence` above the published one, verifies the signature and **commits**
`policy/announcements.json` + `.sig`. It never pushes: push the commit to
`main` or open it as a pull request (reviewable). The app picks it up within
six hours, no release needed. `check` also enforces the writing guidelines:
title ≤ 10 words, summary ≤ 2 sentences, German and English, `https` links,
an `until` date for `important`.

Test locally with a Debug build:
`GIROCRAB_ANNOUNCEMENTS_KEY=<base64 test key> GIROCRAB_ANNOUNCEMENTS_URL=http://localhost:8000/announcements.json`.
