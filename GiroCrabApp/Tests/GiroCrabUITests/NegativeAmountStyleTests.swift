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
        XCTAssertEqual(NegativeAmountStyle.neutral.negativeSpec, Theme.outflowSpec)
        XCTAssertEqual(NegativeAmountStyle.red.negativeSpec, Theme.negativeSpec)
        XCTAssertNotEqual(NegativeAmountStyle.red.negativeSpec, NegativeAmountStyle.neutral.negativeSpec)
        XCTAssertNotEqual(NegativeAmountStyle.contrast.negativeSpec, NegativeAmountStyle.red.negativeSpec)
    }

    func testContrastSchemeIsOrangeAndBlue() throws {
        XCTAssertEqual(NegativeAmountStyle.allCases, [.neutral, .red, .contrast])
        XCTAssertEqual(NegativeAmountStyle(rawValue: "contrast"), .contrast)
        // Positive amounts keep the green pair except in the colour-blind-safe scheme.
        XCTAssertEqual(NegativeAmountStyle.red.positiveSpec, Theme.inflowSpec)
        XCTAssertNotEqual(NegativeAmountStyle.contrast.positiveSpec, Theme.inflowSpec)
    }
}
