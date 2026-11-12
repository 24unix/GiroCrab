import SwiftUI
import GiroCrabCore

/// "Bank hinzufügen": one search field for every way GiroCrab can reach a
/// bank – FinTS 3.0 (direct), a bank's own API, or PSD2 via Enable Banking.
/// Type a bank name ("Sparkasse", "N26", "bunq" …), an 8-digit BLZ or a German
/// IBAN; results are grouped by how they connect.
struct AddBankSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                BankAddView(onAdded: { dismiss() })
            }
            .formStyle(.grouped)
            .navigationTitle("Bank hinzufügen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
        #endif
        .onAppear { model.loadLivePsd2Banks() }
    }
}

/// Form rows: search field, grouped results, and the form for the chosen bank.
struct BankAddView: View {
    @Environment(AppModel.self) private var model
    var onAdded: () -> Void = {}

    @State private var query = ""
    @State private var selected: BankSearchResult?

    private static let suggestions = ["Sparkasse", "Volksbank", "ING", "DKB", "Postbank", "N26", "Revolut", "C24", "bunq", "Trade Republic", "Scalable Capital", "PayPal"]

    private var results: [BankSearchResult] {
        searchBanks(query: query, livePsd2: model.livePsd2Banks, perGroupLimit: 12)
    }

    var body: some View {
        Section {
            if let sel = selected {
                selectedRow(sel)
            } else {
                demoBankButton
                searchField
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    suggestionRow
                } else {
                    resultList
                }
            }
        }
        if let sel = selected {
            detail(sel)
        }
    }

    // MARK: Search

    private var searchField: some View {
        #if os(macOS)
        // The system search field (magnifier, clear button, Esc clears).
        SystemSearchField(text: $query, prompt: String(localized: "Bank, BLZ oder IBAN suchen …"))
        #else
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Bank, BLZ oder IBAN suchen …", text: $query)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: { Label("Suche löschen", systemImage: "xmark.circle.fill") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        #endif
    }

    private var suggestionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("z. B. Sparkasse, ING, N26, Revolut, bunq – oder die 8-stellige BLZ / Ihre IBAN")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.suggestions, id: \.self) { s in
                        Button(s) { query = s }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            manualFinTsButton
        }
    }

    /// "Demo-Bank (Test & Vorschau)": simulated bank, login `demo`, PIN 12345, any TAN.
    private var demoBankButton: some View {
        Button {
            model.addDemoBank()
            onAdded()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label("Demo-Bank hinzufügen (Test & Vorschau)", systemImage: "play.circle")
                Text("Kennung: demo, PIN: 12345, beliebige TAN – ohne echte Bank und ohne Netzwerk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderedProminent)
    }

    private var manualFinTsButton: some View {
        Button {
            selected = BankSearchResult(id: "fints:custom", name: "", mode: .finTs, country: "DE", blz: "", url: "", connector: nil, aspsp: "", tested: "")
        } label: {
            Label("Andere FinTS-Bank (BLZ + URL manuell)", systemImage: "square.and.pencil")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder private var resultList: some View {
        let all = results
        if all.isEmpty {
            Text("Keine Bank gefunden. Prüfen Sie die Schreibweise oder geben Sie die BLZ ein.")
                .font(.callout).foregroundStyle(.secondary)
            manualFinTsButton
        } else {
            ForEach([BankAccessMode.finTs, .ownApi, .psd2], id: \.self) { mode in
                let rows = all.filter { $0.mode == mode }
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.groupTitle(mode)).font(.subheadline.weight(.semibold))
                        Text(Self.groupHint(mode)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                    ForEach(rows, id: \.id) { r in
                        Button { selected = r } label: { row(r) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func row(_ r: BankSearchResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(r))
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name)
                if let d = Self.detailLine(r) {
                    Text(d).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            badge(r.mode)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func badge(_ m: BankAccessMode) -> some View {
        Text(Self.badgeText(m))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Self.badgeColor(m).opacity(0.15), in: Capsule())
            .foregroundStyle(Self.badgeColor(m))
    }

    // MARK: Selected bank

    private func selectedRow(_ r: BankSearchResult) -> some View {
        HStack {
            row(r)
            Button("Ändern") { selected = nil }
                .buttonStyle(.borderless)
        }
    }

    @ViewBuilder private func detail(_ r: BankSearchResult) -> some View {
        Section {
            switch r.mode {
            case .finTs:
                FinTsAddForm(prefill: r.id == "fints:custom" ? nil : r, onAdded: onAdded)
            case .ownApi:
                if let k = r.connector { KindAddForm(kind: k, onAdded: onAdded) }
            case .psd2:
                if let k = r.connector {
                    KindAddForm(kind: k, onAdded: onAdded)
                } else {
                    Psd2AddForm(bank: r, onAdded: onAdded)
                }
            }
        }
    }

    // MARK: Labels

    static func groupTitle(_ m: BankAccessMode) -> LocalizedStringKey {
        switch m {
        case .finTs: return "Direkt (FinTS 3.0 / HBCI)"
        case .ownApi: return "Direkt (Eigene API)"
        case .psd2: return "PSD2 (via Enable Banking)"
        }
    }

    static func groupHint(_ m: BankAccessMode) -> LocalizedStringKey {
        switch m {
        case .finTs: return "Keine Registrierung bei Dritten nötig"
        case .ownApi: return "Direkter Zugang über die API der Bank"
        case .psd2: return "Benötigt eine kostenlose eigene Enable-Banking-Anwendung"
        }
    }

    static func badgeText(_ m: BankAccessMode) -> LocalizedStringKey {
        switch m {
        case .finTs: return "FinTS"
        case .ownApi: return "Eigene API"
        case .psd2: return "PSD2"
        }
    }

    static func badgeColor(_ m: BankAccessMode) -> Color {
        switch m {
        case .finTs: return .green
        case .ownApi: return .blue
        case .psd2: return .purple
        }
    }

    static func symbol(_ r: BankSearchResult) -> String {
        if let k = r.connector, let d = bankCatalog().first(where: { $0.kind == k }) { return d.sfSymbol }
        return r.mode == .psd2 ? "building.columns.circle" : "building.columns"
    }

    static func detailLine(_ r: BankSearchResult) -> String? {
        switch r.mode {
        case .finTs: return String(localized: "BLZ \(r.blz)")
        case .psd2: return r.country.isEmpty ? nil : r.country
        case .ownApi: return nil
        }
    }
}

/// Add form for a bank with a dedicated connector (bunq, comdirect, Trade
/// Republic, PayPal, American Express, Amazon Visa).
struct KindAddForm: View {
    @Environment(AppModel.self) private var model
    let kind: ConnectorKind
    var onAdded: () -> Void = {}
    @State private var login = ""

    /// Banks that need the login to sign in. For the others (Amazon, Amex,
    /// PayPal, bunq …) the field is only an optional display name.
    private var loginRequired: Bool {
        [.comdirect, .tradeRepublic, .volksbankKasselGoettingen, .direkt1822, .finTsGeneric].contains(kind)
    }

    var body: some View {
        if let d = bankCatalog().first(where: { $0.kind == kind }) {
            DemoHintBanner(style: .credentials) { login = "demo" }
            TextField(d.loginLabel, text: $login)
                .autocorrectionDisabled()
            LabeledContent("Verfahren", value: d.protocol)
            if !d.bankCode.isEmpty { LabeledContent("BLZ", value: d.bankCode) }
            Text(d.note).font(.caption).foregroundStyle(.secondary)
            let missing = d.requiredSettings.filter { key in !(model.settings.first { $0.key == key }?.hasValue ?? false) }
            if !missing.isEmpty {
                Label("Wird nach dem Hinzufügen abgefragt: \(missing.map { settingLabels[$0] ?? $0 }.joined(separator: ", "))", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Bank hinzufügen") {
                model.addConnection(kind, login: kind == .tradeRepublic ? normalizePhoneNumber(input: login) : login)
                login = ""
                onAdded()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(loginRequired && login.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Gibt es den Zugang schon (gleiche Bank, gleiche Kennung), wird er aktualisiert statt doppelt angelegt.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Add form for a bank reached through Enable Banking: the bank is fixed by the
/// search result; the Enable Banking credentials are asked for right after adding.
struct Psd2AddForm: View {
    @Environment(AppModel.self) private var model
    let bank: BankSearchResult
    var onAdded: () -> Void = {}
    @State private var label = ""

    private var missing: [String] {
        (bankCatalog().first { $0.kind == .enableBanking }?.requiredSettings ?? [])
            .filter { key in !(model.settings.first { $0.key == key }?.hasValue ?? false) }
    }

    var body: some View {
        LabeledContent("Bank", value: bank.name)
        LabeledContent("Land", value: bank.country)
        LabeledContent("Verfahren", value: String(localized: "PSD2 über Enable Banking"))
        DemoHintBanner(style: .credentials) { label = "demo" }
        TextField("Bezeichnung (optional)", text: $label)
            .autocorrectionDisabled()
        if !bank.tested.isEmpty {
            Label(bank.tested, systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("Sie melden sich in einem GiroCrab-Fenster direkt bei Ihrer Bank an. Dafür brauchen Sie eine kostenlose eigene Anwendung auf enablebanking.com – die Einrichtung führt Sie Schritt für Schritt hindurch.")
            .font(.caption).foregroundStyle(.secondary)
        if !missing.isEmpty {
            Label("Wird nach dem Hinzufügen abgefragt: \(missing.map { settingLabels[$0] ?? $0 }.joined(separator: ", "))", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        Button("Bank hinzufügen") {
            model.addEnableBankingConnection(aspsp: bank.aspsp, country: bank.country, name: bank.name, label: label)
            label = ""
            onAdded()
        }
        .keyboardShortcut(.defaultAction)
    }
}

#if os(macOS)
import AppKit

/// NSSearchField for inline searches inside forms (where `.searchable`, which
/// lives in the toolbar, does not fit). Takes focus when it appears.
struct SystemSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel(prompt)
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
    }
}
#endif
