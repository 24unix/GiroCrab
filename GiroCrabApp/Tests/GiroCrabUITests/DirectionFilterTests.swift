import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Income / expense filter of the booking list (GitHub #53).
@MainActor
final class DirectionFilterTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    func testListAndTotalsFollowTheFilter() throws {
        let all = model.bookings.count
        model.directionFilter = .expense
        XCTAssertFalse(model.bookings.isEmpty)
        XCTAssertTrue(model.bookings.allSatisfy { $0.amountCents < 0 })
        XCTAssertEqual(model.page?.incomeCents, 0)
        let expenses = model.bookings.count
        model.directionFilter = .income
        XCTAssertTrue(model.bookings.allSatisfy { $0.amountCents > 0 })
        XCTAssertEqual(model.page?.expenseCents, 0)
        XCTAssertLessThanOrEqual(model.bookings.count + expenses, all)
        XCTAssertNil(model.errorMessage)
    }

    func testPrintSourceFollowsTheFilter() throws {
        model.directionFilter = .income
        let source = try XCTUnwrap(model.printSource())
        XCTAssertFalse(source.rows.isEmpty)
        XCTAssertTrue(source.rows.allSatisfy { $0.amountCents > 0 })
        XCTAssertEqual(source.filterNotes, [PrintDirection.income.title])
    }

    func testRevealingABookingOutsideTheListClearsTheFilter() throws {
        model.directionFilter = .income
        let expense = try XCTUnwrap(
            try XCTUnwrap(model.vault).listTransactions(filter: {
                var f = model.currentFilter; f.direction = .expense; return f
            }()).transactions.first)
        model.revealBooking(expense.id)
        XCTAssertEqual(model.directionFilter, .all)
    }

    func testDemoFilterLaunchOption() {
        let m = AppModel(options: LaunchOptions(arguments: ["--demo-seed", "--select", "giro", "--demo-filter", "expense"], environment: [:]))
        XCTAssertEqual(m.directionFilter, .expense)
        XCTAssertTrue(m.bookings.allSatisfy { $0.amountCents < 0 })
    }
}
