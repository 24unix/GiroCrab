import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Depot value line (#465): no flat padding before the first or after the last real value.
final class DepotChartSeriesTests: XCTestCase {
    private func series(_ cents: [Int64]) -> [DailyBalance] {
        cents.enumerated().map { DailyBalance(date: String(format: "2026-10-%02d", $0.offset + 1), balanceCents: $0.element) }
    }

    func testFlatHistoryIsNoLine() {
        XCTAssertTrue(DepotChartSeries.points(series([500, 500, 500, 500]), lastDate: "2026-10-04").isEmpty)
    }

    func testCutsLeadInAndTail() {
        // value changes on day 4 and 6; snapshot date is day 8 -> day 3 ... day 6
        let out = DepotChartSeries.points(series([100, 100, 100, 200, 200, 300, 300, 300]), lastDate: "2026-10-08")
        XCTAssertEqual(out.map(\.date), ["2026-10-03", "2026-10-04", "2026-10-05", "2026-10-06"])
    }

    func testNothingPastLastSnapshot() {
        let out = DepotChartSeries.points(series([100, 100, 200, 300, 400, 400]), lastDate: "2026-10-04")
        XCTAssertEqual(out.last?.date, "2026-10-04")
        XCTAssertEqual(out.first?.date, "2026-10-02")
    }
}
