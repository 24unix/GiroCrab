import Foundation
import SwiftUI
import UniformTypeIdentifiers
import GiroCrabCore
#if os(macOS)
import AppKit
#endif

extension AppModel {
    // MARK: - Printing (GitHub #53) & Umsatz-Export (#53 PDF / #372 CAMT)

    /// Writes export bytes through the system save panel (iOS: share/file exporter).
    func presentExportFile(data: Data, format: BookingExportFormat, filename: String) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [format.contentType]
        panel.directoryURL = ExportDirectory.preferred
        panel.title = String(localized: "Umsätze sichern")
        panel.prompt = String(localized: "Sichern")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            ExportDirectory.remember(fileURL: url)
        } catch {
            showError(String(localized: "Export fehlgeschlagen"), error.localizedDescription)
        }
        #else
        exportFile = ExportFileDocument(data: data)
        exportContentType = format.contentType
        exportFilename = filename
        showExportExporter = true
        #endif
    }

    /// Saves one file per account into a folder the user picks (never replacing existing files).
    func presentExportFiles(_ files: [(data: Data, filename: String)], format: BookingExportFormat) {
        guard !files.isEmpty else { return }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = ExportDirectory.preferred
        panel.title = String(localized: "Ordner für \(files.count) Dateien wählen")
        panel.prompt = String(localized: "Sichern")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        var saved = 0
        var lastURL: URL?
        var firstName = files[0].filename
        for file in files {
            let url = ExportDirectory.freeURL(in: directory, filename: file.filename)
            do {
                try file.data.write(to: url, options: .withoutOverwriting)
                if saved == 0 { firstName = url.lastPathComponent }
                lastURL = url
                saved += 1
            } catch {
                showError(String(localized: "Export fehlgeschlagen"), error.localizedDescription)
                return
            }
        }
        if let lastURL { ExportDirectory.remember(fileURL: lastURL) }
        toast = saved == 1
            ? String(localized: "Gespeichert: \(firstName)")
            : String(localized: "\(saved) Dateien gespeichert")
        #else
        // iOS: fall back to the first file via the share sheet.
        if let first = files.first {
            presentExportFile(data: first.data, format: format, filename: first.filename)
        }
        #endif
    }

    /// Accounts of the sidebar selection (empty = all) – which accounts the export sheet ticks.
    var exportScopeAccountIDs: [Int64] { selectionAccountIDs }

    /// Everything the list shows (account, period, search, scope, status) without the list limit.
    func printSource() -> PrintReport? {
        guard let vault else { return nil }
        var filter = currentFilter
        filter.limit = 0
        do {
            let rows = try vault.listTransactions(filter: filter).transactions
            return exportReport(bookings: rows, accountIDs: nil, period: .current, bookingIDs: nil, options: nil)
        } catch {
            showError(String(localized: "Drucken nicht möglich"), error.localizedDescription)
            return nil
        }
    }

    /// Vault filter for an export: the list's filter with the sheet's accounts and period.
    /// `ignoreListFilters` (CAMT.053) drops search, category, direction, tags, merchant and
    /// review status, so the closing balance matches the bank's.
    func exportFilter(accountIDs: [Int64]?, period: ExportPeriodPreset, options: ExportOptions?,
                      ignoreListFilters: Bool = false) -> BookingFilter {
        var filter = currentFilter
        filter.limit = 0
        filter.offset = 0
        if let accountIDs, !accountIDs.isEmpty { filter.accountIds = accountIDs }
        if ignoreListFilters {
            filter.categoryId = nil
            filter.includeSubcategories = true
            filter.uncategorizedOnly = false
            filter.search = nil
            filter.scope = .all
            filter.merchantKey = nil
            filter.direction = .all
            filter.checked = nil
            filter.tagIds = []
            filter.untaggedOnly = false
        }
        let salary = salaryCycle?.lastDate
        if let range = period.range(customFrom: options?.customFrom ?? "", customTo: options?.customTo ?? "",
                                    salaryFrom: salary) {
            // `.all` → open range; `.current` returns nil and keeps the list's dates.
            filter.dateFrom = range.0
            filter.dateTo = range.1
        }
        return filter
    }

    /// Bookings for an export, read off the main thread (`list_transactions` enriches every
    /// row). `nil` when the vault was locked or swapped meanwhile.
    /// `withBalances`: also the balance after each booking (#577, CSV „Saldo“ column),
    /// only for a selection of accounts, as in the list.
    func loadExportPage(accountIDs: [Int64]?, period: ExportPeriodPreset, bookingIDs: Set<Int64>?,
                        options: ExportOptions?, ignoreListFilters: Bool = false, withBalances: Bool = false)
        async throws -> (bookings: [Booking], balances: [Int64: Int64])? {
        var filter = exportFilter(accountIDs: accountIDs, period: period, options: options,
                                  ignoreListFilters: ignoreListFilters)
        filter.withBalances = withBalances && selectionHasBalances
        guard let page = try await vaultOffMain({ try $0.listTransactions(filter: filter) }) else {
            return nil
        }
        var rows = page.transactions
        if let bookingIDs { rows = rows.filter { bookingIDs.contains($0.id) } }
        let balances = Dictionary(uniqueKeysWithValues: page.runningBalances.map { ($0.bookingId, $0.balanceCents) })
        return (rows, balances)
    }

    /// Report for already loaded export bookings (cheap: no vault access).
    func exportReport(bookings: [Booking], accountIDs: [Int64]?, period: ExportPeriodPreset,
                      bookingIDs: Set<Int64>?, options: ExportOptions?) -> PrintReport {
        let accounts = allAccounts.map {
            PrintAccount(id: $0.id, name: $0.name, iban: $0.iban, balanceCents: $0.balanceCents,
                         balanceDate: $0.balanceDate, currency: $0.currency, owner: $0.owner)
        }
        let periodLabel = exportPeriodLabel(period, bookingIDs: bookingIDs, options: options)
        let title: String = {
            if let accountIDs, accountIDs.count == 1,
               let a = allAccounts.first(where: { $0.id == accountIDs[0] }) {
                return a.name
            }
            return self.title
        }()
        var report = PrintReport(title: title, periodLabel: periodLabel, rows: bookings.map(PrintRow.init),
                                 accounts: accounts)
        // The list's own income/expense filter is named in the printout header.
        switch directionFilter {
        case .all: break
        case .income: report.filterNotes = [PrintDirection.income.title]
        case .expense: report.filterNotes = [PrintDirection.expenses.title]
        }
        // and the tag filter (#228)
        if let note = tagFilterNote { report.filterNotes.append(note) }
        return report
    }

    private func exportPeriodLabel(_ period: ExportPeriodPreset, bookingIDs: Set<Int64>?,
                                   options: ExportOptions?) -> String {
        if bookingIDs != nil { return String(localized: "Auswahl") }
        // „Neue Umsätze“ ignores the period
        if period == .current { return sidebarSelection == .newBookings ? Period.all.title : periodTitle }
        if period == .custom, let o = options, !o.customFrom.isEmpty {
            return "\(PrintReportBuilder.statementDate(o.customFrom)) – \(PrintReportBuilder.statementDate(o.customTo))"
        }
        if period == .sinceSalary, let c = salaryCycle {
            return String(localized: "Seit Gehalt am \(PrintReportBuilder.statementDate(c.lastDate))")
        }
        return period.title
    }

    /// End-of-day balances since `from` for each account (key = id) and combined (key 0).
    func printDailyBalances(accountIds: [Int64], from: String) -> [Int64: [String: Int64]] {
        guard let vault else { return [:] }
        return Self.dailyBalances(vault, accountIds: accountIds, from: from)
    }

    /// `printDailyBalances` off the main thread; `nil` when the vault was locked or swapped.
    func loadDailyBalances(accountIds: [Int64], from: String) async throws -> [Int64: [String: Int64]]? {
        try await vaultOffMain { Self.dailyBalances($0, accountIds: accountIds, from: from) }
    }

    nonisolated private static func dailyBalances(_ vault: Vault, accountIds: [Int64],
                                                  from: String) -> [Int64: [String: Int64]] {
        guard !accountIds.isEmpty else { return [:] }
        let today = Calendar.current.startOfDay(for: Date())
        let start = DateText.date(from) ?? today
        let days = UInt32(max(1, (Calendar.current.dateComponents([.day], from: start, to: today).day ?? 0) + 1))
        func map(_ ids: [Int64]) -> [String: Int64] {
            let points = (try? vault.balanceHistory(accountIds: ids, days: days)) ?? []
            return Dictionary(points.map { ($0.date, $0.balanceCents) }, uniquingKeysWith: { _, b in b })
        }
        var out: [Int64: [String: Int64]] = [0: map(accountIds)]
        for id in accountIds { out[id] = map([id]) }
        return out
    }
}
