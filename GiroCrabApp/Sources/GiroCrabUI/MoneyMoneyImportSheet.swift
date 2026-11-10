import SwiftUI
import UniformTypeIdentifiers
import GiroCrabCore

/// "Aus MoneyMoney importieren…": migrates a multi-year MoneyMoney export
/// (CSV or XML) incl. categories and notes. Re-importing never duplicates.
struct MoneyMoneyImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var picking = false
    @State private var targeted = false
    @State private var fileName = ""
    @State private var fileData: Data?
    /// nil = "Neues Konto aus Datei anlegen"
    @State private var target: Int64?
    @State private var preview: MoneyMoneyImportPreview?
    @State private var error: String?
    @State private var loading = false
    @State private var importing = false
    @State private var keepCategories = true
    @State private var keepNotes = true

    private let types: [UTType] = [.xml, .commaSeparatedText, .plainText, .data]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square").font(.title2).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aus MoneyMoney importieren").font(.headline)
                    Text("Komplette Historie, Kategorien und Notizen – ohne Duplikate bei späteren Abrufen.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            guide
            dropZone
            if fileData != nil {
                Picker("Zielkonto", selection: $target) {
                    Text("Neues Konto aus Datei anlegen").tag(Int64?.none)
                    ForEach(model.allAccounts) { a in Text("\(a.name) · \(a.bankName)").tag(Int64?.some(a.id)) }
                }
                Toggle("Kategorien übernehmen", isOn: $keepCategories).toggleStyle(.switch).controlSize(.small)
                Toggle("Notizen übernehmen", isOn: $keepNotes).toggleStyle(.switch).controlSize(.small)
            }
            if loading { ProgressView().controlSize(.small) }
            if let preview { previewCard(preview) }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.warning) }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(importing ? "Importiere …" : "Importieren") { runImport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview == nil || importing || (preview?.totalRows ?? 0) == 0)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Theme.card)
        .interactiveDismissDisabled(importing)
        .onAppear {
            if let demo = model.demoImportPreview {
                preview = demo
                fileName = "MoneyMoney-Umsaetze.xml"
                fileData = Data([0])
            }
        }
        .onChange(of: target) { _, _ in refreshPreview() }
        .onChange(of: keepCategories) { _, _ in refreshPreview() }
        .fileImporter(isPresented: $picking, allowedContentTypes: types) { result in
            if case .success(let url) = result { load(url) }
        }
    }

    // MARK: - Pieces

    private var guide: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(["Konto wählen", "⌘A (alle Umsätze markieren)", "Umsätze exportieren … → XML oder CSV"].enumerated()), id: \.offset) { i, text in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                        .frame(width: 20, height: 20).background(Circle().fill(Theme.selection))
                    Text(text).font(.caption).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.canvas))
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: fileData == nil ? "tray.and.arrow.down" : "doc.text").font(.title)
                .foregroundStyle(targeted ? Theme.accent : Theme.secondary)
            Text(fileData == nil ? ".xml- oder .csv-Datei hierher ziehen" : fileName).font(.callout.weight(.medium))
            Button(fileData == nil ? "Datei auswählen …" : "Andere Datei …") { picking = true }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(targeted ? Theme.selection : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(targeted ? Theme.accent : Theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            load(url)
            return true
        } isTargeted: { targeted = $0 }
    }

    private func previewCard(_ p: MoneyMoneyImportPreview) -> some View {
        let span = [p.dateRangeStart, p.dateRangeEnd].compactMap { $0.map { String($0.prefix(4)) } }
        let years = span.count == 2 ? (span[0] == span[1] ? span[0] : "\(span[0]) – \(span[1])") : "–"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                stat(years, "Zeitraum")
                stat(p.newBookings.formatted(.number.locale(Locale(identifier: "de_DE"))), "neue Buchungen")
                stat("\(p.notesCount)", "Notizen")
                stat("\(p.duplicatesSkippedOrEnriched)", "bereits vorhanden")
            }
            if !p.detectedCategories.isEmpty {
                Text("\(p.detectedCategories.count) Kategorien: " + p.detectedCategories.prefix(6).joined(separator: ", ") + (p.detectedCategories.count > 6 ? " …" : ""))
                    .font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
            }
            if target == nil { Text("Neues Archivkonto: „\(p.suggestedAccountName)“ – Saldo = Summe der Umsätze.").font(.caption).foregroundStyle(Theme.secondary) }
            if p.duplicatesSkippedOrEnriched > 0 {
                Text("Bereits vorhandene Buchungen werden nicht doppelt angelegt; sie erhalten nur Kategorie und Notiz.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        .card()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.text)
            Text(label).font(.caption2).foregroundStyle(Theme.secondary)
        }
    }

    // MARK: - Actions

    private func load(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            fileData = try Data(contentsOf: url)
            fileName = url.lastPathComponent
            refreshPreview()
        } catch {
            self.error = describe(error)
        }
    }

    private func refreshPreview() {
        guard let vault = model.vault, let data = fileData else { return }
        let (name, tgt) = (fileName, target)
        loading = true; error = nil
        Task {
            let result = await Task.detached { () -> Result<MoneyMoneyImportPreview, Error> in
                Result { try vault.previewMoneymoneyImport(data: data, fileName: name, targetAccountId: tgt) }
            }.value
            loading = false
            switch result {
            case .success(let p): preview = p
            case .failure(let e):
                preview = nil
                if case CoreError.InvalidInput = e {
                    error = "In dieser Datei wurden keine MoneyMoney-Umsätze erkannt (erwartet: CSV mit Datum/Betrag oder XML <transactions>)."
                } else { error = describe(e) }
            }
        }
    }

    private func runImport() {
        guard let vault = model.vault, let data = fileData else { return }
        let (name, tgt, cats, notes) = (fileName, target, keepCategories, keepNotes)
        importing = true
        Task {
            let result = await Task.detached { () -> Result<MoneyMoneyImportResult, Error> in
                Result { try vault.importMoneymoneyData(data: data, fileName: name, targetAccountId: tgt, preserveCategories: cats, preserveNotes: notes) }
            }.value
            importing = false
            switch result {
            case .success(let r):
                model.finishMoneyMoneyImport(r)
                dismiss()
            case .failure(let e): error = describe(e)
            }
        }
    }
}

extension AppModel {
    func finishMoneyMoneyImport(_ r: MoneyMoneyImportResult) {
        reloadAll()
        if r.accountCreated { sidebarSelection = .account(r.accountId) }
        toast = "MoneyMoney: \(r.imported) Buchungen importiert"
            + (r.enriched > 0 ? ", \(r.enriched) ergänzt" : "")
            + (r.duplicates > 0 ? ", \(r.duplicates) bereits vorhanden" : "")
    }
}
