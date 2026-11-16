import SwiftUI
import UniformTypeIdentifiers
import GiroCrabCore

/// "Sammelüberweisung" (GitHub #240): many payments from one account in one
/// order (HKCCM) with one TAN. Table editor (resizable on macOS), CSV import,
/// then a read-only review. The bank's TAN request is shown by `TwoFactorSheet`.
struct BatchTransferSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reportRedaction) private var redaction
    @Environment(\.dismiss) private var dismiss
    @Environment(\.textScale) private var textScale
    @Environment(\.undoManager) private var undoManager
    @State private var selection = Set<BatchRow.ID>()
    @State private var reviewing = false
    @State private var showImporter = false
    @State private var dropTargeted = false

    private var draft: BatchDraft { model.batchDraft }
    private var rows: [BatchRow] { draft.rows }
    private var invalid: Int { rows.filter { !$0.isValid }.count }
    private var totalCents: Int64 { rows.compactMap(\.cents).reduce(0, +) }
    private var account: Account? { model.batchAccounts.first { $0.id == draft.accountID } }
    private var pinStored: Bool {
        guard let id = account?.connectionId else { return false }
        return model.isDemo || (model.connectionStatus(id)?.hasPin ?? false)
    }
    private var canReview: Bool { account != nil && !rows.isEmpty && invalid == 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !reviewing { TransferKindPicker(batch: true).padding(.bottom, 10) }
            Divider()
            if reviewing { review } else { editor }
            if let e = model.transferError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).appFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 8)
            }
            Divider()
            buttons.padding(14)
        }
        #if os(macOS)
        // A table of many rows: the sheet can be resized (unlike the single transfer form).
        .frame(minWidth: 760 * textScale, idealWidth: 920 * textScale, maxWidth: .infinity,
               minHeight: 520 * textScale, idealHeight: 680 * textScale, maxHeight: .infinity)
        #endif
        .task { if model.options.demoSheet == "batch-transfer-confirm" { reviewing = true } } // screenshots
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
            if case .success(let url) = result { model.importBatchCSV(url) }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Theme.accent.opacity(0.06)).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !reviewing, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.importBatchCSV(url) }
            }
            return true
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            Text(reviewing ? "Sammelüberweisung prüfen" : "Neue Überweisung").appFont(.title2, weight: .semibold)
            Spacer()
            if !reviewing {
                Button { showImporter = true } label: { Label("CSV importieren …", systemImage: "square.and.arrow.down") }
                    .help("Spalten: Name, IBAN, Betrag, Verwendungszweck (Trennzeichen ; , oder Tab). Datei hierher ziehen.")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: editor

    private var bookingText: String {
        draft.singleBookings ? String(localized: "Einzelbuchungen pro Zahlung") : String(localized: "Eine Sammelbuchung")
    }

    /// The choices side by side (label above) instead of a tall form.
    private var options: some View {
        @Bindable var draft = model.batchDraft
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                labeled("Von Konto") {
                    SourceAccountPicker(selection: $draft.accountID, accounts: model.batchAccounts)
                }
                labeled("Buchung auf dem Kontoauszug") {
                    Picker("Buchung", selection: $draft.singleBookings) {
                        Text("Eine Sammelbuchung").tag(false)
                        Text("Einzelbuchungen pro Zahlung").tag(true)
                    }
                }
                .frame(width: 200 * textScale)
                labeled("Ausführung") {
                    Picker("Ausführung", selection: $draft.scheduled) {
                        Text("Normale Überweisung").tag(false)
                        Text("Terminüberweisung").tag(true)
                    }
                }
                .frame(width: 150 * textScale)
                // Always there (disabled unless scheduled): the layout does not jump.
                labeled("Ausführungsdatum") {
                    DatePicker("Ausführungsdatum", selection: $draft.executionDate,
                               in: (Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())...,
                               displayedComponents: .date)
                        .disabled(!draft.scheduled)
                }
                .fixedSize()
            }
            if let note = draft.importNote {
                Label(note, systemImage: "doc.text").appFont(.callout).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func labeled<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).appFont(.caption).foregroundStyle(Theme.secondary)
            content().labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var editor: some View {
        @Bindable var draft = model.batchDraft
        return VStack(spacing: 0) {
            options
            Divider()
            #if os(macOS)
            Table($draft.rows, selection: $selection) {
                TableColumn("Name") { $r in
                    TextField("Name", text: $r.name, prompt: Text("Name")).labelsHidden()
                        .sensitive()
                }
                .width(min: 120, ideal: 170)
                TableColumn("IBAN") { $r in
                    HStack(spacing: 6) {
                        TextField("IBAN", text: $r.iban, prompt: Text("DE00 …")).labelsHidden()
                            .appFont(.body, design: .monospaced)
                            .sensitive()
                        if !r.iban.isEmpty && !r.ibanValid {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.negative).help("IBAN ungültig (Prüfsumme/Länge)")
                                .accessibilityLabel("IBAN ungültig")
                        }
                    }
                }
                .width(min: 220 * textScale, ideal: 245 * textScale, max: 280 * textScale)
                TableColumn("Betrag") { $r in
                    HStack(spacing: 4) {
                        if r.cents == nil {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.negative).help("Betrag > 0 eingeben")
                                .accessibilityLabel("Betrag fehlt")
                        }
                        TextField("Betrag", text: $r.amountText, prompt: Text("0,00")).labelsHidden()
                            .multilineTextAlignment(.trailing).appFont(.body, monospacedDigit: true)
                            .sensitive()
                    }
                }
                .width(min: 80, ideal: 95, max: 120)
                TableColumn("Verwendungszweck") { $r in
                    TextField("Zweck", text: $r.purpose, prompt: Text("Verwendungszweck")).labelsHidden()
                        .sensitive()
                }
                .width(min: 160, ideal: 260)
            }
            .frame(maxHeight: .infinity)
            .onDeleteCommand { removeSelected() }
            #else
            // iPhone: a Table collapses to its first column, so a list of cards
            List {
                ForEach($draft.rows) { $r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Name", text: $r.name, prompt: Text("Name"))
                            Spacer()
                            TextField("Betrag", text: $r.amountText, prompt: Text("0,00"))
                                .multilineTextAlignment(.trailing).monospacedDigit().fixedSize()
                        }
                        TextField("IBAN", text: $r.iban, prompt: Text("DE00 …"))
                            .appFont(.caption, design: .monospaced)
                            .foregroundStyle(r.ibanValid ? Theme.secondary : Color.red)
                        TextField("Zweck", text: $r.purpose, prompt: Text("Verwendungszweck"))
                            .appFont(.caption).foregroundStyle(Theme.secondary)
                    }
                    .sensitive()
                }
                .onDelete { offsets in draft.remove(Set(offsets.map { draft.rows[$0].id }), undo: undoManager) }
            }
            .listStyle(.plain)
            #endif

            Divider()
            HStack(spacing: 8) {
                Button { draft.rows.append(BatchRow()) } label: { Image(systemName: "plus") }
                    .help("Zeile hinzufügen").accessibilityLabel("Zeile hinzufügen")
                #if os(macOS)
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .help("Ausgewählte Zeilen entfernen (⌘Z macht es rückgängig)").disabled(selection.isEmpty)
                    .accessibilityLabel("Ausgewählte Zeilen entfernen")
                #endif
                Spacer()
                if invalid > 0 {
                    Label("\(invalid) fehlerhaft", systemImage: "exclamationmark.triangle.fill")
                        .appFont(.callout).foregroundStyle(Theme.negative)
                }
                Text("\(rows.count) Zahlungen · \(String(localized: "Summe"))").appFont(.callout).foregroundStyle(Theme.secondary)
                Text(Money.format(totalCents)).appFont(.title3, weight: .semibold, monospacedDigit: true).fixedSize().sensitive()
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
    }

    // MARK: review

    /// One compact band: the total, then what and from where.
    private var summary: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Summe").appFont(.caption).foregroundStyle(Theme.secondary)
                Text(Money.format(totalCents)).appFont(.title, weight: .semibold, monospacedDigit: true).fixedSize().sensitive()
            }
            Divider().frame(height: 40)
            VStack(alignment: .leading, spacing: 3) {
                (Text("\(rows.count) Zahlungen") + Text(" · ") + Text(account.map { "\(redaction.masking($0.name)) · \(redaction.masking(formatIBAN($0.iban)))" } ?? "")).lineLimit(1)
                Text("\(bookingText) · \(draft.scheduled ? String(localized: "Terminüberweisung") : String(localized: "Heute (SEPA-Überweisung)"))")
                    .foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .appFont(.callout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var review: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            #if os(macOS)
            Table(rows) {
                TableColumn("Name") { r in Text(r.name).sensitive() }.width(min: 120, ideal: 170)
                TableColumn("IBAN") { r in Text(r.iban).appFont(.body, design: .monospaced).sensitive() }
                    .width(min: 220 * textScale, ideal: 245 * textScale, max: 280 * textScale)
                TableColumn("Betrag") { r in
                    Text(Money.format(r.cents ?? 0)).appFont(.body, monospacedDigit: true).sensitive()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 80, ideal: 95, max: 120)
                TableColumn("Verwendungszweck") { r in Text(r.purpose).sensitive() }.width(min: 160, ideal: 260)
            }
            .frame(maxHeight: .infinity)
            #else
            List(rows) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(r.name)
                        Spacer()
                        Text(Money.format(r.cents ?? 0)).monospacedDigit()
                    }
                    Text(r.iban).appFont(.caption, design: .monospaced).foregroundStyle(Theme.secondary)
                    Text(r.purpose).appFont(.caption).foregroundStyle(Theme.secondary)
                }
                .sensitive()
            }
            .listStyle(.plain)
            #endif
            Divider()
            pinArea
            Label("Bitte Empfänger und IBAN genau prüfen. Eine freigegebene Überweisung lässt sich meist nicht mehr zurückholen.", systemImage: "exclamationmark.shield")
                .appFont(.callout).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 10)
        }
    }

    @ViewBuilder private var pinArea: some View {
        @Bindable var draft = model.batchDraft
        if !pinStored {
            SecureField("Banking-PIN", text: $draft.pin, prompt: Text("wird nicht gespeichert"))
                .frame(maxWidth: 360 * textScale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 10)
        }
    }

    private func removeSelected() {
        draft.remove(selection, undo: undoManager)
        selection = []
    }

    private var buttons: some View {
        HStack {
            Button("Abbrechen", role: .cancel) { model.cancelBatchSheet(); dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            if reviewing {
                Button("Zurück") { reviewing = false; model.transferError = nil }
                Button("Jetzt mit TAN freigeben") { model.startBatch() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            } else {
                Button("Weiter") { model.transferError = nil; reviewing = true }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!canReview)
            }
        }
    }
}

/// "Einzeln | Sammelüberweisung" under the title of both transfer sheets.
struct TransferKindPicker: View {
    @Environment(AppModel.self) private var model
    let batch: Bool

    var body: some View {
        Picker("Art", selection: Binding(
            get: { batch ? 1 : 0 },
            set: { new in
                if new == 1 && !batch { model.switchToBatchTransfer() }
                if new == 0 && batch { model.switchToSingleTransfer() }
            })
        ) {
            Text("Einzeln").tag(0)
            Text("Sammelüberweisung").tag(1)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .frame(maxWidth: .infinity)
    }
}
