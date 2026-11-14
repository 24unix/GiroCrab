import XCTest
@testable import GiroCrabUI
import GiroCrabCore

/// #383: the split flow behind „Umsatz aufteilen (Splitbuchung)“ saves and reads back.
@MainActor
final class SplitBookingTests: XCTestCase {
    func testSaveSplitsRoundTrips() async throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let booking = try XCTUnwrap(model.bookings.first { $0.amountCents < 0 })
        let half = booking.amountCents / 2
        let parts = [
            TransactionSplitInput(categoryId: booking.categoryId, amountCents: half, note: "a"),
            TransactionSplitInput(categoryId: nil, amountCents: booking.amountCents - half, note: "b"),
        ]
        XCTAssertNil(model.saveSplits(parts, for: booking))
        let stored = await model.splits(for: booking)
        XCTAssertEqual(stored?.count, 2)
        XCTAssertEqual(stored?.reduce(0) { $0 + $1.amountCents }, booking.amountCents)
    }
}
