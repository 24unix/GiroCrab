import XCTest
@testable import GiroCrabUI

/// The colour picker: fixed swatches plus the custom colours already in use.
final class ColorChoicesTests: XCTestCase {
    private let palette = ["#2563EB", "#D97706"]

    func testExtraSwatchesAddYellowBrownAndSlate() {
        let all = ColorChoices.swatches(palette: palette)
        XCTAssertEqual(Array(all.prefix(2)), palette)
        XCTAssertEqual(all.count, palette.count + 3)
        XCTAssertEqual(Set(all).count, all.count)
    }

    func testCustomColoursAreTheUsedOnesOutsideTheSwatches() {
        let used = ["#2563EB", "#ff0000", "#FF0000", "", "#00ff00", "#FF0000", ColorChoices.extras[0]]
        XCTAssertEqual(ColorChoices.customColors(used: used, palette: palette), ["#FF0000", "#00FF00"])
    }

    func testCustomColoursAreCapped() {
        let used = (0..<40).map { String(format: "#0000%02X", $0) }
        XCTAssertEqual(ColorChoices.customColors(used: used, palette: palette).count, ColorChoices.maxCustom)
    }
}

/// „Entfernen“ on a custom colour.
@MainActor
final class RemoveColorTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    private let custom = "#123456"

    private func paint() throws -> (accounts: [Int64], category: Int64) {
        let accounts = Array(model.allAccounts.prefix(2)).map(\.id)
        XCTAssertEqual(accounts.count, 2)
        for id in accounts { model.setAccountColor(id, hex: custom) }
        let category = try XCTUnwrap(model.categories.first { $0.depth == 0 }).id
        model.setCategoryColor(category, hex: custom)
        return (accounts, category)
    }

    private func hexes(_ accounts: [Int64], _ category: Int64) -> [String] {
        accounts.map { id in model.allAccounts.first { $0.id == id }!.colorHex.uppercased() }
            + [model.categories.first { $0.id == category }!.colorHex.uppercased()]
    }

    func testRemoveLeavesNoElementWithTheColour() throws {
        let (accounts, category) = try paint()
        model.removeColor(custom)
        let after = hexes(accounts, category)
        XCTAssertFalse(after.contains(custom))
        XCTAssertFalse(after.last!.isEmpty, "a category always keeps a colour")
    }
}
