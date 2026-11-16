import XCTest
import GiroCrabCore
@testable import GiroCrabUI

final class HeaderPieSlicesTests: XCTestCase {
    private func cat(_ id: Int64, parent: Int64?, name: String, own: Int64, total: Int64, depth: UInt32) -> GiroCrabCore.Category {
        GiroCrabCore.Category(id: id, parentId: parent, name: name, sfSymbol: "tag", colorHex: "", sortOrder: 0, depth: depth,
                              path: name, ownTotalCents: own, totalCents: total, transactionCount: 1, budgetCents: nil)
    }

    func testSubcategoriesShareTheParentsSide() {
        let cats = [
            cat(1, parent: nil, name: "Wohnen", own: -100, total: -1100, depth: 0),
            cat(2, parent: 1, name: "Miete", own: -900, total: -900, depth: 1),
            cat(3, parent: 1, name: "Strom", own: -150, total: -150, depth: 1),
            cat(4, parent: 1, name: "Erstattung", own: 50, total: 50, depth: 1),
            cat(5, parent: 2, name: "Garage", own: -1, total: -1, depth: 2),
        ]
        let parts = HeaderPieSlices.subcategories(of: 1, in: cats)
        XCTAssertEqual(parts.map(\.id).sorted(), ["2", "3", "own"])
        XCTAssertEqual(parts.first { $0.id == "2" }?.cents, 900)
        XCTAssertTrue(HeaderPieSlices.subcategories(of: 99, in: cats).isEmpty)
    }

    func testExpensesUseTopLevelTotals() {
        let cats = [
            cat(1, parent: nil, name: "Wohnen", own: 0, total: -500, depth: 0),
            cat(2, parent: 1, name: "Miete", own: -500, total: -500, depth: 1),
            cat(3, parent: nil, name: "Gehalt", own: 2000, total: 2000, depth: 0),
        ]
        XCTAssertEqual(HeaderPieSlices.expenses(cats), [HeaderPieSlices.Part(id: "1", label: "Wohnen", cents: 500)])
    }

    func testFoldKeepsLargestAndSumsTheRest() {
        let parts = (1...6).map { HeaderPieSlices.Part(id: "\($0)", label: "K\($0)", cents: Int64($0 * 100)) }
        let slices = HeaderPieSlices.fold(parts, limit: 4)
        XCTAssertEqual(slices.map(\.id), ["6", "5", "4", "rest"])
        XCTAssertEqual(slices.last?.cents, 600)
        XCTAssertEqual(HeaderPieSlices.fold(parts, limit: 6).count, 6)
        XCTAssertEqual(slices.reduce(0) { $0 + $1.cents }, 2100)
    }
}
