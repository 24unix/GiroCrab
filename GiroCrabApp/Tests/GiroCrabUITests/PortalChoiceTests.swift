import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Amex / Amazon Visa must stay on the web login when Enable Banking
/// credentials exist only for PSD2 banks such as C24.
@MainActor
final class PortalChoiceTests: XCTestCase {
    func testCredentialsAloneKeepTheWebLogin() {
        XCTAssertFalse(AppModel.cardUsesEnableBanking(optIn: nil, hasApp: true, hasKey: true))
        XCTAssertFalse(AppModel.cardUsesEnableBanking(optIn: "", hasApp: true, hasKey: true))
        XCTAssertFalse(AppModel.cardUsesEnableBanking(optIn: "0", hasApp: true, hasKey: true))
    }

    func testOptInNeedsCredentials() {
        XCTAssertTrue(AppModel.cardUsesEnableBanking(optIn: "1", hasApp: true, hasKey: true))
        XCTAssertTrue(AppModel.cardUsesEnableBanking(optIn: " 1 ", hasApp: true, hasKey: true))
        XCTAssertFalse(AppModel.cardUsesEnableBanking(optIn: "1", hasApp: true, hasKey: false))
        XCTAssertFalse(AppModel.cardUsesEnableBanking(optIn: "1", hasApp: false, hasKey: true))
    }

    func testOptInKeyPerCard() {
        XCTAssertEqual(AppModel.enableBankingOptInKey(.americanExpress), "enablebanking.use.amex")
        XCTAssertEqual(AppModel.enableBankingOptInKey(.amazonVisa), "enablebanking.use.amazonvisa")
    }
}
