import XCTest
@testable import GiroCrabUI

/// AmazonOrderRef parses the purpose of Amazon-orders bookings
/// (items + "– Bestellung <code>" suffix, see amazon_orders.rs `purpose()`).
final class AmazonOrderRefTests: XCTestCase {
    private func parse(_ purpose: String, domain: String? = "amazon.de") -> AmazonOrderRef? {
        AmazonOrderRef.parse(purpose: purpose, merchantDomain: domain)
    }

    func testSingleItemOrder() {
        let r = parse("2× DURACELL CR123 Batterie  – Bestellung 028-7519991-8057161")!
        XCTAssertEqual(r.items, "2× DURACELL CR123 Batterie")
        XCTAssertEqual(r.code, "028-7519991-8057161")
    }

    func testMultiItemOrderCountsRemainingSegments() {
        let r = parse("USB-Kabel; Buch; 4× AA Zellen – Bestellung 028-0171190-7789978")!
        // the row shows the first two items, the rest becomes "+N weitere"
        XCTAssertEqual(r.items, "USB-Kabel, Buch")
        XCTAssertEqual(r.moreCount, 1)
        XCTAssertEqual(r.itemList, ["USB-Kabel", "Buch", "4× AA Zellen"])
        XCTAssertEqual(r.code, "028-0171190-7789978")
    }

    func testTwoItemOrderShowsBothItems() {
        let r = parse("RayNeo Lens Shade; Magicfly Textilfarbe – Bestellung 028-9527653-7863537")!
        XCTAssertEqual(r.items, "RayNeo Lens Shade, Magicfly Textilfarbe")
        XCTAssertEqual(r.moreCount, 0)
    }

    func testSubscriptionChargeCode() {
        let r = parse("Amazon Kids+ – Bestellung D01-8331121-0187829")!
        XCTAssertEqual(r.items, "Amazon Kids+")
        XCTAssertEqual(r.code, "D01-8331121-0187829")
    }

    func testRefundBooking() {
        let r = parse("Erstattung für Bestellung D01-5502121-7039028")!
        XCTAssertEqual(r.items, "Erstattung")
        XCTAssertEqual(r.code, "D01-5502121-7039028")
    }

    func testNonAmazonMerchantIsIgnored() {
        XCTAssertNil(parse("2× Dingen – Bestellung 028-7519991-8057161", domain: "zinia.de"))
        XCTAssertNil(parse("2× Dingen – Bestellung 028-7519991-8057161", domain: nil))
    }

    func testPurposeWithoutOrderCodeIsIgnored() {
        // regular card payment booked at Amazon (no order reference inside)
        XCTAssertNil(parse("AMAZON PAYMENTS EU 1234567890"))
        XCTAssertNil(parse(""))
    }

    func testCodeMustMatchAmazonPattern() {
        XCTAssertNil(parse("Buch – Bestellung 12-34-56"))
    }

    func testSubscriptionFlagDistinguishesAboFromOrder() {
        XCTAssertFalse(parse("Buch – Bestellung 028-0171190-7789978")!.isSubscription)
        XCTAssertTrue(parse("Amazon Kids+ – Bestellung D01-8331121-0187829")!.isSubscription)
        XCTAssertTrue(parse("Erstattung für Bestellung D01-5502121-7039028")!.isSubscription)
        XCTAssertFalse(parse("Erstattung für Bestellung 028-7519991-8057161")!.isSubscription)
    }

    func testOrderURLUsesTheBookingShopDomain() {
        XCTAssertEqual(parse("Buch – Bestellung 028-1234567-7654321")!.orderURL,
                       URL(string: "https://www.amazon.de/gp/your-account/order-details?orderID=028-1234567-7654321"))
        XCTAssertEqual(parse("Book – Bestellung 028-1234567-7654321", domain: "amazon.com")!.orderURL,
                       URL(string: "https://www.amazon.com/gp/your-account/order-details?orderID=028-1234567-7654321"))
    }

    func testItemsLessDigitalOrderIsRecognised() {
        // importer purpose for orders without item titles (e.g. digital purchases)
        let r = parse("Bestellung 302-1234567-7789978")!
        XCTAssertEqual(r.items, "")
        XCTAssertEqual(r.code, "302-1234567-7789978")
        XCTAssertFalse(r.isSubscription)
    }

    func testRefundToleratesTrailingWhitespace() {
        // hand-edited purposes may carry stray whitespace after the code
        let r = parse("Erstattung für Bestellung 028-1234567-7654321 ")!
        XCTAssertEqual(r.code, "028-1234567-7654321")
    }

    func testItemsSeparatorWithoutOrderCodeIsIgnored() {
        XCTAssertNil(parse("USB-Kabel; Buch"))
    }

    func testBookingTextRecognisesAmazonDespiteLogoDomainOverride() {
        // user overrode the merchant logo domain; the booking text still identifies Amazon
        let r = AmazonOrderRef.parse(purpose: "Buch – Bestellung 028-1234567-7654321",
                                     merchantDomain: "smile.amazon.de",
                                     bookingText: "Amazon-Bestellung")!
        XCTAssertEqual(r.code, "028-1234567-7654321")
        XCTAssertEqual(r.domain, "amazon.de")
        XCTAssertNil(AmazonOrderRef.parse(purpose: "Buch – Bestellung 028-1234567-7654321",
                                          merchantDomain: "smile.amazon.de"))
    }
}
