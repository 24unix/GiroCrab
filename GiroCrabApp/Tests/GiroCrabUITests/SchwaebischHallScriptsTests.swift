import XCTest
@testable import GiroCrabUI

/// The browser scripts throw fixed codes; only those become messages (#290).
final class SchwaebischHallScriptsTests: XCTestCase {
    func testCodesBecomeFixedMessages() {
        let m = SchwaebischHallScripts.errorMessage(for:)
        XCTAssertTrue(m("Error: bsh:session").contains("Bitte erneut anmelden"))
        XCTAssertTrue(m("bsh:timeout").contains("antwortet nicht"))
        XCTAssertTrue(m("Error: bsh:too-large").contains("25 MB"))
        XCTAssertTrue(m("bsh:not-pdf").contains("kein PDF"))
        XCTAssertTrue(m("Error: bsh:http:503").contains("HTTP 503"))
    }

    func testOtherTextsAreNeverShown() {
        let unreadable = SchwaebischHallScripts.errorMessage(for: nil)
        XCTAssertTrue(unreadable.contains("nicht gelesen werden"))
        for text in ["Load failed", "Unexpected token '<', \"<html>Max Muster\"… is not valid JSON",
                     "bsh:", "bsh:unknown-code", "bsh:http:99999"] {
            let message = SchwaebischHallScripts.errorMessage(for: text)
            XCTAssertFalse(message.contains("Muster"), text)
            XCTAssertFalse(message.contains("Load failed"), text)
        }
        XCTAssertEqual(SchwaebischHallScripts.errorMessage(for: "Load failed"), unreadable)
        XCTAssertEqual(SchwaebischHallScripts.errorMessage(for: "bsh:unknown-code"), unreadable)
    }
}
