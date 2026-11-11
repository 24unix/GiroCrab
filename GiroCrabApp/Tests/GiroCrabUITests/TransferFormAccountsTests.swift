import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Archived accounts (#65) never appear in the transfer form – neither as a
/// sending account nor as a GiroCode account (#67).
@MainActor
final class TransferFormAccountsTests: XCTestCase {
    func testArchivedAccountsAreNotOffered() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let sending = try XCTUnwrap(model.transferAccounts.first, "demo data has a FinTS checking account")
        XCTAssertTrue(model.transferFormAccounts.contains { $0.id == sending.id })
        model.setAccountArchived(sending, true)
        XCTAssertFalse(model.transferAccounts.contains { $0.id == sending.id })
        XCTAssertFalse(model.giroCodeAccounts.contains { $0.id == sending.id },
                       "an archived FinTS account must not turn into a GiroCode account")
        XCTAssertFalse(model.transferFormAccounts.contains { $0.id == sending.id })
    }
}
