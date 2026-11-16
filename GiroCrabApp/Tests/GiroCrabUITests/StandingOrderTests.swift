import XCTest
import GiroCrabCore
@testable import GiroCrabUI

/// Standing orders can be created, changed and deleted (#496): the draft, its request and the
/// link from a „Geplant“ row to the stored order.
@MainActor
final class StandingOrderTests: XCTestCase {
    private func order(id: Int64 = 7, canChange: Bool = true, canDelete: Bool = true) -> StandingOrderInfo {
        StandingOrderInfo(
            id: id, accountId: 1, accountName: "Giro", orderId: "A1", recipientName: "Vermieter GmbH",
            recipientIban: "DE89370400440532013000", amountCents: 85_000, purpose: "Miete",
            firstDate: "2026-01-01", lastDate: nil, timeUnit: "M", interval: 1, execDay: 3,
            canChange: canChange, canDelete: canDelete)
    }

    func testDraftFromOrderKeepsEveryField() throws {
        let d = StandingDraft(order: order(), action: .change)
        XCTAssertEqual(d.orderRowID, 7)
        XCTAssertEqual(d.cents, 85_000)
        XCTAssertTrue(d.ibanValid)
        XCTAssertFalse(d.hasEnd)
        let req = try XCTUnwrap(d.request(demo: true))
        XCTAssertEqual(req.action, .change)
        XCTAssertEqual(req.orderRowId, 7)
        XCTAssertEqual(req.timeUnit, "M")
        XCTAssertEqual(req.interval, 1)
        XCTAssertEqual(req.execDay, 3)
        XCTAssertNil(req.lastDate)
        XCTAssertNil(req.recipientBic)
    }

    func testValidationRejectsBadInput() {
        var d = StandingDraft(order: order(), action: .change)
        XCTAssertTrue(d.isValid)
        d.amountText = "0"
        XCTAssertFalse(d.isValid)
        d.amountText = "10,00"
        d.iban = "DE00 0000 0000 0000 0000 00"
        XCTAssertFalse(d.isValid)
        d.iban = "DE89 3704 0044 0532 0130 00"
        d.hasEnd = true
        d.lastDate = Calendar.current.date(byAdding: .day, value: -1, to: d.firstDate) ?? d.firstDate
        XCTAssertFalse(d.isValid, "the last execution must not precede the first")
        d.hasEnd = false
        d.name = String(repeating: "x", count: 71)
        XCTAssertFalse(d.isValid)
    }

    func testRhythmWords() {
        var d = StandingDraft()
        XCTAssertEqual(d.rhythmText, String(localized: "monatlich"))
        d.interval = 3
        XCTAssertEqual(d.rhythmText, String(localized: "vierteljährlich"))
        d.unit = "W"
        d.interval = 1
        XCTAssertEqual(d.rhythmText, String(localized: "wöchentlich"))
        XCTAssertEqual(StandingDraft.weekdayName(1), Calendar.current.weekdaySymbols[1])
        XCTAssertEqual(StandingDraft.weekdayName(7), Calendar.current.weekdaySymbols[0])
    }

    func testPlannedRowFindsItsOrder() {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        model.standingOrders = [order(id: 7)]
        func row(_ id: String, kind: PlannedKind = .standingOrder) -> PlannedPayment {
            PlannedPayment(id: id, kind: kind, accountId: 1, accountName: "Giro", date: "2026-12-03",
                           counterparty: "Vermieter GmbH", counterpartyIban: "", amountCents: -85_000,
                           purpose: "Miete", rhythmUnit: "M", rhythmInterval: 1)
        }
        XCTAssertEqual(model.standingOrder(for: row("standing-7-2026-12-03"))?.id, 7)
        XCTAssertNil(model.standingOrder(for: row("standing-8-2026-12-03")))
        XCTAssertNil(model.standingOrder(for: row("transfer-7", kind: .scheduledTransfer)))
    }

    func testFormFollowsTheBanksLimits() {
        let limits = StandingOrderLimits(
            minDaysAhead: 3, maxDaysAhead: 60, months: [1, 3, 6, 12], weeks: [], daysOfMonth: [1, 15, 31], weekdays: [])
        var d = StandingDraft(order: order(), action: .change)
        d.interval = 2
        d.execDay = 10
        XCTAssertEqual(d.allowedIntervals(limits), [1, 3, 6, 12])
        XCTAssertEqual(d.allowedDays(limits), [1, 15, 31])
        d.conform(to: limits)
        XCTAssertEqual(d.interval, 1)
        XCTAssertEqual(d.execDay, 15, "the nearest allowed day")
        let range = d.firstDateRange(limits)
        XCTAssertGreaterThanOrEqual(d.firstDate, range.lowerBound)
        XCTAssertLessThanOrEqual(d.firstDate, range.upperBound)
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: range.lowerBound).day
        XCTAssertEqual(days, 3)
        // Weekly: the lists of the monthly rhythm do not apply.
        d.unit = "W"
        XCTAssertTrue(d.allowedIntervals(limits).isEmpty)
        XCTAssertTrue(d.allowedDays(limits).isEmpty)
    }

    func testUnknownLimitsOfferEverything() {
        var d = StandingDraft(order: order(), action: .change)
        d.conform(to: nil)
        XCTAssertEqual(d.interval, 1)
        XCTAssertEqual(d.execDay, 3)
        XCTAssertGreaterThanOrEqual(d.firstDate, StandingDraft.tomorrow.addingTimeInterval(-86_400))
    }

    func testNextOccurrenceUsesTheLastDayInShortMonths() throws {
        let cal = Calendar.current
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }
        XCTAssertEqual(StandingDraft.nextOccurrence(ofDay: 15, after: date(2026, 11, 10)), date(2026, 11, 15))
        XCTAssertEqual(StandingDraft.nextOccurrence(ofDay: 15, after: date(2026, 11, 15)), date(2026, 12, 15), "never today")
        XCTAssertEqual(StandingDraft.nextOccurrence(ofDay: 31, after: date(2027, 1, 31)), date(2027, 2, 28))
        XCTAssertEqual(StandingDraft.nextOccurrence(ofDay: 1, after: date(2026, 12, 20)), date(2027, 1, 1))
    }

    func testDraftFromBookingRepeatsIt() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        var b = try XCTUnwrap(model.bookings.first)
        b.counterparty = "Vermieter GmbH"
        b.counterpartyIban = "DE89370400440532013000"
        b.amountCents = -85_000
        b.purpose = "Miete November"
        b.bookingDate = "2026-11-03"
        let today = try XCTUnwrap(DateText.date("2026-11-10"))
        let d = StandingDraft(booking: b, series: nil, accountID: 5, today: today)
        XCTAssertEqual(d.action, .create)
        XCTAssertEqual(d.accountID, 5)
        XCTAssertEqual(d.name, "Vermieter GmbH")
        XCTAssertEqual(d.cents, 85_000)
        XCTAssertTrue(d.ibanValid)
        XCTAssertEqual(d.purpose, "Miete", "the month is dropped")
        XCTAssertEqual(d.interval, 1)
        XCTAssertEqual(d.execDay, 3)
        XCTAssertEqual(DateText.iso(d.firstDate), "2026-12-03")
        XCTAssertTrue(d.isValid)
    }

    func testRecurringPurposeDropsWhatChanges() {
        let clean = StandingDraft.recurringPurpose
        XCTAssertEqual(clean("Miete November 2026"), "Miete")
        XCTAssertEqual(clean("Abschlag Strom Kd-Nr 482910 vom 03.11.2026"), "Abschlag Strom Kd-Nr 482910")
        XCTAssertEqual(clean("Beitrag 11/2026 Mitgl. 4711"), "Beitrag Mitgl. 4711")
        XCTAssertEqual(clean("Rate 2026-11-03 Vertrag 20457781"), "Rate Vertrag 20457781", "long numbers stay")
        XCTAssertEqual(clean("Mai 2026"), "Mai 2026", "nothing left: keep the original")
        XCTAssertEqual(clean("Wohnung Mainzer Str. 5, Dezember"), "Wohnung Mainzer Str. 5")
    }

    func testFirstDateAndExecutionDayStayConsistent() throws {
        let cal = Calendar.current
        var d = StandingDraft(order: order(), action: .change)
        XCTAssertTrue(d.firstDateMatchesDay, "a change starts on the next date of its day, not on the stored start")
        XCTAssertGreaterThan(d.firstDate, cal.startOfDay(for: Date()))
        XCTAssertEqual(cal.component(.day, from: d.firstDate), 3)
        // the day picker moves the date
        d.execDay = 20
        XCTAssertFalse(d.firstDateMatchesDay)
        d.syncDate(to: nil)
        XCTAssertTrue(d.firstDateMatchesDay)
        XCTAssertEqual(cal.component(.day, from: d.firstDate), 20)
        // the date picker moves the day
        d.firstDate = try XCTUnwrap(cal.date(byAdding: .day, value: 40, to: d.firstDate))
        d.syncDay(to: nil)
        XCTAssertTrue(d.firstDateMatchesDay)
        XCTAssertEqual(d.execDay, cal.component(.day, from: d.firstDate))
        // weekly: the weekday follows
        d.unit = "W"
        d.syncDay(to: nil)
        XCTAssertTrue(d.firstDateMatchesDay)
        XCTAssertEqual(d.execDay, (cal.component(.weekday, from: d.firstDate) + 5) % 7 + 1)
        XCTAssertTrue(d.isValid)
    }

    func testBankLimitsNeverLeaveAMismatch() {
        let limits = StandingOrderLimits(
            minDaysAhead: 2, maxDaysAhead: 0, months: [], weeks: [], daysOfMonth: [1, 15], weekdays: [])
        var d = StandingDraft(order: order(), action: .change)
        d.firstDate = Calendar.current.date(byAdding: .day, value: 10, to: Date()) ?? Date()
        d.syncDay(to: limits)
        XCTAssertTrue([1, 15].contains(d.execDay))
        XCTAssertTrue(d.firstDateMatchesDay)
        XCTAssertGreaterThanOrEqual(d.firstDate, d.firstDateRange(limits).lowerBound)
    }
}
