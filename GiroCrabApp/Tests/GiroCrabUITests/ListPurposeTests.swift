import XCTest
@testable import GiroCrabUI

/// Purpose behind the name in the booking list (#497).
final class ListPurposeTests: XCTestCase {
    private func text(_ purpose: String, clean: String = "", name: String = "Max Mustermann",
                      counterparty: String = "Max Mustermann", method: String = "Überweisung",
                      bookingText: String = "") -> String? {
        ListPurpose.text(purpose: purpose, cleanPurpose: clean, shownName: name, counterparty: counterparty,
                         paymentMethod: method, bookingText: bookingText)
    }

    func testShowsThePurposeOnOneLine() {
        XCTAssertEqual(text("Miete  November\n2026"), "Miete November 2026")
    }

    func testPrefersTheCleanedPurpose() {
        XCTAssertEqual(text("EREF+123 SVWZ+Rechnung 4711", clean: "Rechnung 4711"), "Rechnung 4711")
    }

    func testNothingWithoutPurpose() {
        XCTAssertNil(text(""))
        XCTAssertNil(text("  \n "))
        XCTAssertNil(text("-- //"))
    }

    func testHidesAPurposeThatRepeatsTheRow() {
        // card payment: the purpose is the merchant again
        XCTAssertNil(text("REWE-Markt GmbH", name: "REWE Markt GmbH", counterparty: "REWE MARKT GMBH"))
        XCTAssertNil(text("rewe", name: "REWE", counterparty: "REWE SAGT DANKE"))
        XCTAssertNil(text("Überweisung"))
        XCTAssertNil(text("Dauerauftrag", method: "", bookingText: "DAUERAUFTRAG"))
    }

    func testKeepsAPurposeThatAddsSomething() {
        XCTAssertEqual(text("REWE Filiale 4711 Kartenzahlung", name: "REWE", counterparty: "REWE"),
                       "REWE Filiale 4711 Kartenzahlung")
    }
}
