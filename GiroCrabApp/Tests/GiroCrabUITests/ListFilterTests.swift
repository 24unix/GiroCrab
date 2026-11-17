import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Account filter beyond the category views and amount range of the booking list (GitHub #357).
@MainActor
final class ListFilterTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        model.period = .all
    }

    override func tearDown() async throws { model = nil }

    // MARK: - Account filter

    func testAccountFilterIsOfferedWhereSeveralAccountsAreListed() throws {
        model.sidebarSelection = .allAccounts
        XCTAssertTrue(model.showsAccountFilter)
        XCTAssertEqual(model.accountFilterCandidates.map(\.id), model.allAccounts.map(\.id))
        model.sidebarSelection = .newBookings
        XCTAssertTrue(model.showsAccountFilter)
        model.sidebarSelection = .uncategorized
        XCTAssertTrue(model.showsAccountFilter)
        let id = try XCTUnwrap(model.allAccounts.first?.id)
        model.sidebarSelection = .account(id)
        XCTAssertFalse(model.showsAccountFilter)
    }

    func testAllAccountsListFollowsTheChosenAccounts() throws {
        model.sidebarSelection = .allAccounts
        let all = model.bookings.count
        let account = try XCTUnwrap(Set(model.bookings.map(\.accountId)).min())
        model.toggleCategoryAccount(account)
        XCTAssertEqual(model.currentFilter.accountIds, [account])
        XCTAssertFalse(model.bookings.isEmpty)
        XCTAssertLessThan(model.bookings.count, all)
        XCTAssertTrue(model.bookings.allSatisfy { $0.accountId == account })
        // a total of all accounts would be wrong now
        XCTAssertNil(model.headerBalance)

        model.toggleCategoryAccount(account)
        XCTAssertEqual(model.bookings.count, all)
    }

    func testGroupOffersOnlyItsAccountsAndNarrowsWithinThem() throws {
        let group = try XCTUnwrap(model.groups.first { $0.accounts.count > 1 })
        let ids = group.accounts.map(\.id)
        model.sidebarSelection = .group(group.id)
        XCTAssertEqual(model.accountFilterCandidates.map(\.id), ids)
        XCTAssertEqual(model.currentFilter.accountIds, ids)
        XCTAssertNotNil(model.headerBalance)

        let first = try XCTUnwrap(ids.first)
        model.toggleCategoryAccount(first)
        XCTAssertEqual(model.currentFilter.accountIds, [first])
        XCTAssertNil(model.headerBalance)
        XCTAssertEqual(model.categoryAccountFilterTitle, String(localized: "Konten: 1 von \(ids.count)"))

        // an account of another group is no choice here: the whole group stays
        let outsider = try XCTUnwrap(model.allAccounts.first { !ids.contains($0.id) })
        model.categoryAccountFilter = [outsider.id]
        XCTAssertEqual(model.currentFilter.accountIds, ids)
        XCTAssertEqual(model.categoryAccountFilterTitle, String(localized: "Konten: Alle"))
    }

    func testNewBookingsFollowTheAccountFilter() throws {
        model.sidebarSelection = .newBookings
        let unfiltered = model.currentFilter
        XCTAssertEqual(unfiltered.accountIds, [])
        XCTAssertEqual(unfiltered.checked, false)
        let account = try XCTUnwrap(Set(model.bookings.map(\.accountId)).min())
        model.toggleCategoryAccount(account)
        XCTAssertEqual(model.currentFilter.accountIds, [account])
        XCTAssertEqual(model.currentFilter.checked, false)
        XCTAssertTrue(model.bookings.allSatisfy { $0.accountId == account && !$0.checked })
    }

    // MARK: - Amount range

    func testAmountFilterNarrowsTheListByAbsoluteAmount() throws {
        model.sidebarSelection = .allAccounts
        let all = model.bookings
        XCTAssertEqual(model.currentFilter.amountMinCents, nil)

        model.amountFilter = AmountFilter(minCents: 5_000, maxCents: 20_000)
        XCTAssertEqual(model.currentFilter.amountMinCents, 5_000)
        XCTAssertEqual(model.currentFilter.amountMaxCents, 20_000)
        XCTAssertFalse(model.bookings.isEmpty)
        XCTAssertTrue(model.bookings.allSatisfy { (5_000...20_000).contains(abs($0.amountCents)) })
        XCTAssertEqual(model.bookings.count, all.filter { (5_000...20_000).contains(abs($0.amountCents)) }.count)
        // income and expenses both count
        XCTAssertTrue(model.bookings.contains { $0.amountCents > 0 })
        XCTAssertTrue(model.bookings.contains { $0.amountCents < 0 })
        // the pre-summed flow of the page no longer stands for the selection
        XCTAssertFalse(model.currentFilter.listHasFlow)

        // with the direction filter
        model.directionFilter = .expense
        XCTAssertTrue(model.bookings.allSatisfy { $0.amountCents < 0 && (5_000...20_000).contains(-$0.amountCents) })

        model.directionFilter = .all
        model.amountFilter = AmountFilter()
        XCTAssertEqual(model.bookings.count, all.count)
        XCTAssertTrue(model.currentFilter.listHasFlow)
    }

    func testAmountFilterAlsoNarrowsNewBookings() throws {
        model.sidebarSelection = .newBookings
        model.amountFilter = AmountFilter(minCents: 10_000, maxCents: nil)
        XCTAssertEqual(model.currentFilter.amountMinCents, 10_000)
        XCTAssertTrue(model.bookings.allSatisfy { abs($0.amountCents) >= 10_000 && !$0.checked })
    }

    func testAmountFilterFromTheHeaderLoadsInTheBackground() async throws {
        model.sidebarSelection = .allAccounts
        let all = model.bookings.count
        model.interactiveAmountFilter = AmountFilter(minCents: 5_000, maxCents: nil)
        // the control returns at once; the old list stays until the new one is in
        XCTAssertEqual(model.bookings.count, all)
        for _ in 0..<100 where model.selectionLoadTask != nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(model.selectionLoadTask)
        XCTAssertLessThan(model.bookings.count, all)
        XCTAssertTrue(model.bookings.allSatisfy { abs($0.amountCents) >= 5_000 })
    }

    func testAmountFilterTitleShowsTheRange() {
        XCTAssertFalse(AmountFilter().isActive)
        XCTAssertEqual(AmountFilter().title, String(localized: "Betrag"))
        let range = AmountFilter(minCents: 5_000, maxCents: 20_000)
        XCTAssertTrue(range.isActive)
        XCTAssertEqual(range.title, String(localized: "Betrag: \(Money.format(5_000)) – \(Money.format(20_000))"))
        XCTAssertEqual(AmountFilter(minCents: 10_000, maxCents: nil).title, String(localized: "Betrag: ≥ \(Money.format(10_000))"))
        XCTAssertEqual(AmountFilter(minCents: nil, maxCents: 10_000).title, String(localized: "Betrag: ≤ \(Money.format(10_000))"))
        XCTAssertEqual(AmountFilter(minCents: 10_000, maxCents: 10_000).title, String(localized: "Betrag: \(Money.format(10_000))"))
    }

    func testReversedRangeIsSwapped() {
        XCTAssertEqual(AmountFilter(minCents: 20_000, maxCents: 5_000).normalized, AmountFilter(minCents: 5_000, maxCents: 20_000))
        XCTAssertEqual(AmountFilter(minCents: 5_000, maxCents: nil).normalized, AmountFilter(minCents: 5_000, maxCents: nil))
    }
}
