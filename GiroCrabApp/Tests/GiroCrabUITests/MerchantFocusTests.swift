import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// "Händler-Historie" opens the list of one merchant's bookings (#495).
@MainActor
final class MerchantFocusTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    private func awaitLoad() async throws {
        for _ in 0..<300 {
            if !model.isLoadingSelection, model.selectionLoadTask == nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The selection load did not finish")
    }

    /// A merchant that books on the chosen account and has several bookings overall.
    private func sample() throws -> (account: Int64, booking: Booking) {
        let all = model.bookings
        let byKey = Dictionary(grouping: all.filter { !$0.merchant.key.isEmpty }, by: \.merchant.key)
        let pick = try XCTUnwrap(byKey.values.filter { $0.count > 1 }.max { $0.count < $1.count }?.first)
        return (pick.accountId, pick)
    }

    func testFocusDropsEveryFilterButThePeriodAndReturns() async throws {
        let (account, booking) = try sample()
        model.sidebarSelection = .account(account)
        model.period = .months12
        model.statusFilter = .checked
        model.directionFilter = .expense
        model.searchText = "zzz"
        let (from, to) = model.periodRange

        model.focusMerchant(of: booking)
        try await awaitLoad()

        XCTAssertEqual(model.merchantFocus?.key, booking.merchant.key)
        XCTAssertEqual(model.sidebarSelection, .allAccounts)
        let f = model.currentFilter
        XCTAssertEqual(f.merchantKey, booking.merchant.key)
        XCTAssertTrue(f.accountIds.isEmpty)
        XCTAssertNil(f.categoryId)
        XCTAssertFalse(f.uncategorizedOnly)
        XCTAssertNil(f.search)
        XCTAssertNil(f.checked)
        XCTAssertEqual(f.direction, .all)
        XCTAssertEqual(f.scope, .all)
        XCTAssertEqual(f.dateFrom, from)
        XCTAssertEqual(f.dateTo, to)
        XCTAssertFalse(model.bookings.isEmpty)
        XCTAssertTrue(model.bookings.allSatisfy { $0.merchant.key == booking.merchant.key })

        model.leaveMerchantFocus()
        try await awaitLoad()

        XCTAssertNil(model.merchantFocus)
        XCTAssertEqual(model.sidebarSelection, .account(account))
        XCTAssertEqual(model.statusFilter, .checked)
        XCTAssertEqual(model.directionFilter, .expense)
        XCTAssertEqual(model.searchText, "zzz")
        XCTAssertEqual(model.period, .months12)
        XCTAssertNil(model.currentFilter.merchantKey)
    }

    func testSidebarSelectionEndsTheFocus() async throws {
        let (account, booking) = try sample()
        model.focusMerchant(of: booking)
        try await awaitLoad()
        XCTAssertNotNil(model.merchantFocus)

        model.sidebarSelection = .account(account)

        XCTAssertNil(model.merchantFocus)
        XCTAssertNil(model.currentFilter.merchantKey)
        XCTAssertTrue(model.bookings.allSatisfy { $0.accountId == account })
        // nothing left to return to
        model.leaveMerchantFocus()
        XCTAssertEqual(model.sidebarSelection, .account(account))
    }
}
