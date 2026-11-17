import XCTest
@testable import GiroCrabUI

final class EquatePlusDocumentFailuresTests: XCTestCase {
    func testASingleBrokenDocumentDoesNotStopTheRun() {
        var f = EquatePlusDocumentFailures()
        for _ in 0..<(EquatePlusDocumentFailures.limit - 1) {
            XCTAssertFalse(f.failed(reason: "HTTP 404 · Test", sessionLost: false))
        }
        f.succeeded()
        // a success resets the run of failures
        for _ in 0..<(EquatePlusDocumentFailures.limit - 1) {
            XCTAssertFalse(f.failed(reason: "HTTP 404 · Test", sessionLost: false))
        }
    }

    func testALongRunOfFailuresStops() {
        var f = EquatePlusDocumentFailures()
        var stopped = false
        for _ in 0..<EquatePlusDocumentFailures.limit { stopped = f.failed(reason: "kein PDF · Test", sessionLost: false) }
        XCTAssertTrue(stopped)
    }

    func testALostSessionStopsAtOnce() {
        var f = EquatePlusDocumentFailures()
        XCTAssertTrue(f.failed(reason: "HTTP 403 · Test", sessionLost: true))
    }

    func testSummaryNamesTheMostFrequentReasons() {
        var f = EquatePlusDocumentFailures()
        _ = f.failed(reason: "HTTP 404 · A", sessionLost: false)
        _ = f.failed(reason: "HTTP 404 · A", sessionLost: false)
        _ = f.failed(reason: "kein PDF · B", sessionLost: false)
        XCTAssertEqual(f.summary, "HTTP 404 · A: 2, kein PDF · B: 1")
    }

    func testReasonFromThePageScriptMessage() {
        func error(_ text: String) -> NSError { NSError(domain: "WKErrorDomain", code: 4, userInfo: ["WKJavaScriptExceptionMessage": text]) }
        XCTAssertEqual(EquatePlusDocumentFailures.reason(for: error("EquatePlus: Dokument nicht abrufbar (HTTP 404).")).reason, "HTTP 404")
        XCTAssertTrue(EquatePlusDocumentFailures.reason(for: error("EquatePlus: Dokument nicht abrufbar (HTTP 403).")).sessionLost)
        XCTAssertFalse(EquatePlusDocumentFailures.reason(for: error("EquatePlus: Dokument nicht abrufbar (HTTP 500).")).sessionLost)
        XCTAssertTrue(EquatePlusDocumentFailures.reason(for: error("EquatePlus: Bitte erneut anmelden.")).sessionLost)
        XCTAssertFalse(EquatePlusDocumentFailures.reason(for: error("EquatePlus: Der Download ist kein PDF.")).sessionLost)
        XCTAssertEqual(EquatePlusDocumentFailures.reason(for: error("EquatePlus: Der Download ist kein PDF (text/html, 4568 B).")).reason,
                       "kein PDF (text/html, 4568 B)")
        // raw text never reaches the user
        XCTAssertFalse(EquatePlusDocumentFailures.reason(for: error("https://x/?csrfpId=secret")).reason.contains("secret"))
    }
}
