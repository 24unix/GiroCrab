import Foundation
import GiroCrabCore

/// The standing order being created, changed or deleted (#496).
struct StandingDraft {
    var action: StandingOrderAction = .create
    /// `standing_orders.id` of the order to change or delete.
    var orderRowID: Int64?
    var accountID: Int64?
    var name = ""
    var iban = ""
    var bic = ""
    var amountText = ""
    var purpose = ""
    var firstDate = StandingDraft.tomorrow
    var hasEnd = false
    var lastDate = Calendar.current.date(byAdding: .year, value: 1, to: StandingDraft.tomorrow) ?? Date()
    /// `M` (months) or `W` (weeks).
    var unit = "M"
    var interval = 1
    /// Day of the month (31 = last day) or weekday (1 = Monday … 7).
    var execDay = 1
    var pin = ""

    static var tomorrow: Date { Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date() }

    var cents: Int64? {
        guard let c = try? parseAmountToCents(text: amountText), c > 0 else { return nil }
        return c
    }
    var ibanValid: Bool { validateIban(iban: iban) }

    /// What the editor still needs before it can go to the review.
    var isValid: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        let lastOK = !hasEnd || lastDate >= firstDate
        return accountID != nil && !n.isEmpty && n.count <= 70 && ibanValid && cents != nil
            && purpose.count <= 140 && lastOK && (1...99).contains(interval) && firstDateMatchesDay
    }

    /// An existing order as a draft (change or delete).
    init(order o: StandingOrderInfo, action: StandingOrderAction) {
        self.action = action
        orderRowID = o.id
        accountID = o.accountId
        name = o.recipientName
        iban = BatchRow.grouped(o.recipientIban)
        amountText = Money.plain(o.amountCents)
        purpose = o.purpose
        firstDate = DateText.date(o.firstDate) ?? Self.tomorrow
        if let last = o.lastDate, let d = DateText.date(last) {
            hasEnd = true
            lastDate = d
        }
        unit = o.timeUnit
        interval = Int(o.interval)
        execDay = Int(o.execDay)
        if action == .change { syncDate(to: nil) }  // the stored start lies in the past: the next date on the order's day
    }

    /// A draft that repeats an outgoing booking: same recipient, amount and purpose, the rhythm of
    /// its recurring series (monthly when none is known), on the booking's day of the month.
    init(booking b: Booking, series: RecurringSeries?, accountID: Int64?, today: Date = Date()) {
        self.init()
        self.accountID = accountID
        name = b.counterparty.isEmpty ? b.merchantName : b.counterparty
        iban = BatchRow.grouped(b.counterpartyIban)
        amountText = Money.plain(abs(b.amountCents))
        purpose = String(Self.recurringPurpose(b.purpose).prefix(140))
        switch series?.interval {
        case .quarterly: interval = 3
        case .halfYearly: interval = 6
        case .yearly: interval = 12
        default: interval = 1
        }
        let cal = Calendar.current
        let day = DateText.date(b.bookingDate).map { cal.component(.day, from: $0) } ?? cal.component(.day, from: today)
        execDay = day >= 31 ? 31 : day
        firstDate = Self.nextOccurrence(ofDay: day, after: today)
        lastDate = cal.date(byAdding: .year, value: 1, to: firstDate) ?? firstDate
    }

    /// The purpose of a booking without what changes from payment to payment: dates, month names
    /// and years ("Miete November 2026" becomes "Miete"). Customer and contract numbers stay, the
    /// recipient needs them. If nothing is left, the original text is kept.
    static func recurringPurpose(_ text: String) -> String {
        let months = "januar|februar|märz|maerz|april|mai|juni|juli|august|september|oktober|november|dezember"
            + "|january|february|march|may|june|july|october|december"
        let patterns = [
            #"\b\d{4}-\d{2}-\d{2}\b"#,                 // 2026-11-03
            #"\b\d{1,2}\.\d{1,2}\.(?:\d{4}|\d{2})?(?!\d)"#, // 03.11.2026, 03.11.26, 03.11.
            #"\b\d{1,2}/\d{4}\b"#,                       // 11/2026
            #"\b\d{1,2}\.\d{4}\b"#,                     // 11.2026
            #"\b(?:\#(months))\b"#,                       // November
            #"\b20\d{2}\b"#,                              // 2026
        ]
        var out = text
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: " ")
        }
        out = out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let edge = CharacterSet(charactersIn: " -–,.;:/+")
        out = out.trimmingCharacters(in: edge)
        // A preposition that pointed at the dropped date ("… vom 03.11.").
        if let re = try? NSRegularExpression(pattern: #"\s+(?:vom|am|für|zum|im|ab|bis|per|für den|for|on)$"#, options: [.caseInsensitive]) {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        return out.isEmpty ? text.trimmingCharacters(in: .whitespaces) : out
    }

    /// The first date after `today` on `day` of a month; in a shorter month the last day.
    static func nextOccurrence(ofDay day: Int, after today: Date) -> Date {
        let cal = Calendar.current
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        for m in 0..<3 {
            guard let month = cal.date(byAdding: .month, value: m, to: startOfMonth),
                  let length = cal.range(of: .day, in: .month, for: month)?.count,
                  let date = cal.date(byAdding: .day, value: min(day, length) - 1, to: month) else { continue }
            if date > cal.startOfDay(for: today) { return date }
        }
        return tomorrow
    }

    init() {}

    func request(demo: Bool) -> StandingOrderRequest? {
        guard let accountID, let cents else { return nil }
        let bic = bic.trimmingCharacters(in: .whitespaces)
        return StandingOrderRequest(
            accountId: accountID, action: action, orderRowId: orderRowID,
            recipientName: name, recipientIban: iban, recipientBic: bic.isEmpty ? nil : bic,
            amountCents: cents, purpose: purpose, firstDate: DateText.iso(firstDate),
            lastDate: hasEnd ? DateText.iso(lastDate) : nil, timeUnit: unit,
            interval: UInt32(interval), execDay: UInt32(execDay))
    }

    /// Whether the first execution falls on the execution day (the bank refuses a schedule that does not add up).
    var firstDateMatchesDay: Bool {
        let cal = Calendar.current
        if unit == "W" { return (cal.component(.weekday, from: firstDate) + 5) % 7 + 1 == execDay }
        let day = cal.component(.day, from: firstDate)
        let length = cal.range(of: .day, in: .month, for: firstDate)?.count ?? 31
        if execDay >= 31 { return day == length }
        return day == execDay || (execDay > length && day == length)
    }

    /// The date picker changed: the execution day follows it.
    mutating func syncDay(to l: StandingOrderLimits?) {
        guard !firstDateMatchesDay else { return }
        let cal = Calendar.current
        if unit == "W" {
            execDay = (cal.component(.weekday, from: firstDate) + 5) % 7 + 1
        } else {
            execDay = cal.component(.day, from: firstDate)
        }
        // a day the bank does not allow moves to the nearest allowed one, and the date after it
        conform(to: l)
    }

    /// The execution day changed: the first execution moves to the next date on it.
    mutating func syncDate(to l: StandingOrderLimits?) {
        guard !firstDateMatchesDay else { return }
        let lower = firstDateRange(l).lowerBound
        let cal = Calendar.current
        let before = cal.date(byAdding: .day, value: -1, to: lower) ?? lower
        if unit == "W" {
            for i in 1...7 {
                guard let d = cal.date(byAdding: .day, value: i, to: before) else { continue }
                if (cal.component(.weekday, from: d) + 5) % 7 + 1 == execDay { firstDate = d; return }
            }
        } else {
            firstDate = Self.nextOccurrence(ofDay: execDay, after: before)
        }
    }

    /// Intervals the bank offers for the chosen unit (empty = any 1…99).
    func allowedIntervals(_ l: StandingOrderLimits?) -> [Int] {
        (unit == "W" ? l?.weeks : l?.months)?.map(Int.init) ?? []
    }

    /// Execution days the bank offers for the chosen unit (empty = any).
    func allowedDays(_ l: StandingOrderLimits?) -> [Int] {
        (unit == "W" ? l?.weekdays : l?.daysOfMonth)?.map(Int.init) ?? []
    }

    /// Earliest and latest first execution the bank accepts (never before tomorrow).
    func firstDateRange(_ l: StandingOrderLimits?) -> ClosedRange<Date> {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let from = cal.date(byAdding: .day, value: max(1, Int(l?.minDaysAhead ?? 1)), to: start) ?? Self.tomorrow
        let to = (l?.maxDaysAhead ?? 0) > 0
            ? cal.date(byAdding: .day, value: Int(l?.maxDaysAhead ?? 0), to: start) ?? .distantFuture
            : .distantFuture
        return from...max(from, to)
    }

    /// Moves values the bank does not allow to the nearest allowed one, so the form never shows a combination it would refuse.
    mutating func conform(to l: StandingOrderLimits?) {
        let intervals = allowedIntervals(l)
        if !intervals.isEmpty, !intervals.contains(interval) { interval = intervals[0] }
        let days = allowedDays(l)
        if !days.isEmpty, !days.contains(execDay) {
            execDay = days.min { abs($0 - execDay) < abs($1 - execDay) } ?? days[0]
        }
        let range = firstDateRange(l)
        if firstDate < range.lowerBound { firstDate = range.lowerBound }
        if firstDate > range.upperBound { firstDate = range.upperBound }
        if !firstDateMatchesDay {
            syncDate(to: l)  // the execution day (snapped above) decides; the date moves onto it
        }
        if lastDate < firstDate { lastDate = firstDate }
    }

    /// "monatlich", "alle 2 Wochen" …, the same words as the planned list.
    var rhythmText: String {
        if unit == "W" {
            return interval <= 1 ? String(localized: "wöchentlich") : String(localized: "alle \(interval) Wochen")
        }
        switch interval {
        case ...1: return String(localized: "monatlich")
        case 3: return String(localized: "vierteljährlich")
        case 6: return String(localized: "halbjährlich")
        case 12: return String(localized: "jährlich")
        default: return String(localized: "alle \(interval) Monate")
        }
    }

    /// "am 15." / "am letzten Tag des Monats" / "montags".
    var execDayText: String {
        if unit == "W" { return Self.weekdayName(execDay) }
        return execDay >= 31 ? String(localized: "am letzten Tag des Monats") : String(localized: "am \(execDay).")
    }

    /// Weekday names for 1 = Monday … 7 = Sunday.
    static func weekdayName(_ day: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols  // Sunday first
        return symbols[day % 7]
    }
}
