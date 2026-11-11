import XCTest
@testable import GiroCrabUI

/// Period presets and the user-defined range (GitHub #53).
@MainActor
final class PeriodTests: XCTestCase {
    private let now = DateText.date("2026-11-11")!

    func testLastYearIsThePreviousCalendarYear() {
        let (from, to) = Period.lastYear.range(now: now)
        XCTAssertEqual(from, "2025-01-01")
        XCTAssertEqual(to, "2025-12-31")
    }

    func testLast12MonthsIncludesTheCurrentMonth() {
        let (from, to) = Period.last12Months.range(now: now)
        XCTAssertEqual(from, "2025-12-01")
        XCTAssertNil(to)
    }

    func testPresetsExcludeCustom() {
        XCTAssertFalse(Period.presets.contains(.custom))
        XCTAssertEqual(Period.presets.count, Period.allCases.count - 1)
    }

    func testCustomPeriodDrivesFilterAndSwapsReversedDates() {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        model.applyCustomPeriod(from: DateText.date("2025-06-30")!, to: DateText.date("2025-03-15")!)
        XCTAssertEqual(model.period, .custom)
        XCTAssertEqual(model.periodRange.0, "2025-03-15")
        XCTAssertEqual(model.periodRange.1, "2025-06-30")
        XCTAssertEqual(model.currentFilter.dateFrom, "2025-03-15")
        XCTAssertEqual(model.currentFilter.dateTo, "2025-06-30")
        XCTAssertTrue(model.bookings.allSatisfy { $0.bookingDate >= "2025-03-15" && $0.bookingDate <= "2025-06-30" })
        XCTAssertNil(model.errorMessage)
    }
}
