#if os(macOS)
import XCTest
import SwiftUI
@testable import GiroCrabUI

/// A long tag name must not widen the inspector (#228): the flow keeps to the offered width.
@MainActor
final class TagFlowTests: XCTestCase {
    private func fitting(_ view: some View, width: CGFloat) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    func testLongNameWrapsInsteadOfWideningTheColumn() {
        let long = "Wandertour 2026 (Eifel und Mosel) Abschied Werner und alle anderen"
        let flow = TagFlow {
            TagChip(name: "Auto", colorHex: "#E67E22", onRemove: {})
            TagChip(name: long, colorHex: "#C0392B", onRemove: {})
        }
        let narrow = fitting(flow, width: 220)
        XCTAssertLessThanOrEqual(narrow.width, 220)
        let oneLine = fitting(TagChip(name: "Auto", colorHex: "", onRemove: {}), width: 220).height
        let alone = fitting(TagFlow { TagChip(name: long, colorHex: "", onRemove: {}) }, width: 220)
        XCTAssertLessThanOrEqual(alone.width, 220)
        XCTAssertGreaterThan(alone.height, oneLine * 1.4, "the long name wraps onto a second line")
    }

    /// The popover behind „+n“: as wide as its chips, wrapped at the cap.
    func testCappedFlowIsOnlyAsWideAsItsChips() {
        let few = TagFlow(maxLineWidth: 260) {
            TagChip(name: "Auto", colorHex: "")
            TagChip(name: "Urlaub", colorHex: "")
        }.fixedSize()
        let one = fitting(TagChip(name: "Auto", colorHex: ""), width: 1000)
        let size = fitting(few, width: 1000)
        XCTAssertLessThan(size.width, 200)
        XCTAssertEqual(size.height, one.height, accuracy: 1)

        let many = TagFlow(maxLineWidth: 260) {
            ForEach(0..<8) { i in TagChip(name: "Urlaub \(i)", colorHex: "") }
        }.fixedSize()
        let wrapped = fitting(many, width: 1000)
        XCTAssertLessThanOrEqual(wrapped.width, 260)
        XCTAssertGreaterThan(wrapped.height, one.height * 2)
    }

    func testShortTagsShareARow() {
        let flow = TagFlow {
            TagChip(name: "Auto", colorHex: "")
            TagChip(name: "Urlaub", colorHex: "")
        }
        let size = fitting(flow, width: 400)
        let one = fitting(TagChip(name: "Auto", colorHex: ""), width: 400)
        XCTAssertEqual(size.height, one.height, accuracy: 1)
        XCTAssertLessThan(size.width, 400)
    }
}
#endif
