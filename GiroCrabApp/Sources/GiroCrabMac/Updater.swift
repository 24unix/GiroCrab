// Sparkle-backed in-app updates for the Developer-ID release bundle.
//
// Only this executable target links Sparkle; GiroCrabUI sees the neutral
// `AppUpdateBackend` protocol. An App Store build (Xcode target) therefore
// contains no Sparkle code.
//
// Security model (keys are written into Info.plist by package-macos-app.sh):
//  * SUFeedURL points at .../releases/latest/download/appcast.xml – one signed
//    appcast for all channels, attached to the latest stable release.
//  * Every archive must carry a valid EdDSA signature for SUPublicEDKey,
//    verified before extraction (SUVerifyUpdateBeforeExtraction), and the
//    appcast itself must be signed (SURequireSignedFeed).
//  * Sparkle additionally requires the new app to be signed by the same
//    Developer ID team as the running one.
// Channels: stable items have no <sparkle:channel>; beta and nightly items are
// tagged `beta` / `nightly`. `allowedChannels` admits them only for users who
// opted in (hidden ⌥ setting) or who run a beta/nightly build, see
// AppUpdateChannel. Every channel is signed exactly like stable.
// Without a public key (e.g. `swift run`, unconfigured forks) the updater is
// never started and the UI hides all update controls.
#if os(macOS) && canImport(Sparkle)
import AppKit
import Sparkle
import GiroCrabUI

@MainActor
final class SparkleUpdateBackend: NSObject, AppUpdateBackend, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []

    /// Starts Sparkle and registers it with `AppUpdates.shared`, or does
    /// nothing if this process is not a configured release bundle.
    static func startIfConfigured() -> SparkleUpdateBackend? {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.trimmingCharacters(in: .whitespaces).isEmpty,
              let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              feed.hasPrefix("https://") || feed.hasPrefix("http://localhost") || feed.hasPrefix("http://127.0.0.1")
        else { return nil }
        let backend = SparkleUpdateBackend()
        AppUpdates.shared.register(backend)
        return backend
    }

    private override init() {
        super.init()
        // The controller keeps its delegate weakly; `self` lives as long as
        // the AppDelegate holds it (app lifetime).
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        let updater = controller.updater
        let changed: @Sendable () -> Void = {
            Task { @MainActor in AppUpdates.shared.refresh() }
        }
        observations = [
            updater.observe(\.canCheckForUpdates) { _, _ in changed() },
            updater.observe(\.lastUpdateCheckDate) { _, _ in changed() },
            updater.observe(\.automaticallyChecksForUpdates) { _, _ in changed() },
            updater.observe(\.automaticallyDownloadsUpdates) { _, _ in changed() },
        ]
    }

    // MARK: SPUUpdaterDelegate (Sparkle calls this on the main thread)

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { AppUpdateChannel.current.sparkleChannels }  // [] = stable only
    }

    // MARK: AppUpdateBackend

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var allowsAutomaticUpdates: Bool { controller.updater.allowsAutomaticUpdates }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func updateChannelDidChange() {
        // Don't keep a pending download from the other channel around.
        controller.updater.resetUpdateCycleAfterShortDelay()
    }
}
#endif
