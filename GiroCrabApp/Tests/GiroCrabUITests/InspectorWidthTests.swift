import XCTest
@testable import GiroCrabUI

final class InspectorWidthTests: XCTestCase {
    func testDraggingLeftWidensAndRightNarrows() {
        XCTAssertEqual(InspectorWidth.dragged(from: 320, translation: -20, textScale: 1), 340)
        XCTAssertEqual(InspectorWidth.dragged(from: 320, translation: 20, textScale: 1), 300)
    }

    func testWidthIsClamped() {
        XCTAssertEqual(InspectorWidth.dragged(from: 320, translation: -500, textScale: 1), InspectorWidth.maximum)
        XCTAssertEqual(InspectorWidth.dragged(from: 320, translation: 500, textScale: 1), InspectorWidth.minimum)
    }

    /// The column is drawn `width * textScale` wide, so the edge follows the pointer 1:1 (#828).
    func testEdgeFollowsPointerAtLargerTextSize() {
        for scale: CGFloat in [1, 1.15, 1.3] {
            let start: CGFloat = 300
            let width = InspectorWidth.dragged(from: start, translation: -23, textScale: scale)
            XCTAssertEqual(width * scale - start * scale, 23, accuracy: 0.0001)
        }
    }

    func testSameTranslationGivesSameWidth() {
        // Drag state is keyed on the start width, not the current one: no feedback per event.
        let first = InspectorWidth.dragged(from: 320, translation: -30, textScale: 1.15)
        let again = InspectorWidth.dragged(from: 320, translation: -30, textScale: 1.15)
        XCTAssertEqual(first, again)
    }
}
