import XCTest
@testable import GiroCrabUI

/// The period menu (GitHub #382, like MoneyMoney) and the user-defined range (GitHub #53).
@MainActor
final class PeriodTests: XCTestCase {
    private let now = DateText.date("2026-11-11")!

    func testMenuSectionsCountBackFromToday() {
        XCTAssertEqual(Period.menu(now: now), [
            [.all],
            [.days(30), .days(90), .months12, .sinceSalary],
            [.month(2026, 11), .month(2026, 10), .month(2026, 9)],
            [.quarter(2026, 4), .quarter(2026, 3), .quarter(2026, 2)],
            [.year(2026), .year(2025), .year(2024)],
        ])
    }

    func testMenuCrossesTheYearBoundary() {
        let menu = Period.menu(now: DateText.date("2026-02-10")!)
        XCTAssertEqual(menu[2], [.month(2026, 2), .month(2026, 1), .month(2025, 12)])
        XCTAssertEqual(menu[3], [.quarter(2026, 1), .quarter(2025, 4), .quarter(2025, 3)])
    }

    func testCalendarPeriodsRunFromFirstToLastDay() {
        XCTAssertTrue(Period.month(2026, 2).range(now: now) == ("2026-02-01", "2026-02-28"))
        XCTAssertTrue(Period.month(2024, 2).range(now: now) == ("2024-02-01", "2024-02-29"))
        XCTAssertTrue(Period.quarter(2025, 4).range(now: now) == ("2025-10-01", "2025-12-31"))
        XCTAssertTrue(Period.year(2025).range(now: now) == ("2025-01-01", "2025-12-31"))
    }

    func testRollingPeriodsEndToday() {
        XCTAssertTrue(Period.days(30).range(now: now) == ("2026-10-13", nil))
        XCTAssertTrue(Period.days(90).range(now: now) == ("2026-08-14", nil))
        XCTAssertTrue(Period.months12.range(now: now) == ("2025-11-12", nil))
        XCTAssertTrue(Period.all.range(now: now) == (nil, nil))
    }

    func testTitlesNameTheYear() {
        XCTAssertTrue(Period.year(2025).title.contains("2025"))
        XCTAssertTrue(Period.quarter(2026, 4).title.contains("2026"))
        XCTAssertTrue(Period.month(2026, 11).title.contains("2026"))
        XCTAssertNotEqual(Period.month(2026, 11).title, Period.month(2026, 10).title)
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

    func testPeriodFiltersBookingsOfTheMonth() {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let month = Period.menu(now: Date())[2][1]
        model.period = month
        let (from, to) = month.range(now: Date())
        XCTAssertEqual(model.currentFilter.dateFrom, from)
        XCTAssertEqual(model.currentFilter.dateTo, to)
    }
}
