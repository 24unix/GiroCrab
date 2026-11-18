import XCTest
import SwiftUI
@testable import GiroCrabUI

@MainActor
final class CompositionShareTests: XCTestCase {
    private func slices(_ n: Int) -> [DepotSlice] {
        (0..<n).map { i in
            DepotSlice(id: "k\(i)", label: "Position \(i)", cents: Int64(100_000 - i * 1_000), count: 1,
                       color: .blue, unclassified: false, memberKeys: ["k\(i)"])
        }
    }

    func testShowAllUnfoldsTheRestSlice() {
        let all = slices(32)
        let folded = CompositionDrawing.ringSlices(all, foldsRing: true, showAll: false)
        XCTAssertEqual(folded.count, DepotComposition.maxPositionSlices + 1)
        XCTAssertTrue(folded.last?.isRest == true)
        XCTAssertEqual(CompositionDrawing.ringSlices(all, foldsRing: true, showAll: true).count, 32)
        // classes never fold
        XCTAssertEqual(CompositionDrawing.ringSlices(all, foldsRing: false, showAll: false).count, 32)
        XCTAssertEqual(CompositionDrawing.tileSlices(all, showAll: true).count, 32)
    }

    func testOnlyAFoldingDisplayOffersShowAll() {
        XCTAssertTrue(CompositionDrawing.isFolded(.ring, all: slices(32), foldsRing: true))
        XCTAssertFalse(CompositionDrawing.isFolded(.ring, all: slices(32), foldsRing: false))
        XCTAssertFalse(CompositionDrawing.isFolded(.ring, all: slices(5), foldsRing: true))
        XCTAssertTrue(CompositionDrawing.isFolded(.bars, all: slices(32), foldsRing: true))
        XCTAssertFalse(CompositionDrawing.isFolded(.tiles, all: slices(8), foldsRing: true))
    }

    func testTheSharedPictureIsAPNG() throws {
        let all = slices(32)
        let total = all.reduce(Int64(0)) { $0 + $1.cents }
        for display in CompositionDisplay.allCases {
            let drawing = CompositionDrawing(display: display, all: all, total: total, currency: "EUR", showAll: true)
            let data = try XCTUnwrap(CompositionSnapshot.png(of: drawing, scheme: .light, textScale: 1, redaction: []),
                                     "\(display) was not drawn")
            XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "\(display) is no PNG")
            XCTAssertGreaterThan(data.count, 1_000)
        }
    }
}
