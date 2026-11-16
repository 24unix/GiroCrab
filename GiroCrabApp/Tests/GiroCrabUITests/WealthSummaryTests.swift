import XCTest
import GiroCrabCore
@testable import GiroCrabUI

@MainActor
final class WealthSummaryTests: XCTestCase {
    func testDemoVaultSplitsCashAssetsAndLiabilities() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        let s = WealthSummary(accounts: model.allAccounts)
        XCTAssertEqual(s.netCents, s.cashCents + s.assetsCents + s.creditCents + s.liabilitiesCents)
        let included = s.cash + s.depots + s.liabilities
        XCTAssertTrue(included.allSatisfy { $0.archivedUnix == nil && $0.inTotal && $0.currency == "EUR" })
        XCTAssertTrue(s.cash.allSatisfy { [.checking, .savings, .cash, .paymentService].contains($0.kind) })
        XCTAssertTrue(s.depots.allSatisfy { $0.kind == .brokerage })
        XCTAssertTrue(s.liabilities.allSatisfy { $0.kind == .creditCard || $0.kind == .loan })
    }

    func testPositionsAreSummedAcrossDepotsByIsin() {
        func h(_ isin: String, _ q: Double, _ v: Int64) -> Holding {
            Holding(isin: isin, wkn: "", name: isin, quantity: q, currentPriceCents: 0, purchasePriceCents: 0, valueCents: v)
        }
        let p = WealthPosition.aggregate([[h("A", 1, 100), h("B", 2, 600)], [h("A", 3, 400)]])
        XCTAssertEqual(p.map(\.isin), ["B", "A"])
        XCTAssertEqual(p.first { $0.isin == "A" }?.quantity, 4)
        XCTAssertEqual(p.first { $0.isin == "A" }?.valueCents, 500)
    }

    func testNetWorthCanExcludeLiabilities() {
        var s = WealthSummary()
        s.buckets[.cash] = []
        XCTAssertEqual(s.netCents(includingLiabilities: false), s.cashCents + s.assetsCents + s.creditCents)
        XCTAssertEqual(s.netCents(includingLiabilities: true), s.netCents)
    }

    func testDayChangeAndGainAreSummedOnlyWhereReported() {
        func h(_ v: Int64, prev: Int64?, gain: Int64?) -> Holding {
            Holding(isin: "A", wkn: "", name: "A", quantity: 1, currentPriceCents: 0, purchasePriceCents: 0, valueCents: v,
                    prevDayPriceCents: nil, prevDayValueCents: prev, profitLossPurchaseCents: gain,
                    profitLossPurchaseRel: nil, profitLossPrevDayCents: nil, profitLossPrevDayRel: nil, custodyType: "")
        }
        let p = WealthPosition.aggregate([[h(1000, prev: 900, gain: 50)], [h(500, prev: nil, gain: nil)]])
        XCTAssertEqual(p.first?.dayChangeCents, 100) // only the depot that reports the previous day
        XCTAssertEqual(p.first?.gainCents, 50)
        XCTAssertNil(WealthPosition.aggregate([[h(10, prev: nil, gain: nil)]]).first?.dayChangeCents)
    }

    func testIncomeSumsLastYearOnlyAndCountsTradeCosts() {
        func t(_ d: SecurityDirection, _ date: String, value: Int64, fees: Int64 = 0, taxes: Int64 = 0, cur: String = "EUR") -> SecurityTransaction {
            SecurityTransaction(id: 0, accountId: 1, externalId: UUID().uuidString, bookingDate: date, settlementDate: "",
                                isin: "", wkn: "", name: "", direction: d, quantity: 0, priceCents: 0, currency: cur,
                                valueCents: value, feesCents: fees, taxesCents: taxes, accruedInterestCents: 0,
                                fxRate: nil, bookingText: "", cashTransactionId: nil)
        }
        let r = WealthIncome.make([
            t(.dividend, "2026-06-01", value: 4000),
            t(.dividend, "2025-01-01", value: 9999), // older than a year
            t(.fee, "2026-05-01", value: -1250),
            t(.buy, "2026-04-01", value: 10000, fees: 100),
            t(.tax, "2026-03-01", value: 500),
            t(.dividend, "2026-02-01", value: 700, cur: "USD"), // foreign currency is skipped
        ], since: "2025-11-14")
        XCTAssertEqual(r, WealthIncome(dividendsCents: 4000, feesCents: 1350, taxesCents: 500))
        XCTAssertTrue(WealthIncome.make([], since: "2025-11-14").isEmpty)
    }

    func testTangibleAccountsAreNotSecurities() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let tangible = Set(model.allAccounts.map(\.id).filter { model.isTangible($0) })
        XCTAssertFalse(tangible.isEmpty)
        let s = WealthSummary(accounts: model.allAccounts, tangibleIds: tangible)
        XCTAssertEqual(Set(s.tangibles.map(\.id)), tangible)
        XCTAssertTrue(s.depots.allSatisfy { !tangible.contains($0.id) })
        // moving an account between asset buckets does not change the total
        XCTAssertEqual(s.assetsCents, WealthSummary(accounts: model.allAccounts).assetsCents)
    }

    func testGainFallsBackToCostPriceWhenTheBankReportsNone() {
        // Quirion: cost price and quantity, no profit/loss field (value 1200 against 10 × 100 cost)
        let h = Holding(isin: "A", wkn: "", name: "A", quantity: 10, currentPriceCents: 120, purchasePriceCents: 100, valueCents: 1200)
        XCTAssertEqual(WealthPosition.aggregate([[h]]).first?.gainCents, 200)
        let none = Holding(isin: "B", wkn: "", name: "B", quantity: 10, currentPriceCents: 120, purchasePriceCents: 0, valueCents: 1200)
        XCTAssertNil(WealthPosition.aggregate([[none]]).first?.gainCents) // no cost price: stays unknown
    }

    func testPositiveCardBalanceStaysAnAssetWhenDebtsAreLeftOut() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        var card = try XCTUnwrap(model.allAccounts.first { $0.kind == .creditCard })
        card.balanceCents = 5_000
        let s = WealthSummary(accounts: [card])
        XCTAssertEqual(s.creditCents, 5_000)
        XCTAssertEqual(s.liabilitiesCents, 0)
        XCTAssertEqual(s.netCents(includingLiabilities: false), 5_000)
        XCTAssertEqual(s.netCents(includingLiabilities: true), 5_000)
        card.balanceCents = -3_000
        let debt = WealthSummary(accounts: [card])
        XCTAssertEqual(debt.netCents(includingLiabilities: true), -3_000)
        XCTAssertEqual(debt.netCents(includingLiabilities: false), 0)
    }

    // MARK: Sachwerte in the wealth view

    private func tangible(source: String = "manual", quantity: Double = 1, bought: Double? = nil, paid: Int64? = nil,
                          unitCost: Int64 = 0, unit: Int64 = 0, value: Int64, symbol: String = "", sold: Bool = false) -> AssetItem {
        AssetItem(id: 7, accountId: 3,
                  setup: AssetItemSetup(name: "Item", priceSource: source, weightGrams: 0, purityPermille: 1000,
                                        interpolation: .step, purchaseDate: "2024-01-01", quantity: bought ?? quantity,
                                        purchasePriceCents: paid, startValueCents: nil, note: "", symbol: symbol),
                  holding: Holding(isin: "", wkn: "", name: "Item", quantity: quantity, currentPriceCents: unit,
                                   purchasePriceCents: unitCost, valueCents: value),
                  quantities: [], values: [], valueDate: "2026-11-14", missingPriceDate: nil, sold: sold)
    }

    func testTangibleGainUsesTheTotalPaidWhileTheQuantityIsUnchanged() throws {
        // 3 pieces for 1000,00 in total: 333,33 per piece would lose a cent
        let item = tangible(quantity: 3, paid: 100_000, unitCost: 33_333, unit: 40_000, value: 120_000)
        let gain = try XCTUnwrap(WealthView.tangibleGain(item))
        XCTAssertEqual(gain.cents, 20_000)
        XCTAssertEqual(gain.percent, 20, accuracy: 0.0001)
        // one piece sold: the per-piece purchase price of the holding applies
        let rest = tangible(quantity: 2, bought: 3, paid: 100_000, unitCost: 33_333, unit: 40_000, value: 80_000)
        XCTAssertEqual(WealthView.tangibleGain(rest)?.cents, 80_000 - 66_666)
        // no purchase price at all: unknown, not zero
        XCTAssertNil(WealthView.tangibleGain(tangible(value: 5_000)))
        let loss = try XCTUnwrap(WealthView.tangibleGain(tangible(paid: 10_000, unitCost: 10_000, value: 7_500)))
        XCTAssertEqual(loss.cents, -2_500)
        XCTAssertEqual(loss.percent, -25, accuracy: 0.0001)
    }

    func testTangibleDayChangeOnlyForAutomaticPrices() {
        let gold = tangible(source: "XAU", quantity: 2, unit: 250_000, value: 500_000)
        XCTAssertEqual(WealthView.tangibleDayChange(gold, previousUnitCents: 248_000), 4_000)
        XCTAssertEqual(WealthView.tangibleDayChange(gold, previousUnitCents: 250_000), 0) // no new price
        XCTAssertNil(WealthView.tangibleDayChange(gold, previousUnitCents: nil))
        let car = tangible(unit: 1_500_000, value: 1_500_000)
        XCTAssertNil(WealthView.tangibleDayChange(car, previousUnitCents: 1_400_000))
    }

    func testTangibleRowCarriesSymbolGainAndItem() {
        let car = tangible(paid: 2_000_000, unitCost: 2_000_000, unit: 1_500_000, value: 1_500_000, symbol: "car.side.fill")
        let row = WealthView.TangibleRow(item: car)
        XCTAssertEqual(row.id, "i7")
        XCTAssertEqual(row.symbol, "car.side.fill")
        XCTAssertEqual(row.item.accountId, 3)
        XCTAssertEqual(row.gainCents, -500_000)
        XCTAssertNil(row.dayChangeCents)
        XCTAssertFalse(row.automatic)
        // without an own icon: the default of the price source
        XCTAssertEqual(WealthView.TangibleRow(item: tangible(source: "XAU", value: 1)).symbol,
                       AssetSymbols.defaultSymbol(source: "XAU"))
        XCTAssertEqual(WealthView.TangibleRow(item: tangible(value: 1)).symbol, AssetSymbols.defaultSymbol(source: "manual"))
    }

    func testGainTextIsSignedOnBothFigures() {
        XCTAssertTrue(WealthView.gainText(cents: 12_345, percent: 5.5).hasPrefix("+"))
        XCTAssertTrue(WealthView.gainText(cents: 12_345, percent: 5.5).contains("(+"))
        XCTAssertFalse(WealthView.gainText(cents: -12_345, percent: -5.5).contains("+"))
        XCTAssertFalse(WealthView.gainText(cents: 0, percent: 0).contains("+"))
    }

    func testDemoTangiblesOpenTheirAccountWithTheItemSelected() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        let account = try XCTUnwrap(model.allAccounts.first { model.isTangible($0.id) })
        let item = try XCTUnwrap(model.assetItems(account.id).first { !$0.sold })
        // the demo items carry a purchase price: the wealth rows show a gain
        XCTAssertNotNil(WealthView.TangibleRow(item: item).gainCents)
        model.interactiveSidebarSelection = .account(item.accountId)
        if model.assetStore.selected != item.id { model.selectAssetItem(item.id) }
        XCTAssertEqual(model.sidebarSelection, .account(account.id))
        XCTAssertEqual(model.selectedAssetItem(in: account.id)?.id, item.id)
        model.openAssetEditor(accountId: item.accountId, itemId: item.id)
        XCTAssertEqual(model.assetStore.editor?.itemId, item.id)
    }

    func testCoverageIsCountedBeforePositionsAreMerged() {
        func h(_ gain: Int64?, prev: Int64?) -> Holding {
            Holding(isin: "A", wkn: "", name: "A", quantity: 1, currentPriceCents: 0, purchasePriceCents: 0, valueCents: 100,
                    prevDayPriceCents: nil, prevDayValueCents: prev, profitLossPurchaseCents: gain,
                    profitLossPurchaseRel: nil, profitLossPrevDayCents: nil, profitLossPrevDayRel: nil, custodyType: "")
        }
        // the same ISIN in two depots: only the first one reports
        let p = WealthPosition.aggregate([[h(10, prev: 90)], [h(nil, prev: nil)]])
        XCTAssertEqual(p.count, 1)
        let c = WealthPosition.coverage(p)
        XCTAssertEqual(c.lines, 2)
        XCTAssertEqual(c.day, 1)
        XCTAssertEqual(c.gain, 1)
    }
}
