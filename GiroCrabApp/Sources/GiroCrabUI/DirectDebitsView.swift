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
                Text("Mandate verwalten und Einzüge als SEPA-Lastschrift-Datei (pain.008) vorbereiten. Dateien lassen sich hierher ziehen.")
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
                        Text("Lege ein Mandat an oder importiere eine Mitgliederliste (CSV) oder eine SEPA-Lastschriftdatei.")
                    } actions: {
                        Button("Mandat hinzufügen") { model.newMandate() }
                        Button("Importieren …") { showImporter = true }
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
        .capturableSheet(item: $model.mandateDraft) { MandateEditorSheet(initial: $0) }
        .capturableSheet(isPresented: $model.showCollectionSheet) { CollectionSheet() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .text, .xml]) { result in
            if case .success(let url) = result { model.importMandateFile(url) }
        }
        .fileExporter(isPresented: $model.showMandateExport, document: model.mandateExport, contentType: .commaSeparatedText,
                      defaultFilename: "mandate.csv") { _ in }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard model.effectiveMandateAccount != nil, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.importMandateFile(url) }
            }
            return true
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
                Button("Importieren …", systemImage: "square.and.arrow.down") { showImporter = true }
                    .help("CSV-Mitgliederliste oder SEPA-Lastschriftdatei (pain.008)")
                Button("Exportieren …", systemImage: "square.and.arrow.up") { model.exportMandates() }
                    .disabled(model.mandates.isEmpty)
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

    /// "Einmalmandat (EM)" / "Dauermandat (AM)": the abbreviations banks print on direct debits.
    var typeText: String {
        oneOff ? String(localized: "Einmalmandat (EM)") : String(localized: "Dauermandat (AM)")
    }

    var typeHelp: String {
        oneOff
            ? String(localized: "EM = Einmalmandat: gilt nur für eine einzelne Lastschrift.")
            : String(localized: "AM = Dauermandat: gilt für wiederkehrende Lastschriften.")
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
                    Text("\(m.reference) · \(m.scheme.title) · \(m.typeText)")
                        .appFont(.callout).foregroundStyle(Theme.secondary).lineLimit(1).sensitive()
                        .help(m.typeHelp)
                    if !model.openReturns(of: m).isEmpty {
                        Label("Rücklastschrift – bitte prüfen", systemImage: "exclamationmark.triangle.fill")
                            .appFont(.caption, weight: .semibold).foregroundStyle(Theme.negative)
                    } else {
                        Text(m.active ? m.sequenceText : String(localized: "Inaktiv"))
                            .appFont(.caption).foregroundStyle(Theme.tertiary)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if m.defaultAmountCents > 0 {
                        Text(Money.format(m.defaultAmountCents))
                            .appFont(.body, weight: .medium, monospacedDigit: true).fixedSize().sensitive(.amounts)
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
