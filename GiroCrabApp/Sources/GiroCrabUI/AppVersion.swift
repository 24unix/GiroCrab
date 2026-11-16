import SwiftUI
import GiroCrabCore

/// Short version line for test builds ("GiroCrab 0.7.5 (18)"), shown at the
/// bottom of the Settings window. `swift run` builds have no `.app` bundle and
/// therefore no Info.plist: they fall back to the workspace version from
/// `Cargo.toml` (compiled into the core) plus "(dev)".
/// The detailed line with the TestFlight pin lives in `AppVersionDisplay`.
enum AppVersion {
    static var displayString: String {
        let info = Bundle.main.infoDictionary
        return text(
            bundleVersion: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            core: coreVersion()
        )
    }

    static func text(bundleVersion: String?, build: String?, core: String) -> String {
        let version = bundleVersion?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !version.isEmpty else { return "GiroCrab \(core) (dev)" }
        let build = build?.trimmingCharacters(in: .whitespaces) ?? ""
        return build.isEmpty || build == version ? "GiroCrab \(version)" : "GiroCrab \(version) (\(build))"
    }
}

/// Subtle footer under every settings pane (macOS and iOS).
struct AppVersionFooter: View {
    /// Computed once: the core call takes no vault lock, but `body` re-runs often.
    private static let line = AppVersion.displayString

    var body: some View {
        Text(verbatim: Self.line)
            .appFont(.caption2)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}
