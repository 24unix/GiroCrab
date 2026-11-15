import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Category context menu › Duplizieren (#510).
@MainActor
final class CategoryDuplicateTests: XCTestCase {
    func testDuplicateCopiesSubtreeNextToOriginal() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let main = try XCTUnwrap(model.categories.first { c in
            c.depth == 0 && model.categories.contains { $0.parentId == c.id }
        })
        let subs = model.categories.filter { $0.parentId == main.id }
        let before = model.categories.count
        let newID = try XCTUnwrap(model.duplicateCategory(main.id))
        let copy = try XCTUnwrap(model.categories.first { $0.id == newID })
        XCTAssertEqual(copy.parentId, main.parentId)
        XCTAssertEqual(copy.sfSymbol, main.sfSymbol)
        XCTAssertTrue(copy.name.hasPrefix(main.name))
        XCTAssertNotEqual(copy.name, main.name)
        let copySubs = model.categories.filter { $0.parentId == newID }
        XCTAssertEqual(copySubs.map(\.name), subs.map(\.name))
        XCTAssertEqual(model.categories.count, before + 1 + copySubs.count)
        XCTAssertEqual(model.categories.filter { $0.parentId == main.id }.count, subs.count)
    }
}
