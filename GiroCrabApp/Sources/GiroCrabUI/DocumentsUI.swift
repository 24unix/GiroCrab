import SwiftUI
import PDFKit
import Vision
import UniformTypeIdentifiers
import GiroCrabCore

extension DocumentInfo: Identifiable {}

// MARK: - Text for receipt matching (PDF text layer / OCR for photos)

enum ReceiptText {
    /// PDFKit text layer for PDFs, Vision OCR (de-DE) for images.
    static func extract(data: Data, fileName: String) async -> String? {
        if data.starts(with: [0x25, 0x50, 0x44, 0x46]) { // %PDF
            return PDFDocument(data: data)?.string
        }
        #if os(macOS)
        guard let img = NSImage(data: data), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        guard let cg = UIImage(data: data)?.cgImage else { return nil }
        #endif
        return await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            req.recognitionLanguages = ["de-DE", "en-US"]
            req.recognitionLevel = .accurate
            do {
                try VNImageRequestHandler(cgImage: cg).perform([req])
            } catch {
                cont.resume(returning: nil)
            }
        }
    }
}

// MARK: - PDFKit preview

#if os(macOS)
struct PDFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = .white
        v.document = PDFDocument(data: data)
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.dataRepresentation() != data { v.document = PDFDocument(data: data) }
    }
}
#else
struct PDFPreview: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.document = PDFDocument(data: data)
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {
        if v.document?.dataRepresentation() != data { v.document = PDFDocument(data: data) }
    }
}
#endif

struct DocumentPreview: View {
    let doc: DocumentInfo
    let data: Data

    var body: some View {
        if doc.mimeType == "application/pdf" {
            PDFPreview(data: data)
        } else if let img = AppModel.image(from: data) {
            img.resizable().scaledToFit()
        } else {
            ContentUnavailableView("Keine Vorschau", systemImage: "doc")
        }
    }
}

func docSymbol(_ doc: DocumentInfo) -> String {
    switch doc.docType {
    case "abrechnung": return "chart.line.uptrend.xyaxis.circle"
    case "kontoauszug": return "list.bullet.rectangle"
    case "postbox": return "tray.full"
    case "steuer": return "percent"
    default: return doc.mimeType.hasPrefix("image") ? "photo" : "doc.text.fill"
    }
}

// MARK: - Inspector card

/// "Belege & Abrechnungen": attached PDFs with inline preview, drop zone,
/// QuickLook and export for the tax return.
struct DocumentsCard: View {
    @Environment(AppModel.self) private var model
    let booking: Booking
    @State private var selected: Int64?
    @State private var targeted = false
    @State private var exporting = false

    var body: some View {
        let docs = model.documents(for: booking)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Belege & Abrechnungen", systemImage: "paperclip").font(.subheadline.weight(.semibold))
                Spacer()
                if !docs.isEmpty {
                    Text("\(docs.count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                }
            }
            ForEach(docs) { d in
                HStack(spacing: 8) {
                    Image(systemName: docSymbol(d)).foregroundStyle(Theme.accent).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.title).font(.callout).lineLimit(1)
                        Text("\(DateText.medium(d.docDate)) · \(ByteCountFormatter.string(fromByteCount: Int64(d.sizeBytes), countStyle: .file))")
                            .font(.caption2).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Button { model.quickLook(d) } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless).help("QuickLook (Leertaste)")
                    Menu {
                        Button("In PostBox verschieben (Verknüpfung lösen)") { model.linkDocument(d, to: nil) }
                        Button("Löschen", role: .destructive) { model.deleteDocument(d) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected == d.id ? Theme.selection : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { selected = (selected == d.id ? nil : d.id) }
            }
            if let id = selected ?? docs.first?.id, let d = docs.first(where: { $0.id == id }), let data = model.documentData(d) {
                DocumentPreview(doc: d, data: data)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }
            // Drop zone
            VStack(spacing: 4) {
                Image(systemName: "arrow.down.doc").font(.title3)
                Text("PDF-Rechnung oder Kassenbon hierher ziehen").font(.caption)
            }
            .foregroundStyle(targeted ? Theme.accent : Theme.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 9).fill(targeted ? Theme.selection : Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(targeted ? Theme.accent : Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .dropDestination(for: URL.self) { urls, _ in
                model.attach(urls, to: booking)
                return !urls.isEmpty
            } isTargeted: { targeted = $0 }
            Button {
                exporting = true
            } label: {
                Label("Alle Belege exportieren (Ordner)", systemImage: "square.and.arrow.up.on.square")
                    .frame(maxWidth: .infinity)
            }
            .help("Für die Steuererklärung: alle Belege nach Jahr sortiert in einen Ordner")
        }
        .card()
        .fileImporter(isPresented: $exporting, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.exportAllDocuments(to: url) }
        }
        .onChange(of: booking.id) { _, _ in selected = nil }
    }
}

// MARK: - "Belege & PostBox" view (center column)

struct DocumentsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var unlinkedOnly = false
    @State private var selected: Int64?
    @State private var exporting = false
    @State private var targeted = false

    var body: some View {
        let docs = model.allDocuments(search: search, unlinkedOnly: unlinkedOnly)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Belege & PostBox").font(.title2.weight(.semibold))
                    Text("Wertpapierabrechnungen, Kontoauszüge, Kassenbons – verschlüsselt im Tresor. PDF oder Foto hierher ziehen: GiroCrab ordnet es dem passenden Umsatz zu.")
                        .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    TextField("Suchen …", text: $search).textFieldStyle(.roundedBorder)
                    Toggle("Nur ohne Buchung", isOn: $unlinkedOnly).toggleStyle(.switch).controlSize(.small)
                    Button { exporting = true } label: { Label("Alle exportieren", systemImage: "square.and.arrow.up") }
                }
                List(selection: $selected) {
                    ForEach(docs) { d in
                        HStack(spacing: 10) {
                            Image(systemName: docSymbol(d)).foregroundStyle(Theme.accent).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.title).fontWeight(.medium).lineLimit(1)
                                Text(d.bookingLabel.isEmpty ? "PostBox · \(d.accountName)" : d.bookingLabel)
                                    .font(.caption).foregroundStyle(d.bookingLabel.isEmpty ? Theme.warning : Theme.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(DateText.medium(d.docDate)).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                        }
                        .tag(d.id)
                        .contextMenu {
                            Button("QuickLook") { model.quickLook(d) }
                            Button("Verknüpfung lösen") { model.linkDocument(d, to: nil) }
                            Button("Löschen", role: .destructive) { model.deleteDocument(d) }
                        }
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if docs.isEmpty {
                        ContentUnavailableView("Keine Belege", systemImage: "doc.on.doc", description: Text("Belege kommen beim Abruf (Trade Republic, comdirect-PostBox, FinTS-Kontoauszug) oder per Drag & Drop."))
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 520)
            Divider()
            Group {
                if let id = selected, let d = docs.first(where: { $0.id == id }), let data = model.documentData(d) {
                    DocumentPreview(doc: d, data: data)
                } else {
                    ContentUnavailableView("Beleg auswählen", systemImage: "doc.richtext", description: Text("Vorschau mit PDFKit"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
        .background(Theme.canvas)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(8)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.dropAnywhere(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
        .fileImporter(isPresented: $exporting, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.exportAllDocuments(to: url) }
        }
        .navigationTitle("")
    }
}
