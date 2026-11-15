import SwiftUI
import UniformTypeIdentifiers
import GiroCrabCore

// Preparing a collection (GitHub #143).

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
                            if line.mandate.nextSequence == "RCUR" {
                                Toggle("Letzter Einzug", isOn: $line.lastCollection).toggleStyle(.checkbox)
                                    .help("Setzt den Folgetyp FNAL; danach wird das Mandat deaktiviert.")
                            }
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
