import SwiftUI
import GiroCrabCore
#if os(macOS)
import AppKit
#endif

/// Hilfe › Problem melden … (#301). macOS: its own window, so the main window
/// stays free to be captured; iOS: a sheet (`BugReportSheet`).
struct BugReportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.undoManager) private var undoManager
    /// Closes the window (macOS) or the sheet (iOS).
    @Environment(\.dismiss) private var dismiss
    /// iOS: set when UIKit presents the report (from the capture bar, over
    /// any sheet); SwiftUI's `dismiss` does not reach that presentation.
    var onClose: (() -> Void)?
    /// The capture left out a dialog over the main window (an alert).
    @State private var dialogOmitted = false
    #if os(iOS)
    @State private var markingUp = false
    #endif

    @State private var options = BugReport.Options()
    @State private var base: CGImage?
    /// Starts true: the first capture follows right after `started`.
    @State private var capturing = true
    /// Set in `onAppear`, after a pending pick's choices were taken over: the
    /// capture and the diagnostics never run with the defaults first.
    @State private var started = false
    @State private var captureRun = 0
    /// Extra black boxes, unit rectangles with the origin top left.
    @State private var masks: [CGRect] = []
    /// Owner of the mask undo actions (Bearbeiten › Widerrufen, ⌘Z).
    @State private var undoTarget = MaskUndoTarget()
    /// Bumped on every undo registration: `canUndo` is not observable.
    @State private var undoTick = 0
    /// Header and sanitized log lines; nil while they are being prepared
    /// (sending waits for them). Built off the main thread, once per change.
    @State private var prepared: PreparedDiagnostics?
    @State private var exporting = false
    @State private var export = PNGFileDocument(data: Data())

    private var redaction: ReportRedaction { options.redaction(demo: model.isDemo) }

    private var captureKey: CaptureKey { CaptureKey(redaction: redaction, run: captureRun, started: started) }

    /// Reload when the log option changes, or the vault opens, locks or is
    /// swapped (demo ↔ own). A new screenshot leaves the diagnostics alone.
    private var diagnosticsKey: DiagnosticsKey {
        DiagnosticsKey(includeLog: options.includeLog, unlocked: model.isUnlocked, demo: model.isDemo, started: started)
    }

    private var canUndo: Bool {
        _ = undoTick
        return undoManager?.canUndo ?? false
    }

    private var canSend: Bool { !capturing && prepared != nil }
    private var canExport: Bool { !capturing && base != nil }

    var body: some View {
        Form {
            Section {
                #if os(macOS)
                Text("Ziehe mit der Maus Rechtecke über Stellen, die zusätzlich schwarz übermalt werden sollen.")
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                #endif
                screenshot
                maskControls
            } header: {
                Text("Screenshot")
            } footer: {
                #if os(macOS)
                // #384: the main window stays usable next to this one
                Text("Aufgenommen wird das Hauptfenster samt geöffnetem Dialog. Liegt das Problem woanders, wechsle dort zur betroffenen Ansicht oder öffne den Dialog und wähle dann „Neu aufnehmen“. Eine neue Aufnahme verwirft die Markierungen, weil sich der Inhalt verschoben haben kann.")
                #else
                Text("Aufgenommen wird, was unter diesem Bericht liegt, samt geöffneter Dialoge. Liegt das Problem woanders, wechsle mit „Andere Ansicht aufnehmen …“ dorthin. Eine neue Aufnahme verwirft die Markierungen, weil sich der Inhalt verschoben haben kann.")
                #endif
            }

            Section {
                if model.isDemo {
                    Toggle("Persönliche Daten schwärzen", isOn: $options.autoRedact)
                } else {
                    Label("Persönliche Daten werden geschwärzt", systemImage: "eye.slash")
                }
                Toggle("Kategorien ausblenden", isOn: $options.hideLabels)
            } footer: {
                Text(model.isDemo
                     ? "Beträge, IBANs, Namen, Kontonamen, Verwendungszwecke und Belege werden abgedeckt; „Kategorien ausblenden“ deckt auch Kategorien, Gruppen und Wertpapiernamen ab. Im Demo-Tresor sind alle Daten erfunden, deshalb lässt sich die Schwärzung hier abschalten."
                     : "Beträge, IBANs, Namen, Kontonamen, Verwendungszwecke und Belege werden abgedeckt; „Kategorien ausblenden“ deckt auch Kategorien, Gruppen und Wertpapiernamen ab. Prüfe das Bild trotzdem, bevor du es teilst.")
            }

            Section {
                Toggle("Abruf-Protokoll anhängen", isOn: $options.includeLog)
                if let prepared {
                    Text(verbatim: prepared.text)
                        .appFont(.caption, design: .monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if prepared.logUnavailable {
                        Label("Das Abruf-Protokoll wird nicht angehängt: Es konnte nicht vollständig geladen und bereinigt werden.",
                              systemImage: "exclamationmark.triangle")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Diagnose wird bereinigt …")
                }
            } header: {
                Text("Diagnose")
            } footer: {
                Text("Beim Öffnen des Issues liegt der geschwärzte Screenshot in der Zwischenablage. Es wird nichts automatisch gesendet: Der Browser zeigt ein vorausgefülltes Issue, das du vor dem Absenden noch bearbeiten kannst.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Problem melden")
        #if os(macOS)
        // HIG: the primary action stays in view, bottom trailing, bound to Return.
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .background(NonRestorableWindow())
        .frame(minWidth: 620, minHeight: 640)
        #else
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Abbrechen") { close() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Issue öffnen") { send() }
                    .disabled(!canSend)
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Als PNG sichern …", systemImage: "square.and.arrow.down") { startExport() }
                    .disabled(!canExport)
            }
            ToolbarItem(placement: .bottomBar) {
                // #384: the GitHub app often takes no pasted picture; "Bild
                // sichern" puts it in Photos, where its editor can pick it.
                // with the diagnostics, like "Issue öffnen"; no thumbnail: the
                // raw picture lacks the user's own boxes
                if canSend, let base, let prepared {
                    ShareLink(item: ReportImage(base: base, masks: masks),
                              message: Text(verbatim: prepared.text),
                              preview: SharePreview(String(localized: "GiroCrab-Fehlerbericht")))
                }
            }
        }
        .fullScreenCover(isPresented: $markingUp) { // report: not captured (part of the report)
            if let base {
                MaskEditorScreen(image: base, masks: masks, canUndo: canUndo,
                                 onAdd: addMask, onUndo: { undoManager?.undo(); undoTick &+= 1 })
            }
        }
        #endif
        // macOS: grey out the help menu's "Problem melden …" while this window
        // is open (its "Neu aufnehmen" refreshes the picture; a new report
        // would silently discard the markings made here).
        .onDisappear { model.isReportOpen = false }
        // a report opened again (menu, capture bar) ends a pending pick and
        // takes over its choices
        .onAppear {
            model.isReportOpen = true
            // only on the first appearance: on iOS it fires again after the
            // mask editor or the share sheet, and must not take another
            // scene's pick then
            guard !started else { return }
            if let pick = model.reportPick {
                options = pick
                model.reportPick = nil
            }
            started = true
        }
        .task(id: captureKey) { await capture() }
        .task(id: diagnosticsKey) { await prepareDiagnostics() }
        .fileExporter(isPresented: $exporting, document: export, contentType: .png,
                      defaultFilename: String(localized: "GiroCrab-Fehlerbericht")) { _ in }
    }

    #if os(macOS)
    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button("Als PNG sichern …") { startExport() }
                    .disabled(!canExport)
                Spacer()
                Button { send() } label: {
                    Label("Issue auf GitHub öffnen", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSend)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        // opaque: the form scrolls underneath
        .background(Color(nsColor: .windowBackgroundColor))
    }
    #endif

    @ViewBuilder
    private var maskControls: some View {
        HStack {
            #if os(macOS)
            Button("Rückgängig", systemImage: "arrow.uturn.backward") { undoManager?.undo(); undoTick &+= 1 }
                .disabled(!canUndo)
            Button("Alle Markierungen entfernen") {
                replaceMasks(with: [], actionName: String(localized: "Markierungen entfernen"))
            }
            .disabled(masks.isEmpty)
            #else
            Button("Bereiche schwärzen …", systemImage: "rectangle.dashed") { markingUp = true }
                .disabled(!canExport)
            #endif
            Spacer()
            #if os(iOS)
            // macOS needs none: the report is a window beside the main one
            Button("Andere Ansicht aufnehmen …", systemImage: "rectangle.on.rectangle") { pickView() }
                .disabled(!model.isUnlocked || capturing)
            #endif
            Button("Neu aufnehmen", systemImage: "camera") { captureRun += 1 }
                .disabled(capturing)
        }
        .buttonStyle(.borderless)
    }

    #if os(iOS)
    /// Closes the report (and Settings, which hosts it) and shows the capture
    /// bar in the main view; it opens a new report from there.
    private func pickView() {
        model.reportPick = options
        // Settings takes its nested sheets (Hilfe, this report) with it; a
        // second dismissal in the same pass could be dropped.
        if model.showSettings { model.showSettings = false } else { close() }
    }
    #endif

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    @ViewBuilder
    private var screenshot: some View {
        if base != nil, dialogOmitted, !capturing {
            Label("Ein geöffneter Hinweis oder Bestätigungsdialog wird nicht aufgenommen; das Bild zeigt, was darunter liegt.",
                  systemImage: "info.circle")
                .appFont(.callout)
                .foregroundStyle(.secondary)
        }
        if let base {
            #if os(macOS)
            MaskCanvas(image: base, masks: masks, onAdd: addMask)
                .opacity(capturing ? 0.5 : 1)
            #else
            // Drawing inside the scrolling form would fight the scroll gesture:
            // marking up happens full screen ("Bereiche schwärzen …").
            MaskCanvas(image: base, masks: masks, interactive: false)
                .opacity(capturing ? 0.5 : 1)
                .onTapGesture { if !capturing { markingUp = true } }
            #endif
        } else {
            HStack {
                Spacer()
                if capturing {
                    ProgressView("Screenshot wird erstellt …")
                } else {
                    Text("Kein Screenshot: Das Hauptfenster ist geschlossen, minimiert, gesperrt oder wurde nicht rechtzeitig geschwärzt. „Neu aufnehmen“ versucht es erneut; sonst wird das Issue ohne Screenshot erstellt.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(minHeight: 160)
        }
    }

    // MARK: Masks (undoable)

    private func addMask(_ rect: CGRect) {
        replaceMasks(with: masks + [rect], actionName: String(localized: "Markierung hinzufügen"))
    }

    /// Every change goes through here, so Bearbeiten › Widerrufen / ⌘Z and the
    /// button undo it (and redo it: the undo registers the opposite change).
    private func replaceMasks(with new: [CGRect], actionName: String) {
        let old = masks
        masks = new
        undoManager?.registerUndo(withTarget: undoTarget) { _ in
            replaceMasks(with: old, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        undoTick &+= 1
    }

    private func capture() async {
        guard started else { return }
        capturing = true
        let result = await BugReport.captureMainWindow(model: model, redaction: redaction)
        guard !Task.isCancelled else { return }
        switch result {
        case .superseded:
            // the newer capture updates the picture; not stuck "busy" if none follows
            capturing = false
            return
        case .noWindow:
            base = nil
            dialogOmitted = false
        case .image(let image, let omitted):
            base = image
            dialogOmitted = omitted
        }
        // Unit rectangles drawn on the old picture may now cover something
        // else (the list scrolled, the window was resized): start over.
        masks.removeAll()
        undoManager?.removeAllActions(withTarget: undoTarget)
        undoTick &+= 1
        capturing = false
    }

    /// Log entries and payee names load together, or the log is left out:
    /// without the names a log line could carry a payee into the issue.
    private func prepareDiagnostics() async {
        guard started else { return }
        prepared = nil
        var entries: [SyncLogEntry] = []
        var counterparties: [String] = []
        var logUnavailable = false
        if options.includeLog {
            let filter = SyncLogFilter(connectionId: nil, onlyErrors: false, search: nil, limit: BugReport.logEntries)
            let limit = BugReport.maxCounterpartyTerms
            if let (log, names) = try? await model.vaultOffMain({ v in (try v.listSyncLog(filter: filter), try v.counterpartyNames(limit: limit)) }) {
                entries = log
                counterparties = names
            } else {
                logUnavailable = model.isUnlocked
            }
        }
        guard !Task.isCancelled else { return }
        let catalog = bankCatalog()
        let info = BugReport.info(model: model, log: entries, catalog: catalog)
        let terms = BugReport.knownTerms(model: model, counterparties: counterparties, catalog: catalog)
        let lines = info.logLines
        // thousands of terms: compiling and matching them can take well over a frame
        let (log, text) = await Task.detached(priority: .userInitiated) {
            let log = BugReport.sanitizedLog(lines, knownTerms: terms)
            return (log, BugReport.render(info, log: log))
        }.value
        guard !Task.isCancelled else { return }
        prepared = PreparedDiagnostics(info: info, log: log, text: text, logUnavailable: logUnavailable)
    }

    private func finalPNG() -> Data? {
        base.flatMap { BugReport.finalPNG(base: $0, masks: masks) }
    }

    private func startExport() {
        guard let png = finalPNG() else { return }
        export = PNGFileDocument(data: png)
        exporting = true
    }

    private func send() {
        guard canSend, let prepared else { return }
        let png = finalPNG()
        if let png { BugReport.copyToPasteboard(png) }
        let url = BugReport.issueURL(info: prepared.info, sanitizedLog: prepared.log, withScreenshot: png != nil)
        openURL(url)
        // Done: the picture is on the clipboard and the issue body says how to
        // paste it, so the report closes like any finished task.
        close()
    }
}

private final class MaskUndoTarget {}

#if os(iOS)
/// The picture as shared (#384): composed only when the share sheet asks.
private struct ReportImage: Transferable {
    let base: CGImage
    let masks: [CGRect]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            guard let png = BugReport.finalPNG(base: item.base, masks: item.masks) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return png
        }
        .suggestedFileName(String(localized: "GiroCrab-Fehlerbericht") + ".png")
    }
}
#endif

private struct CaptureKey: Hashable {
    var redaction: ReportRedaction
    var run: Int
    var started: Bool
}

private struct DiagnosticsKey: Hashable {
    var includeLog: Bool
    var unlocked: Bool
    var demo: Bool
    var started: Bool
}

private struct PreparedDiagnostics {
    var info: BugReport.Info
    /// Already sanitized.
    var log: [String]
    /// The diagnostics block as shown (and shared on iOS); built once.
    var text: String
    /// The log was asked for but could not be loaded with its payee names.
    var logUnavailable: Bool
}

/// The captured picture with the user's black boxes; dragging adds a box.
private struct MaskCanvas: View {
    let image: CGImage
    let masks: [CGRect]
    var interactive = true
    var onAdd: (CGRect) -> Void = { _ in }
    @State private var draft: CGRect?
    #if os(macOS)
    @State private var crosshair = false
    #endif

    var body: some View {
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let size = geo.size
                    let shown = masks + (draft.map { [$0] } ?? [])
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        ForEach(shown.indices, id: \.self) { i in
                            let m = shown[i]
                            Rectangle()
                                .fill(.black)
                                .frame(width: m.width * size.width, height: m.height * size.height)
                                .position(x: m.midX * size.width, y: m.midY * size.height)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { v in draft = unitRect(v.startLocation, v.location, in: size) }
                            .onEnded { v in
                                let r = unitRect(v.startLocation, v.location, in: size)
                                draft = nil
                                if r.width > 0.004, r.height > 0.004 { onAdd(r) }
                            }
                    )
                    .allowsHitTesting(interactive)
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4)) }
            #if os(macOS)
            // HIG: show that the picture takes a drag (crosshair over it).
            .onHover { inside in setCrosshair(interactive && inside) }
            .onDisappear { setCrosshair(false) }
            #endif
            .accessibilityElement()
            .accessibilityLabel("Vorschau des Screenshots")
            .accessibilityValue(masks.isEmpty
                ? String(localized: "Persönliche Daten sind abgedeckt.")
                : String(localized: "Persönliche Daten sind abgedeckt, dazu \(masks.count) eigene Markierungen."))
    }

    #if os(macOS)
    private func setCrosshair(_ on: Bool) {
        guard on != crosshair else { return }
        crosshair = on
        if on { NSCursor.crosshair.push() } else { NSCursor.pop() }
    }
    #endif

    private func unitRect(_ a: CGPoint, _ b: CGPoint, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        let x0 = clamp(min(a.x, b.x) / size.width), x1 = clamp(max(a.x, b.x) / size.width)
        let y0 = clamp(min(a.y, b.y) / size.height), y1 = clamp(max(a.y, b.y) / size.height)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

#if os(macOS)

/// The report is a one-off task: its window is not reopened at the next launch.
private struct NonRestorableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isRestorable = false
        }
    }
}
#endif

#if os(iOS)
/// Full-screen markup: dragging in the scrolling form would fight scrolling.
private struct MaskEditorScreen: View {
    let image: CGImage
    let masks: [CGRect]
    let canUndo: Bool
    let onAdd: (CGRect) -> Void
    let onUndo: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Ziehe Rechtecke über Stellen, die zusätzlich schwarz übermalt werden sollen.")
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                MaskCanvas(image: image, masks: masks, onAdd: onAdd)
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Bereiche schwärzen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Rückgängig", systemImage: "arrow.uturn.backward", action: onUndo)
                        .disabled(!canUndo)
                }
            }
        }
    }
}

/// iOS/iPadOS: Einstellungen › Problem melden. Marked, so a capture stops
/// below it: the report is never part of its own picture.
struct BugReportSheet: View {
    var onClose: (() -> Void)?

    var body: some View {
        NavigationStack { BugReportView(onClose: onClose) }
            .background(ReportWindowTracker(role: .report))
    }
}
#endif

#if os(iOS)
/// "Andere Ansicht aufnehmen" (#384, iOS: the report is a sheet that covers
/// the main view): floats over the main view and its sheets
/// (`ReportPickOverlay`) while the user moves to the view or dialog to
/// report; "Hier aufnehmen" opens a new report over it, which captures the
/// scene tapped. No personal data in it. The bar stays until that report
/// appears (`onAppear` ends the pick).
struct ReportPickBar: View {
    @Environment(AppModel.self) private var model
    /// Presents the report over whatever the scene shows on top; `false`
    /// when an alert blocks it.
    let openReport: () -> Bool
    /// Shown after "Hier aufnehmen" hit an alert.
    @State private var blocked = false

    var body: some View {
        VStack {
            Spacer()
            bar
        }
    }

    private var bar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text("Wechsle zur betroffenen Ansicht oder öffne den Dialog und nimm ihn dann auf.")
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { blocked = !openReport() } label: {
                    Label("Hier aufnehmen", systemImage: "camera")
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                Button("Abbrechen", systemImage: "xmark") { model.reportPick = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            if blocked {
                Text("Schließe zuerst den geöffneten Hinweis, dann wähle erneut „Hier aufnehmen“.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }
}
#endif

/// Opens the bug report: a window on macOS, a sheet on iOS.
struct BugReportButton: View {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #else
    @Environment(AppModel.self) private var model
    @State private var showing = false
    #endif

    var body: some View {
        #if os(macOS)
        Button { openWindow(id: "bug-report") } label: {
            Label("Problem melden …", systemImage: "ladybug")
        }
        #else
        // iOS: a row that opens a sheet carries no ellipsis.
        Button { showing = true } label: {
            Label("Problem melden", systemImage: "ladybug")
        }
        .sheet(isPresented: $showing) { BugReportSheet().environment(model) } // report: not captured (the report itself)
        #endif
    }
}
