import XCTest
@testable import GiroCrabUI

/// The progress panel of the Amazon fetch (#1008): which year or order is read,
/// how far along it is, and how many orders were found so far.
final class AmazonFetchProgressTests: XCTestCase {
    func testOrderListsShowTheYearLargeAndTheYearCount() {
        let p = AmazonFetchProgress.orderLists(year: 2021, index: 4, count: 25, found: 183)
        XCTAssertEqual(p.title, "Jahr 2021")
        XCTAssertTrue(p.detail.contains("Bestellliste 5 von 25"), p.detail)
        XCTAssertTrue(p.detail.contains("183 Bestellungen gefunden"), p.detail)
        XCTAssertEqual(p.fraction, 4.0 / 25.0, accuracy: 0.0001)
    }

    func testYearIsNotGroupedLikeANumber() {
        let p = AmazonFetchProgress.orderLists(year: 2026, index: 0, count: 2, found: 0)
        XCTAssertFalse(p.title.contains("2.026"), p.title)
        XCTAssertFalse(p.caption.contains("2.026"), p.caption)
    }

    func testOneFoundOrderIsSingular() {
        let p = AmazonFetchProgress.orderLists(year: 2026, index: 1, count: 2, found: 1)
        XCTAssertTrue(p.detail.contains("1 Bestellung gefunden"), p.detail)
    }

    func testNothingFoundYetSaysNoCount() {
        let p = AmazonFetchProgress.orderLists(year: 2026, index: 0, count: 2, found: 0)
        XCTAssertFalse(p.detail.contains("gefunden"), p.detail)
    }

    func testOrderDetailsCountOrdersAndNameTheirYear() {
        let p = AmazonFetchProgress.orderDetails(index: 477, total: 890, year: 2019, skipped: 0)
        XCTAssertEqual(p.title, "Bestellung 478 von 890")
        XCTAssertTrue(p.detail.contains("2019"), p.detail)
        XCTAssertEqual(p.fraction, 477.0 / 890.0, accuracy: 0.0001)
    }

    func testOrderDetailsWithoutYearStillSayWhatIsRead() {
        let p = AmazonFetchProgress.orderDetails(index: 0, total: 3, year: nil, skipped: 0)
        XCTAssertFalse(p.detail.isEmpty)
    }

    /// The header line (and VoiceOver) keeps the short text it showed before.
    func testCaptionKeepsTheHeaderText() {
        XCTAssertEqual(AmazonFetchProgress.orderLists(year: 2021, index: 0, count: 2, found: 0).caption, "Bestellliste 2021 …")
        XCTAssertEqual(AmazonFetchProgress.orderDetails(index: 477, total: 890, year: nil, skipped: 0).caption, "Bestellung 478 von 890 …")
    }

    func testFractionNeverLeavesTheBar() {
        XCTAssertEqual(AmazonFetchProgress.orderLists(year: 2026, index: 0, count: 0, found: 0).fraction, 0)
        XCTAssertEqual(AmazonFetchProgress.orderDetails(index: 9, total: 3, year: nil, skipped: 0).fraction, 1)
    }

    /// #1035: known older orders are skipped and the panel says how many.
    func testOrderDetailsNameTheSkippedKnownOrders() {
        let p = AmazonFetchProgress.orderDetails(index: 2, total: 24, year: 2026, skipped: 866)
        XCTAssertEqual(p.title, "Bestellung 3 von 24")
        XCTAssertTrue(p.detail.contains("866 bereits übernommen"), p.detail)
        let none = AmazonFetchProgress.orderDetails(index: 2, total: 24, year: 2026, skipped: 0)
        XCTAssertFalse(none.detail.contains("übernommen"), none.detail)
    }

    func testRereadChoicesDefaultToNinetyDays() {
        XCTAssertEqual(AmazonReread.standard, .days90)
        XCTAssertEqual(AmazonReread.allCases.map(\.rawValue), [30, 90, 180, 365, 0])
        XCTAssertEqual(AmazonReread(rawValue: 0), .always)
    }

    func testOnlyUnknownOrdersAreRead() {
        let codes = ["302-1", "302-2", "302-3"]
        let (read, skipped) = AmazonReread.split(codes, skip: ["302-2", "999-9"])
        XCTAssertEqual(read, ["302-1", "302-3"])
        XCTAssertEqual(skipped, 1)
    }
}
