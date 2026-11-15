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

    // MARK: - CAMT.053

    private func demoModel() -> AppModel {
        let model = AppModel(options: LaunchOptions(arguments: ["--demo-seed"], environment: [:]))
        XCTAssertEqual(model.vaultState, .open)
        return model
    }

    private func demoBookings(_ model: AppModel, account: Int64? = nil) async throws -> [Booking] {
        let rows = try await model.loadExportBookings(
            accountIDs: account.map { [$0] }, period: .all, bookingIDs: nil, options: nil)
        return try XCTUnwrap(rows)
    }

    /// Demo bookings of one IBAN account plus edge cases: pending entry, control
    /// characters, a long purpose, a non-IBAN counterparty and no GVC.
    private func camtFixture() async throws -> (Account, [Booking]) {
        let model = demoModel()
        let account = try XCTUnwrap(model.allAccounts.first { !$0.iban.isEmpty })
        var bookings = Array(try await demoBookings(model, account: account.id).prefix(6))
        XCTAssertGreaterThanOrEqual(bookings.count, 3)
        bookings[0].purpose = "Rechnung\u{1}Nr. 7 & <Sonder> \u{0B}" + String(repeating: "x", count: 300)
        bookings[0].cleanPurpose = ""
        bookings[0].gvc = ""
        bookings[0].purposeCode = "SALA"
        bookings[1].isPending = true
        bookings[1].counterpartyIban = "1234567890"
        bookings[2].counterparty = String(repeating: "N", count: 200)
        return (account, bookings)
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
        let (account, bookings) = try await camtFixture()
        for (format, schema) in [(BookingExportFormat.camt053v02, "camt.053.001.02"), (.camt053v08, "camt.053.001.08")] {
            let xml = BookingExportBuilder.camt053(
                account: account, bookings: bookings, format: format,
                openingCents: 100_000, openingDate: bookings.map(\.bookingDate).min()!)
            XCTAssertFalse(xml.contains("\u{1}"))
            try validate(xml, schema: schema)
        }
        // Account without IBAN → <Othr><Id>
        var noIBAN = account
        noIBAN.iban = ""
        noIBAN.accountNumber = "4711"
        let xml = BookingExportBuilder.camt053(
            account: noIBAN, bookings: bookings, format: .camt053v08, openingCents: 0, openingDate: "2025-01-01")
        XCTAssertTrue(xml.contains("<Othr><Id>4711</Id></Othr>"), xml)
        try validate(xml, schema: "camt.053.001.08")
    }

    func testCamt053StatusOrderAndClosingBalance() async throws {
        let (account, bookings) = try await camtFixture()
        let v08 = BookingExportBuilder.camt053(
            account: account, bookings: bookings, format: .camt053v08, openingCents: 100_000, openingDate: "2025-01-01")
        XCTAssertTrue(v08.contains("<Sts><Cd>BOOK</Cd></Sts>"))
        XCTAssertTrue(v08.contains("<Sts><Cd>PDNG</Cd></Sts>"))
        let v02 = BookingExportBuilder.camt053(
            account: account, bookings: bookings, format: .camt053v02, openingCents: 100_000, openingDate: "2025-01-01")
        XCTAssertTrue(v02.contains("<Sts>BOOK</Sts>"))
        XCTAssertTrue(v02.contains("<Sts>PDNG</Sts>"))
        // Acct: Ownr before Svcr; TxDtls: Purp before RmtInf
        for xml in [v02, v08] {
            if let svcr = xml.range(of: "<Svcr>") {
                XCTAssertLessThan(try XCTUnwrap(xml.range(of: "<Ownr>")).lowerBound, svcr.lowerBound)
            }
            let entry = try XCTUnwrap(xml.components(separatedBy: "<Ntry>").first { $0.contains("<Purp>") })
            XCTAssertLessThan(try XCTUnwrap(entry.range(of: "<Purp>")).lowerBound,
                              try XCTUnwrap(entry.range(of: "<RmtInf>")).lowerBound)
        }
        // CLBD = OPBD + booked entries only (the pending one is left out).
        let booked = bookings.filter { !$0.isPending }.reduce(Int64(0)) { $0 + $1.amountCents }
        let closing = 100_000 + booked
        let amount = "\(closing.magnitude / 100).\(String(format: "%02llu", closing.magnitude % 100))"
        let clbd = try XCTUnwrap(v08.range(of: "<Cd>CLBD</Cd>"))
        XCTAssertTrue(v08[clbd.upperBound...].hasPrefix("</CdOrPrtry></Tp><Amt Ccy=\"EUR\">\(amount)</Amt>"), v08)
    }

    func testCamtOpeningBalanceIsPreviousDayEndOrMissing() {
        XCTAssertEqual(BookingExportBuilder.camtOpeningBalance(
            endOfDay: ["2025-02-28": 50_000, "2025-03-01": 60_000], firstDate: "2025-03-01"), 50_000)
        // No history for the day before → no invented 0
        XCTAssertNil(BookingExportBuilder.camtOpeningBalance(endOfDay: ["2025-03-01": 60_000], firstDate: "2025-03-01"))
        XCTAssertNil(BookingExportBuilder.camtOpeningBalance(endOfDay: [:], firstDate: ""))
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
        let loaded = try await model.loadExportBookings(
            accountIDs: [account.id], period: .lastMonth, bookingIDs: nil, options: nil)
        let one = try XCTUnwrap(loaded)
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
