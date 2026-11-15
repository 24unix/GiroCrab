import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Category views can be narrowed to accounts (GitHub #406).
@MainActor
final class CategoryAccountFilterTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        model.period = .all
    }

    override func tearDown() async throws { model = nil }

    /// A category and an account that has bookings in it, next to bookings of other accounts.
    private func mixedCategory() throws -> (category: Int64, account: Int64) {
        let vault = try XCTUnwrap(model.vault)
        for c in model.categories {
            model.sidebarSelection = .category(c.id)
            let accounts = Set(try vault.listTransactions(filter: model.currentFilter).transactions.map(\.accountId))
            if accounts.count > 1, let first = accounts.min() { return (c.id, first) }
        }
        throw XCTSkip("The demo vault has no category with bookings of several accounts")
    }

    func testCategoryListFollowsTheChosenAccounts() throws {
        let (category, account) = try mixedCategory()
        model.sidebarSelection = .category(category)
        let all = model.bookings.count
        XCTAssertNotNil(model.headerBalance)

        model.toggleCategoryAccount(account)
        XCTAssertEqual(model.currentFilter.accountIds, [account])
        XCTAssertEqual(model.currentFilter.categoryId, category)
        XCTAssertFalse(model.bookings.isEmpty)
        XCTAssertLessThan(model.bookings.count, all)
        XCTAssertTrue(model.bookings.allSatisfy { $0.accountId == account })
        // the category total covers all accounts
        XCTAssertNil(model.headerBalance)

        // stays for the other category views …
        model.sidebarSelection = .uncategorized
        XCTAssertEqual(model.currentFilter.accountIds, [account])
        XCTAssertTrue(model.currentFilter.uncategorizedOnly)
        // … but never narrows the account views
        model.sidebarSelection = .allAccounts
        XCTAssertEqual(model.currentFilter.accountIds, [])

        model.sidebarSelection = .category(category)
        model.toggleCategoryAccount(account)
        XCTAssertEqual(model.currentFilter.accountIds, [])
        XCTAssertEqual(model.bookings.count, all)
    }

    func testAllAccountsChosenOrUnknownAccountsMeanNoFilter() throws {
        model.sidebarSelection = .uncategorized
        for a in model.allAccounts { model.toggleCategoryAccount(a.id) }
        XCTAssertTrue(model.categoryAccountFilter.isEmpty)
        XCTAssertEqual(model.categoryAccountFilterTitle, String(localized: "Konten: Alle"))

        // an account that no longer exists (deleted, other vault)
        model.categoryAccountFilter = [-42]
        XCTAssertEqual(model.currentFilter.accountIds, [])
    }
}
