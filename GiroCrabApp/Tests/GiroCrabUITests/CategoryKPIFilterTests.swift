import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// The KPI tiles of the category views count what the list shows (#357).
@MainActor
final class CategoryKPIFilterTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        model.period = .all
    }

    override func tearDown() async throws { model = nil }

    private func listFlow() throws -> [Int64] {
        let f = try XCTUnwrap(model.vault).listTransactions(filter: model.currentFilter).flow
        return [f.consumptionCents, f.investedCents, f.incomeCents]
    }

    private var tiles: [Int64] { [model.consumptionThisMonth, model.investedThisMonth, model.incomeThisMonth] }

    func testUncategorizedTilesFollowTheListFilters() throws {
        model.sidebarSelection = .uncategorized
        XCTAssertEqual(tiles, try listFlow())
        let account = try XCTUnwrap(model.allAccounts.first).id
        let changes: [() -> Void] = [
            { self.model.directionFilter = .income },
            { self.model.directionFilter = .all; self.model.amountFilter = AmountFilter(minCents: 5_000, maxCents: nil) },
            { self.model.amountFilter = AmountFilter(); self.model.statusFilter = .new },
            { self.model.statusFilter = .all; self.model.toggleCategoryAccount(account) },
        ]
        for change in changes {
            change()
            XCTAssertEqual(tiles, try listFlow())
        }
    }

    func testCategoryTilesFollowTheAmountFilter() throws {
        let category = try XCTUnwrap(model.categories.first { $0.depth == 0 && $0.transactionCount > 0 })
        model.sidebarSelection = .category(category.id)
        model.amountFilter = AmountFilter(minCents: 5_000, maxCents: nil)
        XCTAssertEqual(tiles, try listFlow())
    }

    func testOtherViewsKeepSummingTheWholeSelection() throws {
        model.sidebarSelection = .allAccounts
        let before = tiles
        model.amountFilter = AmountFilter(minCents: 5_000, maxCents: nil)
        XCTAssertEqual(tiles, before)
    }
}
