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

    /// #357: the amount range narrows the sidebar's category sums like the list.
    func testAmountRangeNarrowsSums() throws {
        let all = topLevelCount
        XCTAssertGreaterThan(all, 0)
        model.amountFilter = AmountFilter(minCents: 10_001, maxCents: nil)
        let above = topLevelCount
        model.amountFilter = AmountFilter(minCents: nil, maxCents: 10_000)
        let below = topLevelCount
        XCTAssertLessThan(above, all)
        XCTAssertLessThan(below, all)
        XCTAssertEqual(above + below, all)
        XCTAssertEqual(model.categorySumFilter.amount, AmountFilter(minCents: nil, maxCents: 10_000))
        XCTAssertNotNil(model.categorySumNote)
        model.amountFilter = AmountFilter()
        XCTAssertEqual(topLevelCount, all)
        XCTAssertNil(model.categorySumNote)
    }

    /// #357: the account filter narrows the sums only in the category views, where it belongs to them;
    /// „Alle Konten“ keeps summing everything and the other filters apply everywhere.
    func testAccountFilterNarrowsSumsOnlyInCategoryViews() throws {
        model.sidebarSelection = .allAccounts
        let all = topLevelCount
        let account = try XCTUnwrap(model.allAccounts.first { $0.kind != .loan }).id
        model.toggleCategoryAccount(account)
        XCTAssertEqual(model.categorySumFilter.accounts, [])
        XCTAssertEqual(topLevelCount, all)
        let category = try XCTUnwrap(model.categories.first { $0.depth == 0 })
        model.sidebarSelection = .category(category.id)
        XCTAssertEqual(model.categorySumFilter.accounts, [account])
        model.reloadCategories() // a synchronous selection change keeps the sums; the interactive one reloads them
        XCTAssertLessThan(topLevelCount, all)
        model.sidebarSelection = .allAccounts
        model.reloadCategories()
        XCTAssertEqual(topLevelCount, all)
        model.directionFilter = .income
        model.reloadCategories()
        XCTAssertNotEqual(topLevelCount, all)
    }

    /// #357: the badge of „Ohne Kategorie“ counts what the filters leave.
    func testUncategorizedBadgeFollowsTheFilters() throws {
        let vault = try XCTUnwrap(model.vault)
        let plain = model.uncategorizedCount
        XCTAssertGreaterThan(plain, 0)
        XCTAssertNil(model.uncategorizedFilteredCount)

        func expected() throws -> Int {
            let q = try XCTUnwrap(model.uncategorizedCountFilter(model.categorySumFilter))
            return Int(try vault.countTransactions(filter: q))
        }
        model.amountFilter = AmountFilter(minCents: 5_000, maxCents: nil)
        XCTAssertLessThan(model.uncategorizedCount, plain)
        XCTAssertEqual(model.uncategorizedCount, try expected())
        model.amountFilter = AmountFilter()
        XCTAssertEqual(model.uncategorizedCount, plain)

        model.directionFilter = .income
        XCTAssertEqual(model.uncategorizedCount, try expected())
        model.directionFilter = .expense
        let expense = model.uncategorizedCount
        model.directionFilter = .income
        XCTAssertEqual(model.uncategorizedCount + expense, plain)
        model.directionFilter = .all

        let account = try XCTUnwrap(model.allAccounts.first { $0.kind != .loan && $0.uncategorizedCount > 0 })
        model.sidebarSelection = .allAccounts
        model.toggleCategoryAccount(account.id)
        XCTAssertEqual(model.uncategorizedCount, plain) // the account filter belongs to the category views
        model.sidebarSelection = .uncategorized
        model.reloadCategories() // a synchronous selection change keeps the sums; the interactive one reloads them
        XCTAssertEqual(model.uncategorizedCount, try expected())
        XCTAssertLessThan(model.uncategorizedCount, plain)
    }
}
