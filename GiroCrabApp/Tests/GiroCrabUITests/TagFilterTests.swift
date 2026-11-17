import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Filtering and totals by tag (#228, part 3): the header's tag filter, the
/// totals of its popover and the per-account counts of „Tags verwalten“.
@MainActor
final class TagFilterTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        model.period = .all
        XCTAssertNil(model.errorMessage)
    }

    override func tearDown() async throws { model = nil }

    private func tag(_ name: String) throws -> GiroCrabCore.Tag {
        try XCTUnwrap(model.tags.first { $0.name == name }, "no tag \(name)")
    }

    private func awaitLoad() async throws {
        for _ in 0..<300 {
            if !model.isLoadingSelection, model.selectionLoadTask == nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The selection load did not finish")
    }

    private func carries(_ b: Booking, _ id: Int64) -> Bool { b.tags.contains { $0.id == id } }

    func testTickedTagsNarrowTheListAndCombineWithAnd() throws {
        let auto = try tag("Auto"), urlaub = try tag("Urlaub")
        let all = model.bookingCountLabel
        model.toggleTagFilter(auto.id)
        XCTAssertEqual(model.currentFilter.tagIds, [auto.id])
        XCTAssertEqual(model.bookingCountLabel, Int(auto.bookingCount), "all accounts, all dates: every Auto booking")
        XCTAssertTrue(model.bookings.allSatisfy { carries($0, auto.id) })
        XCTAssertEqual(model.tagFilterTitle, "Tags: 1")
        XCTAssertFalse(model.currentFilter.listHasFlow, "the narrowed list's sums are not the selection's KPIs")

        model.toggleTagFilter(urlaub.id)
        XCTAssertFalse(model.bookings.isEmpty, "the demo has a booking with both")
        XCTAssertTrue(model.bookings.allSatisfy { carries($0, auto.id) && carries($0, urlaub.id) })
        XCTAssertLessThan(model.bookingCountLabel, Int(auto.bookingCount))

        model.toggleUntaggedFilter()
        XCTAssertEqual(model.tagFilter, BookingTagFilter(untagged: true), "„Ohne Tag“ replaces the ticked tags")
        XCTAssertTrue(model.bookings.allSatisfy { $0.tags.isEmpty })
        XCTAssertEqual(model.tagFilterTitle, "Ohne Tag")

        model.toggleTagFilter(auto.id)
        XCTAssertFalse(model.tagFilter.untagged, "ticking a tag ends „Ohne Tag“")
        model.clearTagFilter()
        XCTAssertEqual(model.bookingCountLabel, all)
        XCTAssertTrue(model.currentFilter.listHasFlow)
    }

    func testTotalsAreWhatTickingATagLists() async throws {
        model.statusFilter = .checked
        let loaded = await model.loadTagTotals()
        let totals = try XCTUnwrap(loaded)
        for t in model.tags {
            model.tagFilter = BookingTagFilter(tagIDs: [t.id])
            XCTAssertEqual(Int(totals[t.id]?.bookingCount ?? 0), model.bookingCountLabel, t.name)
            XCTAssertEqual(totals[t.id]?.sumCents ?? 0, model.bookings.reduce(0) { $0 + $1.amountCents }, t.name)
        }
        model.tagFilter = BookingTagFilter(untagged: true)
        XCTAssertEqual(Int(totals[nil]?.bookingCount ?? 0), model.bookingCountLabel)
        // the popover's numbers ignore its own ticks
        let reloaded = await model.loadTagTotals()
        let again = try XCTUnwrap(reloaded)
        XCTAssertEqual(again.mapValues(\.bookingCount), totals.mapValues(\.bookingCount))
    }

    func testDeletedTagLeavesTheFilter() throws {
        let auto = try tag("Auto"), urlaub = try tag("Urlaub")
        model.tagFilter = BookingTagFilter(tagIDs: [auto.id, urlaub.id])
        model.deleteTags([urlaub.id])
        XCTAssertEqual(model.tagFilter.tagIDs, [auto.id])
    }

    func testMerchantListDropsAndRestoresTheTagFilter() throws {
        let auto = try tag("Auto")
        model.toggleTagFilter(auto.id)
        let booking = try XCTUnwrap(model.bookings.first { !$0.merchant.key.isEmpty })
        model.focusMerchant(of: booking)
        XCTAssertFalse(model.tagFilter.isActive)
        model.leaveMerchantFocus()
        XCTAssertEqual(model.tagFilter.tagIDs, [auto.id])
    }

    func testAccountCountsAddUpAndListTheirBookings() async throws {
        let auto = try tag("Auto")
        let loaded = await model.loadTagAccountCounts(auto.id)
        let rows = try XCTUnwrap(loaded)
        XCTAssertEqual(rows.filter { !$0.linked }.reduce(0) { $0 + $1.bookingCount }, auto.bookingCount,
                       "each booking once, at its own account")
        let first = try XCTUnwrap(rows.first)
        XCTAssertFalse(first.linked)

        model.period = .months12
        model.statusFilter = .checked
        model.showTagManager = true
        model.showBookings(ofTag: auto.id, account: first.accountId)
        try await awaitLoad()
        XCTAssertFalse(model.showTagManager)
        XCTAssertEqual(model.sidebarSelection, .account(first.accountId))
        XCTAssertEqual(model.period, .all)
        XCTAssertEqual(model.statusFilter, .all)
        XCTAssertEqual(model.tagFilter.tagIDs, [auto.id])
        XCTAssertEqual(model.bookingCountLabel, Int(first.bookingCount))
        XCTAssertTrue(model.bookings.allSatisfy { carries($0, auto.id) && $0.accountId == first.accountId })
    }

    func testLinkedLoanRowListsTheRatesShownInTheLoan() async throws {
        let auto = try tag("Auto")
        let loaded = await model.loadTagAccountCounts(auto.id)
        let loan = try XCTUnwrap(loaded?.first { $0.linked }, "the demo's Autobank rates are linked to the Autokredit")
        XCTAssertEqual(model.accountsByID[loan.accountId]?.kind, .loan)
        model.showBookings(ofTag: auto.id, account: loan.accountId)
        try await awaitLoad()
        XCTAssertEqual(model.bookingCountLabel, Int(loan.bookingCount))
        XCTAssertTrue(model.bookings.allSatisfy { carries($0, auto.id) && $0.accountId != loan.accountId },
                      "rates of the Girokonto, shown in the loan")
    }

    func testNewBookingsIgnoreTheTagFilter() throws {
        model.toggleTagFilter(try tag("Auto").id)
        model.sidebarSelection = .newBookings
        XCTAssertTrue(model.currentFilter.tagIds.isEmpty)
        XCTAssertFalse(model.showsTagFilter)
    }
}
