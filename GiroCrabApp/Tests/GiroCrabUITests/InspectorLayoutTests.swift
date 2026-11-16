import XCTest
@testable import GiroCrabUI

/// Anpassbare rechte Seitenleiste (#448): order, hiding and the stored form of `InspectorLayout`.
final class InspectorLayoutTests: XCTestCase {
    func testStandardShowsEverySectionInDefaultOrder() {
        let layout = InspectorLayout(storageValue: "")
        XCTAssertEqual(layout, .standard)
        XCTAssertEqual(layout.visible, InspectorSection.allCases)
        XCTAssertTrue(layout.hiddenSections.isEmpty)
    }

    func testHideAndShow() {
        var layout = InspectorLayout.standard
        layout.hide(.note)
        layout.hide(.rawData)
        XCTAssertFalse(layout.visible.contains(.note))
        XCTAssertEqual(layout.hiddenSections, [.note, .rawData])

        layout.show(.note)
        XCTAssertEqual(layout.visible.last, .note, "shown again at the bottom of the visible list")
        XCTAssertEqual(layout.hiddenSections, [.rawData])
        XCTAssertFalse(layout.isStandard)
    }

    func testInsertAtGapAccountsForTheDraggedCardItself() {
        var layout = InspectorLayout.standard
        // Receipt (index 0) dropped into the gap below note (gap 2) lands right after note.
        layout.insert(.receipt, atGap: 2)
        XCTAssertEqual(Array(layout.visible.prefix(3)), [.note, .receipt, .salary])

        // Raw data (last) dropped above the first card.
        layout.insert(.rawData, atGap: 0)
        XCTAssertEqual(layout.visible.first, .rawData)

        // Dropping a card into one of its own neighbouring gaps changes nothing.
        let before = layout
        let index = layout.visible.firstIndex(of: .salary)!
        layout.insert(.salary, atGap: index)
        XCTAssertEqual(layout, before)
        layout.insert(.salary, atGap: index + 1)
        XCTAssertEqual(layout, before)

        // Below the last card.
        layout.insert(.note, atGap: layout.visible.count)
        XCTAssertEqual(layout.visible.last, .note)
    }

    func testDraggingAHiddenSectionIntoTheListShowsIt() {
        var layout = InspectorLayout.standard
        layout.hide(.documents)
        layout.insert(.documents, atGap: 1)
        XCTAssertEqual(layout.visible[1], .documents)
        XCTAssertTrue(layout.hiddenSections.isEmpty)
    }

    func testStorageRoundTrip() {
        var layout = InspectorLayout.standard
        layout.insert(.categories, atGap: 0)
        layout.hide(.salary)
        layout.hide(.rawData)
        let restored = InspectorLayout(storageValue: layout.storageValue)
        XCTAssertEqual(restored, layout)
        XCTAssertEqual(restored.visible.first, .categories)
        XCTAssertEqual(restored.hiddenSections, [.salary, .rawData])
    }

    func testStoredValueToleratesUnknownDuplicateAndMissingSections() {
        // An older/newer app version or a damaged value: unknown names are dropped, duplicates
        // counted once, and sections missing from the value appear at the end, visible.
        let layout = InspectorLayout(storageValue: "rawData,futureCard,-note,rawData,receipt")
        XCTAssertEqual(Array(layout.visible.prefix(2)), [.rawData, .receipt])
        XCTAssertEqual(layout.hiddenSections, [.note])
        XCTAssertEqual(Set(layout.order), Set(InspectorSection.allCases))
        XCTAssertEqual(layout.order.count, InspectorSection.allCases.count)
    }

    func testDragPayloadOnlyAcceptsOwnPrefix() {
        XCTAssertEqual(InspectorSection(dragPayload: InspectorSection.note.dragPayload), .note)
        XCTAssertNil(InspectorSection(dragPayload: "note"))
        XCTAssertNil(InspectorSection(dragPayload: InspectorSection.dragPrefix + "unknown"))
    }
}
