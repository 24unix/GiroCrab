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

extension ParsedPayment {
    init(_ d: PaymentDetails) {
        self.init(name: d.name, iban: d.iban, bic: d.bic, amountText: d.amountCents.map(Money.plain), purpose: d.purpose)
    }
}

enum PaymentParser {
    // MARK: free text (transfer from clipboard) – parsed by the core (`payment_input.rs`)

    static func parseText(_ text: String) -> ParsedPayment {
        ParsedPayment(parsePaymentText(text: text))
    }

    /// "1.234,56" / "1,234.56" / "1234.56" -> locale-independent "1234.56" text accepted by the core parser.
    static func normalizeAmount(_ raw: String) -> String? {
        parseAmountLoose(text: raw).map(Money.plain)
    }

    // MARK: EPC QR (GiroCode)

    static func parseEPC(_ payload: String) -> ParsedPayment? {
        parseEpcPayload(payload: payload).map(ParsedPayment.init)
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

    /// Largest inflated stream that is looked at: an invoice document is a few hundred
    /// kilobytes; a crafted PDF could otherwise have the buffer grow 512-fold.
    static let maxInflatedBytes = 16 * 1024 * 1024

    static func inflate(_ zlib: Data, limit: Int = maxInflatedBytes) -> Data? {
        let payload = zlib.dropFirst(2) // strip zlib header; Compression wants raw deflate
        var cap = min(max(payload.count * 8, 64 * 1024), limit)
        while true {
            var out = [UInt8](repeating: 0, count: cap)
            let n = payload.withUnsafeBytes { src -> Int in
                guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(&out, cap, base, payload.count, nil, COMPRESSION_ZLIB)
            }
            if n > 0 && n < cap { return Data(out[0..<n]) }
            // full buffer or failure: try a bigger one, but never past the limit
            guard cap < limit else { return nil }
            cap = min(cap * 4, limit)
        }
    }

    /// Scale for rendering the first PDF page for QR detection: 3x, but never more
    /// than `maxPixels` in the bitmap (a crafted media box of 200000 x 200000 pt
    /// would otherwise ask for gigabytes). nil = unusable page size.
    static func pdfRenderScale(for box: CGSize, base: CGFloat = 3, maxPixels: CGFloat = 40_000_000) -> CGFloat? {
        guard box.width.isFinite, box.height.isFinite, box.width >= 1, box.height >= 1 else { return nil }
        let pixels = box.width * base * box.height * base
        let scale = pixels > maxPixels ? base * (maxPixels / pixels).squareRoot() : base
        // at least a few pixels per module are needed for a QR code to be read
        return scale >= 0.5 ? scale : nil
    }

    private static func image(from data: Data, isPDF: Bool) -> CGImage? {
        if isPDF {
            guard let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
            let box = page.bounds(for: .mediaBox)
            guard let scale = pdfRenderScale(for: box.size) else { return nil }
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

    static func qrPayloads(_ cg: CGImage) async -> [String] {
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
