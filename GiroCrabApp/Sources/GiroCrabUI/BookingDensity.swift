import SwiftUI
import GiroCrabCore

/// Local presentation preference; never changes the vault or the booking filter.
enum BookingDensity: String, CaseIterable, Identifiable {
    case compact, standard, spacious

    static let defaultsKey = "bookingDensity"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: String(localized: "Kompakt")
        case .standard: String(localized: "Standard")
        case .spacious: String(localized: "Großzügig")
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact: 4
        case .standard: 5
        case .spacious: 9
        }
    }

    func showsDetails(isActive: Bool) -> Bool {
        self == .spacious || (self == .compact && isActive)
    }

    /// Prefer the already cleaned text, avoiding a duplicate of the row title.
    func purpose(for booking: Booking) -> String {
        ListPurpose.text(for: booking) ?? ""
    }
}
