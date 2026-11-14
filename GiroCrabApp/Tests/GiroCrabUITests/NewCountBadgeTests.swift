import XCTest
@testable import GiroCrabUI

/// The bubble with the number of new bookings next to an account's name.
final class NewCountBadgeTests: XCTestCase {
    func testShowsTheCountAndCapsLongNumbers() {
        XCTAssertNil(NewCountBadge.label(for: 0))
        XCTAssertEqual(NewCountBadge.label(for: 1), "1")
        XCTAssertEqual(NewCountBadge.label(for: 999), "999")
        XCTAssertEqual(NewCountBadge.label(for: 1000), "999+")
    }
}
