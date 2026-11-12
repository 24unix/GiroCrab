cask "girocrab@nightly" do
  # The rolling `nightly` pre-release replaces its disk image on every build, so there is no
  # stable version or checksum to pin. Integrity still holds: the app is Developer ID
  # signed and notarized (Gatekeeper checks it on first launch, Homebrew keeps the
  # quarantine flag), and later updates come through Sparkle with EdDSA verification.
  version :latest
  sha256 :no_check

  url "https://github.com/GiroCrab/GiroCrab/releases/download/nightly/GiroCrab-macOS-arm64.dmg"
  name "GiroCrab Nightly"
  desc "Local-first banking app for German banks"
  homepage "https://github.com/GiroCrab/GiroCrab"

  # No `auto_updates`: casks with `version :latest` are already skipped by
  # `brew upgrade` (unless --greedy). In-app updates (Sparkle) keep a nightly
  # install on the nightly channel.
  conflicts_with cask: [
    "girocrab",
    "girocrab@beta",
  ]
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "GiroCrab.app"

  # Same app data as the stable cask, see docs/homebrew.md.
  zap trash: [
    "~/Library/Application Support/GiroCrab",
    "~/Library/Caches/app.girocrab.mac",
    "~/Library/HTTPStorages/app.girocrab.mac",
    "~/Library/HTTPStorages/app.girocrab.mac.binarycookies",
    "~/Library/Preferences/app.girocrab.mac.plist",
    "~/Library/Saved Application State/app.girocrab.mac.savedState",
    "~/Library/WebKit/app.girocrab.mac",
  ]

  caveats <<~EOS
    Nightly builds are untested development snapshots. Back up your vault first:
      ~/Library/Application Support/GiroCrab
    `brew uninstall --cask --zap girocrab@nightly` moves it to the Trash.
    Switching the channel inside the app works, but `brew upgrade --greedy` may
    then replace a newer in-app update with this cask's version. To change the
    channel for good, switch the cask instead (see docs/homebrew.md).
  EOS
end
