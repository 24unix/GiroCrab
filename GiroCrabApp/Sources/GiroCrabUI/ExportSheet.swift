import SwiftUI
import GiroCrabCore

// MARK: - Umsätze exportieren (GitHub #53 / #372)
//
// One compact sheet: format → period → accounts → options. It opens on the last period
// and accounts (limited to the sidebar's scope); "Exportieren …" hands over to the system save panel.
// PDF = white-label Umsatzliste; CAMT.053 needs exactly one account (#372).

struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var options = ExportOptions.load()
    @State private var busy = false
    /// Export error, shown on the sheet itself (the app's alert would stay hidden behind it).
    @State private var failure: String?
    @State private var showDetails = false
    /// Booking count for the current choices, loaded off the main thread (`nil` while
    /// loading). Refreshed only when `previewKey` changes.
    @State private var previewCount: Int?
    @State private var selectedIDs: Set<Int64> = []
    @State private var customFromDate = Date()
    @State private var customToDate = Date()
    @State private var showAccountPicker = false
    /// Saved account choice, read once; a context-menu export writes it back unchanged.
    @State private var savedAccountIDs: [Int64] = []

    /// The three format choices; CAMT.053 has a version of its own.
    private enum FormatFamily: String, CaseIterable, Identifiable {
        case pdf, csv, camt
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pdf: return String(localized: "PDF")
            case .csv: return "CSV"
            case .camt: return String(localized: "CAMT.053")
            }
        }
    }

    private var formatFamily: Binding<FormatFamily> {
        Binding(
            get: {
                switch options.format {
                case .pdf: return .pdf
                case .csv: return .csv
                case .camt053v08, .camt053v02: return .camt
                }
            },
            set: { family in
                switch family {
                case .pdf: options.format = .pdf
                case .csv: options.format = .csv
                case .camt: if !options.format.isCamt { options.format = .camt053v08 }
                }
            })
    }

    /// The marked bookings: those of the context menu, else the list's selection.
    private var markedIDs: Set<Int64> {
        model.exportBookingIDs
            ?? (model.selectedBookingIDs.isEmpty ? Set(model.selectedBookingID.map { [$0] } ?? []) : model.selectedBookingIDs)
    }

    private var selectionCount: Int { markedIDs.count }

    private var exportIDs: Set<Int64>? {
        options.scope == .selection ? markedIDs : nil
    }

    /// Every active account; the sidebar scope only decides what is ticked on open.
    private var poolAccounts: [Account] {
        model.allAccounts.filter { !$0.isArchived }
    }

    /// Same bank grouping as the sidebar (`bankGroupKey`), "Ohne Bank" last.
    private var accountsByBank: [(bank: String, accounts: [Account])] {
        let grouped = Dictionary(grouping: poolAccounts) { model.bankGroupKey(for: $0) }
        return grouped.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return b.isEmpty }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }.map { bank in
            (bank.isEmpty ? String(localized: "Ohne Bank") : bank,
             grouped[bank]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }

    private var selectedAccounts: [Account] {
        poolAccounts.filter { selectedIDs.contains($0.id) }
    }

    /// Context-menu „Umsatz exportieren“ — lock to the marked bookings (no account/period chrome).
    private var isSelectionExport: Bool { model.exportPreferSelection }

    private var isBulk: Bool {
        showsOutputMode && options.accountOutput == .perAccount
    }

    /// „Pro Konto eine Datei“ only when several accounts can produce separate files.
    private var showsOutputMode: Bool {
        #if os(macOS)
        options.scope != .selection && !options.format.isCamt && selectedAccounts.count > 1
        #else
        false // iOS has no multi-file save
        #endif
    }

    /// A loan's balance is no sum of its own bookings, a depot has none: CAMT.053
    /// refuses both in the core, so the picker does too (#483).
    private func camtUsable(_ account: Account) -> Bool {
        account.kind != .loan && account.kind != .brokerage
    }

    /// Exactly one account a CAMT.053 statement can cover.
    private func camtSelectionOK<S: Collection>(_ ids: S) -> Bool where S.Element == Int64 {
        guard ids.count == 1, let id = ids.first, let account = model.account(for: id) else { return false }
        return camtUsable(account)
    }

    private var camtAccountOK: Bool {
        !options.format.isCamt || camtSelectionOK(effectiveAccountIDs)
    }

    /// First account a CAMT.053 statement can cover.
    private var firstCamtAccount: Account? {
        selectedAccounts.first(where: camtUsable) ?? poolAccounts.first(where: camtUsable)
    }

    private var canExport: Bool {
        !busy && camtAccountOK && !effectiveAccountIDs.isEmpty && (isBulk || (previewCount ?? 0) > 0)
    }

    /// Accounts used for the export query (selection → accounts of the marked bookings).
    private var effectiveAccountIDs: [Int64] {
        if options.scope == .selection {
            let fromBookings = accountIDsForSelectedBookings
            if !fromBookings.isEmpty { return fromBookings.sorted() }
        }
        return Array(selectedIDs).sorted()
    }

    private var accountIDsForSelectedBookings: Set<Int64> {
        guard let ids = exportIDs else { return [] }
        return Set(model.bookings.filter { ids.contains($0.id) }.map(\.accountId))
    }

    /// Everything the preview depends on; a change reloads it (`.task(id:)` cancels the old load).
    private struct PreviewKey: Equatable {
        var options: ExportOptions
        var accountIDs: [Int64]
        var bookingIDs: Set<Int64>?
    }

    /// Column and layout toggles don't change the count, so they don't reload it.
    private var previewKey: PreviewKey {
        var counted = ExportOptions()
        counted.format = options.format
        counted.scope = options.scope
        counted.periodPreset = options.periodPreset
        counted.customFrom = options.customFrom
        counted.customTo = options.customTo
        counted.direction = options.direction
        return PreviewKey(options: counted, accountIDs: effectiveAccountIDs, bookingIDs: exportIDs)
    }

    private func period(for options: ExportOptions) -> ExportPeriodPreset {
        options.scope == .selection ? .current : options.periodPreset
    }

    private var countText: String {
        if options.scope != .selection, selectedIDs.isEmpty { return String(localized: "Bitte mindestens ein Konto wählen.") }
        guard let n = previewCount else { return "…" }
        if n == 0 { return String(localized: "Keine Umsätze") }
        let rows = n == 1 ? String(localized: "1 Umsatz") : String(localized: "\(n) Umsätze")
        return isBulk ? String(localized: "\(rows) in \(selectedAccounts.count) Dateien") : rows
    }

    var body: some View {
        NavigationStack {
            Form {
                formatSection
                scopeSection
                if options.format == .pdf || options.format == .csv {
                    detailsSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle(sheetTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? String(localized: "Wird erstellt …") : String(localized: "Exportieren …")) { Task { await export() } }
                        .disabled(!canExport)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        #if os(macOS)
        .desktopFrame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 460)
        #endif
        .alert(String(localized: "Export fehlgeschlagen"),
               isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .onAppear { bootstrap() }
        .onDisappear { persistOptions() }
        .task(id: previewKey) { await refreshPreview() }
        .onChange(of: options.periodPreset) { _, preset in
            if preset == .custom { syncCustomDatesFromOptions() }
        }
        .onChange(of: selectionCount) { _, n in
            if n == 0, !isSelectionExport { options.scope = .filtered }
        }
        .onChange(of: options.format) { _, format in
            if format.isCamt, !isSelectionExport, !camtAccountOK, let first = firstCamtAccount {
                selectedIDs = [first.id]
            }
        }
    }

    private var sheetTitle: String {
        if isSelectionExport, selectionCount <= 1 {
            return String(localized: "Umsatz exportieren")
        }
        return String(localized: "Umsätze exportieren")
    }

    /// Saves the choices when the sheet closes. The context-menu export keeps the saved
    /// accounts (it ticks the marked bookings' accounts).
    private func persistOptions() {
        var snapshot = options
        snapshot.scope = .filtered
        snapshot.selectedAccountIDs = isSelectionExport ? savedAccountIDs : Array(selectedIDs).sorted()
        snapshot.save()
    }

    // MARK: - Sections

    private var formatSection: some View {
        Section {
            Picker("Format", selection: formatFamily) {
                ForEach(FormatFamily.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if options.format.isCamt {
                Picker("Version", selection: $options.format) {
                    Text("Aktuell").tag(BookingExportFormat.camt053v08)
                    Text("Älter, für ältere Programme").tag(BookingExportFormat.camt053v02)
                }
            }
        } footer: {
            Text(options.format.subtitle).leadingFooter()
        }
    }

    private var scopeSection: some View {
        Section {
            if isSelectionExport {
                LabeledContent(
                    selectionCount == 1
                        ? String(localized: "Dieser Umsatz")
                        : String(localized: "Auswahl"),
                    value: selectionCount == 1
                        ? String(localized: "1 Buchung")
                        : String(localized: "\(selectionCount) Buchungen")
                )
            } else {
                Picker("Zeitraum", selection: periodChoice) {
                    if selectionCount > 0 {
                        Text(selectionCount == 1
                             ? String(localized: "Markierter Umsatz")
                             : String(localized: "Markierte Umsätze (\(selectionCount))"))
                            .tag(PeriodChoice.selection)
                    }
                    ForEach(periodChoices) { Text(periodTitle($0)).tag(PeriodChoice.preset($0)) }
                }
                if options.scope == .filtered {
                    if options.periodPreset == .custom {
                        DatePicker("Von", selection: $customFromDate, in: ...customToDate, displayedComponents: .date)
                        DatePicker("Bis", selection: $customToDate, in: customFromDate..., displayedComponents: .date)
                    }
                    LabeledContent("Konten") {
                        accountButton
                    }
                    if showsOutputMode {
                        Toggle("Pro Konto eine Datei", isOn: perAccountBinding)
                    }
                }
            }
            LabeledContent("Umfang") {
                Text(countText).foregroundStyle(.secondary)
            }
        } footer: {
            scopeFooter
        }
        .onChange(of: customFromDate) { _, d in
            options.customFrom = DateText.iso(d)
        }
        .onChange(of: customToDate) { _, d in
            options.customTo = DateText.iso(d)
        }
    }

    @ViewBuilder
    private var scopeFooter: some View {
        if options.format.isCamt, !camtAccountOK {
            if effectiveAccountIDs.count == 1 {
                Text("Für Darlehen und Depots gibt es keinen CAMT.053-Auszug.").leadingFooter()
            } else {
                Text("CAMT.053 gilt immer für genau ein Konto.").leadingFooter()
            }
        } else if options.scope == .selection, options.format.isCamt {
            Text("CAMT.053 für markierte Buchungen enthält deren Zeitraum mit den echten Salden des Kontos.")
                .leadingFooter()
        } else if isBulk {
            Text("Du wählst gleich einen Ordner für die Dateien.").leadingFooter()
        }
    }

    private var perAccountBinding: Binding<Bool> {
        Binding(
            get: { options.accountOutput == .perAccount },
            set: { options.accountOutput = $0 ? .perAccount : .combined })
    }

    /// Period pop-up entry: the marked bookings or a period preset.
    private enum PeriodChoice: Hashable {
        case selection
        case preset(ExportPeriodPreset)
    }

    private var periodChoice: Binding<PeriodChoice> {
        Binding(
            get: { options.scope == .selection ? .selection : .preset(options.periodPreset) },
            set: { choice in
                switch choice {
                case .selection:
                    options.scope = .selection
                case .preset(let preset):
                    options.scope = .filtered
                    options.periodPreset = preset
                }
            })
    }

    private var periodChoices: [ExportPeriodPreset] {
        ExportPeriodPreset.menuCases.filter { $0 != .sinceSalary || model.salaryCycle != nil }
    }

    private func periodTitle(_ preset: ExportPeriodPreset) -> String {
        switch preset {
        case .current:
            return String(localized: "Aktuelle Ansicht (\(model.periodTitle))")
        case .sinceSalary:
            if let c = model.salaryCycle {
                return String(localized: "Seit \(PrintReportBuilder.statementDate(c.lastDate))")
            }
            return preset.title
        default:
            return preset.title
        }
    }

    private func syncCustomDatesFromOptions() {
        if options.customFrom.isEmpty || options.customTo.isEmpty {
            let (from, to) = Period.previousMonth().range
            options.customFrom = from ?? DateText.iso(Date())
            options.customTo = to ?? DateText.iso(Date())
        }
        customFromDate = DateText.date(options.customFrom) ?? Date()
        customToDate = DateText.date(options.customTo) ?? Date()
        if customFromDate > customToDate { swap(&customFromDate, &customToDate) }
    }

    // MARK: Accounts

    private var accountSummary: String {
        let n = selectedIDs.count
        if n == 0 { return String(localized: "Keine") }
        if n == 1, let only = selectedAccounts.first { return only.name }
        if n == poolAccounts.count { return String(localized: "Alle Konten") }
        return String(localized: "\(n) Konten")
    }

    private var accountButton: some View {
        Button {
            showAccountPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(accountSummary).sensitive()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .capturablePopover(isPresented: $showAccountPicker, arrowEdge: .bottom) {
            ExportAccountPicker(groups: accountsByBank, selectedIDs: $selectedIDs,
                                singleChoice: options.format.isCamt, isUsable: { !options.format.isCamt || camtUsable($0) })
        }
    }

    // MARK: Options

    private var detailsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showDetails) {
                Toggle("Kategorie", isOn: $options.showCategory)
                Toggle("Notizen", isOn: $options.showNote)
                if options.format == .csv {
                    Toggle("IBAN der Gegenseite", isOn: $options.showIban)
                    Toggle("Tags", isOn: $options.showTags)
                }
                Toggle("Tagessaldo-Spalte", isOn: $options.showDailyBalance)
                if options.format == .csv {
                    Toggle("Saldo-Spalte (nach jeder Buchung)", isOn: $options.showRunningBalance)
                }
                if options.format == .pdf {
                    Toggle("Nach Konto gruppieren", isOn: $options.groupByAccount)
                }
                Toggle("Nur erste Zeile Verwendungszweck", isOn: $options.firstLineOnly)
                Picker("Reihenfolge", selection: $options.newestFirst) {
                    Text("Älteste zuerst").tag(false)
                    Text("Neueste zuerst").tag(true)
                }
            } label: {
                Text("Optionen")
            }
        } footer: {
            if options.format == .pdf {
                Text("Anfangssaldo und Endsaldo stehen immer im Kopf.").leadingFooter()
            }
        }
    }

    // MARK: - Lifecycle

    private func bootstrap() {
        savedAccountIDs = options.selectedAccountIDs
        if isSelectionExport {
            // Context menu: only the marked bookings.
            options.scope = .selection
            let bookingAccounts = accountIDsForSelectedBookings
            selectedIDs = bookingAccounts.isEmpty ? Set(poolAccounts.map(\.id)) : bookingAccounts
        } else {
            // Menu / toolbar: period and accounts as last chosen; the accounts within the
            // sidebar's scope (an account or group), else all of the sidebar's accounts.
            options.scope = .filtered
            if options.periodPreset == .custom { syncCustomDatesFromOptions() }
            let pool = Set(poolAccounts.map(\.id))
            let sidebar = Set(model.exportScopeAccountIDs)
            let scope = sidebar.isEmpty ? pool : sidebar.intersection(pool)
            var ids = Set(options.selectedAccountIDs).intersection(scope)
            if ids.isEmpty { ids = scope }
            if options.format.isCamt, !camtSelectionOK(ids) {
                ids = firstCamtAccount.map { [$0.id] } ?? []
            }
            selectedIDs = ids
            showDetails = options.hasNonDefaultContent
        }
    }

    /// Loads the booking count off the main thread. Runs from `.task(id: previewKey)`, so a
    /// newer choice cancels this load; a cancelled or stale load never publishes.
    private func refreshPreview() async {
        let key = previewKey
        guard !key.accountIDs.isEmpty else {
            previewCount = 0
            return
        }
        previewCount = nil
        do {
            guard let bookings = try await loadBookings(accountIDs: key.accountIDs, bookingIDs: key.bookingIDs,
                                                        options: key.options)?.bookings,
                  !Task.isCancelled, key == previewKey else { return }
            let report = model.exportReport(bookings: bookings, accountIDs: key.accountIDs, period: period(for: key.options),
                                            bookingIDs: key.bookingIDs, options: key.options)
            previewCount = report.rows.count
        } catch {
            guard !Task.isCancelled else { return }
            previewCount = 0
        }
    }

    /// Period the core states for a CAMT.053 export (`nil` for other formats and
    /// marked bookings, where the rows set it). Also names the file, so name and
    /// OPBD/CLBD dates agree.
    private func camtRange(options: ExportOptions, accountIDs: [Int64], period: ExportPeriodPreset,
                           bookingIDs: Set<Int64>?) -> (from: String?, to: String?)? {
        guard options.format.isCamt, bookingIDs == nil else { return nil }
        let filter = model.exportFilter(accountIDs: accountIDs, period: period, options: options,
                                        ignoreListFilters: true)
        return (filter.dateFrom, BookingExportBuilder.camtEndDate(filter.dateTo))
    }

    /// Bookings for an export, off the main thread. CAMT.053 ignores the list's search,
    /// category and direction filters so its closing balance matches the bank's.
    /// `withBalances`: the CSV „Saldo“ column (#577); the preview count needs none.
    private func loadBookings(accountIDs: [Int64], bookingIDs: Set<Int64>?, options: ExportOptions,
                              withBalances: Bool = false) async throws -> (bookings: [Booking], balances: [Int64: Int64])? {
        try await model.loadExportPage(
            accountIDs: accountIDs.isEmpty ? nil : accountIDs,
            period: period(for: options),
            bookingIDs: bookingIDs, options: options, ignoreListFilters: options.format.isCamt,
            withBalances: withBalances)
    }

    @MainActor
    private func export() async {
        busy = true
        defer { busy = false }
        do {
            if isBulk {
                let files = try await buildFiles(accountIDs: effectiveAccountIDs)
                finish { model.presentExportFiles(files, format: options.format) }
            } else {
                guard let file = try await buildFileOptional(accountIDs: effectiveAccountIDs, bookingIDs: exportIDs,
                                                             options: options) else { throw ExportError.empty }
                finishAndPresent(file: file)
            }
        } catch is CancellationError {
            return
        } catch let CoreError.InvalidInput(message) {
            failure = message
        } catch {
            failure = describe(error)
        }
    }

    /// One file per account; accounts without bookings in the period are skipped.
    @MainActor
    private func buildFiles(accountIDs: [Int64]) async throws -> [(data: Data, filename: String)] {
        var files: [(data: Data, filename: String)] = []
        for id in accountIDs {
            if let file = try await buildFileOptional(accountIDs: [id], bookingIDs: nil, options: options) {
                files.append(file)
            }
        }
        guard !files.isEmpty else { throw ExportError.empty }
        return files
    }

    private func finishAndPresent(file: (data: Data, filename: String)) {
        finish { model.presentExportFile(data: file.data, format: options.format, filename: file.filename) }
    }

    /// Closes the sheet, then runs `present` (the save panel must not open over the sheet).
    private func finish(_ present: @escaping () -> Void) {
        model.exportBookingIDs = nil
        model.exportPreferSelection = false
        dismiss()
        DispatchQueue.main.async(execute: present)
    }

    @MainActor
    private func buildFileOptional(accountIDs: [Int64], bookingIDs: Set<Int64>?,
                                   options: ExportOptions) async throws -> (data: Data, filename: String)? {
        let period = period(for: options)
        // nil = vault locked or swapped while loading: nothing to export.
        guard let loaded = try await loadBookings(accountIDs: accountIDs, bookingIDs: bookingIDs, options: options,
                                                  withBalances: options.format == .csv && options.showRunningBalance) else {
            throw CancellationError()
        }
        guard !loaded.bookings.isEmpty else { return nil }
        var report = model.exportReport(bookings: loaded.bookings, accountIDs: accountIDs, period: period,
                                        bookingIDs: bookingIDs, options: options)
        report.runningBalances = loaded.balances
        report.generatedAt = Date()
        report.logoDataURI = nil
        report = BookingExportBuilder.prepareStatement(report)
        let print = options.asPrintOptions
        let needsDaily = options.format == .pdf || (options.showDailyBalance && !options.format.isCamt)
        if needsDaily, let earliest = report.rows.map(\.date).min() {
            let ids = Array(Set(report.rows.map(\.accountId))).sorted()
            guard let balances = try await model.loadDailyBalances(accountIds: ids, from: earliest) else {
                throw CancellationError()
            }
            report.dailyBalances = balances
        }
        let range = camtRange(options: options, accountIDs: accountIDs, period: period, bookingIDs: bookingIDs)
        let data: Data
        switch options.format {
        case .csv:
            data = Data(BookingExportBuilder.csv(report, options: options).utf8)
        case .camt053v08, .camt053v02:
            guard accountIDs.count == 1, let accountID = accountIDs.first else {
                throw ExportError.camtMultiAccount
            }
            // The core reads entries and booked balances from the vault. Marked
            // bookings export their own period; a period export uses the same
            // bounds as the list, without its search/category filters.
            let request = BookingExportBuilder.camtRequest(
                accountID: accountID, format: options.format,
                from: range?.from, to: range?.to, bookingIDs: bookingIDs)
            guard let xml = try await model.vaultOffMain({ try $0.camt053Export(request: request) }) else {
                throw CancellationError()
            }
            data = Data(xml.utf8)
        case .pdf:
            let html = PrintReportBuilder.html(report, options: print, paper: .a4)
            #if os(macOS) || os(iOS)
            data = try await HTMLPDFRenderer.shared.pdf(html: html, paper: .a4)
            #else
            throw ExportError.unsupported
            #endif
        }
        let name = BookingExportBuilder.defaultFilename(
            accounts: report.accounts, rows: report.rows, format: options.format,
            fallbackTitle: report.title, rangeFrom: range?.from, rangeTo: range?.to)
        return (data, name)
    }
}

private enum ExportError: LocalizedError {
    case unsupported
    case camtMultiAccount
    case empty
    var errorDescription: String? {
        switch self {
        case .unsupported:
            return String(localized: "PDF-Export ist auf dieser Plattform nicht verfügbar.")
        case .camtMultiAccount:
            return String(localized: "CAMT.053 nur für ein einzelnes Konto (#372).")
        case .empty:
            return String(localized: "Keine Umsätze für den Export.")
        }
    }
}

/// Account choice of the export sheet: searchable, grouped by bank, a bank's checkbox
/// toggles all its accounts. `singleChoice` (CAMT.053) picks exactly one account.
private struct ExportAccountPicker: View {
    let groups: [(bank: String, accounts: [Account])]
    @Binding var selectedIDs: Set<Int64>
    let singleChoice: Bool
    let isUsable: (Account) -> Bool
    @State private var search = ""

    private var shownGroups: [(bank: String, accounts: [Account])] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return groups }
        return groups.compactMap { g in
            let hits = g.bank.localizedCaseInsensitiveContains(q)
                ? g.accounts : g.accounts.filter { $0.matchesSidebarSearch(q) }
            return hits.isEmpty ? nil : (g.bank, hits)
        }
    }

    var body: some View {
        let allIDs = Set(groups.flatMap { $0.accounts.map(\.id) })
        VStack(spacing: 0) {
            if allIDs.count > 8 {
                TextField("Konto, Bank oder IBAN", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                Divider()
            }
            List {
                ForEach(shownGroups, id: \.bank) { group in
                    Section {
                        ForEach(group.accounts, id: \.id) { row($0) }
                    } header: {
                        if groups.count > 1 { bankHeader(group) }
                    }
                }
            }
            .listStyle(.plain)
            if !singleChoice {
                Divider()
                HStack {
                    Button("Alle") { selectedIDs = allIDs }
                        .disabled(selectedIDs == allIDs)
                    Button("Keine") { selectedIDs = [] }
                        .disabled(selectedIDs.isEmpty)
                    Spacer()
                    Text(String(localized: "\(selectedIDs.count) von \(allIDs.count) gewählt"))
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
        }
        .frame(width: 340, height: 380)
    }

    private func bankHeader(_ group: (bank: String, accounts: [Account])) -> some View {
        let ids = Set(group.accounts.filter(isUsable).map(\.id))
        let chosen = ids.intersection(selectedIDs)
        let allOn = !ids.isEmpty && chosen.count == ids.count
        return HStack(spacing: 8) {
            if !singleChoice {
                Button {
                    if allOn { selectedIDs.subtract(ids) } else { selectedIDs.formUnion(ids) }
                } label: {
                    Image(systemName: allOn ? "checkmark.square.fill" : (chosen.isEmpty ? "square" : "minus.square.fill"))
                        .foregroundStyle(chosen.isEmpty ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(allOn ? "Alle von \(group.bank) abwählen" : "Alle von \(group.bank) wählen"))
            }
            Text(group.bank).appFont(.subheadline, weight: .semibold)
        }
    }

    private func row(_ account: Account) -> some View {
        let on = selectedIDs.contains(account.id)
        let usable = isUsable(account)
        let caption = usable ? subtitle(account) : ""
        return Button {
            if singleChoice {
                selectedIDs = [account.id]
            } else {
                selectedIDs.formSymmetricDifference([account.id])
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: singleChoice
                      ? (on ? "largecircle.fill.circle" : "circle")
                      : (on ? "checkmark.square.fill" : "square"))
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name).lineLimit(1).sensitive()
                    if !usable {
                        Text("Nicht für Darlehen und Depots")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    } else if !caption.isEmpty {
                        Text(caption)
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .sensitive()
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func subtitle(_ account: Account) -> String {
        [account.owner, account.iban.isEmpty ? "" : formatIBAN(account.iban)]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
