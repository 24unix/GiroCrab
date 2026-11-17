import XCTest
import Security
import GiroCrabCore
@testable import GiroCrabUI

@MainActor
final class AdvanziaTests: XCTestCase {
    func testOnlyExactHTTPSOriginsAreTrusted() {
        XCTAssertTrue(AdvanziaSecurity.isPortalURL(URL(string: "https://mein.advanzia.com/")))
        XCTAssertTrue(AdvanziaSecurity.isLoginURL(URL(string: "https://id.advanzia.com/")))
        for value in ["http://mein.advanzia.com/", "https://mein.advanzia.com.evil.invalid/", "https://sub.mein.advanzia.com/", "https://mein.advanzia.com:444/", "https://user@mein.advanzia.com/", "file:///tmp/test"] {
            XCTAssertFalse(AdvanziaSecurity.isPortalURL(URL(string: value)))
        }
        XCTAssertFalse(AdvanziaSecurity.isPortalURL(URL(string: "https://id.advanzia.com/")))
        XCTAssertFalse(AdvanziaSecurity.isLoginURL(URL(string: "https://mein.advanzia.com/")))
    }
    func testProfileNamespacesDoNotUseSequentialConnectionIDs() {
        let a = AdvanziaLocalSecrets.key("00000000-0000-4000-8000-000000000001")
        let b = AdvanziaLocalSecrets.key("00000000-0000-4000-8000-000000000002")
        XCTAssertNotEqual(a[kSecAttrAccount as String] as? String, b[kSecAttrAccount as String] as? String)
        XCTAssertEqual(a[kSecAttrSynchronizable as String] as? Bool, false)
    }
    func testUntrustedErrorsCannotReachTheUI() {
        let value = AdvanziaSecurity.errorMessage("PRIVATE RESPONSE: invented-secret")
        XCTAssertFalse(value.contains("invented-secret"))
        XCTAssertNotEqual(AdvanziaSecurity.errorMessage("AUTH"), AdvanziaSecurity.errorMessage("TIMEOUT"))
    }
    func testAccountUUIDValidation() {
        XCTAssertEqual(AdvanziaSecurity.account("00000000-0000-4000-8000-000000000001"), "00000000-0000-4000-8000-000000000001")
        XCTAssertNil(AdvanziaSecurity.account("not-an-account"))
    }
    func testDemoDoesNotOpenABankPortal() {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let c = BankConnection(id: 1, connector: .advanzia, displayName: "Testkarte", loginName: "demo", bankCode: "", sfSymbol: "creditcard", lastSyncUnix: nil, allAccountsArchived: false)
        XCTAssertFalse(model.usesPortal(c))
        XCTAssertEqual(ConnectorKind.advanzia.displayName, "Advanzia Bank")
        XCTAssertTrue(bankCatalog().contains { $0.kind == .advanzia })
    }
}
