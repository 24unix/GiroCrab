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

    func testQuartersFoldMonthsAndSpanThreeMonths() {
        let months = [
            CategoryPeriodSum(period: "2025-01", cents: -100),
            CategoryPeriodSum(period: "2025-03", cents: -200),
            CategoryPeriodSum(period: "2025-04", cents: -50),
            CategoryPeriodSum(period: "2025-12", cents: -7),
        ]
        let q = CategorySumChart.quarters(months)
        XCTAssertEqual(q.map(\.period), ["2025-01", "2025-04", "2025-10"])
        XCTAssertEqual(q.map(\.cents), [-300, -50, -7])
        let bars = CategorySumChart.bars(months, unit: .quarter)
        XCTAssertEqual(bars.count, 3)
        XCTAssertEqual(Calendar.current.component(.month, from: bars[0].end), 4)
        XCTAssertEqual(bars[0].cents, -300)
        // months stay one month wide
        XCTAssertEqual(Calendar.current.component(.month, from: CategorySumChart.bars(months)[0].end), 2)
    }

    func testAxisDatesAreThinnedToBars() {
        let bars = CategorySumChart.bars((1...12).map { CategoryPeriodSum(period: String(format: "2025-%02d", $0), cents: -1) })
        let ticks = CategorySumChart.axisDates(bars)
        XCTAssertLessThanOrEqual(ticks.count, 6)
        XCTAssertEqual(ticks.first, bars.first?.mid)
        XCTAssertTrue(CategorySumChart.axisDates([]).isEmpty)
    }

    @MainActor func testCategoryQuarterUnitLoadsMonths() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let cat = try XCTUnwrap(model.categories.first { $0.totalCents != 0 })
        model.sidebarSelection = .category(cat.id)
        model.categoryBarUnit = .quarter
        model.reloadCategoryHistory()
        XCTAssertEqual(model.effectiveCategoryBarUnit, .quarter)
        XCTAssertTrue(model.categoryHistory.allSatisfy { $0.period.count == 7 })
        let quarters = CategorySumChart.bars(model.categoryHistory, unit: .quarter)
        XCTAssertEqual(quarters.map(\.cents).reduce(0, +), model.categoryHistory.map(\.cents).reduce(0, +))
    }
}
