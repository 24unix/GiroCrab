cask "girocrab" do
  version "0.5.5"
  sha256 "fb20c939f1bdfe0ff6f971d402c581cc4ebb6fe73b27f214ea391469008c5304"

  # Up to v0.5.5 the release asset is a ZIP; from the first release with the
  # signed disk image on, scripts/update-homebrew-cask.sh switches this to .dmg.
  url "https://github.com/GiroCrab/GiroCrab/releases/download/v#{version}/GiroCrab-macOS-arm64.zip"
  name "GiroCrab"
  desc "Local-first banking app for German banks"
  homepage "https://github.com/GiroCrab/GiroCrab"

  # Only stable releases: the rolling "nightly" tag is a GitHub pre-release and
  # is therefore never returned by the "latest release" endpoint.
  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  conflicts_with cask: [
    "girocrab@beta",
    "girocrab@nightly",
  ]
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "GiroCrab.app"

  # `brew uninstall --zap` moves these to the Trash (recoverable until it is emptied).
  # This includes the encrypted vault (~/Library/Application Support/GiroCrab/tresor.girocrab).
  # Deliberately NOT touched: the iCloud Drive sync/mirror folder and the Keychain item
  # "de.girocrab.vault" that holds the vault key.
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
    Your encrypted GiroCrab vault lives in
      ~/Library/Application Support/GiroCrab
    `brew uninstall --cask girocrab` keeps it.
    `brew uninstall --cask --zap girocrab` moves it to the Trash.
    Make a backup before zapping if you want to keep your data.
    Switching to beta/nightly inside the app works, but `brew upgrade --greedy`
    may then replace the newer in-app update with this cask's version. To change
    the channel for good, install girocrab@beta or girocrab@nightly instead.
  EOS
end
