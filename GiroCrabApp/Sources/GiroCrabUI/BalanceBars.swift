import Foundation
import GiroCrabCore

/// Look of the balance history in the header (GitHub #203): the line shows every day,
/// bars show the average balance per month (or per day) and make trends and years comparable.
enum BalanceChartStyle: String, CaseIterable, Identifiable {
    case line
    case bars

    static let defaultsKey = "chart.balanceStyle"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: String(localized: "Linie")
        case .bars: String(localized: "Balken")
        }
    }
}

/// Width of one bar: automatic = days up to two months, months up to six years, years beyond.
enum BalanceBarUnit: String, CaseIterable, Identifiable {
    case automatic = "auto"
    case day
    case month
    case year

    static let defaultsKey = "chart.balanceBarUnit"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatisch")
        case .day: String(localized: "Tage")
        case .month: String(localized: "Monate")
        case .year: String(localized: "Jahre")
        }
    }

    /// Resolves `.automatic` against the length of the shown history.
    func resolved(dayCount: Int) -> BalanceBarUnit {
        guard self == .automatic else { return self }
        if dayCount <= 62 { return .day }
        // ~72 monthly bars still read as bars; beyond that they turn into a barcode
        return dayCount <= 6 * 366 ? .month : .year
    }

    /// Characters of the ISO date (`yyyy-MM-dd`) that identify one bar.
    var keyLength: Int {
        switch self {
        case .year: 4
        case .month: 7
        case .day, .automatic: 10
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .year: .year
        case .month: .month
        case .day, .automatic: .day
        }
    }
}

/// One bar: a day, calendar month or calendar year of the balance history.
struct BalanceBucket: Identifiable, Equatable {
    /// Position in the series (0 = oldest).
    let id: Int
    /// First day of the bucket (the day itself, the 1st of the month, or January 1st).
    let start: Date
    /// Last day of the bucket that has data (click target: its bookings).
    let last: Date
    /// Average end-of-day balance over the days of the bucket.
    let averageCents: Int64
    /// Balance at the end of the bucket's last day.
    let closingCents: Int64
    /// Days that went into the average.
    let days: Int

    var euros: Double { Double(averageCents) / 100 } // display only
}

enum BalanceBuckets {
    /// Groups the daily balances (`yyyy-MM-dd`, oldest first, one row per day) into bars.
    /// Months and years are grouped by their ISO prefix, so time zones never shift a day into
    /// the wrong bar.
    static func make(_ points: [DailyBalance], unit: BalanceBarUnit) -> [BalanceBucket] {
        let keyLength = unit.resolved(dayCount: points.count).keyLength
        let startSuffix = switch keyLength {
        case 4: "-01-01" // year -> January 1st
        case 7: "-01"    // month -> the 1st
        default: ""
        }
        var out: [BalanceBucket] = []
        var key = ""
        var sum: Int64 = 0
        var group: [DailyBalance] = []

        func flush() {
            guard let first = group.first, let lastPoint = group.last,
                  let lastDate = DateText.date(lastPoint.date),
                  let start = DateText.date(String(first.date.prefix(keyLength)) + startSuffix)
            else { return }
            let n = Int64(group.count)
            // rounded half away from zero, so a month at -0,5 ct does not show as +0
            let avg = (sum + (sum >= 0 ? n / 2 : -n / 2)) / n
            out.append(BalanceBucket(id: out.count, start: start, last: lastDate,
                                     averageCents: avg, closingCents: lastPoint.balanceCents, days: group.count))
        }

        for p in points {
            let k = String(p.date.prefix(keyLength))
            if k != key, !group.isEmpty {
                flush()
                group.removeAll(keepingCapacity: true)
                sum = 0
            }
            key = k
            group.append(p)
            sum += p.balanceCents
        }
        if !group.isEmpty { flush() }
        return out
    }

    /// January 1st of every year that starts after `first` and up to `last`:
    /// where the chart draws its year separators.
    static func yearStarts(from first: Date, to last: Date, calendar: Calendar = .current) -> [Date] {
        let y0 = calendar.component(.year, from: first)
        let y1 = calendar.component(.year, from: last)
        guard y1 > y0 else { return [] }
        return (y0 + 1...y1).compactMap { calendar.date(from: DateComponents(year: $0, month: 1, day: 1)) }
    }
}
