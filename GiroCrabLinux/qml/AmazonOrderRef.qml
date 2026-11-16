pragma Singleton
import QtQuick

// AmazonOrderRef.swift: order info extracted from an Amazon-orders booking purpose.
//
// The importer stores items and order code in a single purpose string
// ("2× A; B – Bestellung 028-1234567-7654321", refunds as
// "Erstattung für Bestellung D01-…", see `purpose()` in
// girocrab-core/src/importers/amazon_orders.rs). The list row shows the
// items instead of the redundant "Bestellung" payment-method label,
// plus the code as its own compact reference.
//
// A ref is a plain object: items (first two items for the list row), moreCount
// (items beyond those), itemList (all items), code, isSubscription, domain
// ("amazon.de" / "amazon.com"), itemASINs (one per item, "" = unknown, from
// `Booking.item_refs`, #354) and isRefund.
QtObject {
    /// Same wording and dash (en dash) as `purpose()` in amazon_orders.rs.
    readonly property string orderSuffix: " – Bestellung "
    readonly property string refundPrefix: "Erstattung für Bestellung "

    function make(items, moreCount, itemList, code, domain, itemASINs) {
        return { items: items, moreCount: moreCount, itemList: itemList, code: code,
                 isSubscription: code.startsWith("D"), domain: domain, itemASINs: itemASINs,
                 isRefund: items === "Erstattung" }
    }

    /// Splits `Booking.item_refs` ("B08XYZ1234,,3453146883"): one entry per item, "" = unknown.
    function asins(itemRefs) { return itemRefs ? itemRefs.split(",") : [] }

    /// An ASIN is 10 upper-case ASCII letters / digits.
    function isASIN(s) { return /^[0-9A-Z]{10}$/.test(s) }

    /// Amazon order codes are 3-7-7 digits ("028-1234567-7654321");
    /// subscription charges start with D ("D01-1234567-7654321").
    function isOrderCode(s) { return /^(?:\d{3}|D\d{2})-\d{7}-\d{7}$/.test(s) }

    /// Order detail page of this booking's shop.
    function orderURL(ref) { return "https://www." + ref.domain + "/gp/your-account/order-details?orderID=" + ref.code }

    /// Product page of the item at `index` in this booking's shop; "" without a valid ASIN.
    function productURL(ref, index) {
        const a = ref.itemASINs[index]
        return a !== undefined && isASIN(a) ? "https://www." + ref.domain + "/dp/" + a : ""
    }

    /// Parses an Amazon-orders booking; null for any other booking.
    ///
    /// Amazon bookings are recognised by the importer's booking text or the
    /// merchant's shop domain. The domain alone is not enough: users can
    /// override the merchant logo domain (e.g. "smile.amazon.de"), which
    /// must not hide the order reference.
    function parse(booking) {
        if (!booking) return null
        const purpose = booking.purpose || ""
        const domain = (booking.merchant_domain || "").toLowerCase()
        const text = booking.booking_text || ""
        const amazonBooking = text === "Amazon-Bestellung" || text === "Amazon-Erstattung"
        if (purpose === "" || !(amazonBooking || domain === "amazon.de" || domain === "amazon.com")) return null
        const shop = domain === "amazon.com" ? "amazon.com" : "amazon.de"
        // Refund booking: the purpose is only the code reference.
        if (purpose.startsWith(refundPrefix)) {
            const code = purpose.slice(refundPrefix.length).trim()
            return isOrderCode(code) ? make("Erstattung", 0, [], code, shop, []) : null
        }
        // Items-less order (e.g. digital purchases): purpose is only "Bestellung <code>".
        if (purpose.startsWith("Bestellung ")) {
            const code = purpose.slice("Bestellung ".length)
            return isOrderCode(code) ? make("", 0, [], code, shop, []) : null
        }
        // Order booking: "<items> – Bestellung <code>"
        const at = purpose.lastIndexOf(orderSuffix)
        if (at < 0) return null
        const code = purpose.slice(at + orderSuffix.length).trim()
        const itemsPart = purpose.slice(0, at).trim()
        if (!isOrderCode(code) || itemsPart === "") return null
        const itemList = itemsPart.split("; ").filter(s => s !== "")
        // Most orders carry one or two items — show both, count only the rest.
        return make(itemList.slice(0, 2).join(", "), Math.max(0, itemList.length - 2), itemList, code, shop,
                    asins(booking.item_refs || ""))
    }

    /// AppModel.amazonRefundSource: the order a refund booking belongs to (same
    /// account, same order code) among the loaded `bookings`. Returns its display
    /// items, full item list and booking id ({ items, list, id }), so the row can
    /// show what the refund is for and the detail view can jump to the original.
    function refundSource(booking, bookings) {
        const ref = parse(booking)
        if (!ref || !ref.isRefund) return null
        for (const other of bookings) {
            if (other.account_id !== booking.account_id || other.id === booking.id) continue
            const o = parse(other)
            if (o && o.code === ref.code && !o.isRefund) return { items: o.items, list: o.itemList, id: other.id }
        }
        return null
    }
}
