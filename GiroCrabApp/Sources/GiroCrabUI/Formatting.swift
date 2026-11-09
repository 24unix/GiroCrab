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
        f.locale = .autoupdatingCurrent
        f.currencyCode = "EUR"
        return f
    }()
    private static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = .autoupdatingCurrent
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    /// i64 cents -> "1.234,56 €" / "€1,234.56" in the user's locale (Decimal, never Double).
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

    /// User input -> cents, accepting the user's locale ("280.000,50" in German,
    /// "280,000.50" in English) as well as plain "280000.5" (Decimal, never Double).
    /// Both separators present: the last one is the decimal separator. Only one
    /// kind present: it is a grouping separator if it is the locale's grouping
    /// separator and every group after it has exactly three digits.
    static func parseCents(_ input: String) -> Int64? {
        let t = input.filter { !($0 == "€" || $0.isWhitespace || $0 == "'") }
        guard !t.isEmpty else { return nil }
        let seps: Set<Character> = [".", ","]
        let used = Set(t.filter { seps.contains($0) })
        var normalized = t
        if used.count == 2, let last = t.last(where: { seps.contains($0) }) {
            let grouping: Character = last == "," ? "." : ","
            normalized = t.replacingOccurrences(of: String(grouping), with: "").replacingOccurrences(of: String(last), with: ".")
        } else if let sep = used.first {
            let groups = t.split(separator: sep, omittingEmptySubsequences: false)
            let localeGrouping = Locale.autoupdatingCurrent.groupingSeparator.flatMap(\.first)
            let isGrouping = (sep == localeGrouping || groups.count > 2) && groups.dropFirst().allSatisfy { $0.count == 3 }
            normalized = isGrouping ? t.replacingOccurrences(of: String(sep), with: "") : t.replacingOccurrences(of: String(sep), with: ".")
        }
        guard let d = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return NSDecimalNumber(decimal: d * 100).rounding(accordingToBehavior: nil).int64Value
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
    /// Display formats follow the user's locale: the templates give
    /// "9. November" / "09.11.2026" in German and "November 9" / "11/09/2026" in English.
    private static func make(template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
    private static let dayMonth = make(template: "dMMMM")
    private static let dayMonthYear = make(template: "dMMMMyyyy")
    private static let weekday = make(template: "EEEE")
    private static let medium = make(template: "ddMMyyyy")
    private static let full = make(template: "EEEEdMMMMyyyy")
    private static let monthShort = make(template: "MMMyy")

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
        if cal.isDateInToday(d) { return String(localized: "Heute, \(dm)") }
        if cal.isDateInYesterday(d) { return String(localized: "Gestern, \(dm)") }
        let wd = weekday.string(from: d)
        return String(localized: "\(wd), \(dm)", comment: "Day header: weekday, day and month")
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
        case .consumption: return String(localized: "Konsum")
        case .income: return String(localized: "Einnahme")
        case .investment: return String(localized: "Investment")
        case .perk: return String(localized: "Perk")
        case .transfer: return String(localized: "Umbuchung")
        case .loan: return String(localized: "Darlehen")
        }
    }
}

extension Booking {
    /// "Supermarkt · Kartenzahlung"
    var subtitle: String {
        let cat = categoryName.isEmpty ? String(localized: "Ohne Kategorie") : categoryName
        return paymentMethod.isEmpty ? cat : "\(cat) · \(paymentMethod)"
    }
}
