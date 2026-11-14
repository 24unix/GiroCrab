import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Text that the copy menus (account header, sidebar, holdings) put on the
/// clipboard. Platform-independent: runs on macOS and the iOS Simulator.
@MainActor
final class ClipboardCopyTests: XCTestCase {
    private func holding(name: String = "MSCI World ETF", isin: String = "IE00B4L5Y983", wkn: String = "A0RPWH") -> Holding {
        Holding(isin: isin, wkn: wkn, name: name, quantity: 12.5, currentPriceCents: 10_050, purchasePriceCents: 9_000, valueCents: 125_625)
    }

    private func account(owner: String, bank: String, iban: String) -> Account {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        var a = model.allAccounts[0]
        a.owner = owner
        a.bankName = bank
        a.iban = iban
        return a
    }

    func testHoldingLineHasNameIsinQuantityPriceAndValue() {
        let line = DepotPositionsView.line(holding())
        let qty = 12.5.formatted(.number.precision(.fractionLength(0...4)))
        XCTAssertEqual(line, [
            "MSCI World ETF", "IE00B4L5Y983",
            "\(qty) × \(Money.format(10_050))", Money.format(125_625),
        ].joined(separator: " · "))
    }

    func testHoldingLineFallsBackToWknAndSkipsEmptyName() {
        let line = DepotPositionsView.line(holding(name: "", isin: ""))
        XCTAssertTrue(line.hasPrefix("A0RPWH · "))
        XCTAssertEqual(line.components(separatedBy: " · ").count, 3)
    }

    func testAllHoldingsAreOneLineEach() {
        let all = [holding(), holding(name: "Bond ETF", isin: "", wkn: "ABC123")]
        let lines = all.map(DepotPositionsView.line).joined(separator: "\n").components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("IE00B4L5Y983"))
        XCTAssertTrue(lines[1].hasPrefix("Bond ETF · ABC123"))
    }

    func testBankDetailsWithBicAndBank() {
        let a = account(owner: "Max Mustermann", bank: "Testbank", iban: "DE02120300000000202051")
        XCTAssertEqual(AccountCopyMenu(account: a).bankDetails(bic: "BYLADEM1001"),
                       "Name: Max Mustermann\nIBAN: DE02 1203 0000 0000 2020 51\nBIC: BYLADEM1001 (Testbank)")
    }

    func testBankDetailsWithoutBicUsesBankName() {
        let a = account(owner: "", bank: "Testbank", iban: "DE02120300000000202051")
        XCTAssertEqual(AccountCopyMenu(account: a).bankDetails(bic: nil), "IBAN: DE02 1203 0000 0000 2020 51\nBank: Testbank")
    }

    func testBankDetailsWithoutBankOrBic() {
        let a = account(owner: "Max", bank: "", iban: "DE02120300000000202051")
        XCTAssertEqual(AccountCopyMenu(account: a).bankDetails(bic: nil), "Name: Max\nIBAN: DE02 1203 0000 0000 2020 51")
        XCTAssertEqual(AccountCopyMenu(account: a).bankDetails(bic: "X"), "Name: Max\nIBAN: DE02 1203 0000 0000 2020 51\nBIC: X")
    }
}
