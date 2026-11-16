import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// "Konto bearbeiten": Kontoart, Notiz (#639, #605, #656).
@MainActor
final class AccountEditTests: XCTestCase {
    func testKindChangeMovesAccountBetweenKindGroups() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let account = try XCTUnwrap(model.allAccounts.first { $0.kind == .checking })
        model.setAccountKind(account.id, to: .brokerage)
        let group = try XCTUnwrap(model.groups.first { $0.accounts.contains { $0.id == account.id } })
        XCTAssertTrue(group.accounts.allSatisfy { $0.kind == .brokerage || $0.id != account.id })
        XCTAssertEqual(model.accountsByID[account.id]?.kind, .brokerage)
        XCTAssertFalse(model.groups.filter { $0.name == "Girokonten" }.contains { $0.accounts.contains { $0.id == account.id } })
    }

    func testAccountNoteRoundTrip() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let id = try XCTUnwrap(model.allAccounts.first).id
        model.setAccountNote("  Zweitkonto  ", for: id)
        XCTAssertEqual(model.accountNote(for: id), "Zweitkonto")
    }
}
