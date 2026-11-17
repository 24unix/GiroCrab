import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Several Amex cards behind one login (#243): responses are grouped by a hash
/// of the card token, and only the card shown first is named from the switcher.
@MainActor
final class PortalCardsTests: XCTestCase {
    private let tx = #"{"transactions":[]}"#
    private let url = "https://global.americanexpress.com/api/servicing/v1/financials/transactions"

    func testCardKeyIsAShortStableHash() {
        XCTAssertEqual(PortalBrowser.cardKey(""), "")
        let k = PortalBrowser.cardKey("token-1")
        XCTAssertEqual(k.count, 16)
        XCTAssertEqual(k, PortalBrowser.cardKey("token-1"))
        XCTAssertNotEqual(k, PortalBrowser.cardKey("token-2"))
        XCTAssertFalse(k.contains("token"))
    }

    func testResponsesKeepTheirCard() {
        let b = PortalBrowser(url: URL(string: "about:blank")!, domains: PortalDomains(kind: .americanExpress))
        b.captured(tx, url: url, card: "token-1")
        b.captured(tx, url: url)
        XCTAssertEqual(b.bodyCards, [PortalBrowser.cardKey("token-1"), ""])
        XCTAssertEqual(b.listCard, PortalBrowser.cardKey("token-1"))
        // side requests may carry the login's other cards: they don't move the list card
        b.captured(#"{"balance":1}"#, url: "https://global.americanexpress.com/api/servicing/v1/financials/balances",
                   card: "token-2")
        XCTAssertEqual(b.listCard, PortalBrowser.cardKey("token-1"))
        XCTAssertEqual(b.cardKeys.count, 2)
        b.labelCurrentCard(name: "American Express® Card", number: "11111")
        b.labelCurrentCard(name: "American Express® Card", number: "11111")
        XCTAssertEqual(b.cards.map(\.key), [PortalBrowser.cardKey("token-1")])
        XCTAssertEqual(b.cards.map(\.number), ["11111"])
        b.teardown()
    }

    func testOnlyTheBookingListNamesACard() {
        XCTAssertTrue(PortalBrowser.isBookingList(url + "?limit=1000&status=posted"))
        XCTAssertFalse(PortalBrowser.isBookingList("https://global.americanexpress.com/api/servicing/v1/financials/transaction_summary"))
        XCTAssertFalse(PortalBrowser.isBookingList("https://global.americanexpress.com/api/servicing/v1/financials/balances"))
    }

    /// The Amex user name is a vault secret next to the login's PIN (password), so the
    /// core deletes it with the connection.
    func testPortalLoginKeyIsASecretOfTheConnection() {
        XCTAssertEqual(AppModel.portalLoginKey(7), "pin.conn.7.login")
        XCTAssertTrue(AppModel.portalLoginKey(7).hasPrefix("pin."))
    }
}
