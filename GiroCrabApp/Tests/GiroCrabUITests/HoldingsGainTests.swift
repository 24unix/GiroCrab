import XCTest
import GiroCrabCore
@testable import GiroCrabUI

@MainActor
final class HoldingsGainTests: XCTestCase {
    private func holding(quantity: Double = 12.5, costPrice: Int64 = 9_000, value: Int64 = 125_625) -> Holding {
        Holding(isin: "DE0001234567", wkn: "", name: "Test ETF", quantity: quantity,
                currentPriceCents: 10_050, purchasePriceCents: costPrice, valueCents: value)
    }

    func testFractionalPositionUsesReportedValueAndRoundsCostToCents() throws {
        let gain = try XCTUnwrap(HoldingsCard.calculatedGain(holding()))
        XCTAssertEqual(gain.cents, 13_125)
        XCTAssertEqual(gain.percent, 11.6666666667, accuracy: 0.000001)
        let fractional = try XCTUnwrap(HoldingsCard.calculatedGain(holding(quantity: 1.2345, costPrice: 1_001, value: 1_500)))
        XCTAssertEqual(fractional.cents, 264) // rounded cost basis: 1,236 cents
    }

    func testLossBreakEvenAndTotalLoss() throws {
        XCTAssertEqual(try XCTUnwrap(HoldingsCard.calculatedGain(holding(value: 100_000))).cents, -12_500)
        XCTAssertEqual(try XCTUnwrap(HoldingsCard.calculatedGain(holding(value: 112_500))).percent, 0)
        XCTAssertEqual(try XCTUnwrap(HoldingsCard.calculatedGain(holding(value: 0))).percent, -100)
    }

    func testMissingOrInvalidCostBasisDoesNotBecomeAnApparentGain() {
        for quantity in [Double.nan, .infinity, 0, -1, .greatestFiniteMagnitude] {
            XCTAssertNil(HoldingsCard.calculatedGain(holding(quantity: quantity)))
        }
        for cost in [Int64(0), -1] {
            XCTAssertNil(HoldingsCard.calculatedGain(holding(costPrice: cost)))
        }
        XCTAssertNil(HoldingsCard.calculatedGain(holding(quantity: 0.00001, costPrice: 1)))
        XCTAssertNil(HoldingsCard.calculatedGain(holding(quantity: 2, costPrice: .max)))
        XCTAssertNil(HoldingsCard.calculatedGain(holding(value: -1)))
    }
}
