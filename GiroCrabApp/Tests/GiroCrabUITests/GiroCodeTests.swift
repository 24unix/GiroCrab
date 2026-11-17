import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// EPC QR ("GiroCode") for read-only accounts such as C24 via Enable Banking.
final class GiroCodeTests: XCTestCase {
    func testPayloadFollowsEPC069() throws {
        let p = try XCTUnwrap(GiroCode.payload(
            name: "Stadtwerke Kassel", iban: "de02 1203 0000 0000 2020 51", bic: "byladem1001",
            amountCents: 12_345, purpose: "Abschlag\nNovember"))
        XCTAssertEqual(p, """
            BCD
            002
            1
            SCT
            BYLADEM1001
            Stadtwerke Kassel
            DE02120300000000202051
            EUR123.45


            Abschlag November
            """)
    }

    /// `pixelsPerModule` pixels per module of the core's matrix (quiet zone included).
    func testImageMatchesCoreMatrix() throws {
        let payload = try XCTUnwrap(GiroCode.payload(name: "A", iban: "DE02120300000000202051", amountCents: 100, purpose: ""))
        let m = try XCTUnwrap(girocodeMatrix(payload: payload))
        XCTAssertEqual(try XCTUnwrap(GiroCode.image(for: payload, pixelsPerModule: 1)).width, Int(m.width))
        let cg = try XCTUnwrap(GiroCode.image(for: payload))
        XCTAssertEqual(cg.width, Int(m.width) * GiroCode.pixelsPerModule)
        XCTAssertEqual(cg.height, Int(m.width) * GiroCode.pixelsPerModule)
    }

    /// Generated image → QR scanner → GiroCrab's own GiroCode parser.
    func testImageRoundTrip() async throws {
        let payload = try XCTUnwrap(GiroCode.payload(
            name: "Müller & Söhne GmbH", iban: "DE02120300000000202051",
            amountCents: 1_999_99, purpose: "Rechnung 2026-117 – Danke"))
        let decoded = await PaymentParser.qrPayloads(try XCTUnwrap(GiroCode.image(for: payload)))
        XCTAssertEqual(decoded.first, payload)
        let parsed = try XCTUnwrap(PaymentParser.parseEPC(payload))
        XCTAssertEqual(parsed.name, "Müller & Söhne GmbH")
        XCTAssertEqual(parsed.iban, "DE02120300000000202051")
        XCTAssertEqual(parsed.purpose, "Rechnung 2026-117 – Danke")
        XCTAssertEqual(try parseAmountToCents(text: try XCTUnwrap(parsed.amountText)), 1_999_99)
    }

    func testPNGEncodesTheCode() throws {
        let payload = try XCTUnwrap(GiroCode.payload(name: "A", iban: "DE02120300000000202051", amountCents: 100, purpose: ""))
        let png = try XCTUnwrap(GiroCode.png(for: payload))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}

/// The Swift wrappers map the core's `PaymentDetails` into the transfer form's fields.
final class PaymentParserTests: XCTestCase {
    func testParseTextMapsCoreResult() {
        let p = PaymentParser.parseText("""
            Empfänger: Stadtwerke Kassel
            IBAN: DE02 1203 0000 0000 2020 51
            BIC: BYLADEM1001
            Betrag: 1.234,50 EUR
            Verwendungszweck: Abschlag November
            """)
        XCTAssertEqual(p.name, "Stadtwerke Kassel")
        XCTAssertEqual(p.iban, "DE02120300000000202051")
        XCTAssertEqual(p.bic, "BYLADEM1001")
        XCTAssertEqual(p.amountText, Money.plain(123_450))
        XCTAssertEqual(p.purpose, "Abschlag November")

        var d = TransferDraft()
        p.apply(to: &d)
        XCTAssertEqual(d.iban, "DE02 1203 0000 0000 2020 51", "IBAN is grouped in the form")
        XCTAssertEqual(d.amountText, Money.plain(123_450))
    }

    func testParseEPC() throws {
        let p = try XCTUnwrap(PaymentParser.parseEPC(
            "BCD\n002\n1\nSCT\nBYLADEM1001\nStadtwerke Kassel\nDE02120300000000202051\nEUR12.30\n\n\nAbschlag"))
        XCTAssertEqual(p, ParsedPayment(name: "Stadtwerke Kassel", iban: "DE02120300000000202051", bic: "BYLADEM1001",
                                        amountText: Money.plain(1_230), purpose: "Abschlag"))
        XCTAssertNil(PaymentParser.parseEPC("hello"))
    }

    func testNormalizeAmount() {
        XCTAssertEqual(PaymentParser.normalizeAmount("1.234,56"), Money.plain(123_456))
        XCTAssertNil(PaymentParser.normalizeAmount("abc"))
    }
}
