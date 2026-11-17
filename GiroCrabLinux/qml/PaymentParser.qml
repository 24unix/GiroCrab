pragma Singleton
import QtQuick

// PaymentParser.swift: payment data from clipboard text (Sm@rtPaste), EPC QR
// payloads, ZUGFeRD / Factur-X XML and PDF text. A ParsedPayment is a plain
// object with the found fields only (name, iban, bic, amountText, purpose).
// QR codes inside dropped images/PDFs: Qt renders the page, rqrr decodes the
// code (read_invoice › src/qr_scan.rs, instead of Vision).
QtObject {
    /// CharacterSet.newlines (U+000A–U+000D, U+0085, U+2028, U+2029).
    readonly property var newlines: /\r\n|[\n\v\f\r\u0085\u2028\u2029]/
    /// CharacterSet.letters; QV4 without Unicode property escapes falls back to "has a case".
    readonly property var letterRx: { try { return new RegExp("\\p{L}", "u") } catch (e) { return null } }
    function hasLetter(s) {
        if (letterRx) return letterRx.test(s)
        for (const ch of s) if (ch.toUpperCase() !== ch.toLowerCase()) return true
        return false
    }
    /// String.prefix(n) without cutting a surrogate pair.
    function prefix(s, n) { const a = Array.from(s || ""); return a.length <= n ? (s || "") : a.slice(0, n).join("") }

    readonly property var ibanPattern: /\b[A-Za-z]{2}\d{2}(?:[ \t]?[A-Za-z0-9]{4}){2,7}(?:[ \t]?[A-Za-z0-9]{1,3})?\b/g
    // (?<![\d.,]) of the Swift pattern as a consumed prefix: the amount is group 1.
    readonly property var amountPattern: /(?:^|[^\d.,])(\d{1,3}(?:\.\d{3})+,\d{2}|\d{1,3}(?:,\d{3})+\.\d{2}|\d+[.,]\d{2})(?!\d)/

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

    // MARK: free text (Sm@rtPaste)

    function parseText(text) {
        const p = {}
        const lines = text.split(newlines).map(l => l.trim()).filter(l => l !== "")

        // IBAN: first candidate with a valid checksum.
        const iban = validIbanIn(text)
        if (iban) p.iban = iban

        // BIC (labelled only, to avoid matching random words).
        const bic = labelled(lines, ["BIC", "SWIFT"])
        if (bic && AppModel.looksLikeBIC(bic)) p.bic = bic.toUpperCase()

        // Amount: prefer labelled / currency-marked numbers.
        const amount = amountOf(text, lines)
        if (amount) p.amountText = amount

        const name = labelled(lines, ["Empfänger", "Zahlungsempfänger", "Kontoinhaber", "Begünstigter", "Name", "Beneficiary", "Recipient", "Payee"])
        if (name) p.name = name
        const purpose = labelled(lines, ["Verwendungszweck", "Zahlungsreferenz", "Rechnungsnummer", "Rechnung Nr.", "Rechnungs-Nr.", "Referenz", "Reference", "Betreff", "Purpose"])
        if (purpose) p.purpose = purpose
        if (p.name === undefined) {
            // First line that is neither IBAN, amount, nor a "label: value" pair.
            const l = lines.find(l => l.indexOf(":") < 0 && validIbanIn(l) === null && amountIn(l) === null
                                 && hasLetter(l) && Array.from(l).length <= 70)
            if (l) p.name = l
        }
        if (p.purpose === undefined) {
            const m = /\b(?:Rechnung(?:s)?(?:nummer|-?nr\.?)?|Invoice(?: No\.?)?|RE)\s*[:#]?\s*([A-Z0-9][A-Z0-9\-/.]{2,})/i.exec(text)
            if (m) p.purpose = "Rechnung " + m[1]
        }
        return p
    }

    function escapeRx(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") }

    function labelled(lines, labels) {
        for (const l of lines) {
            for (const label of labels) {
                const m = new RegExp("^" + escapeRx(label) + "\\s*[:=]\\s*(.+)$", "i").exec(l)
                if (m && m[1].trim() !== "") return m[1].trim()
            }
        }
        return null
    }

    function amountIn(s) { const m = amountPattern.exec(s); return m ? m[1] : null }

    function validIbanIn(s) {
        const rx = new RegExp(ibanPattern.source, "g")
        let m
        while ((m = rx.exec(s)) !== null) {
            const c = m[0].toUpperCase().replace(/\s/g, "")
            if (AppModel.validateIban(c)) return c
        }
        return null
    }

    function amountOf(text, lines) {
        // 1. Currency-marked ("123,45 €", "EUR 123.45").
        const cur = /(?:EUR|€)\s*(\d[\d.,]*\d)/i.exec(text) || /(\d[\d.,]*\d)\s*(?:EUR|€)/i.exec(text)
        if (cur) return normalizeAmount(cur[1])
        // 2. Labelled.
        for (const l of lines) {
            const v = /betrag|summe|total|amount|zu zahlen|gesamt/i.test(l) ? amountIn(l) : null
            if (v) return normalizeAmount(v)
        }
        // 3. Any decimal number outside IBAN lines.
        for (const l of lines) {
            if (validIbanIn(l) !== null) continue
            const v = amountIn(l)
            if (v) return normalizeAmount(v)
        }
        return null
    }

    /// "1.234,56" / "1,234.56" / "1234.56" -> the plain amount text of the form.
    function normalizeAmount(raw) {
        let s = raw.trim()
        const c = s.lastIndexOf(","), d = s.lastIndexOf(".")
        if (c >= 0 && d >= 0) {
            const decimal = c > d ? "," : "."
            const group = decimal === "," ? "." : ","
            s = s.split(group).join("").split(decimal).join(".")
        } else if (c >= 0) {
            s = s.split(",").join(".")
        }
        const cents = AppModel.parseCents(s)
        return cents !== null && cents > 0 ? Fmt.plain(cents) : null
    }

    // MARK: EPC QR (GiroCode)

    function parseEPC(payload) {
        const l = payload.split(newlines).map(x => x.trim())
        if (l.length < 7 || l[0] !== "BCD") return null
        const p = {}
        if (l[4] !== "") p.bic = l[4]
        if (l[5] !== "") p.name = l[5]
        const iban = l[6].toUpperCase().replace(/\s/g, "")
        if (iban !== "") p.iban = iban
        if (l.length > 7 && l[7].toUpperCase().startsWith("EUR")) { const a = normalizeAmount(l[7].slice(3)); if (a) p.amountText = a }
        const remittance = l.length > 10 ? l[10] : ""
        const reference = l.length > 9 ? l[9] : ""
        const purpose = remittance === "" ? reference : remittance
        if (purpose !== "") p.purpose = purpose
        return p
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
