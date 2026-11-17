import Compression
import XCTest
@testable import GiroCrabUI

/// Bounds for crafted invoice PDFs.
final class PaymentParserLimitsTests: XCTestCase {
    /// zlib container (2-byte header) around raw deflate of `bytes`.
    private func zlib(_ bytes: [UInt8]) -> Data {
        var out = [UInt8](repeating: 0, count: bytes.count + 1024)
        let n = compression_encode_buffer(&out, out.count, bytes, bytes.count, nil, COMPRESSION_ZLIB)
        return Data([0x78, 0x9C]) + Data(out[0..<n])
    }

    func testNormalStreamsAreInflated() throws {
        let text = Array("<rsm:CrossIndustryInvoice>x</rsm:CrossIndustryInvoice>".utf8)
        let out = try XCTUnwrap(PaymentParser.inflate(zlib(text)))
        XCTAssertEqual(Array(out), text)
    }

    func testAStreamPastTheLimitIsRefused() {
        let bomb = zlib([UInt8](repeating: 0x41, count: 4 * 1024 * 1024))
        XCTAssertNotNil(PaymentParser.inflate(bomb, limit: 8 * 1024 * 1024))
        XCTAssertNil(PaymentParser.inflate(bomb, limit: 1024 * 1024), "never grows past the limit")
    }

    func testGarbageDoesNotLoopOrGrow() {
        XCTAssertNil(PaymentParser.inflate(Data([0x78, 0x9C, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]), limit: 1024 * 1024))
    }

    func testPageRenderScaleIsBounded() throws {
        XCTAssertEqual(PaymentParser.pdfRenderScale(for: CGSize(width: 595, height: 842)), 3)
        let big = try XCTUnwrap(PaymentParser.pdfRenderScale(for: CGSize(width: 10_000, height: 10_000)))
        XCTAssertLessThanOrEqual(10_000 * big * 10_000 * big, 40_000_001)
        XCTAssertNil(PaymentParser.pdfRenderScale(for: CGSize(width: 200_000, height: 200_000)), "unusably small scale")
        XCTAssertNil(PaymentParser.pdfRenderScale(for: .zero))
        XCTAssertNil(PaymentParser.pdfRenderScale(for: CGSize(width: CGFloat.infinity, height: 100)))
    }
}
