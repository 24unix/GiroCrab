import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Category context menu (#168): Umbenennen, Symbol & Farbe, Verschieben nach –
/// the same pattern as accounts and groups.
@MainActor
final class CategoryEditTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    private func category(_ id: Int64) -> GiroCrabCore.Category? { model.categories.first { $0.id == id } }

    /// A sub-category and a second main category that is not its parent.
    private func subAndOtherMain() throws -> (sub: GiroCrabCore.Category, other: GiroCrabCore.Category) {
        let sub = try XCTUnwrap(model.categories.first { $0.depth > 0 })
        let other = try XCTUnwrap(model.categories.first { $0.depth == 0 && $0.id != sub.parentId })
        return (sub, other)
    }

    func testRenameKeepsEverythingElse() throws {
        let (sub, _) = try subAndOtherMain()
        let dialog = GroupDialog.renameCategory(sub)
        XCTAssertTrue(dialog.needsText)
        XCTAssertTrue(dialog.isRename)
        XCTAssertEqual(dialog.initialText, sub.name)

        model.renameCategory(sub.id, to: "  Umbenannt  ")
        let c = try XCTUnwrap(category(sub.id))
        XCTAssertEqual(c.name, "Umbenannt")
        XCTAssertEqual(c.parentId, sub.parentId)
        XCTAssertEqual(c.sfSymbol, sub.sfSymbol)
        XCTAssertEqual(c.colorHex.uppercased(), sub.colorHex.uppercased())

        model.renameCategory(sub.id, to: "   ")
        XCTAssertEqual(category(sub.id)?.name, "Umbenannt", "an empty name is ignored")
    }

    func testMoveToOtherMainCategoryAndToTopLevel() throws {
        let (sub, other) = try subAndOtherMain()
        model.moveCategory(sub.id, to: other.id)
        XCTAssertEqual(category(sub.id)?.parentId, other.id)
        XCTAssertTrue(model.expandedCategories.contains(other.id), "the new parent opens, so the moved category stays in view")

        model.moveCategory(sub.id, to: nil)
        XCTAssertNil(category(sub.id)?.parentId)
        XCTAssertEqual(category(sub.id)?.depth, 0)
    }

    func testMoveTargetsLeaveOutTheCategoryAndItsChildren() throws {
        let (sub, _) = try subAndOtherMain()
        let parent = try XCTUnwrap(sub.parentId)
        let targets = Set(model.categoryMoveTargets(for: parent).map(\.id))
        XCTAssertFalse(targets.contains(parent), "not into itself")
        XCTAssertFalse(targets.contains(sub.id), "not into its own sub-category")
        XCTAssertTrue(targets.contains(where: { id in category(id)?.depth == 0 }))

        // even if asked directly, a category never moves below itself
        model.moveCategory(parent, to: sub.id)
        XCTAssertNil(category(parent)?.parentId)
    }

    func testSymbolAndColourViaPopoverFunctions() throws {
        let (sub, _) = try subAndOtherMain()
        model.setCategorySymbol(sub.id, symbol: "cart")
        model.setCategoryColor(sub.id, hex: "#DC2626")
        let c = try XCTUnwrap(category(sub.id))
        XCTAssertEqual(c.sfSymbol, "cart")
        XCTAssertEqual(c.colorHex.uppercased(), "#DC2626")
        XCTAssertEqual(c.name, sub.name)

        let popover = model.iconColorBinding(.category(sub.id))
        XCTAssertFalse(popover.wrappedValue)
        model.iconColorTarget = .category(sub.id)
        XCTAssertTrue(popover.wrappedValue)
        popover.wrappedValue = false
        XCTAssertNil(model.iconColorTarget)
    }
}
