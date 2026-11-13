# Homebrew distribution

GiroCrab for macOS is distributed through a Homebrew Cask that installs the **signed and
notarized stable release** from GitHub (Apple Silicon only, macOS 14 Sonoma or later).

**Release artifact:** a Developer-ID-signed, notarized and stapled disk image
`GiroCrab-macOS-arm64.dmg` (introduced with the Sparkle PR, GiroCrab/GiroCrab#120). Releases
up to v0.5.5 only have `GiroCrab-macOS-arm64.zip`, so the stable cask still points to the
ZIP; `scripts/update-homebrew-cask.sh` switches it to `.dmg` with the first release that
ships the image. `girocrab@beta` and `girocrab@nightly` point to `.dmg` directly, because
no beta or nightly release exists yet. Homebrew handles both formats the same way
(`app "GiroCrab.app"`).

```bash
brew tap girocrab/tap https://github.com/GiroCrab/GiroCrab   # once
brew install --cask girocrab/tap/girocrab           # stable
brew install --cask girocrab/tap/girocrab@beta      # beta (pre-release)
brew install --cask girocrab/tap/girocrab@nightly   # nightly build
```

The casks live in [`Casks/`](../Casks/) in the root of this repo, which is where Homebrew
looks for them. The explicit `brew tap` URL turns this repository into the tap
`girocrab/tap`, so no separate `GiroCrab/homebrew-tap` repository is needed. If one is
created later, the `brew tap` line is dropped and the install commands stay the same. The
three casks install the same `GiroCrab.app` and therefore declare `conflicts_with` each
other.

## Channels: stable, beta, nightly

| Cask | Source | Version / checksum | `auto_updates` | livecheck |
|---|---|---|---|---|
| `girocrab` | `releases/download/vX.Y.Z/…` | pinned | yes | `:github_latest` |
| `girocrab@beta` | `releases/download/vX.Y.Z-beta.N/…` (pre-release) | pinned | yes | git tags `vX.Y.Z-beta.N` |
| `girocrab@nightly` | `releases/download/nightly/…` (rolling) | `version :latest`, `sha256 :no_check` | no (not allowed with `:latest`) | – |

- The `@beta` / `@nightly` suffixes follow Homebrew's naming for variants
  (e.g. `firefox@nightly`).
- **Nightly has no pinned checksum**, because the rolling `nightly` release replaces its
  disk image on every build. It is still signed: Homebrew keeps the quarantine flag, so Gatekeeper
  checks the Developer ID signature and notarization on first launch, and later updates
  come through Sparkle with EdDSA verification. A pinned checksum would need dated nightly
  disk images plus a cask update every night.
- The app picks its update channel from the installed build (`X.Y.ZbN` → beta,
  `<tag>.<timestamp>` → nightly), so a Homebrew beta or nightly install keeps getting
  beta or nightly updates through Sparkle. See `docs/auto-updates.md` on the Sparkle branch.

### Switching the channel inside the app

Users who installed through Homebrew **can** switch the channel in the app
(Settings › Updates, ⌥). Nothing has to be removed: with `auto_updates true` Homebrew
leaves updates to Sparkle. One thing to know:

- Homebrew still records the cask that was installed. `brew upgrade` (without `--greedy`)
  ignores self-updating casks, so this is harmless by default.
- **`brew upgrade --greedy`** reinstalls the cask's version when that cask is bumped. If
  someone installed `girocrab`, switched to beta in the app (e.g. 0.7.0b1) and later runs
  `brew upgrade --greedy` after the stable cask moved to 0.6.1, Homebrew **replaces the
  beta with the older 0.6.1**. A beta may already have changed the vault format.
- Recommendation (also in the caveats of `@beta`/`@nightly`): to change the channel
  permanently, switch the cask instead:
  `brew uninstall --cask girocrab && brew install --cask girocrab/tap/girocrab@beta`.
  The vault stays in `~/Library/Application Support/GiroCrab` (no `--zap`).

## Own tap vs. official `homebrew/cask`

| | Own tap (`Casks/` in this repo) | Official `homebrew/cask` |
|---|---|---|
| Install command | `brew tap girocrab/tap https://github.com/GiroCrab/GiroCrab` once, then `brew install --cask girocrab/tap/girocrab` | `brew install --cask girocrab` |
| Who updates | us (script below) | Homebrew's autobump bot, from `livecheck` |
| Requirements | none | notability + review (see below) |
| Available | immediately | after acceptance |

Requirements for the official repository (checked by `brew audit --cask --new`):

- **Notability:** roughly ≥ 75 stars, or ≥ 30 forks or watchers, and the GitHub repo must be
  **at least 30 days old**. GiroCrab has the stars (154 at the time of writing), but the repo
  was created on 2026-11-09, so `audit --new` currently fails with *"GitHub repository too
  new"*. The earliest submission date is around 2026-12-09.
- **Signed and notarized app.** Homebrew/cask no longer accepts apps that fail Gatekeeper.
  GiroCrab qualifies: the release app is signed with a Developer ID, notarized and stapled
  (`spctl` reports `source=Notarized Developer ID`).
- Stable, versioned download URLs (we have these: `releases/download/vX.Y.Z/...`).

Recommendation: start with the own tap now. Submit to `homebrew/cask` once the repo is
30 days old. After that the official cask is updated automatically, and the tap can then
be retired or kept as a mirror.

## Only stable releases

- The cask URL is pinned to a tag: `releases/download/v#{version}/GiroCrab-macOS-arm64.dmg`
  (`.zip` up to v0.5.5).
- `livecheck` uses `strategy :github_latest`. GitHub's "latest release" never returns a
  pre-release, so the rolling `nightly` pre-release is never offered.
- `scripts/update-homebrew-cask.sh` updates `girocrab.rb` only from published stable
  releases (`vX.Y.Z`), and `girocrab@beta.rb` only from pre-releases `vX.Y.Z-beta.N`.
  `nightly` is refused (that cask has no version to update).
- Possible later alternative: once every stable release ships a Sparkle `appcast.xml`,
  livecheck could use `strategy :sparkle` with
  `url "https://github.com/GiroCrab/GiroCrab/releases/latest/download/appcast.xml"`.
  `:github_latest` is simpler and does not depend on the appcast, so we keep it.

## In-app updates (Sparkle) and `auto_updates true`

The app updates itself through Sparkle, so the cask declares `auto_updates true`. As a
result, `brew upgrade` skips GiroCrab unless the user passes `--greedy`, and Homebrew does
not fight Sparkle over the app bundle. The version Homebrew shows can lag behind the
installed app; this is expected for self-updating casks.

> Note: the current release v0.5.5 does not yet contain `Sparkle.framework`. The
> `auto_updates true` stanza becomes accurate with the first stable release that ships
> Sparkle. Until then, users upgrade with `brew upgrade --cask --greedy girocrab`.

## Releasing: updating the cask

After `scripts/notarize.sh --upload <tag>` has published the release:

```bash
scripts/update-homebrew-cask.sh vX.Y.Z           # -> Casks/girocrab.rb
scripts/update-homebrew-cask.sh vX.Y.Z-beta.N    # -> Casks/girocrab@beta.rb
```

`girocrab@beta.rb` carries a placeholder version and checksum until the first beta
pre-release exists; run the script once that release is published. Nightly needs no
update.

The script reads the release via `gh api`, picks the asset (`.dmg`, or `.zip` for releases
up to v0.5.5), takes its SHA-256 digest (or downloads and hashes it if GitHub has no
digest), and rewrites `version`, `sha256` and the file name in the `url` line of
`Casks/girocrab.rb` (or `girocrab@beta.rb`). It does **not** commit or push.

Then validate against a local tap and commit the changed cask to this repo:

```bash
brew tap girocrab/tap "$PWD"         # local checkout as the tap (use `brew untap girocrab/tap` afterwards)
brew style --cask girocrab/tap/girocrab
brew audit --cask --online --strict girocrab/tap/girocrab
```

Users get the new cask on their next `brew update`, once the commit is on `main`.

## Uninstall and `--zap`: the vault

| Command | Effect |
|---|---|
| `brew uninstall --cask girocrab` | removes `GiroCrab.app` only. The vault and settings stay. |
| `brew uninstall --cask --zap girocrab` | also moves app data to the **Trash** |

The `zap trash:` list covers `~/Library/Application Support/GiroCrab`, which holds the
encrypted vault `tresor.girocrab`, plus the app's caches, preferences, HTTP storage,
WebKit data and saved window state (`app.girocrab.mac`).

Why the vault is included: `--zap` is an explicit opt-in that means "remove everything
this app left behind", and Homebrew reviewers expect app data in it. To make this safe
and documented rather than silent:

- `trash:` moves files to the Trash instead of deleting them, so they can be restored until
  the Trash is emptied.
- The cask's `caveats` (shown on install) say where the vault is, and that `--zap` moves it
  to the Trash.
- The vault key in the Keychain (service `de.girocrab.vault`) is **not** removed, so a
  restored vault can still be opened.
- The optional iCloud Drive sync/mirror folder (`iCloud Drive/GiroCrab`, or
  `iCloud Drive/moneymoney`) is **never** touched, because it may be the user's only
  backup.

If maintainers would rather never touch the vault, remove that one line from `zap` and
change the caveat text to "is never deleted by Homebrew".

## README snippet (draft, not yet added)

```markdown
### Homebrew
brew tap girocrab/tap https://github.com/GiroCrab/GiroCrab
brew install --cask girocrab/tap/girocrab
```
