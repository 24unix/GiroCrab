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

    /// #427: +59 EUR split into +200 EUR and a counter part of -141 EUR.
    func testMixedSignSplitIsValidAndRoundTrips() async throws {
        XCTAssertTrue(SplitMath.isValid(total: 5_900, parts: [20_000, -14_100]))
        XCTAssertEqual(SplitMath.remaining(total: 5_900, parts: [20_000]), -14_100)
        XCTAssertFalse(SplitMath.isValid(total: 5_900, parts: [20_000, -14_000]))
        XCTAssertFalse(SplitMath.isValid(total: 5_900, parts: [5_900, 0]))
        XCTAssertFalse(SplitMath.isValid(total: 5_900, parts: [5_900]))

        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let booking = try XCTUnwrap(model.bookings.first { $0.amountCents < 0 })
        let big = booking.amountCents * 3
        let parts = [
            TransactionSplitInput(categoryId: booking.categoryId, amountCents: big, note: "a"),
            TransactionSplitInput(categoryId: nil, amountCents: booking.amountCents - big, note: "b"),
        ]
        XCTAssertNil(model.saveSplits(parts, for: booking))
        let stored = await model.splits(for: booking)
        XCTAssertEqual(stored?.map(\.amountCents).sorted(), [big, booking.amountCents - big].sorted())
    }
}
