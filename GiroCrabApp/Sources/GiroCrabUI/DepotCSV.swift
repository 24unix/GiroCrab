import Foundation
import GiroCrabCore

/// CSV of a depot's positions or activities, as shown (search, period and filter applied).
/// Same dialect as the booking export: UTF-8 with BOM, semicolon, decimal comma, CRLF, and a
/// guard against spreadsheet formulas (`=`, `+`, `-`, `@` at the start of a text).
enum DepotCSV {
    static func field(_ value: String, text: Bool = true) -> String {
        var s = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if text, let first = value.first, "=+-@\t\r".contains(first) { s = "'" + s }
        if s.contains(";") || s.contains("\"") { return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return s
    }

    /// Default file name: account, what is exported, the year filter if one is set, and the day
    /// ("Welt-Depot-ETF_Aktivitaeten_2026_2026-11-18"). Spaces and characters a file name cannot carry
    /// become hyphens.
    static func filename(account: String, kind: String, year: Int? = nil, date: Date = Date()) -> String {
        let cleaned = account.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\t "))
            .filter { !$0.isEmpty }.joined(separator: "-")
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return [cleaned.isEmpty ? "Depot" : cleaned, kind, year.map(String.init), day.string(from: date)]
            .compactMap { $0 }.joined(separator: "_")
    }

    /// `-1234,56`: German decimal comma, no grouping.
    static func amount(_ cents: Int64) -> String {
        let a = cents.magnitude
        return (cents < 0 ? "-" : "") + "\(a / 100)," + String(format: "%02d", Int(a % 100))
    }

    /// Quantities keep up to six decimals (savings plans buy fractions), without trailing zeros.
    static func quantity(_ q: Double) -> String {
        var s = String(format: "%.6f", q)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.replacingOccurrences(of: ".", with: ",")
    }

    static func percent(_ p: Double) -> String { String(format: "%.2f", p).replacingOccurrences(of: ".", with: ",") }

    private static func document(header: [String], rows: [[String]]) -> String {
        let head = header.map { field($0, text: false) }.joined(separator: ";")
        return "\u{FEFF}" + ([head] + rows.map { $0.joined(separator: ";") }).joined(separator: "\r\n") + "\r\n"
    }

    static func activities(_ items: [SecurityTransaction], currency: String) -> String {
        let header = [
            String(localized: "Datum"), String(localized: "Wertpapier"), "ISIN", "WKN", String(localized: "Art"),
            String(localized: "Menge"), String(localized: "Kurs"), String(localized: "Bruttobetrag"),
            String(localized: "Gebühren"), String(localized: "Steuern"), String(localized: "Währung"),
            String(localized: "Buchungstext"),
        ]
        let rows = items.map { t in
            [
                field(t.bookingDate, text: false), field(t.name), field(t.isin, text: false), field(t.wkn, text: false),
                field(DepotActivities.kindTitle(t), text: false), quantity(t.quantity), amount(t.priceCents),
                amount(t.valueCents), amount(DepotActivities.feeCents(t)), amount(DepotActivities.taxCents(t)),
                field(t.currency.isEmpty ? currency : t.currency, text: false), field(t.bookingText),
            ]
        }
        return document(header: header, rows: rows)
    }

    /// Price and quantity as the table shows them: a bond quotes a percentage of its nominal amount
    /// (98,50 is 98,50 %, not 98,50 €), so the unit of the quantity and of the price go along.
    static func positions(_ items: [DepotPosition], currency: String) -> String {
        let header = [
            String(localized: "Wertpapier"), "ISIN", "WKN", String(localized: "Menge"), String(localized: "Mengeneinheit"),
            String(localized: "Einstandskurs"), String(localized: "Kurs"), String(localized: "Kurseinheit"),
            String(localized: "Wert"), String(localized: "Gewinn/Verlust"), String(localized: "Gewinn/Verlust %"),
            String(localized: "Anlageklasse"), String(localized: "Instrument"), String(localized: "Währung"),
        ]
        let rows = items.map { p in
            let h = p.holding
            let price = priceColumns(p, accountCurrency: currency)
            return [
                field(p.displayName), field(h.isin, text: false), field(h.wkn, text: false),
                quantity(h.quantity), field(p.basis == .percentOfNominal ? String(localized: "Nominal") : String(localized: "Stück"), text: false),
                price.purchase, price.current, field(price.unit, text: false),
                amount(h.valueCents), p.gain.map { amount($0.cents) } ?? "",
                p.gain?.percent.map(percent) ?? "",
                field(p.asset.classification.assetClass.title, text: false),
                field(p.asset.classification.instrument.title, text: false), currency,
            ]
        }
        return document(header: header, rows: rows)
    }

    /// Purchase and current price with their unit: "%" for a bond, the position's own currency where
    /// the table shows it, else the account currency; nothing where the table shows no price.
    static func priceColumns(_ p: DepotPosition, accountCurrency: String) -> (purchase: String, current: String, unit: String) {
        let h = p.holding
        if p.hidesPrice { return ("", "", "") }
        if p.basis == .percentOfNominal {
            return (h.purchasePriceCents > 0 ? percent(Double(h.purchasePriceCents) / 100) : "",
                    percent(Double(h.currentPriceCents) / 100), "%")
        }
        if let native = h.nativeCurrency(accountCurrency: accountCurrency), let current = h.nativePriceCents {
            return (h.nativePurchasePriceCents.map(amount) ?? "", amount(current), native)
        }
        return (amount(h.purchasePriceCents), amount(h.currentPriceCents), accountCurrency)
    }
}
