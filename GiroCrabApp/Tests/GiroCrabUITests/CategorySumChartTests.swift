import XCTest
import GiroCrabCore
@testable import GiroCrabUI

final class CategorySumChartTests: XCTestCase {
    func testBarsParseMonthsAndFlipExpenseOnlySeries() {
        let bars = CategorySumChart.bars([
            CategoryPeriodSum(period: "2025-01", cents: -1500),
            CategoryPeriodSum(period: "2025-03", cents: -2000),
        ])
        XCTAssertEqual(bars.count, 2)
        XCTAssertTrue(CategorySumChart.flipsSign(bars))
        let mixed = CategorySumChart.bars([
            CategoryPeriodSum(period: "2025-01", cents: -1500),
            CategoryPeriodSum(period: "2025-02", cents: 500),
        ])
        XCTAssertFalse(CategorySumChart.flipsSign(mixed))
        XCTAssertFalse(CategorySumChart.flipsSign([]))
    }

    @MainActor func testCategorySelectionLoadsMonthlySums() async throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let cat = try XCTUnwrap(model.categories.first { $0.totalCents != 0 })
        model.sidebarSelection = .category(cat.id)
        model.reloadCategoryHistory()
        XCTAssertFalse(model.categoryHistory.isEmpty)
        model.sidebarSelection = .allAccounts
        model.reloadCategoryHistory()
        XCTAssertTrue(model.categoryHistory.isEmpty)
    }

    func testBarsParseYearAndDayPeriods() {
        let years = CategorySumChart.bars([CategoryPeriodSum(period: "2024", cents: -100), CategoryPeriodSum(period: "2025", cents: -200)])
        XCTAssertEqual(years.count, 2)
        XCTAssertEqual(Calendar.current.component(.year, from: years[1].start), 2025)
        let days = CategorySumChart.bars([CategoryPeriodSum(period: "2025-03-14", cents: -100)])
        XCTAssertEqual(Calendar.current.component(.day, from: days[0].start), 14)
    }

    @MainActor func testCategoryBarUnitControlsGrouping() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let cat = try XCTUnwrap(model.categories.first { $0.totalCents != 0 })
        model.sidebarSelection = .category(cat.id)
        model.categoryBarUnit = .month
        model.reloadCategoryHistory()
        let months = model.categoryHistory
        XCTAssertTrue(months.allSatisfy { $0.period.count == 7 })
        model.categoryBarUnit = .year
        model.reloadCategoryHistory()
        XCTAssertTrue(model.categoryHistory.allSatisfy { $0.period.count == 4 })
        XCTAssertEqual(model.categoryHistory.map(\.cents).reduce(0, +), months.map(\.cents).reduce(0, +))
        model.categoryBarUnit = .day
        model.reloadCategoryHistory()
        XCTAssertTrue(model.categoryHistory.allSatisfy { $0.period.count == 10 })
        XCTAssertGreaterThanOrEqual(model.categoryHistory.count, months.count)
    }
}
