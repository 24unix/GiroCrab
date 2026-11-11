import XCTest
import GiroCrabCore
@testable import GiroCrabUI

@MainActor
final class BookingScopeTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        XCTAssertNil(model.errorMessage)
    }

    override func tearDown() async throws { model = nil }

    private func ids(for scope: BookingScope) throws -> [Int64] {
        var filter = model.currentFilter
        filter.scope = scope
        return try XCTUnwrap(model.vault).listTransactions(filter: filter).transactions.map(\.id)
    }

    private func awaitBookings(_ expected: [Int64]) async throws {
        for _ in 0..<200 {
            if model.bookings.map(\.id) == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The latest scope request did not load its bookings")
    }

    func testScopeLoadsBookingsAndKeepsUnchangedKPIs() async throws {
        let expected = try ids(for: .investments)
        XCTAssertFalse(expected.isEmpty)
        let flow = try XCTUnwrap(model.selectionFlow)
        model.selectedBookingID = model.bookings.first { $0.flow == .consumption }?.id

        model.scope = .investments
        try await awaitBookings(expected)

        XCTAssertEqual(model.scope, .investments)
        XCTAssertEqual(model.page?.transactions.map(\.id), expected)
        XCTAssertEqual(model.selectedBookingID, expected.first)
        XCTAssertEqual(model.selectionFlow?.consumption, flow.consumption)
        XCTAssertEqual(model.selectionFlow?.invested, flow.invested)
        XCTAssertEqual(model.selectionFlow?.income, flow.income)
        XCTAssertNil(model.errorMessage)
    }

    func testRapidSwitchesKeepTheLatestScope() async throws {
        let expected = try ids(for: .everyday)
        model.scope = .investments
        await Task.yield()
        model.scope = .all
        await Task.yield()
        model.scope = .everyday

        try await awaitBookings(expected)
        // Give superseded background requests a chance to return as well.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.scope, .everyday)
        XCTAssertEqual(model.bookings.map(\.id), expected)
        XCTAssertEqual(model.page?.transactions.map(\.id), expected)
        XCTAssertNil(model.errorMessage)
    }

    func testAccountRefreshSupersedesAnOutstandingScopeRequest() async throws {
        let account = try XCTUnwrap(model.allAccounts.first { $0.kind == .checking })
        model.scope = .investments
        await Task.yield()
        model.sidebarSelection = .account(account.id)
        let expected = try ids(for: .investments)

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.sidebarSelection, .account(account.id))
        XCTAssertEqual(model.bookings.map(\.id), expected)
        XCTAssertEqual(model.page?.transactions.map(\.id), expected)
        XCTAssertNil(model.errorMessage)
    }
}
