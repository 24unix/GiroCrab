cask "girocrab@beta" do
  # Filled in by scripts/update-homebrew-cask.sh vX.Y.Z-beta.N (placeholder until the
  # first beta pre-release exists).
  version "0.6.0-beta.1"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/GiroCrab/GiroCrab/releases/download/v#{version}/GiroCrab-macOS-arm64.dmg"
  name "GiroCrab Beta"
  desc "Local-first banking app for German banks"
  homepage "https://github.com/GiroCrab/GiroCrab"

  # Beta tags are GitHub pre-releases (vX.Y.Z-beta.N), so read the git tags.
  livecheck do
    url "https://github.com/GiroCrab/GiroCrab.git"
    regex(/^v?(\d+(?:\.\d+)+-beta\.\d+)$/i)
  end

  # In-app updates (Sparkle) keep a beta install on the beta channel.
  auto_updates true
  conflicts_with cask: [
    "girocrab",
    "girocrab@nightly",
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
    This is a beta (pre-release) version of GiroCrab. Back up your vault first:
      ~/Library/Application Support/GiroCrab
    `brew uninstall --cask --zap girocrab@beta` moves it to the Trash.
    Switching the channel inside the app works, but `brew upgrade --greedy` may
    then replace a newer in-app update with this cask's version. To change the
    channel for good, switch the cask instead (see docs/homebrew.md).
  EOS
end
