import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Bar style of the balance history (GitHub #203): average balance per month or day.
final class BalanceBarsTests: XCTestCase {
    private func days(from start: String, count: Int, cents: (Int) -> Int64) -> [DailyBalance] {
        let first = DateText.date(start)!
        return (0..<count).map { i in
            let d = Calendar.current.date(byAdding: .day, value: i, to: first)!
            return DailyBalance(date: DateText.iso(d), balanceCents: cents(i))
        }
    }

    func testMonthlyBarsAverageEveryDayOfTheMonth() {
        // 2025-12-30 … 2026-02-02: Dec has 2 days, Jan 31, Feb 2
        let pts = days(from: "2025-12-30", count: 35) { Int64($0) * 100 }
        let bars = BalanceBuckets.make(pts, unit: .month)
        XCTAssertEqual(bars.count, 3)
        XCTAssertEqual(bars.map(\.days), [2, 31, 2])
        XCTAssertEqual(bars[0].averageCents, 50)              // (0 + 100) / 2
        XCTAssertEqual(bars[1].averageCents, 1_700)           // days 2…32 -> 17 €
        XCTAssertEqual(bars[1].closingCents, 3_200)
        XCTAssertEqual(DateText.iso(bars[1].start), "2026-01-01")
        XCTAssertEqual(DateText.iso(bars[1].last), "2026-01-31")
        XCTAssertEqual(bars.map(\.id), [0, 1, 2])
    }

    func testAutomaticUsesDaysForShortPeriods() {
        let short = days(from: "2026-10-01", count: 31) { _ in 1_000 }
        XCTAssertEqual(BalanceBuckets.make(short, unit: .automatic).count, 31)
        let long = days(from: "2026-01-01", count: 120) { _ in 1_000 }
        XCTAssertEqual(BalanceBuckets.make(long, unit: .automatic).count, 4)
        XCTAssertEqual(BalanceBuckets.make(long, unit: .day).count, 120)
    }

    func testNegativeAverageRoundsAwayFromZero() {
        let pts = days(from: "2026-03-01", count: 2) { $0 == 0 ? -1 : 0 }
        XCTAssertEqual(BalanceBuckets.make(pts, unit: .month).first?.averageCents, -1)
    }

    func testEmptyHistoryHasNoBars() {
        XCTAssertTrue(BalanceBuckets.make([], unit: .automatic).isEmpty)
    }

    func testYearSeparatorsSitOnJanuaryFirst() {
        let years = BalanceBuckets.yearStarts(from: DateText.date("2024-06-15")!, to: DateText.date("2026-02-01")!)
        XCTAssertEqual(years.map(DateText.iso), ["2025-01-01", "2026-01-01"])
        XCTAssertTrue(BalanceBuckets.yearStarts(from: DateText.date("2026-01-01")!, to: DateText.date("2026-12-31")!).isEmpty)
    }

    func testAxisShowsZeroMaxAndMin() {
        XCTAssertEqual(BalanceChart.axisValues(min: -1_000, max: 2_000, domain: -1_200...2_200), [0, 2_000, -1_000])
    }

    func testAxisDropsLabelsTooCloseTogether() {
        // stable positive balance: min sits right below max -> only 0 and max
        XCTAssertEqual(BalanceChart.axisValues(min: 9_500, max: 10_000, domain: 0...10_800), [0, 10_000])
        // line chart far above zero: zero is outside the shown range
        XCTAssertEqual(BalanceChart.axisValues(min: 4_000, max: 6_000, domain: 3_700...6_300), [6_000, 4_000])
    }

    func testCompactEurosIsShort() {
        let s = BalanceChart.compactEuros(12_345)
        XCTAssertTrue(s.hasSuffix(" €"))
        XCTAssertLessThanOrEqual(s.count, 12, s)
        XCTAssertTrue(BalanceChart.compactEuros(0).hasPrefix("0"))
        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(4_820.0.formatted(FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...3)).locale(de)), "4.820")
    }

    func testYearLabelsThinOutForLongHistories() {
        let steps = [1, 2, 5, 10, 20]
        // 3 years on a wide chart: every year
        XCTAssertEqual(BalanceChart.axisStride(units: 3, width: 800, labelWidth: 48, steps: steps), 1)
        // 15 years in 800 pt (16 labels fit): still every year; in 400 pt (8 fit): every 2nd
        XCTAssertEqual(BalanceChart.axisStride(units: 15, width: 800, labelWidth: 48, steps: steps), 1)
        XCTAssertEqual(BalanceChart.axisStride(units: 15, width: 400, labelWidth: 48, steps: steps), 2)
        // 30 years on a phone: every 10th
        XCTAssertEqual(BalanceChart.axisStride(units: 30, width: 300, labelWidth: 48, steps: steps), 5)
        XCTAssertEqual(BalanceChart.axisStride(units: 30, width: 150, labelWidth: 48, steps: steps), 10)
    }

    func testAutomaticUsesYearsBeyondSixYears() {
        XCTAssertEqual(BalanceBarUnit.automatic.resolved(dayCount: 6 * 365), .month)
        XCTAssertEqual(BalanceBarUnit.automatic.resolved(dayCount: 7 * 365), .year)
        let pts = days(from: "2018-12-30", count: 368) { Int64($0) }  // 2 days 2018, 365 2019, 1 day 2020
        let bars = BalanceBuckets.make(pts, unit: .year)
        XCTAssertEqual(bars.map(\.days), [2, 365, 1])
        XCTAssertEqual(bars.map { DateText.iso($0.start) }, ["2018-01-01", "2019-01-01", "2020-01-01"])
        XCTAssertEqual(bars[1].averageCents, 184)                 // days 2…366 -> 184
        XCTAssertEqual(DateText.iso(bars[1].last), "2019-12-31")
    }
}
