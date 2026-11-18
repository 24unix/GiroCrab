import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Drag and drop of sidebar categories (#977): reorder among siblings, hang under another category.
@MainActor
final class CategoryDragTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    private func children(of parent: Int64?) -> [Int64] {
        model.categories.filter { $0.parentId == parent }.map(\.id)
    }

    private func drag(_ id: Int64) -> [String] { [GroupDrag.category(id)] }

    func testPayloadRoundTrip() {
        XCTAssertEqual(GroupDrag.categoryID(GroupDrag.category(42)), 42)
        XCTAssertNil(GroupDrag.categoryID(GroupDrag.account(42)))
        XCTAssertNil(GroupDrag.accountID(GroupDrag.category(42)))
        XCTAssertNil(GroupDrag.groupUUID(GroupDrag.category(42)))
    }

    func testDropBeforeAndAfterReordersSiblings() throws {
        let top = children(of: nil)
        try XCTSkipIf(top.count < 3, "demo vault has too few main categories")
        XCTAssertTrue(model.dropCategory(drag(top[2]), onto: top[0], place: .before))
        XCTAssertEqual(children(of: nil).prefix(3), [top[2], top[0], top[1]])
        XCTAssertTrue(model.dropCategory(drag(top[2]), onto: top[1], place: .after))
        XCTAssertEqual(children(of: nil).prefix(3), [top[0], top[1], top[2]])
    }

    func testDropIntoHangsItUnderTheTargetAsLastChild() throws {
        let top = children(of: nil)
        try XCTSkipIf(top.count < 2, "demo vault has too few main categories")
        let kids = children(of: top[0])
        XCTAssertTrue(model.dropCategory(drag(top[1]), onto: top[0], place: .into))
        XCTAssertEqual(children(of: top[0]), kids + [top[1]])
        XCTAssertFalse(children(of: nil).contains(top[1]))
        XCTAssertTrue(model.expandedCategories.contains(top[0]), "the target opens so the category stays in view")
    }

    func testSubcategoryMovesBeforeAnotherMainCategory() throws {
        let top = children(of: nil)
        let parent = try XCTUnwrap(top.first { !children(of: $0).isEmpty })
        let child = try XCTUnwrap(children(of: parent).first)
        XCTAssertTrue(model.dropCategory(drag(child), onto: parent, place: .before))
        XCTAssertNil(model.categories.first { $0.id == child }?.parentId)
        XCTAssertEqual(children(of: nil).firstIndex(of: child).map { $0 + 1 }, children(of: nil).firstIndex(of: parent))
    }

    func testNeverBelowItselfOrItsOwnSubcategories() throws {
        let top = children(of: nil)
        let parent = try XCTUnwrap(top.first { !children(of: $0).isEmpty })
        let child = try XCTUnwrap(children(of: parent).first)
        let before = model.categories.map(\.id)
        XCTAssertFalse(model.canDropCategory(parent, on: parent))
        XCTAssertFalse(model.canDropCategory(parent, on: child))
        XCTAssertFalse(model.dropCategory(drag(parent), onto: child, place: .into))
        XCTAssertEqual(model.categories.map(\.id), before)
        XCTAssertNil(model.errorMessage)
    }

    func testForeignPayloadsAreIgnored() throws {
        let top = children(of: nil)
        XCTAssertFalse(model.dropCategory([GroupDrag.account(1), BookingDrag.payload([1])], onto: top[0], place: .before))
    }

    func testShiftByOnePlace() throws {
        let top = children(of: nil)
        try XCTSkipIf(top.count < 2, "demo vault has too few main categories")
        XCTAssertFalse(model.canShiftCategory(top[0], by: -1))
        XCTAssertTrue(model.canShiftCategory(top[0], by: 1))
        model.shiftCategory(top[0], by: 1)
        XCTAssertEqual(children(of: nil).prefix(2), [top[1], top[0]])
        model.shiftCategory(top[0], by: -1)
        XCTAssertEqual(children(of: nil).prefix(2), [top[0], top[1]])
    }

    func testLowerHalfGoesIntoMainCategoriesAndBelowSubcategories() throws {
        let top = children(of: nil)
        let parent = try XCTUnwrap(top.first { !children(of: $0).isEmpty })
        let child = try XCTUnwrap(children(of: parent).first)
        XCTAssertTrue(model.categoryTakesDropInto(parent))
        XCTAssertFalse(model.categoryTakesDropInto(child))
    }
}
