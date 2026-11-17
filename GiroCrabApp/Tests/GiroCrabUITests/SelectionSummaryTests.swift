import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// #878: count and sum of the selected bookings, over all accounts, one sum per currency.
@MainActor
final class SelectionSummaryTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    func testNoTotalsWithoutSelection() {
        model.selectedBookingIDs = []
        XCTAssertTrue(model.selectionTotals.isEmpty)
        XCTAssertFalse(model.isMultiSelection)
    }

    func testTotalsSumSelectionPerCurrency() throws {
        let bookings = Array(model.visibleBookings.prefix(5))
        try XCTSkipIf(bookings.count < 2, "demo vault has too few bookings")
        model.selectedBookingIDs = Set(bookings.map(\.id))
        XCTAssertTrue(model.isMultiSelection)
        let totals = model.selectionTotals
        for t in totals {
            let expected = bookings.filter { $0.currency == t.currency }.reduce(Int64(0)) { $0 + $1.amountCents }
            XCTAssertEqual(t.cents, expected, t.currency)
        }
        XCTAssertEqual(totals.map(\.currency), totals.map(\.currency).sorted())
        XCTAssertEqual(Set(totals.map(\.currency)), Set(bookings.map(\.currency)))
    }

    func testTotalsUpdateWhenSelectionChanges() throws {
        let bookings = Array(model.visibleBookings.prefix(3))
        try XCTSkipIf(bookings.count < 3, "demo vault has too few bookings")
        model.selectedBookingIDs = Set(bookings.map(\.id))
        let all = model.selectionTotals.reduce(Int64(0)) { $0 + $1.cents }
        model.selectedBookingIDs.remove(bookings[0].id)
        let fewer = model.selectionTotals.reduce(Int64(0)) { $0 + $1.cents }
        XCTAssertEqual(all - fewer, bookings[0].amountCents)
    }
}
