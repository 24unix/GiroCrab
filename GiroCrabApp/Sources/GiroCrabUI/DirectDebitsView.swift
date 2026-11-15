import SwiftUI
import UniformTypeIdentifiers
import GiroCrabCore

/// „Lastschriften“ (GitHub #143): mandates of a creditor account, the creditor
/// ID and the preparation of a collection (`pain.008` files).
struct DirectDebitsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var listFocused: Bool
    @State private var creditorText = ""
    @State private var showImporter = false
    @State private var deleting: Mandate?

    private struct ReloadKey: Equatable {
        let account: Int64?
        let version: Int
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lastschriften").appFont(.title2, weight: .semibold)
                Text("Mandate verwalten und Einzüge als SEPA-Lastschrift-Datei (pain.008) vorbereiten.")
                    .appFont(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            if model.debitAccounts.isEmpty {
                ContentUnavailableView(
                    "Kein Konto zum Einziehen",
                    systemImage: "building.columns",
                    description: Text("Lastschriften ziehst du von einem Girokonto mit IBAN ein."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                controls.padding(.horizontal, 20)
                if let error = model.mandateError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .appFont(.callout).foregroundStyle(Theme.negative)
                        .padding(.horizontal, 20)
                } else if let note = model.mandateNote {
                    Label(note, systemImage: "checkmark.circle")
                        .appFont(.callout).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 20)
                }
                if model.mandates.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Mandate", systemImage: "doc.text")
                    } description: {
                        Text("Lege ein Mandat an oder importiere eine Mitgliederliste (CSV).")
                    } actions: {
                        Button("Mandat hinzufügen") { model.newMandate() }
                        Button("CSV importieren …") { showImporter = true }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
        }
        .padding(.top, 16)
        .background(Theme.canvas)
        .task(id: ReloadKey(account: model.effectiveMandateAccount?.id, version: model.mandatesVersion)) {
            await model.reloadMandates()
            creditorText = model.creditorID
        }
        .sheet(item: $model.mandateDraft) { MandateEditorSheet(initial: $0) }
        .sheet(isPresented: $model.showCollectionSheet) { CollectionSheet() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
            if case .success(let url) = result { model.importMandateCSV(url) }
        }
        .confirmationDialog("Mandat löschen?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { m in
            Button("Löschen", role: .destructive) { model.deleteMandate(m) }
        } message: { m in
            Text("Das Mandat „\(m.reference)“ wird entfernt. Bereits eingereichte Einzüge bleiben unverändert.")
        }
    }

    // MARK: controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Gläubigerkonto", selection: Binding(
                    get: { model.effectiveMandateAccount?.id },
                    set: { model.mandateAccountID = $0; model.mandateError = nil; model.mandateNote = nil })) {
                    ForEach(model.debitAccounts) { a in
                        Label(a.name, systemImage: a.sfSymbol).tag(Int64?.some(a.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .sensitive(.labels)
                .frame(minWidth: 150, maxWidth: 260)
                Spacer(minLength: 0)
                Button("CSV importieren …", systemImage: "square.and.arrow.down") { showImporter = true }
                Button("Mandat hinzufügen", systemImage: "plus") { model.newMandate() }
                Button("Einzug vorbereiten …", systemImage: "arrow.down.doc") { model.openCollection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.mandates.contains(where: \.active) || model.creditorID.isEmpty)
                    .help(model.creditorID.isEmpty ? "Zuerst die Gläubiger-ID eintragen." : "")
            }
            HStack(spacing: 8) {
                Text("Gläubiger-ID").appFont(.callout).foregroundStyle(Theme.secondary)
                TextField("z. B. DE98ZZZ09999999999", text: $creditorText)
                    .textFieldStyle(.roundedBorder)
                    .appFont(.callout, monospacedDigit: true)
                    .frame(maxWidth: 280)
                    .sensitive()
                    .onSubmit { model.saveCreditorID(creditorText) }
                Button("Speichern") { model.saveCreditorID(creditorText) }
                    .disabled(creditorText.trimmingCharacters(in: .whitespaces) == model.creditorID)
                if model.creditorID.isEmpty, !model.suggestedCreditorID.isEmpty, creditorText.isEmpty {
                    Button("„\(model.suggestedCreditorID)“ übernehmen") {
                        creditorText = model.suggestedCreditorID
                        model.saveCreditorID(creditorText)
                    }
                    .sensitive()
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: list

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    ForEach(Array(model.mandates.enumerated()), id: \.element.id) { index, m in
                        MandateRow(mandate: m, isLast: index == model.mandates.count - 1, onDelete: { deleting = $0 })
                            .id(m.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.downArrow) { model.moveMandateSelection(1); return .handled }
            .onKeyPress(.upArrow) { model.moveMandateSelection(-1); return .handled }
            .onKeyPress(.escape) {
                guard model.selectedMandateID != nil else { return .ignored }
                model.selectedMandateID = nil
                return .handled
            }
            .onChange(of: model.selectedMandateID) { _, id in
                listFocused = true
                guard let id else { return }
                withAnimation(Motion.animation(.easeOut(duration: 0.15))) { proxy.scrollTo(id) }
            }
            .onAppear { listFocused = model.options.screenshotPath == nil }
        }
    }

    private var header: some View {
        let active = model.mandates.filter(\.active).count
        return VStack(spacing: 0) {
            HStack {
                Text("Mandate").appFont(.subheadline, weight: .semibold).foregroundStyle(Theme.text)
                Spacer()
                Text("\(active) aktiv, \(model.mandates.count - active) inaktiv")
                    .appFont(.subheadline).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .modifier(DayCardSegment(isTop: true, isBottom: false))
    }
}

extension MandateScheme {
    var title: String {
        switch self {
        case .core: String(localized: "Basislastschrift")
        case .cor1: String(localized: "COR1")
        case .b2b: String(localized: "Firmenlastschrift")
        }
    }
}

extension Mandate {
    /// "Erster Einzug" / "Folgeeinzug" / "Einmalig".
    var sequenceText: String {
        switch nextSequence {
        case "OOFF": String(localized: "Einmalig")
        case "RCUR": String(localized: "Folgeeinzug")
        default: String(localized: "Erster Einzug")
        }
    }
}

private struct MandateRow: View {
    @Environment(AppModel.self) private var model
    let mandate: Mandate
    let isLast: Bool
    let onDelete: (Mandate) -> Void

    var body: some View {
        let m = mandate
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .foregroundStyle(m.active ? Theme.accent : Theme.tertiary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill((m.active ? Theme.accent : Theme.tertiary).opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.debtorName).appFont(.body, weight: .medium).lineLimit(1).sensitive()
                    Text("\(m.reference) · \(m.scheme.title)")
                        .appFont(.callout).foregroundStyle(Theme.secondary).lineLimit(1).sensitive()
                    Text(m.active ? m.sequenceText : String(localized: "Inaktiv"))
                        .appFont(.caption).foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if m.defaultAmountCents > 0 {
                        Text(Money.format(m.defaultAmountCents))
                            .appFont(.body, weight: .medium, monospacedDigit: true).fixedSize().sensitive()
                    }
                    Text(m.lastCollected.map { String(localized: "zuletzt \(DateText.medium($0))") } ?? String(localized: "noch nie eingezogen"))
                        .appFont(.caption).foregroundStyle(Theme.secondary)
                }
            }
            .frame(minHeight: 44, alignment: .top)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .opacity(m.active ? 1 : 0.65)
            .background(model.selectedMandateID == m.id ? Theme.selection : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { model.selectedMandateID = m.id }
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.editMandate(m) })
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(model.selectedMandateID == m.id ? [.isButton, .isSelected] : .isButton)
            .contextMenu {
                Button("Bearbeiten …", systemImage: "pencil") { model.editMandate(m) }
                Button(m.active ? "Deaktivieren" : "Aktivieren", systemImage: m.active ? "pause.circle" : "play.circle") {
                    model.setMandateActive(m, !m.active)
                }
                Divider()
                Button("Löschen …", systemImage: "trash", role: .destructive) { onDelete(m) }
            }
            if !isLast {
                Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1).padding(.leading, 64)
            }
        }
        .modifier(DayCardSegment(isTop: false, isBottom: isLast))
    }
}

/// Inspector of „Lastschriften“: the selected mandate.
struct MandateInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let m = model.mandates.first(where: { $0.id == model.selectedMandateID }) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(m.debtorName).appFont(.title3, weight: .semibold).sensitive()
                    Text("\(m.scheme.title) · \(m.active ? m.sequenceText : String(localized: "Inaktiv"))")
                        .appFont(.callout).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                VStack(alignment: .leading, spacing: 10) {
                    field("Mandatsreferenz", m.reference)
                    field("Unterschrieben am", DateText.medium(m.signedDate), sensitive: false)
                    field("IBAN", m.debtorIban, mono: true)
                    if !m.debtorBic.isEmpty { field("BIC", m.debtorBic, mono: true) }
                    if m.defaultAmountCents > 0 { field("Betrag", Money.format(m.defaultAmountCents), mono: true) }
                    if !m.defaultPurpose.isEmpty { field("Verwendungszweck", m.defaultPurpose) }
                    if let last = m.lastCollected { field("Zuletzt eingezogen", DateText.medium(last), sensitive: false) }
                    if !m.note.isEmpty { field("Notiz", m.note) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                HStack {
                    Button("Bearbeiten …", systemImage: "pencil") { model.editMandate(m) }
                    Button(m.active ? "Deaktivieren" : "Aktivieren", systemImage: m.active ? "pause.circle" : "play.circle") {
                        model.setMandateActive(m, !m.active)
                    }
                }
                .buttonStyle(.bordered)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("Kein Mandat ausgewählt", systemImage: "doc.text")
                    .appFont(.headline)
                Text("Wähle ein Mandat, um Details zu sehen.")
                    .appFont(.callout).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    @ViewBuilder
    private func field(_ label: LocalizedStringKey, _ value: String, mono: Bool = false, sensitive: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).appFont(.caption).foregroundStyle(Theme.secondary)
            let t = Text(value).appFont(.callout, monospacedDigit: mono).textSelection(.enabled)
            if sensitive { t.sensitive() } else { t }
        }
    }
}

// MARK: - Mandat bearbeiten

struct MandateEditorSheet: View {
    @Environment(AppModel.self) private var model
    @State private var draft: MandateDraft

    init(initial: MandateDraft) { _draft = State(initialValue: initial) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    TextField("IBAN", text: $draft.iban)
                    TextField("BIC (optional)", text: $draft.bic)
                } header: { Text("Zahlungspflichtiger").appSectionHeader() }
                Section {
                    TextField("Mandatsreferenz", text: $draft.reference)
                    DatePicker("Unterschrieben am", selection: $draft.signed, in: ...Date(), displayedComponents: .date)
                    Picker("Art", selection: $draft.scheme) {
                        ForEach([MandateScheme.core, .cor1, .b2b], id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Einmaliges Mandat", isOn: $draft.oneOff)
                    Toggle("Aktiv", isOn: $draft.active)
                } header: { Text("Mandat").appSectionHeader() }
                Section {
                    TextField("Betrag (optional)", text: $draft.amountText)
                    TextField("Verwendungszweck (optional)", text: $draft.purpose)
                    TextField("Notiz (optional)", text: $draft.note)
                } header: { Text("Vorgaben für den Einzug").appSectionHeader() }
            }
            .formStyle(.grouped)
            if let error = model.mandateError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .appFont(.callout).foregroundStyle(Theme.negative)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { model.mandateDraft = nil }.keyboardShortcut(.cancelAction)
                Button("Sichern") { model.mandateDraft = draft; model.saveMandateDraft() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        #if os(macOS)
        .frame(width: 460, height: 640)
        #endif
    }
}

// MARK: - Einzug vorbereiten

/// A `pain.008` file handed to `.fileExporter`.
struct XMLFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct CollectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.textScale) private var textScale
    @State private var due = Calendar.current.date(byAdding: .day, value: 5, to: Date()) ?? Date()
    @State private var exporting: DebitFile?

    private var included: [CollectionLine] { model.collectionLines.filter(\.included) }
    private var invalid: Int { included.filter { $0.cents == nil }.count }
    private var totalCents: Int64 { included.compactMap(\.cents).reduce(0, +) }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Text("Einzug vorbereiten").appFont(.title2, weight: .semibold)
                Spacer()
                DatePicker("Fälligkeit", selection: $due, in: Date()..., displayedComponents: .date)
                    .onChange(of: due) { _, _ in model.collectionFiles = [] }
            }
            .padding(20)
            Divider()
            if model.collectionFiles.isEmpty {
                List {
                    ForEach($model.collectionLines) { $line in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $line.included).labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.mandate.debtorName).fontWeight(.medium).sensitive()
                                Text("\(line.mandate.reference) · \(line.mandate.sequenceText)")
                                    .appFont(.caption).foregroundStyle(Theme.secondary).sensitive()
                            }
                            Spacer()
                            TextField("Zweck", text: $line.purpose)
                                .textFieldStyle(.roundedBorder).frame(width: 180 * textScale)
                            TextField("Betrag", text: $line.amountText)
                                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                .frame(width: 90 * textScale)
                                .foregroundStyle(line.included && line.cents == nil ? Theme.negative : Theme.text)
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                filesList
            }
            if let error = model.mandateError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .appFont(.callout).foregroundStyle(Theme.negative)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 8)
            }
            Divider()
            footer
        }
        #if os(macOS)
        .frame(minWidth: 720 * textScale, idealWidth: 820 * textScale, minHeight: 460 * textScale, idealHeight: 560 * textScale)
        #endif
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: XMLFileDocument(data: Data((exporting?.xml ?? "").utf8)), contentType: .xml,
                      defaultFilename: exporting?.fileName ?? "lastschrift.xml") { _ in exporting = nil }
    }

    private var filesList: some View {
        List {
            Section {
                ForEach(model.collectionFiles, id: \.fileName) { f in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.fileName).fontWeight(.medium)
                            Text("\(f.scheme.title) · \(f.sequence) · \(f.count) Lastschriften · \(Money.format(f.totalCents))")
                                .appFont(.caption).foregroundStyle(Theme.secondary).sensitive()
                        }
                        Spacer()
                        Button("Sichern …", systemImage: "square.and.arrow.down") { exporting = f }
                    }
                }
            } header: { Text("Dateien").appSectionHeader() }
            Section {
                Text("Reiche die Dateien bei deiner Bank ein (Banking-Portal, Datei-Upload). Danach markierst du die Mandate als eingezogen, damit der nächste Einzug als Folgeeinzug läuft.")
                    .appFont(.callout).foregroundStyle(Theme.secondary)
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            if model.collectionFiles.isEmpty {
                Text("\(included.count) Lastschriften · \(Money.format(totalCents))").appFont(.callout).foregroundStyle(Theme.secondary).sensitive()
            }
            Spacer()
            Button("Schließen", role: .cancel) { model.showCollectionSheet = false; dismiss() }.keyboardShortcut(.cancelAction)
            if model.collectionFiles.isEmpty {
                Button("Dateien erzeugen") { model.buildCollection(dueDate: due) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(included.isEmpty || invalid > 0)
            } else {
                Button("Als eingezogen markieren") { model.markCollected(model.collectionFiles, dueDate: due) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }
}
