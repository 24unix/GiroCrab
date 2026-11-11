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

    func testLimitsAndInvalidInput() throws {
        let long = String(repeating: "x", count: 200)
        let p = try XCTUnwrap(GiroCode.payload(name: long, iban: "DE02120300000000202051", amountCents: 5, purpose: long))
        let lines = p.components(separatedBy: "\n")
        XCTAssertEqual(lines[5].count, GiroCode.maxName)
        XCTAssertEqual(lines[7], "EUR0.05")
        XCTAssertEqual(lines[10].count, GiroCode.maxRemittance)
        XCTAssertEqual(lines[4], "", "BIC is optional")
        XCTAssertNil(GiroCode.payload(name: "A", iban: "DE02", amountCents: 100, purpose: ""))
        XCTAssertNil(GiroCode.payload(name: " ", iban: "DE02120300000000202051", amountCents: 100, purpose: ""))
        XCTAssertNil(GiroCode.payload(name: "A", iban: "DE02120300000000202051", amountCents: 0, purpose: ""))
        XCTAssertNil(GiroCode.payload(name: "A", iban: "DE02120300000000202051", amountCents: GiroCode.maxCents + 1, purpose: ""))
    }

    /// Generated image → QR scanner → GiroCrab's own GiroCode parser.
    func testImageRoundTrip() async throws {
        let payload = try XCTUnwrap(GiroCode.payload(
            name: "Müller & Söhne GmbH", iban: "DE02120300000000202051",
            amountCents: 1_999_99, purpose: "Rechnung 2026-117 – Danke"))
        let cg = try XCTUnwrap(GiroCode.image(for: payload))
        // scale up so the detector sees clean modules
        let big = try XCTUnwrap(Self.scaled(cg, by: 8))
        let decoded = await PaymentParser.qrPayloads(big)
        XCTAssertEqual(decoded.first, payload)
        let parsed = try XCTUnwrap(PaymentParser.parseEPC(payload))
        XCTAssertEqual(parsed.name, "Müller & Söhne GmbH")
        XCTAssertEqual(parsed.iban, "DE02120300000000202051")
        XCTAssertEqual(parsed.purpose, "Rechnung 2026-117 – Danke")
        XCTAssertEqual(try parseAmountToCents(text: try XCTUnwrap(parsed.amountText)), 1_999_99)
    }

    private static func scaled(_ cg: CGImage, by f: Int) -> CGImage? {
        let w = cg.width * f, h = cg.height * f
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
