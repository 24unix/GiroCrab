import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// The cashflow card follows the sidebar selection (#731).
@MainActor
final class CashflowSelectionTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    private func totals(_ ids: [Int64]) async throws -> (income: Int64, expense: Int64) {
        let loaded = await model.cashflow(.year, count: 5, accountIds: ids)
        let rows = try XCTUnwrap(loaded)
        return (rows.map(\.incomeCents).reduce(0, +), rows.map(\.expenseCents).reduce(0, +))
    }

    func testOverviewSelectsAllAccounts() {
        model.sidebarSelection = .allAccounts
        XCTAssertEqual(model.currentFilter.accountIds, [])
    }

    func testSingleAccountIsSubsetOfAll() async throws {
        let all = try await totals([])
        XCTAssertGreaterThan(all.income + all.expense, 0, "demo vault has bookings")
        var differs = false
        for account in model.allAccounts {
            model.sidebarSelection = .account(account.id)
            XCTAssertEqual(model.currentFilter.accountIds, [account.id])
            let one = try await totals(model.currentFilter.accountIds)
            XCTAssertLessThanOrEqual(one.income, all.income)
            XCTAssertLessThanOrEqual(one.expense, all.expense)
            if one.income != all.income || one.expense != all.expense { differs = true }
        }
        // At least one account shows less than the whole vault, i.e. the filter is applied.
        XCTAssertTrue(differs)
        // Selecting every account equals the overview.
        let ids = model.allAccounts.map(\.id)
        let together = try await totals(ids)
        XCTAssertEqual(together.income, all.income)
        XCTAssertEqual(together.expense, all.expense)
    }
}
