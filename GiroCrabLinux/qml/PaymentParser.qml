pragma Singleton
import QtQuick

// PaymentParser.swift: payment data from clipboard text (Sm@rtPaste), EPC QR
// payloads, ZUGFeRD / Factur-X XML and PDF text. A ParsedPayment is a plain
// object with the found fields only (name, iban, bic, amountText, purpose).
// QR codes inside dropped images/PDFs: Qt renders the page, rqrr decodes the
// code (read_invoice › src/qr_scan.rs, instead of Vision).
QtObject {
    /// String.prefix(n) without cutting a surrogate pair.
    function prefix(s, n) { const a = Array.from(s || ""); return a.length <= n ? (s || "") : a.slice(0, n).join("") }

    function isEmpty(p) { return !p || (p.name === undefined && p.iban === undefined && p.bic === undefined && p.amountText === undefined && p.purpose === undefined) }

    /// ParsedPayment.apply(to:) as a draft patch: only the fields that were found.
    function patch(p) {
        const d = {}
        if (p.name !== undefined) d.name = p.name
        if (p.iban !== undefined) d.iban = AppModel.groupedIBAN(p.iban)
        if (p.bic !== undefined) d.bic = p.bic
        if (p.amountText !== undefined) d.amountText = p.amountText
        if (p.purpose !== undefined) d.purpose = prefix(p.purpose, 140)
        return d
    }

    /// The core's PaymentDetails (cents, null = not found) as a ParsedPayment.
    function fromDetails(d) {
        const p = {}
        if (!d) return p
        if (d.name !== null) p.name = d.name
        if (d.iban !== null) p.iban = d.iban
        if (d.bic !== null) p.bic = d.bic
        if (d.amount_cents !== null) p.amountText = Fmt.plain(d.amount_cents)
        if (d.purpose !== null) p.purpose = d.purpose
        return p
    }

    // MARK: free text (Sm@rtPaste)

    /// IBAN with a valid checksum, labelled BIC, amount, name and purpose (core: parse_payment_text).
    function parseText(text) {
        return fromDetails(AppModel.coreOrNull("parse_payment_text", { text: text }))
    }

    /// "1.234,56" / "1,234.56" / "1234.56" -> the plain amount text of the form, null when no amount > 0.
    function normalizeAmount(raw) {
        const cents = AppModel.coreOrNull("parse_amount_loose", { text: raw })
        return cents !== null ? Fmt.plain(cents) : null
    }

    // MARK: EPC QR (GiroCode)

    /// null when the payload is no SEPA credit transfer GiroCode (core: parse_epc_payload).
    function parseEPC(payload) {
        const d = AppModel.coreOrNull("parse_epc_payload", { payload: payload })
        return d ? fromDetails(d) : null
    }

    // MARK: ZUGFeRD / Factur-X XML

    /// Character data like XMLParser delivers it: CDATA sections verbatim,
    /// named and numeric character references (&#228; &#xE4;) decoded.
    readonly property string textPattern: "((?:<!\\[CDATA\\[[\\s\\S]*?\\]\\]>|[^<])*)<"
    function decodeEntities(s) {
        return s.replace(/&(#x[0-9A-Fa-f]+|#\d+|lt|gt|quot|apos|amp);/g, (m, e) => {
            if (e[0] === "#") {
                const cp = e[1] === "x" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)
                return cp > 0 && cp <= 0x10FFFF ? String.fromCodePoint(cp) : m
            }
            return { lt: "<", gt: ">", quot: "\"", apos: "'", amp: "&" }[e]
        })
    }
    function xmlText(s) {
        let out = "", rest = s
        for (;;) {
            const i = rest.indexOf("<![CDATA[")
            if (i < 0) { out += decodeEntities(rest); break }
            const j = rest.indexOf("]]>", i + 9)
            if (j < 0) { out += decodeEntities(rest); break }
            out += decodeEntities(rest.slice(0, i)) + rest.slice(i + 9, j)
            rest = rest.slice(j + 3)
        }
        return out.trim()
    }
    function firstElement(xml, tag) {
        const m = new RegExp("<(?:[\\w-]+:)?" + tag + "\\b[^>]*>" + textPattern).exec(xml)
        const v = m ? xmlText(m[1]) : ""
        return v !== "" ? v : null
    }

    function parseInvoiceXML(xml) {
        const partyRx = /<(?:[\w-]+:)?SellerTradeParty\b[^>]*>([\s\S]*?)<\/(?:[\w-]+:)?SellerTradeParty>/
        const party = partyRx.exec(xml)
        const seller = party ? firstElement(party[1], "Name") : null
        const iban = firstElement(xml, "IBANID")
        const bic = firstElement(xml, "BICID")
        const ref = firstElement(xml, "PaymentReference")
        const docRx = new RegExp("<(?:[\\w-]+:)?ExchangedDocument\\b[^>]*>[\\s\\S]*?<(?:[\\w-]+:)?ID\\b[^>]*>" + textPattern)
        const doc = docRx.exec(xml)
        const invoiceID = doc && xmlText(doc[1]) !== "" ? xmlText(doc[1]) : null
        const amount = firstElement(xml, "DuePayableAmount") || firstElement(xml, "GrandTotalAmount")
        const p = {}
        if (seller) p.name = seller
        if (iban) p.iban = iban.toUpperCase().replace(/\s/g, "")
        if (bic) p.bic = bic
        if (amount) { const a = normalizeAmount(amount); if (a) p.amountText = a }
        if (ref) p.purpose = ref
        else if (invoiceID) p.purpose = "Rechnung " + invoiceID
        return isEmpty(p) || (seller === null && iban === null) ? null : p
    }

    // MARK: files (PDF / XML / image)

    /// Order: embedded XML → EPC QR → text layer. `path` is a local file path; the
    /// file is read off the GUI thread and `done(p)` gets the result (null = nothing).
    function parseFile(path, done) {
        AppModel.coreAsync("read_invoice", { path: path }, r => done(parseInvoiceResult(r)), () => done(null))
    }
    function parseInvoiceResult(r) {
        if (r.xml) { const p = parseInvoiceXML(r.xml); if (p) return p }
        if (r.epc) { const p = parseEPC(r.epc); if (p) return p }
        if (r.text) { const p = parseText(r.text); return isEmpty(p) ? null : p }
        return null
    }
}
