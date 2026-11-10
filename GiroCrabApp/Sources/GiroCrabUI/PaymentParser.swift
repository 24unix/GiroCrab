import Foundation
import PDFKit
import Vision
import Compression
import GiroCrabCore

/// Payment data extracted from clipboard text, ZUGFeRD XML, EPC QR or PDF text.
struct ParsedPayment: Equatable {
    var name: String?
    var iban: String?
    var bic: String?
    var amountText: String?
    var purpose: String?

    var isEmpty: Bool { name == nil && iban == nil && bic == nil && amountText == nil && purpose == nil }

    /// Fills only the fields that were found.
    func apply(to d: inout TransferDraft) {
        if let name { d.name = name }
        if let iban { d.iban = TransferSheetView.groupedIBAN(iban) }
        if let bic { d.bic = bic }
        if let amountText { d.amountText = amountText }
        if let purpose { d.purpose = String(purpose.prefix(140)) }
    }
}

enum PaymentParser {
    // MARK: free text (Sm@rtPaste)

    static func parseText(_ text: String) -> ParsedPayment {
        var p = ParsedPayment()
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        // IBAN: first candidate with a valid checksum.
        let ibanRx = try! NSRegularExpression(pattern: #"\b[A-Za-z]{2}\d{2}(?:[ \t]?[A-Za-z0-9]{4}){2,7}(?:[ \t]?[A-Za-z0-9]{1,3})?\b"#)
        let ns = text as NSString
        for m in ibanRx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let cand = ns.substring(with: m.range).uppercased().filter { !$0.isWhitespace }
            if validateIban(iban: cand) { p.iban = cand; break }
        }

        // BIC (labelled only, to avoid matching random words).
        if let v = labelled(lines, ["BIC", "SWIFT"]), TransferSheetView.looksLikeBIC(v) { p.bic = v.uppercased() }

        // Amount: prefer labelled / currency-marked numbers.
        p.amountText = amount(in: text, lines: lines)

        // Name.
        p.name = labelled(lines, ["Empfänger", "Zahlungsempfänger", "Kontoinhaber", "Begünstigter", "Name", "Beneficiary", "Recipient", "Payee"])
        // Purpose.
        p.purpose = labelled(lines, ["Verwendungszweck", "Zahlungsreferenz", "Rechnungsnummer", "Rechnung Nr.", "Rechnungs-Nr.", "Referenz", "Reference", "Betreff", "Purpose"])
        if p.name == nil {
            // First line that is neither IBAN, amount, nor a "label: value" pair.
            p.name = lines.first { l in
                !l.contains(":") && validIbanIn(l) == nil && amountIn(l) == nil
                    && l.rangeOfCharacter(from: .letters) != nil && l.count <= 70
            }
        }
        if p.purpose == nil, let rn = firstMatch(#"(?i)\b(?:Rechnung(?:s)?(?:nummer|-?nr\.?)?|Invoice(?: No\.?)?|RE)\s*[:#]?\s*([A-Z0-9][A-Z0-9\-/\.]{2,})"#, in: text) {
            p.purpose = "Rechnung \(rn)"
        }
        return p
    }

    private static func labelled(_ lines: [String], _ labels: [String]) -> String? {
        for l in lines {
            for label in labels {
                let pat = "^(?i)" + NSRegularExpression.escapedPattern(for: label) + #"\s*[:=]\s*(.+)$"#
                if let v = firstMatch(pat, in: l)?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return v }
            }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: pattern),
              let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return (s as NSString).substring(with: m.range(at: 1))
    }

    private static let amountPattern = #"(?<![\d.,])(\d{1,3}(?:\.\d{3})+,\d{2}|\d{1,3}(?:,\d{3})+\.\d{2}|\d+[.,]\d{2})(?![\d])"#

    private static func amountIn(_ s: String) -> String? { firstMatch(amountPattern, in: s) }

    private static func validIbanIn(_ s: String) -> String? {
        let rx = try! NSRegularExpression(pattern: #"\b[A-Za-z]{2}\d{2}(?:[ \t]?[A-Za-z0-9]{4}){2,7}(?:[ \t]?[A-Za-z0-9]{1,3})?\b"#)
        let ns = s as NSString
        for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let c = ns.substring(with: m.range).uppercased().filter { !$0.isWhitespace }
            if validateIban(iban: c) { return c }
        }
        return nil
    }

    private static func amount(in text: String, lines: [String]) -> String? {
        // 1. Currency-marked ("123,45 €", "EUR 123.45").
        if let v = firstMatch(#"(?i)(?:EUR|€)\s*(\d[\d.,]*\d)"#, in: text) ?? firstMatch(#"(?i)(\d[\d.,]*\d)\s*(?:EUR|€)"#, in: text) {
            return normalizeAmount(v)
        }
        // 2. Labelled.
        for l in lines {
            if l.range(of: #"(?i)betrag|summe|total|amount|zu zahlen|gesamt"#, options: .regularExpression) != nil, let v = amountIn(l) {
                return normalizeAmount(v)
            }
        }
        // 3. Any decimal number outside IBAN lines.
        for l in lines where validIbanIn(l) == nil {
            if let v = amountIn(l) { return normalizeAmount(v) }
        }
        return nil
    }

    /// "1.234,56" / "1,234.56" / "1234.56" -> locale-independent "1234.56" text accepted by the core parser.
    static func normalizeAmount(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let c = s.lastIndex(of: ","), let d = s.lastIndex(of: ".") {
            let decimal = c > d ? Character(",") : Character(".")
            let group = decimal == "," ? Character(".") : Character(",")
            s = s.filter { $0 != group }.replacingOccurrences(of: String(decimal), with: ".")
        } else if s.contains(",") {
            s = s.replacingOccurrences(of: ",", with: ".")
        }
        guard let dec = Decimal(string: s, locale: Locale(identifier: "en_US")), dec > 0,
              let cents = try? parseAmountToCents(text: s) else { return nil }
        return Money.plain(cents)
    }

    // MARK: EPC QR (GiroCode)

    static func parseEPC(_ payload: String) -> ParsedPayment? {
        let l = payload.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard l.count >= 7, l[0] == "BCD" else { return nil }
        var p = ParsedPayment()
        if !l[4].isEmpty { p.bic = l[4] }
        if !l[5].isEmpty { p.name = l[5] }
        let iban = l[6].uppercased().filter { !$0.isWhitespace }
        if !iban.isEmpty { p.iban = iban }
        if l.count > 7, l[7].uppercased().hasPrefix("EUR") { p.amountText = normalizeAmount(String(l[7].dropFirst(3))) }
        let remittance = l.count > 10 ? l[10] : ""
        let reference = l.count > 9 ? l[9] : ""
        let purpose = remittance.isEmpty ? reference : remittance
        if !purpose.isEmpty { p.purpose = purpose }
        return p
    }

    // MARK: ZUGFeRD / Factur-X XML

    static func parseInvoiceXML(_ data: Data) -> ParsedPayment? {
        let d = InvoiceXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = d
        parser.parse()
        var p = ParsedPayment()
        p.name = d.seller
        p.iban = d.iban?.uppercased().filter { !$0.isWhitespace }
        p.bic = d.bic
        if let a = d.amount ?? d.grandTotal { p.amountText = normalizeAmount(a) }
        if let ref = d.paymentReference ?? d.invoiceID.map({ "Rechnung \($0)" }) { p.purpose = ref }
        return p.isEmpty || d.seller == nil && d.iban == nil ? nil : p
    }

    // MARK: files (PDF / XML / image)

    /// Order: embedded XML → EPC QR → text layer.
    static func parseFile(_ url: URL) async -> ParsedPayment? {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let isPDF = data.starts(with: [0x25, 0x50, 0x44, 0x46])
        if !isPDF, let s = String(data: data.prefix(4096), encoding: .utf8), s.contains("CrossIndustryInvoice") {
            return parseInvoiceXML(data)
        }
        if isPDF, let xml = embeddedInvoiceXML(in: data), let p = parseInvoiceXML(xml) { return p }
        if let cg = image(from: data, isPDF: isPDF), let payload = await qrPayloads(cg).first(where: { $0.hasPrefix("BCD") }),
           let p = parseEPC(payload) { return p }
        if let text = await ReceiptText.extract(data: data, fileName: url.lastPathComponent) {
            let p = parseText(text)
            return p.isEmpty ? nil : p
        }
        return nil
    }

    /// Scans PDF streams (inflating Flate ones) for a CrossIndustryInvoice document.
    static func embeddedInvoiceXML(in pdf: Data) -> Data? {
        let start = Data("stream".utf8), end = Data("endstream".utf8)
        var cursor = pdf.startIndex
        while let s = pdf.range(of: start, in: cursor..<pdf.endIndex) {
            guard let e = pdf.range(of: end, in: s.upperBound..<pdf.endIndex) else { break }
            cursor = e.upperBound
            var body = pdf[s.upperBound..<e.lowerBound]
            if body.first == 0x0D { body = body.dropFirst() }
            if body.first == 0x0A { body = body.dropFirst() }
            let raw = Data(body)
            if raw.range(of: Data("CrossIndustryInvoice".utf8)) != nil { return raw }
            if raw.count > 8, raw[raw.startIndex] == 0x78, let inflated = inflate(raw),
               inflated.range(of: Data("CrossIndustryInvoice".utf8)) != nil { return inflated }
        }
        return nil
    }

    private static func inflate(_ zlib: Data) -> Data? {
        let payload = zlib.dropFirst(2) // strip zlib header; Compression wants raw deflate
        var cap = max(payload.count * 8, 64 * 1024)
        for _ in 0..<4 {
            var out = [UInt8](repeating: 0, count: cap)
            let n = payload.withUnsafeBytes { src -> Int in
                guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(&out, cap, base, payload.count, nil, COMPRESSION_ZLIB)
            }
            if n > 0 && n < cap { return Data(out[0..<n]) }
            cap *= 4
        }
        return nil
    }

    private static func image(from data: Data, isPDF: Bool) -> CGImage? {
        if isPDF {
            guard let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
            let box = page.bounds(for: .mediaBox)
            let scale: CGFloat = 3
            let size = CGSize(width: box.width * scale, height: box.height * scale)
            guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            return ctx.makeImage()
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func qrPayloads(_ cg: CGImage) async -> [String] {
        await withCheckedContinuation { cont in
            let req = VNDetectBarcodesRequest()
            req.symbologies = [.qr]
            do {
                try VNImageRequestHandler(cgImage: cg).perform([req])
                cont.resume(returning: (req.results ?? []).compactMap { $0.payloadStringValue })
            } catch {
                cont.resume(returning: [])
            }
        }
    }
}

private final class InvoiceXMLDelegate: NSObject, XMLParserDelegate {
    var path: [String] = []
    var text = ""
    var seller: String?, iban: String?, bic: String?, paymentReference: String?, invoiceID: String?
    var amount: String?, grandTotal: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        path.append(name.split(separator: ":").last.map(String.init) ?? name)
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { path.removeLast(); text = "" }
        guard !v.isEmpty, let last = path.last else { return }
        switch last {
        case "Name" where path.contains("SellerTradeParty") && seller == nil: seller = v
        case "IBANID" where iban == nil: iban = v
        case "BICID" where bic == nil: bic = v
        case "PaymentReference" where paymentReference == nil: paymentReference = v
        case "ID" where path.suffix(2) == ["ExchangedDocument", "ID"] && invoiceID == nil: invoiceID = v
        case "DuePayableAmount" where amount == nil: amount = v
        case "GrandTotalAmount" where grandTotal == nil: grandTotal = v
        default: break
        }
    }
}
