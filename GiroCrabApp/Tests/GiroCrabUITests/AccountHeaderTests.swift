import XCTest
import GiroCrabCore
@testable import GiroCrabUI

@MainActor
final class AccountHeaderTests: XCTestCase {
    func testHolderLineShowsTrimmedOwnerAndHidesEmpty() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        var account = try XCTUnwrap(model.allAccounts.first)
        account.owner = "  Mia Beispiel \n"
        XCTAssertEqual(accountHolderLine(account), "Mia Beispiel")
        account.owner = "   "
        XCTAssertNil(accountHolderLine(account))
        account.owner = ""
        XCTAssertNil(accountHolderLine(account))
    }
}
