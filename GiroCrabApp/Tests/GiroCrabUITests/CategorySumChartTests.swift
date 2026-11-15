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
}
