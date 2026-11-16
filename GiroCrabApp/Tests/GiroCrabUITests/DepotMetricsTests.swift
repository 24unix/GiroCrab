import XCTest
import SwiftUI
import GiroCrabCore
@testable import GiroCrabUI

@MainActor
final class DepotMetricsTests: XCTestCase {
    private func holding(_ name: String, qty: Double = 10, price: Int64 = 10_000, cost: Int64 = 8_000,
                         prevValue: Int64? = nil, pl: Int64? = nil) -> Holding {
        Holding(isin: "ISIN-\(name)", wkn: "", name: name, quantity: qty, currentPriceCents: price,
                purchasePriceCents: cost, valueCents: Int64(qty * Double(price)), prevDayValueCents: prevValue,
                profitLossPurchaseCents: pl)
    }

    private func asset(_ h: Holding, _ cls: AssetClass = .equity) -> ClassifiedAsset {
        ClassifiedAsset(holding: h, classification: AssetClassification(
            securityKey: h.isin, assetClass: cls, assetClassSource: .rule, instrument: .unclassified, instrumentSource: .unknown),
            assetItemId: nil)
    }

    private func tx(_ id: Int64, _ dir: SecurityDirection, value: Int64 = 0, fees: Int64 = 0, taxes: Int64 = 0,
                    date: String = "2026-03-01", currency: String = "EUR", account: Int64 = 1, name: String = "Test ETF") -> SecurityTransaction {
        SecurityTransaction(id: id, accountId: account, externalId: "e\(id)", bookingDate: date, settlementDate: "", isin: "IE0001",
                            wkn: "A0001", name: name, direction: dir, quantity: 1, priceCents: value, currency: currency,
                            valueCents: value, feesCents: fees, taxesCents: taxes, accruedInterestCents: 0, fxRate: nil,
                            bookingText: "", cashTransactionId: nil)
    }

    // MARK: P&L

    func testGainPercentIsSumOverCostNotAverageOfPercentages() throws {
        // A: cost 1.000, value 2.000 (+100 %), B: cost 9.000, value 10.000 (+11,1 %): average would be 55,6 %
        let a = holding("A", qty: 10, price: 20_000, cost: 10_000)
        let b = holding("B", qty: 10, price: 100_000, cost: 90_000)
        let f = try XCTUnwrap(DepotMetrics.unrealized([asset(a), asset(b)]))
        XCTAssertEqual(f.amountCents, 100_000 + 100_000)
        XCTAssertEqual(try XCTUnwrap(f.percent), 20.0, accuracy: 0.0001) // 2.000 / 10.000
    }

    func testMissingCostBasisIsNotZeroAndCoverageIsReported() throws {
        let known = holding("K", cost: 8_000)
        let unknown = holding("U", cost: 0)
        let f = try XCTUnwrap(DepotMetrics.unrealized([asset(known), asset(unknown)]))
        XCTAssertEqual(f.covered, 1)
        XCTAssertEqual(f.total, 2)
        XCTAssertTrue(f.isPartial)
        XCTAssertNil(DepotMetrics.unrealized([asset(unknown)]), "no basis at all: not available, not 0")
        XCTAssertNil(DepotMetrics.unrealized([ClassifiedAsset]()))
        XCTAssertNil(DepotMetrics.unrealized([HoldingFigures.Gain?]()))
    }

    func testBankReportedGainWinsOverCalculation() throws {
        let h = holding("R", qty: 10, price: 10_000, cost: 5_000, pl: 123)
        let f = try XCTUnwrap(DepotMetrics.unrealized([asset(h)]))
        XCTAssertEqual(f.amountCents, 123)
        XCTAssertEqual(f.calculated, 0)
        XCTAssertEqual(f.baseCents, 100_000 - 123)
    }

    func testBondQuotedInPercentUsesNominalForCost() throws {
        // nominal 10.000 €, price 98 % -> value 9.800 €, cost 95 % -> 9.500 €
        var bond = Holding(isin: "DE0001", wkn: "", name: "Anleihe", quantity: 10_000, currentPriceCents: 98_00,
                           purchasePriceCents: 95_00, valueCents: 9_800_00)
        XCTAssertEqual(HoldingFigures.priceBasis(bond, isBond: true), .percentOfNominal)
        XCTAssertEqual(HoldingFigures.gain(bond, basis: .percentOfNominal)?.cents, 300_00)
        // not recognised as a bond: no invented figure
        XCTAssertEqual(HoldingFigures.priceBasis(bond, isBond: false), .unknown)
        XCTAssertNil(HoldingFigures.gain(bond, basis: .unknown))
        bond.valueCents = 0
        XCTAssertEqual(HoldingFigures.priceBasis(bond, isBond: true), .unknown)
    }

    func testForeignCurrencyPriceWithoutMatchingValueGivesNoCalculatedGain() {
        // price in USD, value in EUR: quantity × price does not match, so no gain is derived
        let h = Holding(isin: "US1", wkn: "", name: "US", quantity: 10, currentPriceCents: 21_000, purchasePriceCents: 16_000, valueCents: 180_000)
        XCTAssertEqual(HoldingFigures.priceBasis(h, isBond: false), .unknown)
        XCTAssertNil(DepotMetrics.unrealized([asset(h)]))
    }

    // MARK: day change

    func testDayChangeOnlyFromPreviousDayData() throws {
        let withPrev = holding("P", qty: 10, price: 10_000, prevValue: 99_000)   // value 100.000
        let without = holding("N")
        let boughtToday = holding("T", prevValue: 0)
        let f = try XCTUnwrap(DepotMetrics.dayChange([withPrev, without, boughtToday]))
        XCTAssertEqual(f.amountCents, 1_000)
        XCTAssertEqual(f.covered, 1)
        XCTAssertEqual(f.total, 3)
        XCTAssertEqual(try XCTUnwrap(f.percent), 1000.0 / 99_000.0 * 100, accuracy: 0.0001)
        XCTAssertNil(DepotMetrics.dayChange([without, boughtToday]))
    }

    func testDayChangeFromReportedPrevDayProfit() throws {
        var h = holding("D", qty: 10, price: 10_000)
        h.profitLossPrevDayCents = 500
        let d = try XCTUnwrap(HoldingFigures.dayChange(h))
        XCTAssertEqual(d.cents, 500)
        XCTAssertEqual(d.previousValueCents, 99_500)
    }

    // MARK: fees and taxes

    func testFeesAndTaxesAreNotCountedTwice() {
        let rows = [
            tx(1, .fee, value: 1_250),                    // own fee line
            tx(2, .fee, value: 1_000, fees: 1_000),       // fee line that repeats its own amount in the field
            tx(3, .tax, value: 400),                      // own tax line
            tx(4, .buy, value: 25_000, fees: 100, taxes: 5),
            tx(5, .dividend, value: 3_840, taxes: 1_012), // withholding tax embedded in the distribution
            tx(6, .fee, value: 0, fees: 700),             // fee line without value: its field counts
        ]
        let t = SecurityActivityTotals.make(rows, currency: "EUR", from: nil, to: nil)
        XCTAssertEqual(t.feesCents, 1_250 + 1_000 + 100 + 700)
        XCTAssertEqual(t.taxesCents, 400 + 5 + 1_012)
        XCTAssertEqual(t.distributionsCents, 3_840)
        XCTAssertEqual(t.distributionCount, 1)
    }

    func testOtherCurrenciesAreNotSummed() {
        let t = SecurityActivityTotals.make([
            tx(1, .dividend, value: 1_000),
            tx(2, .dividend, value: 5_000, currency: "USD"), // no reliable conversion
        ], currency: "EUR", from: nil, to: nil)
        XCTAssertEqual(t.distributionsCents, 1_000)
        XCTAssertEqual(t.otherCurrencyCount, 1)
        XCTAssertEqual(t.count, 1)
    }

    func testNoActivitiesMeansUnavailableNotZero() {
        XCTAssertTrue(SecurityActivityTotals.make([], currency: "EUR", from: nil, to: nil).isEmpty)
        // activities exist, but none in the period
        let t = SecurityActivityTotals.make([tx(1, .dividend, value: 100, date: "2025-01-01")], currency: "EUR", from: "2026-01-01", to: nil)
        XCTAssertTrue(t.isEmpty)
    }

    // MARK: depot and period filter

    func testActivitiesFilteredByDepotPeriodKindAndSearch() {
        let rows = [
            tx(1, .buy, value: 100, date: "2026-03-10", name: "iShares World"),
            tx(2, .dividend, value: 50, date: "2026-02-01", name: "iShares World"),
            tx(3, .buy, value: 70, date: "2026-03-12", account: 2, name: "iShares World"),  // other depot
            tx(4, .sell, value: 90, date: "2026-03-20", name: "Vanguard All-World"),
            tx(5, .buy, value: 10, fees: 5, date: "2025-12-31", name: "Old"),
        ]
        let march = DepotActivities.filtered(rows, accountId: 1, filter: .all, query: "", from: "2026-03-01", to: "2026-03-31")
        XCTAssertEqual(march.map(\.id), [1, 4])
        XCTAssertEqual(DepotActivities.filtered(rows, accountId: 1, filter: .buys, query: "", from: nil, to: nil).map(\.id), [1, 5])
        XCTAssertEqual(DepotActivities.filtered(rows, accountId: 1, filter: .distributions, query: "", from: nil, to: nil).map(\.id), [2])
        XCTAssertEqual(DepotActivities.filtered(rows, accountId: 1, filter: .costs, query: "", from: nil, to: nil).map(\.id), [5])
        XCTAssertEqual(DepotActivities.filtered(rows, accountId: 1, filter: .all, query: "vanguard", from: nil, to: nil).map(\.id), [4])
        XCTAssertEqual(DepotActivities.filtered(rows, accountId: 1, filter: .all, query: "ie0001", from: "2026-03-01", to: "2026-03-31").map(\.id), [1, 4], "ISIN search")
        XCTAssertEqual(DepotActivities.filtered(rows, accountId: 1, filter: .all, query: "a0001", from: nil, to: nil).count, 4, "WKN search")
    }

    func testActivitiesAreSecurityTransactionsOnly() {
        // The filter takes SecurityTransaction values and nothing else: cash bookings of the clearing
        // account cannot enter, and the link to them stays a plain id.
        var linked = tx(1, .buy, value: 100)
        linked.cashTransactionId = 4_711
        let shown = DepotActivities.filtered([linked], accountId: 1, filter: .all, query: "", from: nil, to: nil)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.first?.cashTransactionId, 4_711)
        let totals = SecurityActivityTotals.make(shown, currency: "EUR", from: nil, to: nil)
        XCTAssertEqual(totals.count, 1, "the buy counts once as an activity, not again for its cash booking")
        XCTAssertEqual(totals.costsCents, 0)
    }

    // MARK: shares, search, sort

    func testSharesUseWholeInventoryAndSearchDoesNotChangeThem() throws {
        let assets = [asset(holding("Alpha", qty: 1, price: 75_000)), asset(holding("Beta", qty: 1, price: 25_000))]
        let all = DepotPosition.make(assets)
        let found = DepotPosition.filtered(all, query: "beta")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(try XCTUnwrap(found[0].share), 0.25, accuracy: 0.0001)
        XCTAssertEqual(all.compactMap(\.share).reduce(0, +), 1.0, accuracy: 0.0001)
    }

    func testNoShareWithoutPositiveTotal() {
        XCTAssertNil(DepotMetrics.share(valueCents: 100, totalCents: 0))
        XCTAssertNil(DepotPosition.make([asset(holding("Z", qty: 0, price: 0))])[0].share)
    }

    func testDefaultSortIsValueDescendingAndMissingGainComesLast() {
        let assets = [
            asset(holding("Small", qty: 1, price: 10_000, cost: 9_000)),
            asset(holding("Big", qty: 1, price: 90_000, cost: 80_000)),
            asset(holding("NoCost", qty: 1, price: 50_000, cost: 0)),
        ]
        let all = DepotPosition.make(assets)
        XCTAssertEqual(DepotSort(), DepotSort(key: .value, ascending: false))
        XCTAssertEqual(DepotPosition.sorted(all, by: DepotSort()).map(\.displayName), ["Big", "NoCost", "Small"])
        XCTAssertEqual(DepotPosition.sorted(all, by: DepotSort(key: .gain, ascending: false)).map(\.displayName), ["Big", "Small", "NoCost"])
        XCTAssertEqual(DepotPosition.sorted(all, by: DepotSort(key: .gain, ascending: true)).map(\.displayName), ["Small", "Big", "NoCost"])
        XCTAssertEqual(DepotPosition.sorted(all, by: DepotSort(key: .name, ascending: true)).map(\.displayName), ["Big", "NoCost", "Small"])
        var s = DepotSort(); s.toggle(.value)
        XCTAssertTrue(s.ascending)
    }

    // MARK: value and composition

    func testDepotValueFlagsDifferenceAndNeverAddsCash() {
        let hs = [holding("A", qty: 1, price: 100_000), holding("B", qty: 1, price: 50_000)]
        XCTAssertNil(DepotValue.resolve(reportedCents: 150_000, holdings: hs).differenceCents)
        XCTAssertNil(DepotValue.resolve(reportedCents: 150_050, holdings: hs).differenceCents, "rounding tolerance")
        let off = DepotValue.resolve(reportedCents: 160_000, holdings: hs)
        XCTAssertEqual(off.cents, 160_000)
        XCTAssertEqual(off.differenceCents, 10_000)
        let none = DepotValue.resolve(reportedCents: 0, holdings: hs)
        XCTAssertEqual(none.source, .positionSum)
        XCTAssertEqual(none.cents, 150_000)
    }

    func testCompositionKeepsUnclassifiedInTheSum() {
        let assets = [
            asset(holding("A", qty: 1, price: 60_000), .equity),
            asset(holding("B", qty: 1, price: 30_000), .unclassified),
            asset(holding("C", qty: 1, price: 10_000), .bond),
        ]
        for mode in [DepotCompositionMode.assetClass, .instrument, .position] {
            XCTAssertEqual(DepotComposition.slices(assets, mode: mode).reduce(0) { $0 + $1.cents }, 100_000, "\(mode)")
        }
        let byClass = DepotComposition.slices(assets, mode: .assetClass)
        XCTAssertTrue(byClass.contains { $0.unclassified && $0.cents == 30_000 })
    }

    func testPositionCompositionFoldsTheTailIntoOneSlice() {
        let assets = (1...10).map { asset(holding("P\($0)", qty: 1, price: Int64($0) * 1_000)) }
        let slices = DepotComposition.slices(assets, mode: .position)
        XCTAssertEqual(slices.count, DepotComposition.maxPositionSlices + 1)
        XCTAssertEqual(slices.last?.count, 3)
        XCTAssertEqual(slices.reduce(0) { $0 + $1.cents }, 55_000)
    }

    // MARK: central depot detection

    func testDepotKindIsDecidedInOnePlace() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        func account(_ name: String) throws -> Account { try XCTUnwrap(model.allAccounts.first { $0.name == name }) }
        XCTAssertEqual(model.depotKind(of: try account("Welt-Depot ETF").id), .securities)
        XCTAssertEqual(model.depotKind(of: try account("Einzeltitel-Depot").id), .securities)
        XCTAssertEqual(model.depotKind(of: try account("Sachwerte").id), .tangible)
        XCTAssertNil(model.depotKind(of: try account("Musterbank Girokonto").id))
        model.sidebarSelection = .account(try account("Welt-Depot ETF").id)
        XCTAssertEqual(model.selectedSecuritiesDepot?.name, "Welt-Depot ETF")
        model.sidebarSelection = .account(try account("Sachwerte").id)
        XCTAssertNil(model.selectedSecuritiesDepot, "Sachwerte keep their own presentation")
        // a checking account is no depot because of its name
        model.sidebarSelection = .allAccounts
        XCTAssertEqual(model.presentation, .bookings)
    }

    func testDepotPeriodIgnoresTheSalaryCycle() {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        model.period = .sinceSalary
        XCTAssertNil(model.depotPeriodRange.0)
        XCTAssertEqual(model.depotPeriodTitle, Period.all.title)
    }

    // MARK: Sachwerte

    func testPresentationRoutesAccountsAndTangiblesIgnoreTheScopeShortcuts() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        func select(_ name: String) throws { model.sidebarSelection = .account(try XCTUnwrap(model.allAccounts.first { $0.name == name }).id) }
        let giro = try XCTUnwrap(model.allAccounts.first { $0.name == "Musterbank Girokonto" })
        let welt = try XCTUnwrap(model.allAccounts.first { $0.name == "Welt-Depot ETF" })
        let sach = try XCTUnwrap(model.allAccounts.first { $0.name == "Sachwerte" })
        try select("Musterbank Girokonto")
        XCTAssertEqual(model.presentation, .bookings)
        try select("Sachwerte")
        XCTAssertEqual(model.presentation, .tangible(sach.id))
        XCTAssertEqual(model.selectedTangibleAccount?.id, sach.id)
        XCTAssertNil(model.selectedSecuritiesDepot)
        try select("Welt-Depot ETF")
        XCTAssertEqual(model.presentation, .securities(welt.id))
        XCTAssertNil(model.selectedTangibleAccount)
        for other in [SidebarItem.allAccounts, .wealth, .newBookings] {
            model.sidebarSelection = other
            XCTAssertEqual(model.presentation, .bookings, "\(other)")
        }
        XCTAssertNotEqual(giro.id, welt.id)
        // booking scope untouched by ⌘1…⌘3 on Sachwerte; on a securities depot they switch the depot tab
        try select("Sachwerte")
        model.scope = .all
        model.applyScopeShortcut(index: 1, scope: BookingScope.ordered[1])
        XCTAssertEqual(model.scope, .all)
        try select("Welt-Depot ETF")
        model.applyScopeShortcut(index: 1, scope: BookingScope.ordered[1])
        XCTAssertEqual(model.depotTab, .activities)
        XCTAssertEqual(model.scope, .all)
        model.sidebarSelection = .allAccounts
        model.applyScopeShortcut(index: 1, scope: BookingScope.ordered[1])
        XCTAssertEqual(model.scope, BookingScope.ordered[1])
    }

    func testSachwertSearchMatchesNameAndClassification() {
        XCTAssertTrue(DepotMetrics.matches(query: "gold", fields: ["Goldkette 585", "Rohstoffe & Edelmetalle"]))
        XCTAssertTrue(DepotMetrics.matches(query: "edelmetalle kette", fields: ["Goldkette 585", "Rohstoffe & Edelmetalle"]))
        XCTAssertFalse(DepotMetrics.matches(query: "auto", fields: ["Goldkette 585", "Rohstoffe & Edelmetalle"]))
        XCTAssertTrue(DepotMetrics.matches(query: "  ", fields: ["x"]), "an empty query keeps everything")
    }

    func testSachwertCompositionGroupsByAssetClassAndLeavesSoldItemsOut() {
        let assets = [
            asset(holding("Haus", qty: 1, price: 495_000_00), .realEstate),
            asset(holding("Auto", qty: 1, price: 19_900_00), .unclassified),
            asset(holding("Gold", qty: 2, price: 3_500_00), .commodity),
            asset(holding("Verkauft", qty: 0, price: 0), .commodity),   // sold: no value, no slice
        ]
        let slices = DepotComposition.slices(assets, mode: .assetClass)
        XCTAssertEqual(slices.reduce(0) { $0 + $1.cents }, 495_000_00 + 19_900_00 + 7_000_00)
        XCTAssertEqual(Set(slices.map(\.id)), Set([AssetClass.realEstate.key, AssetClass.commodity.key, AssetClass.unclassified.key]))
        XCTAssertTrue(slices.first { $0.id == AssetClass.unclassified.key }?.unclassified ?? false)
    }

    // MARK: display rules

    func testOtherActivitiesNeverShowTheBankTextAsKind() {
        var t = tx(1, .other)
        t.bookingText = "Max Mustermann Privat"
        XCTAssertEqual(DepotActivities.kindTitle(t), String(localized: "Sonstige"))
        XCTAssertFalse(DepotActivities.kindTitle(t).contains("Mustermann"))
    }

    func testCostsAreShownPositiveWhileARefundKeepsItsMinus() {
        XCTAssertEqual(DepotActivities.feeCents(tx(1, .fee, value: 1_250)), 1_250)
        XCTAssertEqual(DepotActivities.feeCents(tx(2, .fee, value: -1_250)), 1_250, "own fee lines are costs whatever their sign")
        XCTAssertEqual(DepotActivities.feeCents(tx(3, .fee, value: 0, fees: 700)), 700)
        XCTAssertEqual(DepotActivities.taxCents(tx(4, .tax, value: 3_650)), 3_650)
        XCTAssertEqual(DepotActivities.feeCents(tx(5, .sell, value: 61_500, fees: 490)), 490)
        XCTAssertEqual(DepotActivities.taxCents(tx(6, .dividend, value: 7_050, taxes: 1_859)), 1_859)
        XCTAssertEqual(DepotActivities.feeCents(tx(7, .buy, value: 10_000, fees: -300)), -300, "a refund stays visible")
    }

    func testSignedAmountsUseTheDepotCurrency() {
        XCTAssertTrue(Money.signed(12_345, currency: "USD").hasPrefix("+"))
        XCTAssertNotEqual(Money.signed(12_345, currency: "USD"), Money.signed(12_345))
        XCTAssertTrue(Money.signed(-12_345, currency: "USD").contains("$") || Money.signed(-12_345, currency: "USD").contains("USD"))
        XCTAssertEqual(Money.signed(5_00), Money.signed(5_00, currency: "EUR"))
    }

    // MARK: composition displays

    private func positions(_ values: [Int64]) -> [ClassifiedAsset] {
        values.enumerated().map { i, v in asset(holding("P\(i)", qty: 1, price: v)) }
    }

    func testEveryFoldKeepsTheSumAndTheCountOfPositions() {
        let assets = positions((1...30).map { Int64($0) * 1_000 })
        let all = DepotComposition.groups(assets, mode: .position)
        XCTAssertEqual(all.count, 30)
        for keep in [DepotComposition.maxPositionSlices, DepotComposition.maxRankedSlices, DepotComposition.maxTiles] {
            let folded = DepotComposition.fold(all, keep: keep)
            XCTAssertEqual(folded.reduce(0) { $0 + $1.cents }, all.reduce(0) { $0 + $1.cents }, "keep \(keep)")
            XCTAssertEqual(folded.reduce(0) { $0 + $1.count }, 30, "keep \(keep): nothing lost, nothing counted twice")
            XCTAssertEqual(folded.count, keep + 1)
            XCTAssertTrue(folded.last?.isRest ?? false)
            XCTAssertEqual(folded.last?.count, 30 - keep)
        }
    }

    func testOneLeftoverSliceIsNoRest() {
        let all = DepotComposition.groups(positions([5_000, 4_000, 3_000]), mode: .position)
        XCTAssertEqual(DepotComposition.fold(all, keep: 2), all, "a rest of one position stays that position")
        XCTAssertEqual(DepotComposition.fold(all, keep: 5), all)
    }

    func testEmptyAndSingleInventories() {
        XCTAssertTrue(DepotComposition.groups([], mode: .position).isEmpty)
        XCTAssertTrue(DepotComposition.groups([], mode: .assetClass).isEmpty)
        let one = DepotComposition.groups(positions([12_300]), mode: .position)
        XCTAssertEqual(one.map(\.cents), [12_300])
        XCTAssertEqual(DepotComposition.fold(one, keep: 7), one)
    }

    func testZeroAndNegativeValuesAreExplainedNotDrawn() {
        let assets = [asset(holding("A", qty: 1, price: 9_000)), asset(holding("Null", qty: 0, price: 0)),
                      asset(Holding(isin: "X", wkn: "", name: "Negativ", quantity: 1, currentPriceCents: 1, purchasePriceCents: 1, valueCents: -500))]
        XCTAssertEqual(DepotComposition.excludedCount(assets), 2)
        let slices = DepotComposition.groups(assets, mode: .position)
        XCTAssertEqual(slices.map(\.cents), [9_000])
        XCTAssertTrue(slices.allSatisfy { $0.cents > 0 })
    }

    func testColoursAreDistinctPerInventoryAndStayTheSameInEveryDisplay() {
        let assets = positions((1...12).map { Int64($0) * 700 })
        let all = DepotComposition.groups(assets, mode: .position)
        // up to the palette size, no two positions of one view share a colour
        XCTAssertEqual(Set(all.map { "\($0.color)" }).count, all.count)
        let colourByID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, "\($0.color)") })
        // ring (7 + rest), ranked bars (10 + rest) and tiles (12): the same position has the same colour
        for keep in [7, 10, 12] {
            for slice in DepotComposition.fold(all, keep: keep) where !slice.isRest {
                XCTAssertEqual("\(slice.color)", colourByID[slice.id], "\(slice.id) at keep \(keep)")
            }
        }
        // neither value nor rank nor the order of the assets matters
        let reordered = DepotComposition.groups(assets.reversed(), mode: .position)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: reordered.map { ($0.id, "\($0.color)") }), colourByID)
        let revalued = DepotComposition.groups((1...12).map { asset(holding("P\($0 - 1)", qty: 1, price: Int64(13 - $0) * 900)) }, mode: .position)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: revalued.map { ($0.id, "\($0.color)") }), colourByID)
        // the start colour is a fixed function of the key
        XCTAssertEqual(DepotColors.startIndex("IE00B4L5Y983"), DepotColors.startIndex("IE00B4L5Y983"))
        XCTAssertTrue((0..<DepotColors.palette.count).contains(DepotColors.startIndex("DE0007236101")))
        // more positions than colours still get a colour each
        XCTAssertEqual(DepotColors.indices(for: (1...40).map { "K\($0)" }).count, 40)
    }

    func testARankingNeverDropsASlice() {
        for n in [9, 10, 11, 12, 13, 30] {
            let all = DepotComposition.groups(positions((1...n).map { Int64($0) * 1_000 }), mode: .position)
            let (shown, rest) = DepotComposition.ranked(all, keep: DepotComposition.maxRankedSlices)
            let listed = shown.reduce(0) { $0 + $1.count } + (rest?.count ?? 0)
            XCTAssertEqual(listed, n, "\(n) positions: every one is listed or in the rest")
            XCTAssertEqual(shown.reduce(0) { $0 + $1.cents } + (rest?.cents ?? 0), all.reduce(0) { $0 + $1.cents }, "\(n)")
            XCTAssertEqual(rest == nil, n <= DepotComposition.maxRankedSlices + 1, "\(n)")
        }
        // exactly eleven: all eleven are shown, no rest
        let eleven = DepotComposition.groups(positions((1...11).map { Int64($0) * 1_000 }), mode: .position)
        XCTAssertEqual(DepotComposition.ranked(eleven, keep: 10).shown.count, 11)
    }

    func testOwnItemsAreMarkedPersonalAndSecuritiesAreNot() {
        let security = asset(holding("Welt", qty: 1, price: 50_000))
        let item = ClassifiedAsset(holding: holding("Mein Haus", qty: 1, price: 495_000_00), classification: security.classification, assetItemId: 7)
        XCTAssertFalse(DepotPosition.make([security])[0].isOwnItem)
        XCTAssertTrue(DepotPosition.make([item])[0].isOwnItem)
        let slices = DepotComposition.groups([security, item], mode: .position)
        XCTAssertEqual(slices.first { $0.label == "Mein Haus" }?.personal, true)
        XCTAssertEqual(slices.first { $0.label == "Welt" }?.personal, false)
        XCTAssertTrue(DepotComposition.groups([item], mode: .assetClass).allSatisfy { !$0.personal }, "class names are labels, not personal")
    }

    func testClassAndInstrumentGroupsKeepTheirFixedColoursAndSumsEqualThePositionView() {
        let assets = [asset(holding("A", qty: 1, price: 60_000), .equity), asset(holding("B", qty: 1, price: 30_000), .bond),
                      asset(holding("C", qty: 1, price: 10_000), .unclassified)]
        let total = DepotComposition.groups(assets, mode: .position).reduce(0) { $0 + $1.cents }
        for mode in [DepotCompositionMode.assetClass, .instrument] {
            XCTAssertEqual(DepotComposition.groups(assets, mode: mode).reduce(0) { $0 + $1.cents }, total)
        }
        XCTAssertEqual(DepotComposition.groups(assets, mode: .assetClass).first { $0.id == AssetClass.equity.key }?.color,
                       WealthPalette.color(AssetClass.choices.firstIndex(of: .equity) ?? 0))
    }

    func testTreemapAreasAreProportionalAndFillTheRectangleWithoutOverlap() {
        let values: [Double] = [50, 25, 12, 8, 3, 2]
        let rect = CGRect(x: 0, y: 0, width: 600, height: 240)
        let rects = Treemap.layout(values, in: rect)
        XCTAssertEqual(rects.count, values.count)
        let area = rect.width * rect.height
        for (r, v) in zip(rects, values) {
            XCTAssertEqual(Double(r.width * r.height), v / 100 * Double(area), accuracy: 0.5)
            XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(r))
        }
        XCTAssertEqual(rects.reduce(0) { $0 + $1.width * $1.height }, area, accuracy: 1)
        for i in rects.indices { for j in rects.indices where j > i {
            let overlap = rects[i].intersection(rects[j])
            XCTAssertLessThan(overlap.isNull ? 0 : overlap.width * overlap.height, 0.5, "\(i) overlaps \(j)")
        } }
    }

    func testTreemapIgnoresZeroValuesAndDegenerateRectangles() {
        let rects = Treemap.layout([10, 0, 5, -3], in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(rects[1], .zero)
        XCTAssertEqual(rects[3], .zero)
        XCTAssertGreaterThan(rects[0].width * rects[0].height, rects[2].width * rects[2].height)
        XCTAssertEqual(Treemap.layout([], in: CGRect(x: 0, y: 0, width: 100, height: 100)), [])
        XCTAssertEqual(Treemap.layout([1, 2], in: .zero), [.zero, .zero])
        XCTAssertEqual(Treemap.layout([0, 0], in: CGRect(x: 0, y: 0, width: 50, height: 50)), [.zero, .zero])
    }

    // MARK: shared across depots and Sachwerte

    func testTheSameSecurityInSeveralDepotsIsOneRowAndOneSlice() throws {
        let a = holding("Welt", qty: 10, price: 10_000, cost: 8_000)       // 100.000, gain 20.000
        let b = holding("Welt", qty: 5, price: 10_000, cost: 9_000)        //  50.000, gain  5.000
        let c = holding("Andere", qty: 1, price: 50_000, cost: 40_000)     //  50.000, gain 10.000
        let assets = [asset(a), asset(b), asset(c)]
        let merged = DepotPosition.merged(DepotPosition.make(assets))
        XCTAssertEqual(merged.count, 2)
        let welt = try XCTUnwrap(merged.first { $0.displayName == "Welt" })
        XCTAssertEqual(welt.holding.quantity, 15)
        XCTAssertEqual(welt.holding.valueCents, 150_000)
        XCTAssertEqual(welt.gain?.cents, 25_000)
        XCTAssertEqual(welt.gain?.costCents, 125_000)
        XCTAssertEqual(try XCTUnwrap(welt.share), 0.75, accuracy: 0.0001, "share of the whole inventory")
        XCTAssertEqual(merged.compactMap(\.share).reduce(0, +), 1.0, accuracy: 0.0001)
        let slices = DepotComposition.groups(assets, mode: .position)
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(Set(slices.map(\.id)).count, 2, "no duplicate ids for a ForEach")
        XCTAssertEqual(slices.reduce(0) { $0 + $1.cents }, 200_000)
    }

    func testFiguresFromPositionGainsMatchTheDepotFigure() throws {
        let assets = [asset(holding("A", qty: 10, price: 20_000, cost: 10_000)), asset(holding("B", qty: 10, price: 100_000, cost: 90_000))]
        let fromAssets = try XCTUnwrap(DepotMetrics.unrealized(assets))
        let fromGains = try XCTUnwrap(DepotMetrics.unrealized(DepotPosition.make(assets).map(\.gain)))
        XCTAssertEqual(fromAssets.amountCents, fromGains.amountCents)
        XCTAssertEqual(fromAssets.baseCents, fromGains.baseCents)
    }

    func testSachwertTilesNeverInventMissingData() throws {
        let none = DepotKPIs.tangibles(valueCents: 0, count: 0, gains: [], days: [], automaticCount: 0, currency: "EUR")
        XCTAssertEqual(none.count, 4)
        XCTAssertNil(none[0].value)
        XCTAssertNil(none[1].value)
        XCTAssertNil(none[2].value)
        XCTAssertNil(none[3].value)
        // a house without purchase data, gold with: coverage is stated, the cost basis only counts what is known
        let gold = HoldingFigures.Gain(cents: 2_000, costCents: 8_000, reported: false)
        let tiles = DepotKPIs.tangibles(valueCents: 510_000, count: 2, gains: [nil, gold],
                                        days: [HoldingFigures.Day(cents: 100, previousValueCents: 9_900)], automaticCount: 1, currency: "EUR")
        XCTAssertNotNil(tiles[1].value)
        XCTAssertTrue(tiles[1].footnote.contains("1") && tiles[1].footnote.contains("2"))
        XCTAssertNotNil(tiles[0].value)
        XCTAssertNil(tiles[3].value) // no largest position given: nothing invented
        let big = DepotKPIs.tangibles(valueCents: 1_000, count: 2, gains: [nil, nil], days: [], automaticCount: 0,
                                      largest: ("Haus", 947), currency: "EUR")
        XCTAssertEqual(big[3].detail, "Haus")
        XCTAssertEqual(big[3].value, DepotFormat.percent(94.7, digits: 1))
        XCTAssertEqual(tiles[2].detail, DepotFormat.percent(100.0 / 9_900.0 * 100, signed: true))
    }

    func testPositionsWithoutAMarketPriceHideItAndMergeKeepsItOnlyWhenAllDo() {
        let house = asset(holding("Haus", qty: 1, price: 495_000_00))
        let gold = asset(holding("Gold", qty: 2, price: 3_500_00))
        let positions = DepotPosition.make([house, gold], hidesPrice: { $0.holding.name == "Haus" })
        XCTAssertEqual(positions.map(\.hidesPrice), [true, false])
        XCTAssertEqual(DepotPosition.make([house, gold]).map(\.hidesPrice), [false, false])
        let a = DepotPosition.make([house, house], hidesPrice: { _ in true })
        XCTAssertTrue(DepotPosition.merged(a).allSatisfy(\.hidesPrice))
        let mixed = DepotPosition.make([house, house], hidesPrice: { _ in false })
        XCTAssertFalse(DepotPosition.merged(mixed).contains(where: \.hidesPrice))
    }

    // MARK: treemap, slice filter

    func testSlicesKnowTheirPositionsAndTheRestCollectsThem() throws {
        let assets = [asset(holding("A", qty: 10, price: 20_000, cost: 10_000)),
                      asset(holding("B", qty: 10, price: 10_000, cost: 9_000)),
                      asset(holding("C", qty: 1, price: 1_000, cost: 0))]
        let slices = DepotComposition.groups(assets, mode: .position)
        XCTAssertTrue(slices.allSatisfy { $0.memberKeys.count == 1 })
        let rest = try XCTUnwrap(DepotComposition.fold(slices, keep: 1).last)
        XCTAssertTrue(rest.isRest)
        XCTAssertEqual(rest.memberKeys.count, 2, "the rest filters to all folded positions")
        let byClass = DepotComposition.groups(assets, mode: .assetClass)
        XCTAssertEqual(byClass.reduce(0) { $0 + $1.memberKeys.count }, 3)
    }

    func testFilteringByKeysKeepsOnlyThosePositionsAndIgnoresStaleKeys() {
        let positions = DepotPosition.make([asset(holding("A", qty: 1, price: 100, cost: 50)),
                                            asset(holding("B", qty: 1, price: 200, cost: 50))])
        let keyA = DepotComposition.key(positions[0].holding)
        XCTAssertEqual(DepotPosition.filtered(positions, keys: [keyA]).count, 1)
        XCTAssertEqual(DepotPosition.filtered(positions, keys: nil).count, 2)
        XCTAssertEqual(DepotPosition.filtered(positions, keys: ["gone"]).count, 2, "a stale filter never empties the list")
        // the search removed the chosen position: the intersection is empty, the filter is not "stale"
        let afterSearch = [positions[1]]
        XCTAssertEqual(DepotPosition.filtered(afterSearch, keys: [keyA], inventory: positions).count, 0)
        XCTAssertEqual(DepotPosition.filtered(afterSearch, keys: ["gone"], inventory: positions).count, 1)
    }

    func testTreemapWithManyTilesFormsRowsAndColumns() {
        let values = (1...9).map { Double(100 - $0 * 5) }
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 210)
        let tiles = Treemap.layout(values, in: rect, preferredAspect: 2.4)
        XCTAssertEqual(tiles.count, 9)
        XCTAssertTrue(Set(tiles.map { Int($0.minY.rounded()) }).count > 1, "more than one row")
        XCTAssertTrue(tiles.allSatisfy { rect.insetBy(dx: -0.5, dy: -0.5).contains($0) })
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.width * $1.height }, rect.width * rect.height, accuracy: 1)
    }
}
