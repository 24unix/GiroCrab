import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Accounts of the same name: what tells them apart in menus, lists and the sidebar.
@MainActor
final class AccountNamesakeTests: XCTestCase {
    private var model: AppModel!
    private var a: Account!
    private var b: Account!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let accounts = Array(model.accountsByID.values.sorted { $0.id < $1.id })
        a = accounts[0]; b = accounts[1]
        a.name = "Konto flex"; b.name = "Konto flex"
        a.iban = "DE02200411550123456700"; b.iban = "DE89370400440532013000"
    }

    private func install() { model.accountsByID[a.id] = a; model.accountsByID[b.id] = b }

    func testDifferentOwnersTellThemApart() {
        a.owner = "Anna Muster"; b.owner = "Max Muster"
        install()
        XCTAssertEqual(model.accountLabel(a), "Konto flex · Anna Muster")
        XCTAssertEqual(model.accountLabel(b), "Konto flex · Max Muster")
    }

    func testOnlyOneOwnerSetTheOtherShowsTheEndOfItsIBAN() {
        a.owner = "Anna Muster"; b.owner = ""
        install()
        XCTAssertEqual(model.accountLabel(a), "Konto flex · Anna Muster")
        XCTAssertEqual(model.accountLabel(b), "Konto flex · …3000")
        XCTAssertNotEqual(model.accountLabel(a), model.accountLabel(b))
    }

    func testSameOwnerOrNoOwnerFallsBackToTheEndOfTheIBAN() {
        a.owner = "Anna Muster"; b.owner = "Anna Muster"
        install()
        XCTAssertEqual(model.accountLabel(a), "Konto flex · …6700")
        XCTAssertEqual(model.accountLabel(b), "Konto flex · …3000")
        a.owner = ""; b.owner = ""
        install()
        XCTAssertNotEqual(model.accountLabel(a), model.accountLabel(b))
    }

    func testAccountWithoutNamesakeKeepsItsPlainName() {
        a.owner = "Anna Muster"; b.name = "Etwas anderes"
        install()
        XCTAssertEqual(model.accountLabel(a), "Konto flex")
        XCTAssertFalse(model.hasNamesake(a))
        XCTAssertEqual(model.accountDistinction(a), "")
    }
}
