import XCTest
@testable import GiroCrabUI

/// Print dialog report builder (GitHub #53, part 2).
@MainActor
final class PrintReportTests: XCTestCase {
    private let rows = [
        PrintRow(id: 1, accountId: 10, accountName: "Giro", date: "2025-03-01", amountCents: 250_000,
                 counterparty: "Arbeitgeber", purpose: "Gehalt März\nPersonalnummer 42", category: "Einkommen"),
        PrintRow(id: 2, accountId: 10, accountName: "Giro", date: "2025-03-02", amountCents: -4_599,
                 counterparty: "Supermarkt <Nord>", purpose: "Einkauf", category: "Lebensmittel", note: "Wocheneinkauf"),
        PrintRow(id: 3, accountId: 20, accountName: "Kreditkarte", date: "2025-03-02", amountCents: -1_200,
                 counterparty: "Café", purpose: "Kartenzahlung"),
    ]

    private func report(_ rows: [PrintRow]? = nil) -> PrintReport {
        PrintReport(title: "Übersicht", periodLabel: "März 2025", rows: rows ?? self.rows,
                    accounts: [PrintAccount(id: 10, name: "Giro", iban: "DE02120300000000202051", balanceCents: 1_000_000,
                                            balanceDate: "2025-03-31", currency: "EUR"),
                               PrintAccount(id: 20, name: "Kreditkarte", iban: "", balanceCents: -1_200,
                                            balanceDate: "2025-03-31", currency: "EUR")])
    }

    func testDirectionFilterAndSortOrder() {
        var o = PrintOptions()
        XCTAssertEqual(PrintReportBuilder.rows(rows, options: o).map(\.id), [3, 2, 1])
        o.newestFirst = false
        XCTAssertEqual(PrintReportBuilder.rows(rows, options: o).map(\.id), [1, 2, 3])
        o.direction = .income
        XCTAssertEqual(PrintReportBuilder.rows(rows, options: o).map(\.id), [1])
        o.direction = .expenses
        XCTAssertEqual(PrintReportBuilder.rows(rows, options: o).map(\.id), [2, 3])
    }

    func testTotals() {
        let t = PrintReportBuilder.totals(rows)
        XCTAssertEqual(t.incomeCents, 250_000)
        XCTAssertEqual(t.expenseCents, -5_799)
        XCTAssertEqual(t.netCents, 244_201)
    }

    func testHTMLEscapesAndHonoursOptions() {
        var o = PrintOptions()
        o.showCategory = false
        o.showNote = false
        o.firstLineOnly = true
        let html = PrintReportBuilder.html(report(), options: o)
        XCTAssertTrue(html.contains("Supermarkt &lt;Nord&gt;"))
        XCTAssertFalse(html.contains("<Nord>"))
        XCTAssertTrue(html.contains("Gehalt März"))
        XCTAssertFalse(html.contains("Personalnummer"))
        XCTAssertFalse(html.contains("Wocheneinkauf"))
        XCTAssertFalse(html.contains("Lebensmittel"))
    }

    func testGroupByAccountAddsSectionsPerAccount() {
        var o = PrintOptions()
        o.groupByAccount = true
        let html = PrintReportBuilder.html(report(), options: o)
        XCTAssertEqual(html.components(separatedBy: "<h2>").count - 1, 2)
        XCTAssertTrue(html.contains("DE02120300000000202051"))
        o.groupByAccount = false
        XCTAssertEqual(PrintReportBuilder.html(report(), options: o).components(separatedBy: "<h2>").count - 1, 0)
    }

    func testDailyBalanceOncePerDay() {
        var o = PrintOptions()
        o.showDailyBalance = true
        var r = report()
        r.dailyBalances = [0: ["2025-03-01": 777_701, "2025-03-02": 777_702]]
        let html = PrintReportBuilder.html(r, options: o)
        // two bookings on 2025-03-02, but its end-of-day balance is printed once
        XCTAssertEqual(html.components(separatedBy: Money.format(777_702)).count - 1, 1)
        XCTAssertEqual(html.components(separatedBy: Money.format(777_701)).count - 1, 1)
    }

    func testPurposeThatRepeatsThePayeeIsDropped() {
        let r = PrintRow(id: 9, accountId: 10, accountName: "Giro", date: "2025-03-03", amountCents: -30_000,
                         counterparty: "Tagesgeld Übertrag", purpose: "tagesgeld übertrag")
        XCTAssertEqual(PrintReportBuilder.displayPurpose(r, firstLineOnly: false), "")
        XCTAssertEqual(PrintReportBuilder.displayPurpose(rows[1], firstLineOnly: false), "Einkauf")
    }

    func testCreatedLineHasDateAndTime() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 21, minute: 45))!
        let line = PrintReportBuilder.createdLine(date)
        XCTAssertTrue(line.contains(DateText.medium("2026-11-11")), line)
        XCTAssertTrue(line.contains(date.formatted(date: .omitted, time: .shortened)), line)
    }

    func testPaginatorAndLogoPlacement() {
        var r = report()
        r.logoDataURI = "data:image/png;base64,AAAA"
        var o = PrintOptions()
        o.logo = .header
        var html = PrintReportBuilder.html(r, options: o, paper: .init(widthMM: 216, heightMM: 279))
        XCTAssertTrue(html.contains("class=\"logo\""))
        XCTAssertFalse(html.contains("class=\"watermark\""))
        XCTAssertTrue(html.contains("var W=216.0, H=279.0"))
        o.logo = .watermark
        html = PrintReportBuilder.html(r, options: o)
        XCTAssertTrue(html.contains("class=\"watermark\""))
        XCTAssertFalse(html.contains("class=\"logo\""))
        o.logo = .off
        XCTAssertFalse(PrintReportBuilder.html(r, options: o).contains("data:image/png"))
    }

    func testScriptStringsCannotCloseTheScript() {
        XCTAssertFalse(PrintReportBuilder.jsString("Konto </script><b>").contains("</"))
    }

    func testOptionsSavedBeforeTheLogoOptionStillLoad() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PrintReportTestsLegacy"))
        defaults.removePersistentDomain(forName: "PrintReportTestsLegacy")
        defaults.set(Data(#"{"showNote":false,"direction":"income"}"#.utf8), forKey: "print.options")
        let o = PrintOptions.load(defaults)
        XCTAssertFalse(o.showNote)
        XCTAssertEqual(o.direction, .income)
        XCTAssertEqual(o.logo, .header)
    }

    func testDailyBalanceHeaderSaysAllAccountsWhenCombined() {
        var o = PrintOptions()
        o.showDailyBalance = true
        var r = report()
        r.dailyBalances = [0: [:], 10: [:], 20: [:]]
        XCTAssertTrue(PrintReportBuilder.html(r, options: o).contains("Tagessaldo (alle Konten)"))
        o.groupByAccount = true
        let grouped = PrintReportBuilder.html(r, options: o)
        XCTAssertFalse(grouped.contains("Tagessaldo (alle Konten)"))
        XCTAssertTrue(grouped.contains(">Tagessaldo<"))
    }

    func testHeaderNamesTheDirectionFilter() {
        var o = PrintOptions()
        XCTAssertEqual(PrintReportBuilder.metaLine(report(), options: o, count: 3), "März 2025 · \(String(localized: "\(3) Buchungen"))")
        o.direction = .expenses
        XCTAssertTrue(PrintReportBuilder.metaLine(report(), options: o, count: 2).contains(PrintDirection.expenses.title))
        var r = report()
        r.filterNotes = [PrintDirection.expenses.title]
        // named once, even when list filter and print option agree
        XCTAssertEqual(PrintReportBuilder.metaLine(r, options: o, count: 2).components(separatedBy: PrintDirection.expenses.title).count, 2)
    }

    func testEmptySelection() {
        let html = PrintReportBuilder.html(report([]), options: PrintOptions())
        XCTAssertTrue(html.contains("Keine Buchungen ausgewählt."))
    }

    func testPrintSourceFollowsTheListFilter() throws {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        model.period = .all
        let source = try XCTUnwrap(model.printSource())
        XCTAssertEqual(source.rows.count, Int(model.page?.totalCount ?? 0))
        model.period = Period.previousMonth()
        let (from, to) = model.periodRange
        let month = try XCTUnwrap(model.printSource())
        XCTAssertTrue(month.rows.allSatisfy { $0.date >= from! && $0.date <= to! })
    }

    func testOptionsRoundTrip() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PrintReportTests"))
        defaults.removePersistentDomain(forName: "PrintReportTests")
        var o = PrintOptions()
        o.direction = .expenses
        o.groupByAccount = true
        o.save(defaults)
        XCTAssertEqual(PrintOptions.load(defaults), o)
    }
}
