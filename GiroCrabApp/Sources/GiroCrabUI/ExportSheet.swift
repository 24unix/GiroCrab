import SwiftUI
import GiroCrabCore

// MARK: - Umsätze exportieren (GitHub #53 / #372)
//
// Output mode → searchable account list (by bank) → period → format.
// PDF = white-label Umsatzliste; CAMT.053 needs exactly one account (#372).

struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var options = ExportOptions.load()
    @State private var busy = false
    /// Export error, shown on the sheet itself (the app's alert would stay hidden behind it).
    @State private var failure: String?
    @State private var showDetails = ExportOptions.load().hasNonDefaultContent
    /// Booking count and file name for the current choices, loaded off the main thread
    /// (`nil` while loading). Refreshed only when `previewKey` changes.
    @State private var previewCount: Int?
    @State private var previewName: String?
    @State private var accountSearch = ""
    @State private var selectedIDs: Set<Int64> = []
    /// Bank names that are collapsed (accounts hidden).
    @State private var collapsedBanks: Set<String> = []
    @State private var customFromDate = Date()
    @State private var customToDate = Date()

    private var selectionCount: Int {
        model.exportBookingIDs?.count
            ?? (model.isMultiSelection ? model.selectedBookingIDs.count : (model.selectedBookingID == nil ? 0 : 1))
    }

    private var canUseSelection: Bool { selectionCount > 0 }

    private var exportIDs: Set<Int64>? {
        guard options.scope == .selection else { return nil }
        return model.exportBookingIDs
            ?? (model.selectedBookingIDs.isEmpty
                ? model.selectedBookingID.map { [$0] }
                : model.selectedBookingIDs)
    }

    /// Accounts available in the current sidebar scope (Übersicht → all).
    private var poolAccounts: [Account] {
        let ids = model.exportScopeAccountIDs
        let pool = model.allAccounts.filter { !$0.isArchived }
        if ids.isEmpty { return pool }
        return pool.filter { ids.contains($0.id) }
    }

    private var filteredAccounts: [Account] {
        let q = accountSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = poolAccounts.sorted {
            if $0.bankName != $1.bankName {
                return $0.bankName.localizedCaseInsensitiveCompare($1.bankName) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.bankName.localizedCaseInsensitiveContains(q)
                || $0.iban.localizedCaseInsensitiveContains(q)
                || $0.owner.localizedCaseInsensitiveContains(q)
        }
    }

    private var accountsByBank: [(bank: String, accounts: [Account])] {
        let none = String(localized: "Ohne Bank")
        let grouped = Dictionary(grouping: filteredAccounts) { a in
            a.bankName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? none : a.bankName
        }
        return grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { bank in (bank, grouped[bank]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
    }

    private var selectedAccounts: [Account] {
        poolAccounts.filter { selectedIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Context-menu „Umsatz exportieren“ — lock to the marked bookings (no account/period chrome).
    private var isSelectionExport: Bool { model.exportPreferSelection }

    private var isBulk: Bool {
        showsOutputMode && options.accountOutput == .perAccount
    }

    /// „Jedes Konto einzeln“ only when multiple accounts can actually produce separate files.
    private var showsOutputMode: Bool {
        !isSelectionExport
            && !options.format.isCamt
            && options.scope != .selection
            && selectedAccounts.count > 1
    }

    /// A loan's balance is no sum of its own bookings, a depot has none: CAMT.053
    /// refuses both in the core, so the picker does too (#483).
    private func camtUsable(_ account: Account) -> Bool {
        account.kind != .loan && account.kind != .brokerage
    }

    private var camtAccountOK: Bool {
        guard options.format.isCamt else { return true }
        let ids = effectiveAccountIDs
        guard ids.count == 1, let id = ids.first, let account = model.account(for: id) else { return false }
        return camtUsable(account)
    }

    /// First account a CAMT.053 statement can cover.
    private var firstCamtAccount: Account? {
        selectedAccounts.first(where: camtUsable) ?? poolAccounts.first(where: camtUsable)
    }

    private var canExport: Bool {
        !busy && camtAccountOK && !effectiveAccountIDs.isEmpty
            && (isBulk || (previewCount ?? 0) > 0 || options.scope == .selection)
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
        let ids = exportIDs ?? []
        return Set(model.bookings.filter { ids.contains($0.id) }.map(\.accountId))
    }

    private var suggestedName: String {
        if isBulk {
            return String(localized: "\(selectedAccounts.count) × Umsaetze-….pdf")
        }
        return previewName ?? "…"
    }

    /// Everything the preview depends on; a change reloads it (`.task(id:)` cancels the old load).
    private struct PreviewKey: Equatable {
        var options: ExportOptions
        var accountIDs: [Int64]
        var bookingIDs: Set<Int64>?
    }

    private var previewKey: PreviewKey {
        PreviewKey(options: options, accountIDs: effectiveAccountIDs, bookingIDs: exportIDs)
    }

    private var exportPeriod: ExportPeriodPreset {
        options.scope == .selection ? .current : options.periodPreset
    }

    private var fallbackTitle: String {
        if options.scope == .selection {
            return selectionCount == 1
                ? String(localized: "Umsatz")
                : String(localized: "\(selectionCount) Umsaetze")
        }
        let n = effectiveAccountIDs.count
        if n == 1, let a = model.allAccounts.first(where: { $0.id == effectiveAccountIDs[0] }) { return a.name }
        return String(localized: "\(n) Konten")
    }

    private var saveTitle: String {
        if busy { return String(localized: "Wird erstellt …") }
        if isBulk {
            return String(localized: "Alle speichern (\(selectedAccounts.count))")
        }
        let count = previewCount.map { " (\($0))" } ?? ""
        switch options.format {
        case .pdf: return String(localized: "PDF speichern\(count)")
        case .csv: return String(localized: "CSV speichern\(count)")
        case .camt053v08, .camt053v02: return String(localized: "CAMT speichern\(count)")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isSelectionExport {
                    selectionSummarySection
                } else {
                    if showsOutputMode { outputModeSection }
                    if options.scope != .selection { accountPickerSection }
                    periodSection
                }
                formatSection
                if options.format == .pdf || options.format == .csv {
                    detailsSection
                }
                Section {
                    LabeledContent("Datei") {
                        Text(suggestedName)
                            .appFont(.caption, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("„Speichern“ legt direkt in Downloads ab. „Unter …“ fragt nach dem Ort.")
                        .leadingFooter()
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
                    HStack(spacing: 12) {
                        #if os(macOS)
                        if !isBulk {
                            Button("Unter …") { Task { await export(askWhere: true) } }
                                .disabled(!canExport || (previewCount == 0 && !isBulk))
                        }
                        #endif
                        Button(saveTitle) { Task { await export(askWhere: false) } }
                            .disabled(!canExport || (!isBulk && previewCount == 0))
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        #if os(macOS)
        .desktopFrame(
            minWidth: isSelectionExport ? 440 : 520,
            idealWidth: isSelectionExport ? 480 : 560,
            minHeight: isSelectionExport ? 380 : 620,
            idealHeight: isSelectionExport ? 460 : 720
        )
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
        .onChange(of: options) { _, _ in persistOptions() }
        .onChange(of: selectedIDs) { _, ids in
            guard !isSelectionExport else { return }
            options.selectedAccountIDs = Array(ids).sorted()
            persistOptions()
        }
        .onChange(of: canUseSelection) { _, ok in
            if !ok, !isSelectionExport { options.scope = .filtered }
        }
        .onChange(of: options.format) { _, format in
            if format.isCamt {
                options.accountOutput = .combined
                if !isSelectionExport, !camtAccountOK, let first = firstCamtAccount {
                    selectedIDs = [first.id]
                }
            }
        }
    }

    private var sheetTitle: String {
        if isSelectionExport, selectionCount <= 1 {
            return String(localized: "Umsatz exportieren")
        }
        return String(localized: "Umsätze exportieren")
    }

    /// Write current options to UserDefaults without mutating `@State` (avoids onChange loops).
    /// Selection-export keeps period/account prefs for the next menu/toolbar open.
    private func persistOptions() {
        var snapshot = options
        if isSelectionExport {
            let previous = ExportOptions.load()
            snapshot.scope = previous.scope == .selection ? .filtered : previous.scope
            snapshot.periodPreset = previous.periodPreset
            snapshot.customFrom = previous.customFrom
            snapshot.customTo = previous.customTo
            snapshot.selectedAccountIDs = previous.selectedAccountIDs
            snapshot.accountOutput = previous.accountOutput
            // Keep the saved format; the selection export may use it too.
            snapshot.format = previous.format
        } else {
            snapshot.selectedAccountIDs = Array(selectedIDs).sorted()
            if snapshot.scope == .selection { snapshot.scope = .filtered }
        }
        snapshot.save()
    }

    // MARK: - Sections

    private var selectionSummarySection: some View {
        Section {
            LabeledContent(
                selectionCount == 1
                    ? String(localized: "Dieser Umsatz")
                    : String(localized: "Auswahl"),
                value: selectionCount == 1
                    ? String(localized: "1 Buchung")
                    : String(localized: "\(selectionCount) Buchungen")
            )
        } footer: {
            Text("Nur die markierten Buchungen. Konten und Zeitraum brauchst du hier nicht.")
                .leadingFooter()
        }
    }

    private var outputModeSection: some View {
        Section {
            ForEach(ExportAccountOutput.allCases) { mode in
                choiceRow(title: mode.title, subtitle: mode.help, selected: options.accountOutput == mode) {
                    options.accountOutput = mode
                }
            }
        } header: {
            Text("Ausgabe").appSectionHeader()
        }
    }

    private var accountPickerSection: some View {
        Section {
            if poolAccounts.count > 8 {
                TextField("Konto, Bank oder IBAN", text: $accountSearch)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text(String(localized: "\(selectedIDs.count) von \(poolAccounts.count) gewählt"))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Alle") { selectedIDs = Set(poolAccounts.map(\.id)) }
                    .disabled(selectedIDs.count == poolAccounts.count)
                Button("Keine") { selectedIDs = [] }
                    .disabled(selectedIDs.isEmpty)
            }
            .buttonStyle(.borderless)

            HStack {
                Button(collapsedBanks.count == accountsByBank.count ? "Alle aufklappen" : "Alle zuklappen") {
                    if collapsedBanks.count == accountsByBank.count {
                        collapsedBanks = []
                    } else {
                        collapsedBanks = Set(accountsByBank.map(\.bank))
                    }
                }
                .buttonStyle(.borderless)
                .appFont(.caption)
                Spacer()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(accountsByBank, id: \.bank) { group in
                        bankHeader(group.bank, accounts: group.accounts)
                        if !collapsedBanks.contains(group.bank) {
                            ForEach(group.accounts, id: \.id) { account in
                                accountCheckRow(account)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: accountListHeight)
        } header: {
            Text("Konten").appSectionHeader()
        } footer: {
            Group {
                if options.format.isCamt {
                    Text("CAMT.053 gilt immer für genau ein Konto (#372).")
                } else if isBulk {
                    Text("Pro gewähltem Konto entsteht eine eigene Datei.")
                }
            }
            .leadingFooter()
        }
    }

    private var accountListHeight: CGFloat {
        let n = filteredAccounts.count
        if n <= 6 { return CGFloat(max(n, 1)) * 36 + CGFloat(accountsByBank.count) * 28 }
        return min(320, CGFloat(min(n, 12)) * 36 + 80)
    }

    private func bankHeader(_ bank: String, accounts: [Account]) -> some View {
        let ids = Set(accounts.map(\.id))
        let selected = ids.intersection(selectedIDs)
        let allOn = selected.count == ids.count
        let someOn = !selected.isEmpty && !allOn
        let expanded = !collapsedBanks.contains(bank)
        return HStack(spacing: 6) {
            Button {
                if expanded { collapsedBanks.insert(bank) }
                else { collapsedBanks.remove(bank) }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .center)
            }
            .buttonStyle(.plain)
            .help(expanded ? String(localized: "Zuklappen") : String(localized: "Aufklappen"))

            Button {
                if options.format.isCamt {
                    // A group without a CAMT-capable account: leave the choice alone.
                    if let one = accounts.first(where: camtUsable) { selectedIDs = [one.id] }
                } else if allOn {
                    selectedIDs.subtract(ids)
                } else {
                    selectedIDs.formUnion(ids)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: allOn ? "checkmark.square.fill" : (someOn ? "minus.square.fill" : "square"))
                        .foregroundStyle(allOn || someOn ? Color.accentColor : .secondary)
                    Text(bank)
                        .appFont(.subheadline, weight: .semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(selected.count)/\(accounts.count)")
                        .appFont(.caption, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(.background)
    }

    private func accountCheckRow(_ account: Account) -> some View {
        let on = selectedIDs.contains(account.id)
        let usable = !options.format.isCamt || camtUsable(account)
        return Button {
            guard usable else { return }
            if options.format.isCamt {
                selectedIDs = [account.id]
            } else if on {
                selectedIDs.remove(account.id)
            } else {
                selectedIDs.insert(account.id)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name)
                        .foregroundStyle(usable ? .primary : .secondary)
                        .lineLimit(1)
                    if options.format.isCamt, !camtUsable(account) {
                        Text("Nicht für Darlehen und Depots")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        let sub = accountSubtitle(account)
                        if !sub.isEmpty {
                            Text(sub)
                                .appFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.vertical, 5)
            .padding(.leading, 22)
            .padding(.trailing, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func accountSubtitle(_ account: Account) -> String {
        var parts: [String] = []
        if !account.owner.isEmpty { parts.append(account.owner) }
        if !account.iban.isEmpty { parts.append(formatIBAN(account.iban)) }
        return parts.joined(separator: " · ")
    }

    private var periodSection: some View {
        Section {
            if canUseSelection {
                choiceRow(
                    title: selectionCount > 1
                        ? String(localized: "Auswahl (\(selectionCount))")
                        : String(localized: "Dieser Umsatz"),
                    subtitle: String(localized: "Nur die markierten Buchungen"),
                    selected: options.scope == .selection
                ) {
                    options.scope = .selection
                }
            }
            ForEach(ExportPeriodPreset.menuCases) { preset in
                choiceRow(
                    title: preset.title,
                    subtitle: periodSubtitle(preset),
                    selected: options.scope == .filtered && options.periodPreset == preset
                ) {
                    options.scope = .filtered
                    options.periodPreset = preset
                    if preset == .custom { syncCustomDatesFromOptions() }
                }
            }
            if options.scope == .filtered, options.periodPreset == .custom {
                DatePicker("Von", selection: $customFromDate, in: ...customToDate, displayedComponents: .date)
                DatePicker("Bis", selection: $customToDate, in: customFromDate..., displayedComponents: .date)
            }
        } header: {
            Text("Zeitraum").appSectionHeader()
        }
        .onChange(of: customFromDate) { _, d in
            options.customFrom = DateText.iso(d)
            persistOptions()
        }
        .onChange(of: customToDate) { _, d in
            options.customTo = DateText.iso(d)
            persistOptions()
        }
    }

    private func periodSubtitle(_ preset: ExportPeriodPreset) -> String? {
        switch preset {
        case .current: return model.periodTitle
        case .custom:
            if options.customFrom.isEmpty { return String(localized: "Von–Bis wählen") }
            return "\(PrintReportBuilder.statementDate(options.customFrom)) – \(PrintReportBuilder.statementDate(options.customTo))"
        case .sinceSalary:
            if let c = model.salaryCycle {
                return String(localized: "Seit \(PrintReportBuilder.statementDate(c.lastDate))")
            }
            return String(localized: "Kein Gehalt erkannt")
        default: return nil
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

    private var formatSection: some View {
        Section {
            ForEach(BookingExportFormat.allCases) { format in
                choiceRow(title: format.title, subtitle: format.subtitle, selected: options.format == format) {
                    options.format = format
                }
            }
        } header: {
            Text("Format").appSectionHeader()
        } footer: {
            if options.format.isCamt, !camtAccountOK {
                if effectiveAccountIDs.count == 1, let id = effectiveAccountIDs.first,
                   let account = model.account(for: id), !camtUsable(account) {
                    Text("Für Darlehen und Depots gibt es keinen CAMT.053-Auszug.")
                        .leadingFooter()
                } else {
                    Text("CAMT.053 gilt immer für genau ein Konto (#372).")
                        .leadingFooter()
                }
            } else if options.scope == .selection, options.format.isCamt {
                Text("CAMT.053 für markierte Buchungen enthält deren Zeitraum mit den echten Salden des Kontos.")
                    .leadingFooter()
            }
        }
    }

    private var detailsSection: some View {
        Section {
            Toggle("Kategorie", isOn: $options.showCategory)
            Toggle("Notizen", isOn: $options.showNote)
            DisclosureGroup(isExpanded: $showDetails) {
                Toggle("Tagessaldo-Spalte", isOn: $options.showDailyBalance)
                Toggle("Nach Konto gruppieren", isOn: $options.groupByAccount)
                Toggle("Nur erste Zeile Verwendungszweck", isOn: $options.firstLineOnly)
                Picker("Reihenfolge", selection: $options.newestFirst) {
                    Text("Älteste zuerst").tag(false)
                    Text("Neueste zuerst").tag(true)
                }
            } label: {
                Text("Weitere Optionen")
            }
        } footer: {
            if options.format == .pdf {
                Text("Einstellungen bleiben gespeichert. Anfangssaldo und Endsaldo stehen immer im Kopf.")
                    .leadingFooter()
            }
        }
    }

    private func choiceRow(title: String, subtitle: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).appFont(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.accentColor : .clear)
                    .accessibilityHidden(!selected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Lifecycle

    private func bootstrap() {
        if isSelectionExport {
            // Context menu: only the marked bookings — ignore saved period/account prefs.
            options.scope = .selection
            let bookingAccounts = accountIDsForSelectedBookings
            selectedIDs = bookingAccounts.isEmpty ? Set(poolAccounts.map(\.id)) : bookingAccounts
        } else {
            // Menu / toolbar / account: full period export (never reopen stuck on „Dieser Umsatz“).
            options.scope = .filtered
            let pool = Set(poolAccounts.map(\.id))
            var ids = Set(options.selectedAccountIDs).intersection(pool)
            if ids.isEmpty {
                if model.exportScopeAccountIDs.count == 1 {
                    ids = Set(model.exportScopeAccountIDs)
                } else {
                    ids = pool
                }
            }
            if options.format.isCamt, ids.count != 1 {
                ids = firstCamtAccount.map { [$0.id] } ?? []
            } else if options.format.isCamt, let one = ids.first,
                      let account = model.account(for: one), !camtUsable(account) {
                ids = firstCamtAccount.map { [$0.id] } ?? []
            }
            selectedIDs = ids
            options.selectedAccountIDs = Array(ids).sorted()
            if accountsByBank.count > 4 {
                collapsedBanks = Set(accountsByBank.map(\.bank))
            }
            if options.periodPreset == .custom { syncCustomDatesFromOptions() }
        }
    }

    /// Loads count + file name off the main thread. Runs from `.task(id: previewKey)`, so a
    /// newer choice cancels this load; a cancelled or stale load never publishes.
    private func refreshPreview() async {
        let key = previewKey
        guard !key.accountIDs.isEmpty || options.scope == .selection else {
            previewCount = 0
            previewName = nil
            return
        }
        previewCount = nil
        do {
            guard let bookings = try await loadBookings(accountIDs: key.accountIDs, bookingIDs: key.bookingIDs,
                                                        options: key.options),
                  !Task.isCancelled, key == previewKey else { return }
            let report = model.exportReport(bookings: bookings, accountIDs: key.accountIDs, period: exportPeriod,
                                            bookingIDs: key.bookingIDs, options: key.options)
            previewCount = report.rows.count
            let range = camtRange(options: key.options, accountIDs: key.accountIDs,
                                  period: exportPeriod, bookingIDs: key.bookingIDs)
            previewName = BookingExportBuilder.defaultFilename(
                accounts: report.accounts, rows: report.rows, format: key.options.format,
                fallbackTitle: fallbackTitle, rangeFrom: range?.from, rangeTo: range?.to)
        } catch {
            guard !Task.isCancelled else { return }
            previewCount = 0
            previewName = nil
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
    private func loadBookings(accountIDs: [Int64], bookingIDs: Set<Int64>?,
                              options: ExportOptions) async throws -> [Booking]? {
        try await model.loadExportBookings(
            accountIDs: accountIDs.isEmpty ? nil : accountIDs,
            period: options.scope == .selection ? .current : options.periodPreset,
            bookingIDs: bookingIDs, options: options, ignoreListFilters: options.format.isCamt)
    }

    @MainActor
    private func export(askWhere: Bool) async {
        busy = true
        defer { busy = false }
        let ids = effectiveAccountIDs
        guard !ids.isEmpty || options.scope == .selection else {
            failure = String(localized: "Bitte mindestens ein Konto wählen.")
            return
        }
        if isBulk {
            await exportBulk(accountIDs: ids)
            return
        }
        do {
            let file = try await buildFile(
                accountIDs: ids.isEmpty ? Array(poolAccounts.map(\.id)) : ids,
                bookingIDs: exportIDs,
                options: options
            )
            finishAndPresent(file: file, askWhere: askWhere)
        } catch is CancellationError {
            return
        } catch let CoreError.InvalidInput(message) {
            failure = message
        } catch {
            failure = describe(error)
        }
    }

    @MainActor
    private func exportBulk(accountIDs: [Int64]) async {
        var files: [(data: Data, filename: String)] = []
        do {
            for id in accountIDs {
                if let file = try await buildFileOptional(accountIDs: [id], bookingIDs: nil, options: options) {
                    files.append(file)
                }
            }
        } catch is CancellationError {
            return
        } catch let CoreError.InvalidInput(message) {
            failure = message
        } catch {
            failure = describe(error)
            return
        }
        guard !files.isEmpty else {
            failure = String(localized: "Keine Umsätze für den Export.")
            return
        }
        model.exportBookingIDs = nil
        model.exportPreferSelection = false
        dismiss()
        DispatchQueue.main.async {
            model.presentExportFiles(files)
        }
    }

    private func finishAndPresent(file: (data: Data, filename: String), askWhere: Bool) {
        model.exportBookingIDs = nil
        model.exportPreferSelection = false
        dismiss()
        DispatchQueue.main.async {
            model.presentExportFile(data: file.data, format: options.format, filename: file.filename, askWhere: askWhere)
        }
    }

    @MainActor
    private func buildFile(accountIDs: [Int64], bookingIDs: Set<Int64>?,
                           options: ExportOptions) async throws -> (data: Data, filename: String) {
        guard let file = try await buildFileOptional(accountIDs: accountIDs, bookingIDs: bookingIDs, options: options) else {
            throw ExportError.empty
        }
        return file
    }

    @MainActor
    private func buildFileOptional(accountIDs: [Int64], bookingIDs: Set<Int64>?,
                                   options: ExportOptions) async throws -> (data: Data, filename: String)? {
        let period = options.scope == .selection ? ExportPeriodPreset.current : options.periodPreset
        // nil = vault locked or swapped while loading: nothing to export.
        guard let bookings = try await loadBookings(accountIDs: accountIDs, bookingIDs: bookingIDs, options: options) else {
            throw CancellationError()
        }
        guard !bookings.isEmpty else { return nil }
        var report = model.exportReport(bookings: bookings, accountIDs: accountIDs, period: period,
                                        bookingIDs: bookingIDs, options: options)
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
            let range = camtRange(options: options, accountIDs: accountIDs, period: period,
                                  bookingIDs: bookingIDs)
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
        let range = camtRange(options: options, accountIDs: accountIDs, period: period,
                              bookingIDs: bookingIDs)
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
