pragma Singleton
import QtQuick

// Text helpers of the booking list and the inspector that only read the already loaded booking
// (no core call): ListPurpose (BookingListView.swift, #497), BookingInlineDetails.swift (#542)
// and AppModel.counterAccount(for:) (AppModel.swift, #523).
QtObject {
    id: details

    // MARK: AppModel.counterAccount(for:) (#523)
    /// Own accounts by IBAN without spaces, upper case: [account] (several when imported twice).
    readonly property var accountsByIBAN: {
        const out = {}
        for (const a of AppModel.allAccounts) {
            const k = normIBAN(a.iban)
            if (k !== "") (out[k] = out[k] || []).push(a)
        }
        return out
    }
    function normIBAN(s) { return (s || "").replace(/\s+/g, "").toUpperCase() }
    /// Own account/pocket matching `booking.counterparty_iban`, if any.
    function counterAccount(b) {
        if (!b) return null
        const list = accountsByIBAN[normIBAN(b.counterparty_iban)]
        return list ? (list.find(a => a.id !== b.account_id) || null) : null
    }

    // MARK: AppModel+Editing.swift › categorizeTargets(for:) (#366)
    /// What a row's menus and drag act on: the multiple selection when the row is part of it,
    /// otherwise the row alone (like a file manager).
    function categorizeTargets(b) {
        if (!b) return []
        return AppModel.isMultiSelection && AppModel.selectedBookingIDs[b.id] ? AppModel.selectedBookings : [b]
    }

    // MARK: ListPurpose (#497)
    /// The name a booking row shows.
    function shownName(b) { return b.merchant.name || b.booking_text }
    /// Letters and digits only, case-insensitive: "REWE Markt GmbH" ≙ "rewe-markt gmbh".
    function normalized(s) {
        let out = ""
        for (const ch of (s || "").toLowerCase())
            if ((ch >= "0" && ch <= "9") || ch.toUpperCase() !== ch.toLowerCase()) out += ch
        return out
    }
    /// One line of purpose, or "" when there is none or it only repeats what the row already
    /// shows (merchant name, counterparty, payment method), as card payments often do.
    function listPurpose(b) {
        if (!b) return ""
        const raw = b.clean_purpose || b.purpose || ""
        const line = raw.split(/\s+/).filter(x => x !== "").join(" ")
        const key = normalized(line)
        if (key === "") return ""
        for (const shown of [shownName(b), b.counterparty, b.payment_method, b.booking_text]) {
            const other = normalized(shown)
            if (other !== "" && other.indexOf(key) >= 0) return ""
        }
        return line
    }

    // MARK: BookingInlineDetails.swift (#542)
    /// SEPA tags in the purpose: [{ tag, start, end }] (start of the tag, end of "TAG+").
    /// Lookbehind-free form of the Mac's `(?<![A-Za-z0-9])[A-Z]{3,4}\+`.
    function tagMatches(text) {
        const re = /(^|[^A-Za-z0-9])([A-Z]{3,4})\+/g
        const out = []
        let m
        while ((m = re.exec(text)) !== null) {
            const start = m.index + m[1].length
            out.push({ tag: m[2], start: start, end: start + m[2].length + 1 })
            re.lastIndex = start + m[2].length + 1
        }
        return out
    }
    readonly property var referenceTags: ["EREF", "KREF", "MREF", "CRED"]
    /// EREF/KREF/MREF/CRED values of the purpose, without NOTPROVIDED / NONREF.
    function sepaFields(purpose) {
        const text = purpose || ""
        const matches = tagMatches(text)
        const fields = {}
        matches.forEach((m, i) => {
            if (referenceTags.indexOf(m.tag) < 0) return
            const end = i + 1 < matches.length ? matches[i + 1].start : text.length
            const value = text.slice(m.end, end).trim()
            if (value !== "" && ["NOTPROVIDED", "NONREF"].indexOf(value.toUpperCase()) < 0) fields[m.tag] = value
        })
        return fields
    }
    /// The original narrative with line breaks and card/date information; only explicitly
    /// tagged references move to the labelled fields.
    function fullPurpose(b) {
        const raw = b.purpose || b.clean_purpose || ""
        const matches = tagMatches(raw)
        let narrative = raw
        for (let i = matches.length - 1; i >= 0; i--) {
            const m = matches[i]
            if (referenceTags.indexOf(m.tag) >= 0) {
                const end = i + 1 < matches.length ? matches[i + 1].start : raw.length
                narrative = narrative.slice(0, m.start) + narrative.slice(end)
            } else if (m.tag === "SVWZ") {
                narrative = narrative.slice(0, m.start) + narrative.slice(m.end)
            }
        }
        const value = narrative.trim()
        return value === shownName(b) ? "" : value
    }
    /// Labelled fields of an expanded row: [{ id, title, value, redaction }], redaction
    /// "personal" | "labels" | "" (Sensitive {} / Sensitive { labels: true } / visible).
    function fields(b) {
        const result = []
        function add(id, title, raw, hides) {
            const value = (raw || "").trim()
            if (value !== "") result.push({ id: id, title: title, value: value, redaction: hides === undefined ? "personal" : hides })
        }
        const title = shownName(b)
        if (b.counterparty !== title) add("counterparty", qsTr("Gegenpartei"), b.counterparty)
        add("category", qsTr("Kategorie"), b.category_path || b.category_name, "labels")
        // tag names often name people: hidden like personal data (#228)
        add("tags", qsTr("Tags"), (b.tags || []).map(t => t.name).join(", "))
        add("note", qsTr("Notiz"), b.note)
        const transactionType = b.payment_method || b.booking_text
        add("type", qsTr("Umsatzart"), transactionType)
        if (b.booking_text !== title && b.booking_text.toLowerCase() !== (transactionType || "").toLowerCase()
                && b.booking_text !== b.clean_purpose)
            add("bookingText", qsTr("Buchungstext"), b.booking_text)
        const refs = sepaFields(b.purpose)
        add("reference", qsTr("Referenz"), refs.EREF)
        add("customerReference", qsTr("Kundenreferenz"), refs.KREF)
        add("mandate", qsTr("Mandatsreferenz"), refs.MREF)
        add("creditor", qsTr("Gläubiger-ID"), refs.CRED)
        const order = AmazonOrderRef.parse(b)
        if (order) add("order", qsTr("Bestellnummer"), order.code)
        if (b.value_date) add("valueDate", qsTr("Wertstellung"), Fmt.medium(b.value_date), "")
        add("account", qsTr("Konto"), b.account_name)
        add("iban", qsTr("IBAN Gegenkonto"), Fmt.iban(b.counterparty_iban))
        return result
    }
}
