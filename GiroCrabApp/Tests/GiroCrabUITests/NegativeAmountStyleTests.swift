import XCTest
@testable import GiroCrabUI

/// Colour of negative amounts in the booking list (GitHub #218).
final class NegativeAmountStyleTests: XCTestCase {
    func testNeutralUntilRedIsChosen() throws {
        let suite = "NegativeAmountStyleTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(NegativeAmountStyle.current(defaults), .neutral)
        defaults.set(NegativeAmountStyle.red.rawValue, forKey: NegativeAmountStyle.defaultsKey)
        XCTAssertEqual(NegativeAmountStyle.current(defaults), .red)
        defaults.set("unknown", forKey: NegativeAmountStyle.defaultsKey)
        XCTAssertEqual(NegativeAmountStyle.current(defaults), .neutral)
        defaults.removePersistentDomain(forName: suite)
    }

    func testColours() {
        XCTAssertEqual(NegativeAmountStyle.neutral.color, Theme.outflow)
        XCTAssertEqual(NegativeAmountStyle.red.color, Theme.negative)
        XCTAssertNotEqual(NegativeAmountStyle.red.color, NegativeAmountStyle.neutral.color)
    }
}
