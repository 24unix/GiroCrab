import SwiftUI

/// Colour of negative amounts in the booking list (GitHub #218,
/// Einstellungen › Allgemein). The minus sign always stays, so the direction
/// never depends on colour alone.
enum NegativeAmountStyle: String, CaseIterable, Identifiable {
    /// Text colour, like the rest of the row (default).
    case neutral
    /// Red, like negative balances in the sidebar.
    case red

    static let defaultsKey = "negativeAmountStyle"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .neutral: String(localized: "Neutral")
        case .red: String(localized: "Rot")
        }
    }

    var color: Color {
        switch self {
        case .neutral: Theme.outflow
        case .red: Theme.negative
        }
    }

    /// The stored choice; unknown or missing values fall back to `.neutral`.
    static func current(_ defaults: UserDefaults = .standard) -> NegativeAmountStyle {
        defaults.string(forKey: defaultsKey).flatMap(NegativeAmountStyle.init(rawValue:)) ?? .neutral
    }
}
