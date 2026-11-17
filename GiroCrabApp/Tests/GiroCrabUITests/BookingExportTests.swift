import XCTest
import PDFKit
@testable import GiroCrabUI
import GiroCrabCore

@MainActor
final class BookingExportTests: XCTestCase {
    private let rows = [
        PrintRow(id: 1, accountId: 10, accountName: "Giro", date: "2025-03-01", amountCents: 250_000,
                 counterparty: "Arbeitgeber", purpose: "Gehalt März\nPersonalnummer 42", category: "Einkommen"),
        PrintRow(id: 2, accountId: 10, accountName: "Giro", date: "2025-03-02", amountCents: -4_599,
                 counterparty: "Supermarkt <Nord>", purpose: "Einkauf", category: "Lebensmittel", note: "Wocheneinkauf"),
    ]

    private func report() -> PrintReport {
        var r = PrintReport(title: "Giro", periodLabel: "März 2025", rows: rows,
                            accounts: [PrintAccount(id: 10, name: "Giro", iban: "DE02120300000000202051",
                                                    balanceCents: 1_000_000, balanceDate: "2025-03-31", currency: "EUR",
                                                    owner: "Max Mustermann")])
        r.dailyBalances = [0: ["2025-03-01": 1_004_599, "2025-03-02": 1_000_000],
                           10: ["2025-03-01": 1_004_599, "2025-03-02": 1_000_000]]
        return r
    }

    func testCSVIncludesDailyBalanceAndEscapes() throws {
        var o = ExportOptions()
        o.format = .csv
        o.showDailyBalance = true
        o.showCurrentBalance = true
        o.newestFirst = false
        let csv = BookingExportBuilder.csv(report(), options: o)
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(csv.contains("# Giro;10000,00;EUR;2025-03-31"))
        XCTAssertTrue(csv.contains("Tagessaldo"))
        XCTAssertTrue(csv.contains("Supermarkt <Nord>"))
        let lines = csv.split(separator: "\r\n").map(String.init)
        let day1 = try XCTUnwrap(lines.first { $0.hasPrefix("2025-03-01") })
        let day2 = try XCTUnwrap(lines.first { $0.hasPrefix("2025-03-02") })
        XCTAssertTrue(day1.contains(";10045,99"))
        XCTAssertTrue(day2.contains(";10000,00"))
    }

    func testCSVWithoutBalancesOmitsColumns() {
        var o = ExportOptions()
        o.format = .csv
        o.showDailyBalance = false
        o.showCurrentBalance = false
        o.showNote = false
        let csv = BookingExportBuilder.csv(report(), options: o)
        XCTAssertFalse(csv.contains("Tagessaldo"))
        XCTAssertFalse(csv.contains("\u{FEFF}# "))
        XCTAssertFalse(csv.contains("Wocheneinkauf"))
    }

    func testCSVRunningBalanceColumn() throws {
        var o = ExportOptions()
        o.format = .csv
        o.showRunningBalance = true
        var r = report()
        r.runningBalances = [1: 1_004_599]
        let csv = BookingExportBuilder.csv(r, options: o)
        let lines = csv.split(separator: "\r\n").map(String.init)
        XCTAssertTrue(try XCTUnwrap(lines.first { $0.contains("Datum;") }).hasSuffix(";Betrag;Währung;Saldo"))
        XCTAssertTrue(try XCTUnwrap(lines.first { $0.hasPrefix("2025-03-01") }).hasSuffix(";EUR;10045,99"))
        // no balance known (e.g. pending): empty cell
        XCTAssertTrue(try XCTUnwrap(lines.first { $0.hasPrefix("2025-03-02") }).hasSuffix(";EUR;"))
        o.showRunningBalance = false
        XCTAssertFalse(BookingExportBuilder.csv(r, options: o).contains("Saldo"))
    }

    /// The balance after each exported booking walks back by its amount (#577).
    func testExportPageCarriesRunningBalances() async throws {
        let model = demoModel()
        let account = try camtAccount(model)
        model.sidebarSelection = .account(account.id)
        let page = try await model.loadExportPage(
            accountIDs: [account.id], period: .all, bookingIDs: nil, options: nil, withBalances: true)
        let loaded = try XCTUnwrap(page)
        let booked = loaded.bookings.filter { !$0.isPending }
        XCTAssertGreaterThan(booked.count, 2)
        for (newer, older) in zip(booked, booked.dropFirst()) {
            let a = try XCTUnwrap(loaded.balances[newer.id]), b = try XCTUnwrap(loaded.balances[older.id])
            XCTAssertEqual(a - b, newer.amountCents)
        }
        let plainPage = try await model.loadExportPage(
            accountIDs: [account.id], period: .all, bookingIDs: nil, options: nil)
        let plain = try XCTUnwrap(plainPage)
        XCTAssertTrue(plain.balances.isEmpty)
    }

    // MARK: - CAMT.053

    private func demoModel() -> AppModel {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        return model
    }

    private func demoBookings(_ model: AppModel, account: Int64? = nil) async throws -> [Booking] {
        let rows = try await model.loadExportPage(
            accountIDs: account.map { [$0] }, period: .all, bookingIDs: nil, options: nil)
        return try XCTUnwrap(rows?.bookings)
    }

    /// A demo account a CAMT.053 statement may cover.
    private func camtAccount(_ model: AppModel) throws -> Account {
        try XCTUnwrap(model.allAccounts.first {
            !$0.iban.isEmpty && $0.kind != .loan && $0.kind != .brokerage
        })
    }

    /// The core writes the statement; the app only hands over the request.
    private func camtXML(_ model: AppModel, account: Int64, format: BookingExportFormat,
                         from: String? = nil, to: String? = nil,
                         bookingIDs: Set<Int64>? = nil) async throws -> String {
        let request = BookingExportBuilder.camtRequest(
            accountID: account, format: format, from: from, to: to, bookingIDs: bookingIDs)
        let xml = try await model.vaultOffMain { try $0.camt053Export(request: request) }
        return try XCTUnwrap(xml)
    }

    private func validate(_ xml: String, schema: String) throws {
        let xmllint = "/usr/bin/xmllint"
        guard FileManager.default.isExecutableFile(atPath: xmllint) else { throw XCTSkip("xmllint fehlt") }
        // Repo root ← GiroCrabApp/Tests/GiroCrabUITests/<file>
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let xsd = root.appendingPathComponent("girocrab-core/tests/fixtures/iso20022/\(schema).xsd")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("camt-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xmllint)
        process.arguments = ["--noout", "--schema", xsd.path, file.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "\(schema): \(output)\n\(xml.prefix(3000))")
    }

    func testCamt053ValidatesAgainstISO20022Schemas() async throws {
        let model = demoModel()
        let account = try camtAccount(model)
        for (format, schema) in [(BookingExportFormat.camt053v02, "camt.053.001.02"),
                                 (.camt053v08, "camt.053.001.08")] {
            let xml = try await camtXML(model, account: account.id, format: format)
            XCTAssertTrue(xml.contains("<MsgPgntn><PgNb>1</PgNb><LastPgInd>true</LastPgInd></MsgPgntn>"), xml)
            XCTAssertTrue(xml.contains("<Ntry>"), xml)
            try validate(xml, schema: schema)
        }
    }

    func testCamtEndDateCapsFuturePeriodsAtToday() {
        XCTAssertEqual(BookingExportBuilder.camtEndDate("2026-11-30", today: "2026-11-15"), "2026-11-15")
        XCTAssertEqual(BookingExportBuilder.camtEndDate("2026-10-31", today: "2026-11-15"), "2026-10-31")
        XCTAssertEqual(BookingExportBuilder.camtEndDate("2026-11-15", today: "2026-11-15"), "2026-11-15")
        XCTAssertNil(BookingExportBuilder.camtEndDate(nil, today: "2026-11-15"))
    }

    func testCamtRequestCarriesFormatPeriodAndSelection() {
        let created = Date(timeIntervalSince1970: 0)
        let request = BookingExportBuilder.camtRequest(
            accountID: 7, format: .camt053v02, from: "2026-01-01", to: "2026-01-31",
            bookingIDs: [9, 3], created: created)
        XCTAssertEqual(request.accountId, 7)
        XCTAssertEqual(request.dateFrom, "2026-01-01")
        XCTAssertEqual(request.dateTo, "2026-01-31")
        XCTAssertEqual(request.bookingIds, [3, 9])
        XCTAssertEqual(request.version, .v02)
        XCTAssertTrue(request.createdAt.hasPrefix("1970-01-01T"), request.createdAt)

        let all = BookingExportBuilder.camtRequest(
            accountID: 7, format: .camt053v08, from: nil, to: nil, bookingIDs: nil)
        XCTAssertNil(all.dateFrom)
        XCTAssertNil(all.dateTo)
        XCTAssertNil(all.bookingIds)
        XCTAssertEqual(all.version, .v08)
    }

    /// Marked bookings are a statement too (#483): only they are listed, their
    /// own period sets the edges.
    func testCamt053MarkedBookingsUseTheirOwnPeriod() async throws {
        let model = demoModel()
        let account = try camtAccount(model)
        let bookings = Array(try await demoBookings(model, account: account.id).prefix(2))
        XCTAssertEqual(bookings.count, 2)
        let xml = try await camtXML(model, account: account.id, format: .camt053v08,
                                    bookingIDs: Set(bookings.map(\.id)))
        XCTAssertEqual(xml.components(separatedBy: "<Ntry>").count - 1, 2, xml)
        let dates = bookings.map(\.bookingDate).sorted()
        XCTAssertTrue(xml.contains("<Dt>\(dates[0])</Dt>"), xml)
        XCTAssertTrue(xml.contains("<Dt>\(dates[1])</Dt>"), xml)
    }

    func testCamtFilterIgnoresListFilters() {
        let model = demoModel()
        let filter = model.exportFilter(accountIDs: [1], period: .all, options: nil, ignoreListFilters: true)
        XCTAssertNil(filter.search)
        XCTAssertNil(filter.categoryId)
        XCTAssertNil(filter.merchantKey)
        XCTAssertNil(filter.checked)
        XCTAssertEqual(filter.direction, .all)
        XCTAssertEqual(filter.scope, .all)
        XCTAssertEqual(filter.accountIds, [1])
        XCTAssertEqual(filter.limit, 0)
    }

    // MARK: - CSV / XML edge cases, files

    /// Field rules are tested in the core (`export::tests`); here the app's wiring.
    func testCSVFormulaGuard() {
        var r = report()
        r.accounts = [PrintAccount(id: 10, name: "=HYPERLINK(\"x\")", iban: "", balanceCents: 0,
                                   balanceDate: "2025-03-31", currency: "EUR", owner: "")]
        var o = ExportOptions()
        o.format = .csv
        o.showCurrentBalance = true
        r.rows.append(PrintRow(id: 3, accountId: 10, accountName: "Giro", date: "2025-03-03", amountCents: -100,
                               counterparty: "-2+3", purpose: "x", category: ""))
        let csv = BookingExportBuilder.csv(r, options: o)
        XCTAssertTrue(csv.contains("# \"'=HYPERLINK(\"\"x\"\")\";"), csv)
        XCTAssertTrue(csv.contains(";'-2+3;"), csv)
    }

    func testEscapeDropsXMLForbiddenControlCharacters() {
        XCTAssertEqual(PrintReportBuilder.esc("a\u{0}b\u{1F}c\u{FFFE}"), "abc")
        XCTAssertEqual(PrintReportBuilder.esc("a\tb\nc\r\nd"), "a\tb\nc\r\nd")
        XCTAssertEqual(PrintReportBuilder.esc("<&>\"'"), "&lt;&amp;&gt;&quot;&#39;")
    }

    func testFreeURLNeverOverwrites() {
        let dir = URL(fileURLWithPath: "/tmp/export")
        var taken: Set<String> = ["Umsaetze.pdf", "Umsaetze-2.pdf"]
        let exists = { (url: URL) in taken.contains(url.lastPathComponent) }
        XCTAssertEqual(ExportDirectory.freeURL(in: dir, filename: "Neu.pdf", exists: exists).lastPathComponent, "Neu.pdf")
        XCTAssertEqual(ExportDirectory.freeURL(in: dir, filename: "Umsaetze.pdf", exists: exists).lastPathComponent,
                       "Umsaetze-3.pdf")
        taken = ["Liste"]
        XCTAssertEqual(ExportDirectory.freeURL(in: dir, filename: "Liste", exists: exists).lastPathComponent, "Liste-2")
    }

    func testPrintMappingIsAlwaysWhiteLabel() {
        var o = ExportOptions()
        o.showDailyBalance = false
        o.showCurrentBalance = false
        let p = o.asPrintOptions
        XCTAssertEqual(p.logo, .off)
        XCTAssertFalse(p.showDailyBalance)
        XCTAssertFalse(p.showCurrentBalance)
    }

    func testDefaultFilenameUsesAccountAndDateRange() {
        let name = BookingExportBuilder.defaultFilename(
            accounts: report().accounts, rows: rows, format: .pdf)
        XCTAssertTrue(name.hasPrefix("Umsaetze-Giro-"), name)
        XCTAssertTrue(name.contains("2025-03-01_2025-03-02"), name)
        XCTAssertTrue(name.hasSuffix(".pdf"), name)

        let camt = BookingExportBuilder.defaultFilename(
            accounts: report().accounts, rows: rows, format: .camt053v08)
        XCTAssertTrue(camt.contains("CAMT053-001-08"), camt)

        // A statement's name uses its statement period, not the booking days.
        let stated = BookingExportBuilder.defaultFilename(
            accounts: report().accounts, rows: rows, format: .camt053v08,
            rangeFrom: "2025-02-28", rangeTo: "2025-03-31")
        XCTAssertTrue(stated.contains("CAMT053-001-08-2025-02-28_2025-03-31"), stated)

        let prepared = BookingExportBuilder.prepareStatement(report())
        XCTAssertEqual(prepared.title, "Giro")
        XCTAssertEqual(prepared.periodLabel, "01.03.2025 – 02.03.2025")
    }

    func testStatementStyleUsesGermanDatesIBANAndPeriodBalances() {
        var o = ExportOptions()
        o.format = .pdf
        var prepared = BookingExportBuilder.prepareStatement(report())
        prepared.dailyBalances = [10: ["2025-03-01": 1_004_599, "2025-03-02": 1_000_000],
                                  0: ["2025-03-01": 1_004_599, "2025-03-02": 1_000_000]]
        let html = PrintReportBuilder.html(prepared, options: o.asPrintOptions, paper: .a4)
        XCTAssertTrue(o.asPrintOptions.statementStyle)
        XCTAssertFalse(html.contains("Kontoauszug"), html)
        XCTAssertTrue(html.contains("Giro"), html)
        XCTAssertTrue(html.contains("01.03.2025") || html.contains("02.03.2025"), html)
        XCTAssertTrue(html.contains("DE02 1203 0000 0000 2020 51") || html.contains("DE021203"), html)
        XCTAssertTrue(html.contains("Max Mustermann"), html)
        XCTAssertTrue(html.contains("Anfangssaldo"), html)
        XCTAssertTrue(html.contains("Endsaldo"), html)
        XCTAssertTrue(html.contains("period-balances"), html)
        XCTAssertTrue(html.contains("Erstellt am"), html) // in page footer script
        XCTAssertFalse(html.contains("Einnahmen"), html)
        XCTAssertFalse(html.contains("Ausgaben"), html)
        // Opening 01.03 = 10045,99 − 2500,00 = 7545,99
        XCTAssertTrue(html.contains("7.545,99") || html.contains("7545,99"), html)
        XCTAssertTrue(html.contains("10.000,00") || html.contains("10000,00"), html)
    }

    func testOpeningAndClosingBalanceFromDaily() {
        let open = PrintReportBuilder.openingBalance(
            rows: rows, endOfDay: ["2025-03-01": 1_004_599, "2025-03-02": 1_000_000])
        XCTAssertEqual(open?.date, "2025-03-01")
        XCTAssertEqual(open?.cents, 1_004_599 - 250_000)
        let close = PrintReportBuilder.closingBalance(
            rows: rows, endOfDay: ["2025-03-01": 1_004_599, "2025-03-02": 1_000_000])
        XCTAssertEqual(close?.date, "2025-03-02")
        XCTAssertEqual(close?.cents, 1_000_000)
    }



    func testExportOptionsRoundTripAndXmlMigration() throws {
        var o = ExportOptions()
        o.format = .camt053v02
        o.scope = .selection
        o.periodPreset = .thisYear
        o.selectedAccountIDs = [42]
        o.accountOutput = .perAccount
        o.showCategory = false
        o.showNote = true
        o.showDailyBalance = false
        let defaults = UserDefaults(suiteName: "BookingExportTests")!
        defaults.removePersistentDomain(forName: "BookingExportTests")
        o.save(defaults)
        let loaded = ExportOptions.load(defaults)
        XCTAssertEqual(loaded.format, .camt053v02)
        XCTAssertEqual(loaded.scope, .selection)
        XCTAssertEqual(loaded.periodPreset, .thisYear)
        XCTAssertEqual(loaded.selectedAccountIDs, [42])
        XCTAssertEqual(loaded.accountOutput, .perAccount)
        XCTAssertFalse(loaded.showCategory)
        XCTAssertTrue(loaded.showNote)
        XCTAssertTrue(loaded.hasNonDefaultContent)

        // Legacy accountID / bulkPerAccount
        let legacyIDs = Data(#"{"format":"pdf","accountID":7,"bulkPerAccount":true}"#.utf8)
        let migratedIDs = try JSONDecoder().decode(ExportOptions.self, from: legacyIDs)
        XCTAssertEqual(migratedIDs.selectedAccountIDs, [7])
        XCTAssertEqual(migratedIDs.accountOutput, .perAccount)

        // Legacy "xml" → camt053v08
        let legacy = Data(#"{"format":"xml","scope":"filtered"}"#.utf8)
        let migrated = try JSONDecoder().decode(ExportOptions.self, from: legacy)
        XCTAssertEqual(migrated.format, .camt053v08)
        XCTAssertEqual(migrated.periodPreset, .lastMonth)
    }

    func testExportBookingsRespectAccountAndPeriod() async throws {
        let model = demoModel()
        let account = try XCTUnwrap(model.allAccounts.first { !$0.iban.isEmpty })
        let all = try await demoBookings(model)
        let loaded = try await model.loadExportPage(
            accountIDs: [account.id], period: .lastMonth, bookingIDs: nil, options: nil)
        let one = try XCTUnwrap(loaded?.bookings)
        XCTAssertTrue(one.allSatisfy { $0.accountId == account.id })
        let (from, to) = Period.previousMonth().range
        XCTAssertTrue(one.allSatisfy { $0.bookingDate >= from! && $0.bookingDate <= to! })
        XCTAssertLessThanOrEqual(one.count, all.count)
        let report = model.exportReport(bookings: one, accountIDs: [account.id], period: .lastMonth,
                                        bookingIDs: nil, options: nil)
        XCTAssertEqual(report.periodLabel, Period.previousMonth().title)
        XCTAssertEqual(report.title, account.name)
    }

    func testOpenBookingExportPrefersSelection() async throws {
        let model = demoModel()
        let ids = Array(try await demoBookings(model).prefix(2).map(\.id))
        XCTAssertEqual(ids.count, 2)
        model.selectedBookingIDs = Set(ids)
        model.selectedBookingID = ids[0]
        model.openBookingExport(selection: true)
        XCTAssertTrue(model.showExportSheet)
        XCTAssertTrue(model.exportPreferSelection)
        XCTAssertEqual(model.exportBookingIDs, Set(ids))
    }

    func testPDFA4PageMediaBox() async throws {
        var report = report()
        report.generatedAt = Date()
        var o = ExportOptions()
        o.format = .pdf
        o.showDailyBalance = false
        o.showCurrentBalance = false
        let html = PrintReportBuilder.html(report, options: o.asPrintOptions, paper: .a4)
        let data = try await HTMLPDFRenderer.shared.pdf(html: html, paper: .a4)
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThanOrEqual(doc.pageCount, 1)
        let page = try XCTUnwrap(doc.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        XCTAssertEqual(box.width, 210 * 72 / 25.4, accuracy: 4)
        XCTAssertEqual(box.height, 297 * 72 / 25.4, accuracy: 4)
        XCTAssertGreaterThan(box.height, box.width)
        let text = page.string ?? ""
        XCTAssertTrue(text.contains("Giro") || text.contains("Übersicht") || text.contains("Arbeitgeber"), text)
        // Upright: title before payee. Upside-down exports reverse that order.
        if let titleAt = (text.range(of: "Giro") ?? text.range(of: "Übersicht"))?.lowerBound,
           let rowAt = text.range(of: "Arbeitgeber")?.lowerBound {
            XCTAssertLessThan(titleAt, rowAt, "PDF appears upside-down: \(text.prefix(400))")
        }
    }




}
