import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// The sidebar's category sums follow the list filters: period, status, accounts (GitHub #621).
@MainActor
final class CategorySumFilterTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    private var topLevelCount: Int { model.categories.filter { $0.depth == 0 }.reduce(0) { $0 + Int($1.transactionCount) } }

    func testNoFilterHasNoNoteAndNoNarrowing() {
        XCTAssertNil(model.categorySumNote)
        XCTAssertTrue(model.categorySumFilter.accounts.isEmpty)
        XCTAssertNil(model.categorySumFilter.checked)
    }

    func testStatusFilterNarrowsSums() throws {
        let all = topLevelCount
        XCTAssertGreaterThan(all, 0)
        model.statusFilter = .checked
        let checked = topLevelCount
        model.statusFilter = .new
        let new = topLevelCount
        XCTAssertEqual(checked + new, all)
        XCTAssertNotNil(model.categorySumNote)
        model.statusFilter = .all
        XCTAssertEqual(topLevelCount, all)
        XCTAssertNil(model.categorySumNote)
    }

    func testDirectionFilterNarrowsSums() throws {
        let all = model.categories.filter { $0.depth == 0 }.reduce(Int64(0)) { $0 + $1.totalCents }
        model.directionFilter = .income
        let income = model.categories.filter { $0.depth == 0 }.reduce(Int64(0)) { $0 + $1.totalCents }
        XCTAssertGreaterThan(income, 0)
        XCTAssertNotNil(model.categorySumNote)
        model.directionFilter = .expense
        let expense = model.categories.filter { $0.depth == 0 }.reduce(Int64(0)) { $0 + $1.totalCents }
        XCTAssertLessThan(expense, 0)
        XCTAssertEqual(income + expense, all)
        model.directionFilter = .all
        XCTAssertNil(model.categorySumNote)
    }

    func testAccountFilterNarrowsSumsInCategoryViews() throws {
        let category = try XCTUnwrap(model.categories.first { $0.depth == 0 && $0.transactionCount > 0 })
        model.sidebarSelection = .category(category.id)
        let all = topLevelCount
        let account = try XCTUnwrap(model.allAccounts.first)
        model.categoryAccountFilter = [account.id]
        XCTAssertLessThan(topLevelCount, all)
        XCTAssertEqual(model.categorySumFilter.accounts, [account.id])
        XCTAssertNotNil(model.categorySumNote)
        model.categoryAccountFilter = []
        XCTAssertEqual(topLevelCount, all)
    }
}
