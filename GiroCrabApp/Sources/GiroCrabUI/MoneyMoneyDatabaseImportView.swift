#if os(macOS)
import AppKit
import SwiftUI
import GiroCrabCore

/// MoneyMoney database import: pick `MoneyMoney.sqlite`, enter the MoneyMoney
/// password, preview, then import all accounts in one go. The database is only
/// read (never changed); the password is dropped from the view state afterwards.
struct MoneyMoneyDatabaseImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    struct Choice: Equatable {
        var selected: Bool
        var kind: AccountKind
        /// nil = "Neues Konto"
        var target: Int64?
    }

    @State private var fileURL: URL?
    @State private var password = ""
    @State private var preview: MoneyMoneyDbPreview?
    @State private var choices: [Int64: Choice] = [:]
    @State private var importCategories = true
    @State private var importNotes = true
    @State private var importGroups = true
    @State private var createConnections = true
    @State private var importPins = false
    @State private var loading = false
    @State private var importing = false
    @State private var error: String?
    @State private var result: MoneyMoneyDbImportResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result {
                resultCard(result)
            } else {
                info
                fileAndPassword
                if loading { ProgressView().controlSize(.small) }
                if let preview {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            totals(preview)
                            accountList(preview)
                            HStack(alignment: .top, spacing: 14) {
                                bankList(preview)
                                optionsCard(preview).frame(width: 330)
                            }
                        }
                        .padding(.trailing, 6)
                    }
                    .frame(height: 560)
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.warning) }
            footer
        }
        .interactiveDismissDisabled(importing)
        .onAppear {
            if let demo = model.demoDbPreview {
                fileURL = URL(fileURLWithPath: "/Users/max/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Database/MoneyMoney.sqlite")
                password = "demo-passwort"
                apply(demo)
            }
        }
        .onDisappear { password = "" }
    }

    // MARK: - Pieces

    private var info: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(Theme.accent)
            Text("MoneyMoney speichert alles in einer mit Ihrem MoneyMoney-Passwort verschlüsselten Datenbank. GiroCrab öffnet sie nur lesend – die Datei und MoneyMoney bleiben unverändert.")
                .font(.caption).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.canvas))
    }

    private var fileAndPassword: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Datenbank").font(.callout).foregroundStyle(Theme.secondary)
                HStack {
                    Text(fileURL?.lastPathComponent ?? String(localized: "MoneyMoney.sqlite auswählen …"))
                        .font(.callout.weight(fileURL == nil ? .regular : .medium))
                        .foregroundStyle(fileURL == nil ? Theme.secondary : Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(fileURL == nil ? "Auswählen …" : "Andere Datei …") { pickFile() }.controlSize(.small)
                }
            }
            GridRow {
                Text("Passwort").font(.callout).foregroundStyle(Theme.secondary)
                HStack {
                    SecureField("MoneyMoney-Passwort (leer, wenn unverschlüsselt)", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { loadPreview() }
                    Button("Vorschau") { loadPreview() }
                        .disabled(fileURL == nil || loading || importing)
                }
            }
        }
    }

    private func totals(_ p: MoneyMoneyDbPreview) -> some View {
        let span = [p.dateRangeStart, p.dateRangeEnd].compactMap { $0.map { String($0.prefix(4)) } }
        let years = span.count == 2 ? (span[0] == span[1] ? span[0] : "\(span[0]) – \(span[1])") : "–"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                stat(years, "Zeitraum")
                stat("\(p.accounts.count)", "Konten")
                stat(p.totalBookings.formatted(), "Buchungen")
                stat("\(p.notesCount)", "Notizen")
                stat("\(p.categoryPaths.count)", "Kategorien")
            }
            if p.pendingBookings > 0 {
                Text("\(p.pendingBookings) vorgemerkte Buchungen werden nicht übernommen – die Bank liefert sie nach der Buchung erneut.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }

    private func accountList(_ p: MoneyMoneyDbPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Konten").font(.subheadline.weight(.semibold)).padding(.bottom, 6)
            ForEach(Array(p.accounts.enumerated()), id: \.element.mmId) { i, a in
                if i > 0 { Divider() }
                accountRow(a)
            }
        }
        .card(padding: 12)
    }

    private func accountRow(_ a: MoneyMoneyDbAccount) -> some View {
        let choice = binding(a)
        return HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: choice.selected).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(accountSubtitle(a)).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                Text(bookingSummary(a)).font(.caption2).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.format(a.computedBalanceCents, currency: a.currency))
                    .font(.callout.monospacedDigit()).foregroundStyle(Theme.text)
                Text("Saldo").font(.caption2).foregroundStyle(Theme.tertiary)
            }
            .help(a.balanceSource)
            .frame(width: 110, alignment: .trailing)
            Picker("", selection: choice.kind) {
                ForEach(AccountKind.importChoices, id: \.self) { k in Text(k.label).tag(k) }
            }
            .labelsHidden().frame(width: 150)
            Picker("", selection: choice.target) {
                Text("Neues Konto").tag(Int64?.none)
                ForEach(model.allAccounts) { acc in
                    Text(acc.id == a.existingAccountId ? String(localized: "\(acc.name) (gleiche IBAN)") : acc.name).tag(Int64?.some(acc.id))
                }
                if let id = a.existingAccountId, !model.allAccounts.contains(where: { $0.id == id }) {
                    Text(a.existingAccountName ?? String(localized: "Vorhandenes Konto")).tag(Int64?.some(id))
                }
            }
            .labelsHidden().frame(width: 190)
        }
        .padding(.vertical, 6)
        .opacity(choice.wrappedValue.selected ? 1 : 0.5)
    }

    private func bankList(_ p: MoneyMoneyDbPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Bankzugänge").font(.subheadline.weight(.semibold)).padding(.bottom, 6)
            ForEach(Array(p.banks.enumerated()), id: \.element.mmId) { i, b in
                if i > 0 { Divider() }
                HStack(spacing: 10) {
                    Image(systemName: b.connector == nil ? "xmark.circle" : "checkmark.circle.fill")
                        .foregroundStyle(b.connector == nil ? Theme.tertiary : Theme.inflow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.name.isEmpty ? (b.connector?.displayName ?? "Bank") : b.name).font(.callout.weight(.medium))
                        Text([b.bankCode.isEmpty ? nil : String(localized: "BLZ \(b.bankCode)"), b.loginName.isEmpty ? nil : String(localized: "Anmeldename \(b.loginName)")]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if b.hasSavedPin {
                        Image(systemName: "key").font(.caption).foregroundStyle(Theme.secondary).help("In MoneyMoney ist eine PIN gespeichert")
                    }
                    Text(bankStatus(b)).font(.caption).foregroundStyle(b.connector == nil ? Theme.tertiary : Theme.text)
                        .frame(width: 110, alignment: .trailing)
                }
                .padding(.vertical, 6)
            }
        }
        .card(padding: 12)
    }

    private func optionsCard(_ p: MoneyMoneyDbPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Kategorien übernehmen (\(p.categoryPaths.count))", isOn: $importCategories)
            if p.replacesStarterCategories && importCategories {
                Text("Ersetzt die GiroCrab-Startkategorien und ihre Regeln – Ihr Tresor enthält noch keine Buchungen.")
                    .font(.caption).foregroundStyle(Theme.secondary).padding(.leading, 2)
            }
            Toggle("Notizen übernehmen (\(p.notesCount))", isOn: $importNotes)
            let groupCount = Set(p.accounts.map(\.groupName).filter { !$0.isEmpty }).count
            if groupCount > 0 {
                Toggle("Kontogruppen übernehmen (\(groupCount))", isOn: $importGroups)
            }
            Toggle("Bankzugänge anlegen", isOn: $createConnections)
            Toggle("Gespeicherte PINs übernehmen", isOn: $importPins)
                .disabled(!createConnections)
            Text("Die PINs werden dann im verschlüsselten GiroCrab-Tresor gespeichert. Ohne diese Option werden sie nicht einmal gelesen.")
                .font(.caption).foregroundStyle(Theme.secondary).padding(.leading, 2)
        }
        .toggleStyle(.switch).controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }

    private func resultCard(_ r: MoneyMoneyDbImportResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Import abgeschlossen", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Theme.inflow)
            HStack(spacing: 18) {
                stat("\(r.accountsCreated)", "Konten neu")
                stat("\(r.accountsMerged)", "Konten ergänzt")
                stat(r.bookingsNew.formatted(), "neue Buchungen")
                stat("\(r.bookingsDuplicates)", "bereits vorhanden")
            }
            Group {
                if r.documentsImported > 0 {
                    Text("\(r.documentsImported) Kontoauszüge (PDF) übernommen.")
                }
                if r.holdingsImported > 0 {
                    Text("\(r.holdingsImported) Depotpositionen übernommen.")
                }
                if r.categoriesCreated > 0 || r.notesImported > 0 {
                    Text("\(r.categoriesCreated) Kategorien angelegt, \(r.notesImported) Notizen übernommen.")
                }
                if r.rulesCreated > 0 {
                    Text("\(r.rulesCreated) Regeln übernommen.")
                }
                if r.rulesDisabled > 0 {
                    Text("\(r.rulesDisabled) davon ausgeschaltet – sie nutzen Angaben, die GiroCrab nicht kennt, gelten nur für bestimmte Konten oder sind fehlerhaft.")
                }
                if r.connectionsCreated > 0 || r.connectionsExisting > 0 {
                    Text(String(localized: "\(r.connectionsCreated) Bankzugänge angelegt")
                        + (r.connectionsExisting > 0 ? String(localized: ", \(r.connectionsExisting) bereits vorhanden") : "")
                        + (r.pinsStored > 0 ? String(localized: ", \(r.pinsStored) PINs im Tresor gespeichert.") : "."))
                }
                if r.banksSkippedUnsupported > 0 {
                    Text("\(r.banksSkippedUnsupported) Bankzugänge werden von GiroCrab noch nicht unterstützt und wurden übersprungen.")
                }
                if r.pendingSkipped > 0 {
                    Text("\(r.pendingSkipped) vorgemerkte Buchungen wurden nicht übernommen.")
                }
            }
            .font(.caption).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var footer: some View {
        HStack {
            Spacer()
            if result != nil {
                Button("Fertig") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button("Abbrechen") { password = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button(importing ? "Importiere …" : "Importieren") { runImport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview == nil || importing || !choices.values.contains(where: \.selected))
            }
        }
    }

    private func stat(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.text)
            Text(label).font(.caption2).foregroundStyle(Theme.secondary)
        }
    }

    // MARK: - Helpers

    private func binding(_ a: MoneyMoneyDbAccount) -> Binding<Choice> {
        Binding(
            get: { choices[a.mmId] ?? Choice(selected: true, kind: a.suggestedKind, target: a.existingAccountId) },
            set: { choices[a.mmId] = $0 }
        )
    }

    private func accountSubtitle(_ a: MoneyMoneyDbAccount) -> String {
        var parts: [String] = []
        if !a.bankName.isEmpty { parts.append(a.bankName) }
        if !a.iban.isEmpty { parts.append(TransferSheetView.groupedIBAN(a.iban)) } else if !a.accountNumber.isEmpty { parts.append(String(localized: "Konto \(a.accountNumber)")) }
        if a.currency != "EUR" { parts.append(a.currency) }
        if !a.groupName.isEmpty { parts.append(String(localized: "Gruppe „\(a.groupName)“")) }
        return parts.joined(separator: " · ")
    }

    private func bookingSummary(_ a: MoneyMoneyDbAccount) -> String {
        let n = a.bookingCount.formatted()
        var s = String(localized: "\(n) Buchungen")
        if let f = a.firstDate, let l = a.lastDate { s += " · \(DateText.medium(f)) – \(DateText.medium(l))" }
        if a.pendingCount > 0 { s += " · " + String(localized: "\(a.pendingCount) vorgemerkt") }
        if a.holdingCount > 0 { s += " · " + String(localized: "\(a.holdingCount) Depotpositionen") }
        return s
    }

    private func bankStatus(_ b: MoneyMoneyDbBank) -> String {
        guard b.connector != nil else { return String(localized: "nicht unterstützt") }
        if b.existingConnectionId != nil { return String(localized: "bereits vorhanden") }
        return createConnections ? String(localized: "wird angelegt") : String(localized: "wird nicht angelegt")
    }

    private func apply(_ p: MoneyMoneyDbPreview) {
        preview = p
        var c: [Int64: Choice] = [:]
        for a in p.accounts {
            c[a.mmId] = choices[a.mmId] ?? Choice(selected: true, kind: a.suggestedKind, target: a.existingAccountId)
        }
        choices = c
    }

    // MARK: - Actions

    private func pickFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "MoneyMoney-Datenbank auswählen (MoneyMoney.sqlite)")
        panel.prompt = String(localized: "Auswählen")
        panel.treatsFilePackagesAsDirectories = true
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Database")
        if FileManager.default.fileExists(atPath: dir.path) { panel.directoryURL = dir }
        if panel.runModal() == .OK, let url = panel.url {
            fileURL = url
            preview = nil
            choices = [:]
            error = nil
        }
        #endif
    }

    private func loadPreview() {
        guard let vault = model.vault, let url = fileURL else { return }
        let pw = password
        loading = true; error = nil
        Task {
            let result = await Task.detached { () -> Result<MoneyMoneyDbPreview, Error> in
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                return Result { try vault.previewMoneymoneyDatabase(path: url.path, password: pw) }
            }.value
            loading = false
            switch result {
            case .success(let p): apply(p)
            case .failure(let e):
                preview = nil
                if case CoreError.Authentication(let m) = e { error = m } else { error = describe(e) }
            }
        }
    }

    private func runImport() {
        guard let vault = model.vault, let url = fileURL, let preview else { return }
        if model.demoDbPreview != nil {
            // demo: nothing to read – show what the summary looks like
            result = MoneyMoneyDbImportResult(accountsCreated: 5, accountsMerged: 1, groupsCreated: 2, bookingsNew: preview.totalBookings, bookingsDuplicates: 0, bookingsEnriched: 0, pendingSkipped: preview.pendingBookings, notesImported: preview.notesCount, categoriesCreated: UInt32(preview.categoryPaths.count), connectionsCreated: 3, connectionsExisting: 0, pinsStored: 0, banksSkippedUnsupported: 1, documentsImported: 0, holdingsImported: 0, rulesCreated: 0, rulesDisabled: 0)
            password = ""
            return
        }
        let options = MoneyMoneyDbImportOptions(
            accounts: preview.accounts.map { a in
                let c = choices[a.mmId] ?? Choice(selected: true, kind: a.suggestedKind, target: a.existingAccountId)
                return MoneyMoneyDbAccountChoice(mmId: a.mmId, import: c.selected, kind: c.kind, targetAccountId: c.target)
            },
            importCategories: importCategories,
            importNotes: importNotes,
            createConnections: createConnections,
            importPins: createConnections && importPins,
            importGroups: importGroups)
        let pw = password
        importing = true; error = nil
        Task {
            let result = await Task.detached { () -> Result<MoneyMoneyDbImportResult, Error> in
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                return Result { try vault.importMoneymoneyDatabase(path: url.path, password: pw, options: options) }
            }.value
            importing = false
            password = ""
            switch result {
            case .success(let r):
                self.result = r
                model.finishMoneyMoneyDbImport(r)
            case .failure(let e):
                if case CoreError.Authentication(let m) = e { error = m } else { error = describe(e) }
            }
        }
    }
}

extension AccountKind {
    static let importChoices: [AccountKind] = [.checking, .savings, .creditCard, .paymentService, .brokerage, .cash, .loan]

    var label: String {
        switch self {
        case .checking: return String(localized: "Girokonto")
        case .savings: return String(localized: "Tagesgeld / Sparen")
        case .creditCard: return String(localized: "Kreditkarte")
        case .paymentService: return String(localized: "Zahlungsdienst")
        case .brokerage: return String(localized: "Depot")
        case .cash: return String(localized: "Bargeld")
        case .loan: return String(localized: "Darlehen")
        }
    }
}

extension AppModel {
    func finishMoneyMoneyDbImport(_ r: MoneyMoneyDbImportResult) {
        reloadAll()
        toast = String(localized: "MoneyMoney: \(r.bookingsNew) Buchungen in \(r.accountsCreated + r.accountsMerged) Konten importiert")
            + (r.bookingsDuplicates > 0 ? String(localized: ", \(r.bookingsDuplicates) bereits vorhanden") : "")
    }
}

extension AppModel {
    /// Invented MoneyMoney database (public example IBANs, fictional names) for
    /// `--demo-sheet moneymoney-db` screenshots.
    static func demoMoneyMoneyDbPreview(existingGiro: Account?) -> MoneyMoneyDbPreview {
        func acc(_ id: Int64, _ name: String, _ bank: String, _ code: String, iban: String = "", number: String = "", currency: String = "EUR",
                 kind: AccountKind, portfolio: Bool = false, existing: Account? = nil, count: UInt32, pending: UInt32 = 0,
                 from: String?, to: String?, balance: Int64, group: String = "Privat") -> MoneyMoneyDbAccount {
            MoneyMoneyDbAccount(mmId: id, name: name, iban: iban, accountNumber: number, currency: currency, bankCode: code, bankName: bank,
                                owner: "Max Mustermann", groupName: group, mmBankId: nil, isPortfolio: portfolio, suggestedKind: kind,
                                existingAccountId: existing?.id, existingAccountName: existing?.name, bookingCount: count, pendingCount: pending, holdingCount: portfolio ? 3 : 0,
                                notesCount: 0, firstDate: from, lastDate: to, computedBalanceCents: balance,
                                balanceSource: "Anfangssaldo laut MoneyMoney-Saldenverlauf + Umsätze")
        }
        let accounts = [
            acc(1, "Girokonto", "comdirect", "20041111", iban: "DE89370400440532013000", kind: .checking, existing: existingGiro,
                count: 4812, pending: 3, from: "2009-04-01", to: "2026-11-09", balance: 3_245_18),
            acc(2, "Visa-Karte", "comdirect", "20041111", number: "4871 •••• 1234", kind: .creditCard, count: 1204, pending: 2,
                from: "2011-02-14", to: "2026-11-08", balance: -412_90),
            acc(3, "Tagesgeld", "1822direkt", "50050201", iban: "DE02120300000000202051", kind: .savings, count: 96,
                from: "2014-06-30", to: "2026-10-31", balance: 12_500_00, group: "Sparen"),
            acc(4, "Depot", "comdirect", "20041111", number: "123456789", kind: .brokerage, portfolio: true, count: 0,
                from: nil, to: nil, balance: 0, group: "Sparen"),
            acc(5, "PayPal", "PayPal", "", number: "max@example.com", kind: .paymentService, count: 640,
                from: "2013-08-02", to: "2026-11-05", balance: 23_45),
            acc(6, "Reisekasse USD", "Musterbank", "12345678", number: "1000200", currency: "USD", kind: .checking, count: 38,
                from: "2019-07-10", to: "2025-09-22", balance: 310_75, group: ""),
        ]
        let banks = [
            MoneyMoneyDbBank(mmId: 1, bankCode: "20041111", name: "comdirect", loginName: "12345678", customerId: "12345678",
                             connector: .comdirect, hasSavedPin: true, existingConnectionId: nil, accountCount: 3),
            MoneyMoneyDbBank(mmId: 2, bankCode: "50050201", name: "1822direkt", loginName: "max.mustermann", customerId: "",
                             connector: .direkt1822, hasSavedPin: true, existingConnectionId: nil, accountCount: 1),
            MoneyMoneyDbBank(mmId: 3, bankCode: "", name: "PayPal", loginName: "max@example.com", customerId: "",
                             connector: .payPal, hasSavedPin: false, existingConnectionId: nil, accountCount: 1),
            MoneyMoneyDbBank(mmId: 4, bankCode: "12345678", name: "Musterbank", loginName: "mustermann", customerId: "",
                             connector: nil, hasSavedPin: false, existingConnectionId: nil, accountCount: 1),
        ]
        let categories = ["Gehalt", "Haushalt › Lebensmittel", "Haushalt › Drogerie", "Wohnen › Miete", "Wohnen › Nebenkosten › Strom",
                          "Mobilität › Tanken", "Mobilität › ÖPNV", "Freizeit › Restaurants", "Freizeit › Sport", "Versicherungen",
                          "Steuern", "Reisen", "Abos", "Gesundheit", "Geschenke", "Sparen"]
        return MoneyMoneyDbPreview(accounts: accounts, banks: banks, categoryPaths: categories, totalBookings: 6790,
                                   pendingBookings: 5, notesCount: 312, splitParts: 14,
                                   dateRangeStart: "2009-04-01", dateRangeEnd: "2026-11-09", replacesStarterCategories: true)
    }
}

#endif
