import SwiftUI
import GiroCrabCore

extension Booking: Identifiable {}
extension Account: Identifiable {}
extension AccountGroup: Identifiable {}
extension GiroCrabCore.Category: Identifiable {}
extension Rule: Identifiable {}
extension BankConnection: Identifiable {}
extension SettingEntry: Identifiable { public var id: String { key } }
extension BankDescriptor: Identifiable { public var id: ConnectorKind { kind } }
extension SavingsPlan: Identifiable { public var id: String { merchant.key } }

/// "Daylight" design tokens: calm, high-contrast light UI.
enum Theme {
    static let canvas = Color(hex: "#F8FAFC")      // light warm slate
    static let sidebar = Color(hex: "#F3F4F6")
    static let card = Color.white
    static let border = Color(hex: "#E2E8F0")
    static let text = Color(hex: "#0F172A")
    static let secondary = Color(hex: "#64748B")
    static let tertiary = Color(hex: "#94A3B8")
    static let outflow = Color(hex: "#0F172A")
    static let inflow = Color(hex: "#059669")
    static let inflowBadge = Color(hex: "#ECFDF5")
    static let accent = Color(hex: "#2563EB")
    static let selection = Color(hex: "#EEF2FF")
    static let loan = Color(hex: "#64748B")
    static let warning = Color(hex: "#B45309")
}

/// White card with a 1px hairline border.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardBackground(padding: padding)) }
}

enum Money {
    private static let currency: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "de_DE")
        f.currencyCode = "EUR"
        return f
    }()
    private static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    /// i64 cents -> "1.234,56 €" (Decimal, never Double).
    static func format(_ cents: Int64, currency code: String = "EUR") -> String {
        currency.currencyCode = code
        let s = currency.string(from: (Decimal(cents) / 100) as NSDecimalNumber) ?? "\(cents)"
        return s.replacingOccurrences(of: "-", with: "−")
    }

    /// "+1.234,56 €" for inflows.
    static func signed(_ cents: Int64) -> String {
        cents > 0 ? "+" + format(cents) : format(cents)
    }

    static func plain(_ cents: Int64) -> String {
        (decimal.string(from: (Decimal(cents) / 100) as NSDecimalNumber) ?? "\(cents)").replacingOccurrences(of: "-", with: "−")
    }

    static func ink(_ cents: Int64) -> Color { cents > 0 ? Theme.inflow : Theme.outflow }
}

enum DateText {
    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = format
        return f
    }
    private static let dayMonth = make("d. MMMM")
    private static let dayMonthYear = make("d. MMMM yyyy")
    private static let weekday = make("EEEE")
    private static let medium = make("dd.MM.yyyy")
    private static let full = make("EEEE, d. MMMM yyyy")
    private static let monthShort = make("MMM yy")

    static func date(_ s: String) -> Date? { iso.date(from: s) }
    static func iso(_ d: Date) -> String { iso.string(from: d) }
    static func medium(_ s: String) -> String { date(s).map { medium.string(from: $0) } ?? s }
    static func long(_ s: String) -> String { date(s).map { full.string(from: $0) } ?? s }

    /// "Heute, 9. November" / "Gestern, 8. November" / "Montag, 2. November" (+ year if not this year).
    static func dayHeader(_ s: String) -> String {
        guard let d = date(s) else { return s }
        let cal = Calendar(identifier: .gregorian)
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: Date())
        let dm = sameYear ? dayMonth.string(from: d) : dayMonthYear.string(from: d)
        if cal.isDateInToday(d) { return "Heute, \(dm)" }
        if cal.isDateInYesterday(d) { return "Gestern, \(dm)" }
        return "\(weekday.string(from: d)), \(dm)"
    }

    /// "2026-11" -> "Nov. 26"
    static func monthLabel(_ ym: String) -> String {
        date(ym + "-01").map { monthShort.string(from: $0) } ?? ym
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 6 {
            self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
        } else {
            self.init(white: 0.55)
        }
    }

    /// Brand colours that are too light for text (yellow, pink) get a dark fallback.
    static func readable(hex: String) -> Color {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF), g = Double((v >> 8) & 0xFF), b = Double(v & 0xFF)
        let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        return lum > 0.72 ? Theme.outflow : Color(hex: hex)
    }
}

extension ConnectorKind {
    var displayName: String {
        switch self {
        case .volksbankKasselGoettingen: return "Volksbank Kassel Göttingen"
        case .direkt1822: return "1822direkt"
        case .comdirect: return "comdirect"
        case .payPal: return "PayPal"
        case .tradeRepublic: return "Trade Republic"
        case .americanExpress: return "American Express"
        case .amazonVisa: return "Amazon Visa"
        }
    }

    /// Subtle institute colour (no logos – a monogram signet instead).
    var tintHex: String {
        switch self {
        case .volksbankKasselGoettingen: return "#1D5FBF"
        case .direkt1822: return "#D63A2F"
        case .comdirect: return "#3C3C3C"
        case .payPal: return "#003087"
        case .tradeRepublic: return "#111111"
        case .americanExpress: return "#2E77BC"
        case .amazonVisa: return "#3C2A7A"
        }
    }

    var tint: Color { Color(hex: tintHex) }

    var monogram: String {
        switch self {
        case .volksbankKasselGoettingen: return "VB"
        case .direkt1822: return "18"
        case .comdirect: return "cd"
        case .payPal: return "P"
        case .tradeRepublic: return "TR"
        case .americanExpress: return "AX"
        case .amazonVisa: return "AV"
        }
    }
}

extension FlowKind {
    var label: String {
        switch self {
        case .consumption: return "Konsum"
        case .income: return "Einnahme"
        case .investment: return "Investment"
        case .perk: return "Perk"
        case .transfer: return "Umbuchung"
        case .loan: return "Darlehen"
        }
    }
}

extension Booking {
    /// "Supermarkt · Kartenzahlung"
    var subtitle: String {
        let cat = categoryName.isEmpty ? "Ohne Kategorie" : categoryName
        return paymentMethod.isEmpty ? cat : "\(cat) · \(paymentMethod)"
    }
}
