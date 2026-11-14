import Foundation
import GiroCrabCore

/// Order info extracted from an Amazon-orders booking purpose.
///
/// The importer stores items and order code in a single purpose string
/// ("2× A; B – Bestellung 028-1234567-7654321", refunds as
/// "Erstattung für Bestellung D01-…", see `purpose()` in
/// girocrab-core/src/importers/amazon_orders.rs). The list row shows the
/// items instead of the redundant "Bestellung" payment-method label,
/// plus the code as its own compact reference.
struct AmazonOrderRef: Equatable {
    /// Items for the list row: first item only; `moreCount` counts the rest.
    let items: String
    /// Items beyond the first one (multi-item orders).
    let moreCount: Int
    /// All items of the order, one entry each — for the detail card and tooltips.
    let itemList: [String]
    /// Amazon order code (e.g. "028-1234567-7654321").
    let code: String
    /// Subscription charges ("D01-…" / Spar-Abo) are recurring, orders are not.
    let isSubscription: Bool
    /// Shop domain the booking belongs to ("amazon.de" / "amazon.com").
    let domain: String

    /// Order detail page of this booking's shop.
    var orderURL: URL? {
        URL(string: "https://www.\(domain)/gp/your-account/order-details?orderID=\(code)")
    }

    /// Same wording and dash (en dash) as `purpose()` in amazon_orders.rs.
    private static let orderSuffix = " – Bestellung "
    private static let refundPrefix = "Erstattung für Bestellung "

    /// True when this ref describes a refund booking (not an order).
    var isRefund: Bool { items == "Erstattung" }

    /// Parses an Amazon-orders booking purpose; nil for any other booking.
    ///
    /// Amazon bookings are recognised by the importer's booking text or the
    /// merchant's shop domain. The domain alone is not enough: users can
    /// override the merchant logo domain (e.g. "smile.amazon.de"), which
    /// must not hide the order reference.
    static func parse(purpose: String, merchantDomain: String?, bookingText: String = "") -> AmazonOrderRef? {
        let domain = merchantDomain?.lowercased() ?? ""
        let amazonBooking = bookingText == "Amazon-Bestellung" || bookingText == "Amazon-Erstattung"
        guard !purpose.isEmpty,
              amazonBooking || domain == "amazon.de" || domain == "amazon.com" else { return nil }
        let shop = domain == "amazon.com" ? "amazon.com" : "amazon.de"
        // Refund booking: the purpose is only the code reference.
        if purpose.hasPrefix(refundPrefix) {
            let code = String(purpose.dropFirst(refundPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return isOrderCode(code)
                ? AmazonOrderRef(items: "Erstattung", moreCount: 0, itemList: [],
                                 code: code, isSubscription: code.hasPrefix("D"), domain: shop)
                : nil
        }
        // Items-less order (e.g. digital purchases): purpose is only "Bestellung <code>".
        if purpose.hasPrefix("Bestellung ") {
            let code = String(purpose.dropFirst("Bestellung ".count))
            return isOrderCode(code)
                ? AmazonOrderRef(items: "", moreCount: 0, itemList: [],
                                 code: code, isSubscription: code.hasPrefix("D"), domain: shop)
                : nil
        }
        // Order booking: "<items> – Bestellung <code>"
        guard let suffix = purpose.range(of: orderSuffix, options: .backwards) else { return nil }
        let code = purpose[suffix.upperBound...].trimmingCharacters(in: .whitespaces)
        let itemsPart = purpose[..<suffix.lowerBound].trimmingCharacters(in: .whitespaces)
        guard isOrderCode(code), !itemsPart.isEmpty else { return nil }
        let itemList = itemsPart.split(separator: "; ", omittingEmptySubsequences: true).map(String.init)
        // Most orders carry one or two items — show both, count only the rest.
        let head = itemList.prefix(2).joined(separator: ", ")
        return AmazonOrderRef(items: head, moreCount: max(0, itemList.count - 2),
                              itemList: itemList, code: code,
                              isSubscription: code.hasPrefix("D"), domain: shop)
    }

    /// Amazon order codes are 3-7-7 digits ("028-1234567-7654321");
    /// subscription charges start with D ("D01-1234567-7654321").
    private static func isOrderCode(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0].count == 3,
              parts[1].count == 7, parts[2].count == 7,
              (parts[1] + parts[2]).allSatisfy(isASCIIDigit) else { return false }
        return parts[0].allSatisfy(isASCIIDigit)
            || (parts[0].first == "D" && parts[0].dropFirst().allSatisfy(isASCIIDigit))
    }

    private static func isASCIIDigit(_ c: Character) -> Bool {
        c.asciiValue.map { (0x30...0x39).contains($0) } ?? false
    }
}

extension AppModel {
    /// The order a refund booking belongs to: same account, same order code.
    /// Returns its display items, full item list and booking id, so the row can
    /// show what the refund is for and the detail view can jump to the original.
    func amazonRefundSource(_ booking: Booking) -> (items: String, list: [String], id: Booking.ID)? {
        guard let ref = AmazonOrderRef.parse(purpose: booking.purpose,
                                             merchantDomain: booking.merchantDomain,
                                             bookingText: booking.bookingText),
              ref.isRefund else { return nil }
        for other in bookings where other.accountId == booking.accountId && other.id != booking.id {
            guard let o = AmazonOrderRef.parse(purpose: other.purpose,
                                               merchantDomain: other.merchantDomain,
                                               bookingText: other.bookingText),
                  o.code == ref.code, !o.isRefund else { continue }
            return (o.items, o.itemList, other.id)
        }
        return nil
    }
}
