import Foundation

/// "Als geprüft markieren": when a selected unchecked booking becomes
/// checked on its own – like a mail app marking a message as read.
/// Stored per device; the checked state itself syncs as usual.
enum AutoReviewDelay: String, CaseIterable, Identifiable {
    case manual
    case immediately = "now"
    case oneSecond = "1s"
    case fiveSeconds = "5s"

    static let defaultsKey = "bookings.autoReviewDelay"
    var id: String { rawValue }

    /// Delay before marking; nil = only by hand.
    var seconds: Double? {
        switch self {
        case .manual: nil
        case .immediately: 0
        case .oneSecond: 1
        case .fiveSeconds: 5
        }
    }

    var title: String {
        switch self {
        case .manual: String(localized: "Nur manuell")
        case .immediately: String(localized: "Sofort")
        case .oneSecond: String(localized: "Nach 1 Sekunde")
        case .fiveSeconds: String(localized: "Nach 5 Sekunden")
        }
    }

    /// The choice stored on this device; "Nur manuell" until one is made.
    static var stored: AutoReviewDelay {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AutoReviewDelay.init(rawValue:)) ?? .manual
    }
}
