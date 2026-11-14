import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// „Neue Umsätze“ (GitHub #352): unreviewed bookings of all accounts, one card per account.
@MainActor
final class NewBookingsTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    /// Three demo accounts and a few demo bookings to build sections from.
    private func samples() throws -> (accounts: [Account], booking: Booking) {
        let accounts = Array(model.allAccounts.prefix(3))
        XCTAssertEqual(accounts.count, 3)
        let booking = try XCTUnwrap(model.bookings.first)
        return (accounts, booking)
    }

    private func booking(_ base: Booking, id: Int64, account: Int64, cents: Int64 = -100, pending: Bool = false) -> Booking {
        var b = base
        b.id = id
        b.accountId = account
        b.amountCents = cents
        b.isPending = pending
        return b
    }

    func testSectionsFollowAccountOrderAndSkipAccountsWithoutBookings() throws {
        let (accounts, base) = try samples()
        let (a, c) = (accounts[0].id, accounts[2].id)
        let bookings = [booking(base, id: 1, account: c), booking(base, id: 2, account: a)]
        XCTAssertEqual(NewBookings.sections(bookings: bookings, accounts: accounts).map(\.id), [a, c])
    }

    func testSectionKeepsBookingOrderAndSumsPending() throws {
        let (accounts, base) = try samples()
        let a = accounts[0].id
        let bookings = [
            booking(base, id: 3, account: a, cents: -100, pending: true),
            booking(base, id: 1, account: a, cents: -999),
            booking(base, id: 2, account: a, cents: -50, pending: true),
        ]
        let section = try XCTUnwrap(NewBookings.sections(bookings: bookings, accounts: accounts).first)
        XCTAssertEqual(section.bookings.map(\.id), [3, 1, 2])
        XCTAssertEqual(section.pendingCents, -150)
    }

    func testUnknownAccountGetsOwnSection() throws {
        let (accounts, base) = try samples()
        var stray = booking(base, id: 9, account: 987_654)
        stray.accountName = "Altes Konto"
        let bookings = [stray, booking(base, id: 1, account: accounts[1].id)]
        let sections = NewBookings.sections(bookings: bookings, accounts: accounts)
        XCTAssertEqual(sections.map(\.id), [accounts[1].id, 987_654])
        XCTAssertNil(sections[1].account)
        XCTAssertEqual(sections[1].title, "Altes Konto")
    }

    func testNewBookingsFilterOnlyUnchecked() throws {
        let picked = Array(model.bookings.prefix(2))
        XCTAssertEqual(picked.count, 2)
        for b in picked { model.setChecked(false, for: b) }
        model.sidebarSelection = .newBookings
        let filter = model.currentFilter
        XCTAssertEqual(filter.checked, false)
        XCTAssertTrue(filter.accountIds.isEmpty)
        XCTAssertFalse(model.bookings.isEmpty)
        XCTAssertTrue(model.bookings.allSatisfy { !$0.checked })
        XCTAssertTrue(Set(picked.map(\.id)).isSubset(of: Set(model.bookings.map(\.id))))
    }

    func testNewBookingsIgnoresListFilters() {
        model.period = Period.menu()[2][0]
        model.directionFilter = .income
        model.statusFilter = .checked
        model.searchText = "zzz"
        model.sidebarSelection = .newBookings
        let filter = model.currentFilter
        XCTAssertNil(filter.dateFrom)
        XCTAssertNil(filter.dateTo)
        XCTAssertEqual(filter.direction, .all)
        XCTAssertEqual(filter.checked, false)
        XCTAssertNil(filter.search)
    }

    func testCheckedBookingStaysInInspector() throws {
        let target = try XCTUnwrap(model.bookings.first)
        model.setChecked(false, for: target)
        model.sidebarSelection = .newBookings
        model.selectedBookingID = target.id
        let shown = try XCTUnwrap(model.bookings.first { $0.id == target.id })
        model.setChecked(true, for: shown)
        XCTAssertFalse(model.newBookingSections.flatMap(\.bookings).contains { $0.id == target.id })
        XCTAssertEqual(model.selectedBooking?.id, target.id)
    }

    func testTitleIsNeueUmsaetze() {
        model.sidebarSelection = .newBookings
        XCTAssertEqual(model.title, "Neue Umsätze")
        XCTAssertNil(model.headerBalance)
    }

    func testSectionsSkipCheckedBookings() throws {
        let (accounts, base) = try samples()
        var done = booking(base, id: 2, account: accounts[0].id)
        done.checked = true
        var open = booking(base, id: 1, account: accounts[0].id)
        open.checked = false
        let sections = NewBookings.sections(bookings: [done, open], accounts: accounts)
        XCTAssertEqual(sections.flatMap(\.bookings).map(\.id), [1])
    }

    /// Entering the page must not select (and so auto-review) a booking nobody clicked.
    func testEnteringPageDoesNotSelectABooking() throws {
        let unchecked = Array(model.bookings.prefix(3))
        for b in unchecked { model.setChecked(false, for: b) }
        let other = try XCTUnwrap(model.bookings.first { !unchecked.map(\.id).contains($0.id) && $0.checked })
        model.selectedBookingID = other.id
        model.sidebarSelection = .newBookings
        XCTAssertNil(model.selectedBookingID)
    }

    /// ↑/↓ and ⇧-click follow the cards, not the date order across accounts.
    func testVisibleBookingsFollowCardOrder() throws {
        for b in model.bookings.prefix(40) { model.setChecked(false, for: b) }
        model.sidebarSelection = .newBookings
        let cardOrder = model.newBookingSections.flatMap(\.bookings).map(\.id)
        XCTAssertGreaterThan(model.newBookingSections.count, 1)
        XCTAssertNotEqual(model.bookings.map(\.id), cardOrder, "demo data must interleave accounts")
        XCTAssertEqual(model.visibleBookings.map(\.id), cardOrder)
    }

    func testPrintoutDoesNotNameAPeriod() throws {
        model.period = Period.menu()[2][0]
        model.sidebarSelection = .newBookings
        let report = try XCTUnwrap(model.printSource())
        XCTAssertEqual(report.periodLabel, Period.all.title)
        XCTAssertFalse(model.showsAccountMarkers)
    }
}
