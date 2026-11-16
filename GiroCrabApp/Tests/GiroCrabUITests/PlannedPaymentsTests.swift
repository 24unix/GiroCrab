import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// „Geplant“ (#240): the page loads through the core and reacts to its filters.
@MainActor
final class PlannedPaymentsTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
    }

    override func tearDown() async throws { model = nil }

    /// The month cards are built once per reload and hold every payment exactly once.
    func testMonthGroupingIsCachedAndComplete() async throws {
        model.plannedHorizon = .all
        await model.reloadPlanned()
        XCTAssertFalse(model.plannedMonths.isEmpty)
        XCTAssertEqual(model.plannedMonths.flatMap(\.items).map(\.id), model.plannedPayments.map(\.id))
        XCTAssertEqual(model.plannedMonths.map(\.id), model.plannedMonths.map(\.id).sorted())
        for m in model.plannedMonths {
            XCTAssertTrue(m.items.allSatisfy { $0.date.hasPrefix(m.id) })
            XCTAssertEqual(m.sumCents, m.items.reduce(Int64(0)) { $0 + $1.amountCents })
        }
        model.plannedAccountFilter = -1 // no such account: the cards empty out with the list
        await model.reloadPlanned()
        XCTAssertTrue(model.plannedMonths.isEmpty)
    }

    /// The demo vault has four scheduled transfers on its Giro account.
    func testDemoVaultLoadsScheduledTransfers() async throws {
        model.sidebarSelection = .planned
        model.plannedHorizon = .all
        await model.reloadPlanned()
        let transfers = model.plannedPayments.filter { $0.kind == .scheduledTransfer }
        XCTAssertEqual(transfers.count, 4)
        let sum: Int64 = transfers.map(\.amountCents).reduce(0, +)
        let expected: Int64 = -170_500
        XCTAssertEqual(sum, expected)
        XCTAssertEqual(model.plannedTotals.count, UInt32(model.plannedPayments.count))
        // the two demo direct debits are the only incoming payments
        let debits = model.plannedPayments.filter { $0.kind == .directDebit }
        XCTAssertEqual(debits.count, 2)
        XCTAssertEqual(model.plannedTotals.incomingCents, debits.map(\.amountCents).reduce(0, +))
        XCTAssertEqual(model.plannedPayments.map(\.date), model.plannedPayments.map(\.date).sorted())
        XCTAssertEqual(model.title, String(localized: "Geplant"))
    }

    func testAccountFilterAndHorizon() async throws {
        model.plannedHorizon = .all
        let other = try XCTUnwrap(model.allAccounts.first { a in
            !model.plannedPayments.contains { $0.accountId == a.id } && a.name != "Musterbank Girokonto"
        })
        model.plannedAccountFilter = other.id
        await model.reloadPlanned()
        XCTAssertTrue(model.plannedPayments.isEmpty)

        model.plannedAccountFilter = nil
        model.plannedHorizon = .days30 // the transfers in 41 days fall out
        await model.reloadPlanned()
        XCTAssertEqual(model.plannedPayments.filter { $0.kind == .scheduledTransfer }.count, 3)
    }

    /// The demo bank reports three standing orders: a rent, a quarterly one and a weekly one.
    func testStandingOrdersAreListedWithTheirRhythm() async throws {
        model.plannedHorizon = .all
        await model.reloadPlanned()
        let standing = model.plannedPayments.filter { $0.kind == .standingOrder }
        XCTAssertEqual(Set(standing.map(\.counterparty)), ["Hausverwaltung Nord", "Sparverein Nord", "Fitnessstudio Mitte"])
        // 12 per order at most in an open period.
        XCTAssertEqual(standing.filter { $0.counterparty == "Fitnessstudio Mitte" }.count, 12)
        let rent = try XCTUnwrap(standing.first { $0.counterparty == "Hausverwaltung Nord" })
        XCTAssertEqual(rent.rhythmText, String(localized: "monatlich"))
        XCTAssertEqual(rent.kindText, String(localized: "Dauerauftrag") + " · " + String(localized: "monatlich"))
        XCTAssertEqual(rent.amountCents, -85_000)
    }

    /// The selection survives a reload while the payment exists and is dropped
    /// when a filter hides it (the inspector must never show a stale row).
    func testSelectionFollowsTheList() async throws {
        model.plannedHorizon = .all
        await model.reloadPlanned()
        let first = try XCTUnwrap(model.plannedPayments.first)
        model.selectedPlannedID = first.id
        await model.reloadPlanned()
        XCTAssertEqual(model.selectedPlannedID, first.id)
        let other = try XCTUnwrap(model.allAccounts.first { $0.id != first.accountId })
        model.plannedAccountFilter = other.id
        await model.reloadPlanned()
        XCTAssertNil(model.selectedPlannedID)
    }

    /// ↑/↓ walk through the list and stop at both ends.
    func testArrowKeysMoveTheSelection() async throws {
        model.plannedHorizon = .all
        await model.reloadPlanned()
        let ids = model.plannedPayments.map(\.id)
        XCTAssertGreaterThan(ids.count, 2)
        model.movePlannedSelection(1)
        XCTAssertEqual(model.selectedPlannedID, ids[0])
        model.movePlannedSelection(1)
        XCTAssertEqual(model.selectedPlannedID, ids[1])
        model.movePlannedSelection(-1)
        model.movePlannedSelection(-1)
        XCTAssertEqual(model.selectedPlannedID, ids[0])
        model.selectedPlannedID = ids.last
        model.movePlannedSelection(1)
        XCTAssertEqual(model.selectedPlannedID, ids.last)
    }

    func testRhythmWording() {
        func text(_ unit: String, _ n: UInt32) -> String {
            PlannedPayment(id: "x", kind: .standingOrder, accountId: 1, accountName: "", date: "2026-12-01",
                           counterparty: "", counterpartyIban: "", amountCents: -1, purpose: "",
                           rhythmUnit: unit, rhythmInterval: n).rhythmText
        }
        XCTAssertEqual(text("M", 3), String(localized: "vierteljährlich"))
        XCTAssertEqual(text("M", 12), String(localized: "jährlich"))
        XCTAssertEqual(text("W", 1), String(localized: "wöchentlich"))
        XCTAssertNotEqual(text("W", 2), text("W", 1))
    }

    func testHorizonEndDates() {
        XCTAssertNil(PlannedHorizon.all.endISO)
        let end = PlannedHorizon.days30.endISO
        XCTAssertEqual(end?.count, 10)
        XCTAssertGreaterThan(end ?? "", DateText.iso(Date()))
    }
}
