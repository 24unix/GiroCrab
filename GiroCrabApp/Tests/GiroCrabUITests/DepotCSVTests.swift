import XCTest
import GiroCrabCore
@testable import GiroCrabUI

final class DepotCSVTests: XCTestCase {
    func testAmountUsesDecimalCommaAndKeepsTheSign() {
        XCTAssertEqual(DepotCSV.amount(123_456), "1234,56")
        XCTAssertEqual(DepotCSV.amount(-5), "-0,05")
        XCTAssertEqual(DepotCSV.amount(0), "0,00")
    }

    func testQuantityKeepsFractionsWithoutTrailingZeros() {
        XCTAssertEqual(DepotCSV.quantity(4.652605), "4,652605")
        XCTAssertEqual(DepotCSV.quantity(30), "30")
        XCTAssertEqual(DepotCSV.quantity(0.5), "0,5")
    }

    func testFieldGuardsFormulasAndQuotesSeparators() {
        XCTAssertEqual(DepotCSV.field("=1+2"), "'=1+2")
        XCTAssertEqual(DepotCSV.field("a;b"), "\"a;b\"")
        XCTAssertEqual(DepotCSV.field("sag \"hallo\""), "\"sag \"\"hallo\"\"\"")
        XCTAssertEqual(DepotCSV.field("Zeile 1\nZeile 2"), "Zeile 1 Zeile 2")
        // numbers and ISINs are not text: no guard
        XCTAssertEqual(DepotCSV.field("-5", text: false), "-5")
    }

    func testTheYearFilterKeepsOnlyThatCalendarYear() {
        func t(_ id: Int64, _ date: String) -> SecurityTransaction {
            SecurityTransaction(id: id, accountId: 1, externalId: "e\(id)", bookingDate: date, settlementDate: "", isin: "", wkn: "",
                                name: "", direction: .buy, quantity: 1, priceCents: 0, currency: "EUR", valueCents: 0, feesCents: 0,
                                taxesCents: 0, accruedInterestCents: 0, fxRate: nil, bookingText: "", cashTransactionId: nil)
        }
        let items = [t(1, "2026-03-01"), t(2, "2025-12-31"), t(3, "2025-01-02"), t(4, "")]
        XCTAssertEqual(DepotActivities.inYear(items, 2025).map(\.id), [2, 3])
        XCTAssertEqual(DepotActivities.inYear(items, nil).count, 4)
        XCTAssertTrue(DepotActivities.inYear(items, 2019).isEmpty)
    }

    func testTheNoteDropsInternalEventCodes() {
        func note(_ text: String) -> String {
            DepotActivities.noteText(SecurityTransaction(id: 1, accountId: 1, externalId: "e", bookingDate: "2026-01-01", settlementDate: "",
                isin: "", wkn: "", name: "", direction: .buy, quantity: 1, priceCents: 0, currency: "EUR", valueCents: 0, feesCents: 0,
                taxesCents: 0, accruedInterestCents: 0, fxRate: nil, bookingText: text, cashTransactionId: nil))
        }
        XCTAssertEqual(note("bardividende ssp_corporate_action_cash"), "Bardividende")
        XCTAssertEqual(note("sparplan ausgeführt trading_savingsplan_executed"), "Sparplan ausgeführt")
        XCTAssertEqual(note("Sparplan ausgeführt"), "Sparplan ausgeführt")
        XCTAssertEqual(note("ssp_only_code"), "")
        XCTAssertEqual(note(""), "")
    }

    func testFilenameStartsWithTheAccountNameAndDropsForbiddenCharacters() {
        let day = Date(timeIntervalSince1970: 1_795_000_000)   // 2026-11-18 (UTC and local time agree on the day)
        XCTAssertEqual(DepotCSV.filename(account: "TR Depot", kind: "Positionen", date: day), "TR-Depot_Positionen_2026-11-18")
        XCTAssertEqual(DepotCSV.filename(account: "A/B: C", kind: "Aktivitaeten", year: 2025, date: day), "A-B-C_Aktivitaeten_2025_2026-11-18")
        XCTAssertEqual(DepotCSV.filename(account: "  ", kind: "Positionen", date: day), "Depot_Positionen_2026-11-18")
    }

    func testActivitiesHaveBomHeaderAndOneRowEach() {
        let t = SecurityTransaction(id: 1, accountId: 1, externalId: "e1", bookingDate: "2026-11-16", settlementDate: "",
                                    isin: "CA3038971022", wkn: "", name: "Fairfax India", direction: .buy, quantity: 4.652605,
                                    priceCents: 1612, currency: "EUR", valueCents: 7500, feesCents: 0, taxesCents: 0,
                                    accruedInterestCents: 0, fxRate: nil, bookingText: "sparplan", cashTransactionId: nil)
        let csv = DepotCSV.activities([t], currency: "EUR")
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"))
        let lines = csv.split(separator: "\r\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasPrefix("2026-11-16;Fairfax India;CA3038971022;;"))
        XCTAssertTrue(lines[1].contains(";4,652605;16,12;75,00;0,00;0,00;EUR;sparplan"))
    }

    private func position(_ h: Holding, _ cls: AssetClass) -> DepotPosition {
        let asset = ClassifiedAsset(holding: h, classification: AssetClassification(
            securityKey: h.isin, assetClass: cls, assetClassSource: .rule, instrument: .unclassified, instrumentSource: .unknown),
            assetItemId: nil)
        return DepotPosition.make([asset])[0]
    }

    /// A bond quotes a percentage of the nominal amount: the file says so instead of a money price.
    func testPositionsCarryTheUnitsOfQuantityAndPrice() throws {
        // nominal 10.000 at 98,50 %: worth 9.850,00 €
        let bond = Holding(isin: "DE0001", wkn: "", name: "Bund 2030", quantity: 10_000, currentPriceCents: 9_850,
                           purchasePriceCents: 9_700, valueCents: 985_000, prevDayValueCents: nil, profitLossPurchaseCents: nil)
        let share = Holding(isin: "US0001", wkn: "", name: "Apple", quantity: 2, currentPriceCents: 17_000,
                            purchasePriceCents: 15_000, valueCents: 34_000, prevDayValueCents: nil, profitLossPurchaseCents: nil,
                            currency: "USD", nativePriceCents: 20_000, nativePurchasePriceCents: 18_000, nativeValueCents: 40_000)
        let plain = Holding(isin: "IE0001", wkn: "", name: "ETF", quantity: 3, currentPriceCents: 10_000,
                            purchasePriceCents: 8_000, valueCents: 30_000, prevDayValueCents: nil, profitLossPurchaseCents: nil)
        let items = [position(bond, .bond), position(share, .equity), position(plain, .equity)]
        XCTAssertEqual(items[0].basis, .percentOfNominal)
        let csv = DepotCSV.positions(items, currency: "EUR")
        let lines = csv.split(separator: "\r\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].contains("Mengeneinheit") && lines[0].contains("Kurseinheit"))
        // bond: nominal, prices in percent
        XCTAssertTrue(lines[1].contains(";10000;Nominal;97,00;98,50;%;9850,00;"), lines[1])
        // a position with its own currency: the price in that currency, the value in the account's
        XCTAssertTrue(lines[2].contains(";2;Stück;180,00;200,00;USD;340,00;"), lines[2])
        XCTAssertTrue(lines[3].contains(";3;Stück;80,00;100,00;EUR;300,00;"), lines[3])
    }
}
