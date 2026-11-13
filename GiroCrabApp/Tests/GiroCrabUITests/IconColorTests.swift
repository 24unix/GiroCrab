import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// "Symbol & Farbe …" for accounts and groups, and account renaming.
@MainActor
final class IconColorTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    func testSymbolListOffersEveryAccountTypesOwnSymbol() throws {
        // the symbols the core gives accounts by type must all be choosable
        let all = SymbolCatalog.sections.flatMap { $0.items.map(\.symbol) }
        let offered = Set(all)
        for a in model.allAccounts {
            XCTAssertTrue(offered.contains(a.sfSymbol), "\(a.name): \(a.sfSymbol) missing")
        }
        XCTAssertEqual(offered.count, all.count, "no duplicates")
    }

    func testGroupColourAndSymbolViaModel() throws {
        model.createUserGroup(name: "Farbtest", moving: nil, parent: nil)
        var g = try XCTUnwrap(model.userGroups.first { $0.name == "Farbtest" })
        XCTAssertEqual(g.colorHex, "")
        model.setUserGroupColor(g, hex: "#DC2626")
        model.updateUserGroup(g, symbol: "envelope.circle")
        g = try XCTUnwrap(model.userGroups.first { $0.uuid == g.uuid })
        XCTAssertEqual(g.colorHex, "#DC2626")
        XCTAssertEqual(g.sfSymbol, "envelope.circle")
        model.setUserGroupColor(g, hex: nil)
        XCTAssertEqual(model.userGroups.first { $0.uuid == g.uuid }?.colorHex, "")
    }

    func testAccountSymbolAndRenameViaModel() throws {
        let a = try XCTUnwrap(model.allAccounts.first)
        model.setAccountSymbol(a.id, symbol: "bitcoinsign.circle")
        XCTAssertEqual(model.account(for: a.id)?.sfSymbol, "bitcoinsign.circle")
        let dialog = GroupDialog.renameAccount(a)
        XCTAssertTrue(dialog.needsText)
        XCTAssertTrue(dialog.isRename)
        XCTAssertEqual(dialog.initialText, a.name)
        model.renameAccount(a.id, to: "Umbenannt")
        XCTAssertEqual(model.account(for: a.id)?.name, "Umbenannt")
    }

    func testPopoverTargetBinding() {
        let b = model.iconColorBinding(.account(1))
        XCTAssertFalse(b.wrappedValue)
        model.iconColorTarget = .account(1)
        XCTAssertTrue(b.wrappedValue)
        XCTAssertFalse(model.iconColorBinding(.group("x")).wrappedValue)
        b.wrappedValue = false
        XCTAssertNil(model.iconColorTarget)
    }
}
