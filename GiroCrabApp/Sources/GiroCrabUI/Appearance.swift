import SwiftUI

/// App-wide appearance (GitHub #388): follow the system, or force light/dark.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "appearance"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Hell")
        case .dark: String(localized: "Dunkel")
        }
    }

    /// For `.preferredColorScheme`; nil follows the system. Screenshot launches
    /// always follow the system (reproducible marketing shots).
    var colorScheme: ColorScheme? {
        guard LaunchOptions.current.screenshotPath == nil else { return nil }
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
