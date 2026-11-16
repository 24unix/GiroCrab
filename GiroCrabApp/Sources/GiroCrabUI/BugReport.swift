import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import WebKit
import GiroCrabCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Hilfe › Problem melden … (GiroCrab/GiroCrab#301): a screenshot of the main
/// window with personal data drawn as placeholders, a scrubbed diagnostics
/// block, and a prefilled GitHub issue. Nothing leaves the device until the
/// user pastes the picture and submits the issue in the browser.
enum BugReport {
    static let newIssue = URL(string: "https://github.com/GiroCrab/GiroCrab/issues/new")!
    /// GitHub answers longer `issues/new` URLs with an error; measured on the
    /// percent-encoded URL (umlauts and "·" take 6 bytes there).
    static let maxURLLength = 7500
    /// Abrufprotokoll entries in the diagnostics.
    static let logEntries: UInt32 = 15

    /// The report's choices. Carried through "Andere Ansicht aufnehmen"
    /// (#384), so the report reopened there captures with the same ones.
    struct Options: Equatable, Sendable {
        /// Off only in the demo vault (fictitious data).
        var autoRedact = true
        var hideLabels = false
        var includeLog = true

        func redaction(demo: Bool) -> ReportRedaction {
            var r: ReportRedaction = autoRedact || !demo ? .personal : []
            if hideLabels { r.insert(.labels) }
            return r
        }
    }

    // MARK: Screenshot

    enum CaptureResult {
        /// `dialogOmitted`: a dialog over the main window is not in the
        /// picture (an alert, or one whose redaction was not confirmed); it
        /// shows what lies under it.
        case image(CGImage, dialogOmitted: Bool)
        /// No main window showing the vault (closed, minimized, locked), or
        /// the redacted view was not confirmed as built: no picture rather
        /// than an unredacted one.
        case noWindow
        /// A newer capture took over; keep whatever is shown.
        case superseded
    }

    @MainActor private static var captureToken = 0


    #if os(macOS)
    typealias PlatformWindow = NSWindow
    #else
    typealias PlatformWindow = UIWindow
    #endif
    typealias Tracker = ReportWindowTracker.TrackingView

    /// Trackers of the windows showing `MainSplitView` (the only window a
    /// capture starts from), of the dialogs over them and (iOS) of the report
    /// sheet. Any other window (Hilfe, Abruf-Protokoll, a locked main
    /// window) is never captured.
    @MainActor private static let trackers = NSHashTable<Tracker>.weakObjects()

    @MainActor static func track(_ tracker: Tracker) { trackers.add(tracker) }
    @MainActor static func untrack(_ tracker: Tracker) { trackers.remove(tracker) }

    @MainActor private static func trackers(_ role: ReportWindowTracker.Role) -> [Tracker] {
        trackers.allObjects.filter { $0.role == role && $0.window != nil }
    }

    /// Some window shows the vault (closed and locked ones do not).
    @MainActor static var hasMainWindow: Bool { !mainWindows().isEmpty }

    /// The redaction `window`'s main views were last built with (per window:
    /// on a Mac or an iPad several main windows can be open).
    @MainActor
    static func renderedRedaction(in window: PlatformWindow) -> ReportRedaction {
        trackers(.main).first { $0.window === window }?.renderedRedaction ?? []
    }

    /// How long a capture waits for the redacted views to be built.
    static let renderTimeout: Duration = .seconds(2)

    /// Redraws the main window and the dialogs over it with `redaction`,
    /// captures them and restores the normal view. A later call wins: an
    /// earlier one that is still waiting returns `.superseded`, so it can
    /// never reset the redaction under a newer capture.
    @MainActor
    static func captureMainWindow(model: AppModel, redaction: ReportRedaction,
                                  settle: Duration = .milliseconds(180)) async -> CaptureResult {
        captureToken += 1
        let token = captureToken
        model.reportRedaction = redaction
        defer { if captureToken == token { model.reportRedaction = [] } }
        // Lets SwiftUI lay out and draw the placeholders (lists need more than one frame).
        try? await Task.sleep(for: settle)
        // Fail closed: capture only once the views of the very window that is
        // captured report the redaction (a minimized window, a second main
        // window or a slow machine may not have rebuilt them yet), and draw a
        // dialog only once its own views do.
        guard !Task.isCancelled, captureToken == token else { return .superseded }
        guard let window = mainWindow() else { return .noWindow }
        // `isSuperset`: `--redact` may add more than this capture asked for.
        let ready = { (r: ReportRedaction) in r.isSuperset(of: redaction) }
        let allReady = {
            ready(renderedRedaction(in: window))
                && dialogLayers(over: window).allSatisfy { $0.tracker.map { ready($0.renderedRedaction) } ?? true }
        }
        let deadline = ContinuousClock.now + renderTimeout
        while !allReady(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard !Task.isCancelled, captureToken == token, model.reportRedaction == redaction else { return .superseded }
        guard ready(renderedRedaction(in: window)) else { return .noWindow }
        // Bottom up; the first dialog that cannot be drawn ends the stack
        // (anything above it would sit on top of it).
        let layers = dialogLayers(over: window)
        let drawable = Array(layers.prefix { $0.tracker.map { ready($0.renderedRedaction) } ?? false })
        guard let image = snapshot(window, dialogs: drawable, hideSearch: redaction.contains(.personal),
                                   coverInputs: !redaction.isEmpty) else {
            return .noWindow
        }
        return .image(image, dialogOmitted: drawable.count < layers.count)
    }

    /// The main windows with content to draw, whatever their state.
    @MainActor
    static func mainWindows() -> [PlatformWindow] {
        let windows = trackers(.main).compactMap(\.window)
        #if os(macOS)
        return windows.filter { $0.contentView != nil }
        #else
        return windows.filter { $0.rootViewController != nil } // what `snapshot` draws
        #endif
    }

    /// Background of the smudge over a text input, pop-up menu or web page of
    /// a dialog (what the user typed or picked there is personal more often
    /// than not): the colour just inside the top left corner of `rect`
    /// (points, origin top left) of `image`, drawn at `scale`.
    private static func inputBackground(_ image: CGImage, _ rect: CGRect, scale: CGFloat) -> CGColor {
        RedactionSmudge.color(of: image, at: CGPoint(x: (rect.minX + 2) * scale, y: (rect.minY + 2) * scale))
            ?? RedactionSmudge.fallback
    }

    #if os(macOS)
    /// The frontmost window that shows the vault. A minimized or hidden one
    /// does not count: it may not redraw before the capture.
    @MainActor
    static func mainWindow() -> NSWindow? {
        guard let app = NSApp else { return nil } // nil in unit tests
        let windows = mainWindows().filter { $0.isVisible && !$0.isMiniaturized }
        return app.orderedWindows.first { windows.contains($0) }
    }

    struct DialogLayer {
        let window: NSWindow
        /// nil: not a capturable dialog (alert, system popover).
        let tracker: Tracker?
    }

    /// The sheets over `main` (a sheet can carry a sheet), then the popovers
    /// of `main` and of those sheets, bottom up, then the registered dialogs
    /// in windows of their own in front of `main` (Settings), each with its
    /// sheets. A dialog window of its own comes to the front when opened, so
    /// it lies above the main window and its sheets; drawing it last matches.
    @MainActor
    private static func dialogLayers(over main: NSWindow) -> [DialogLayer] {
        let dialogs = trackers(.dialog)
        func tracked(_ w: NSWindow) -> Tracker? { dialogs.first { $0.window === w } }

        // A capturable popover is known by its tracker; the class name finds
        // the others (system popovers), so they count as left out.
        func popovers(of hosts: [NSWindow]) -> [NSWindow] {
            hosts.flatMap { host in
                (host.childWindows ?? []).filter { w in
                    w.isVisible && !hosts.contains(w)
                        && (tracked(w) != nil || "\(type(of: w))".contains("Popover"))
                }
            }
        }

        /// `w` and the sheets over it (a sheet can carry a sheet).
        func sheetChain(from w: NSWindow) -> [NSWindow] {
            var chain = [w]
            while let sheet = chain.last?.attachedSheet { chain.append(sheet) }
            return chain
        }

        let hosts = sheetChain(from: main)
        var layers = (hosts.dropFirst() + popovers(of: hosts)).map { DialogLayer(window: $0, tracker: tracked($0)) }

        // `orderedWindows` runs front to back; draw back to front. Sheets of a
        // dialog window follow it (e.g. "Passwort vorschlagen" over Settings).
        var seen = Set(hosts.map(ObjectIdentifier.init))
        var separate: [NSWindow] = []
        for w in NSApp?.orderedWindows ?? [] {
            if w === main { break }
            guard w.isVisible, !w.isMiniaturized, !seen.contains(ObjectIdentifier(w)),
                  tracked(w) != nil else { continue }
            separate.append(w)
        }
        for w in separate.reversed() {
            let chain = sheetChain(from: w)
            chain.forEach { seen.insert(ObjectIdentifier($0)) }
            layers += (chain + popovers(of: chain)).map { DialogLayer(window: $0, tracker: tracked($0)) }
        }
        return layers
    }

    /// `hideSearch`: search fields are drawn by AppKit, so `.sensitive()`
    /// cannot cover them. Every `NSSearchField` in the window (toolbar or
    /// not, whichever way SwiftUI hosts `.searchable`) shows a placeholder for
    /// the snapshot only; setting `stringValue` sends no action or
    /// text-change notification, so the search binding and the list stay.
    /// `dialogs` are drawn at their place over the window (sheets and
    /// popovers are windows of their own), with their inputs covered when
    /// `coverInputs` (anything is to be hidden at all).
    @MainActor
    private static func snapshot(_ window: NSWindow, dialogs: [DialogLayer], hideSearch: Bool, coverInputs: Bool) -> CGImage? {
        guard window.isVisible, !window.isMiniaturized else { return nil }
        let fields = hideSearch ? searchFields(in: window) : []
        let saved = fields.map(\.stringValue)
        for f in fields where !f.stringValue.isEmpty { f.stringValue = ReportRedaction.placeholder }
        defer { for (f, text) in zip(fields, saved) where f.stringValue != text { f.stringValue = text } }
        guard let base = WindowScreenshot.bitmap(of: window)?.cgImage else { return nil }
        guard !dialogs.isEmpty else { return base }
        // A dialog window of its own (Settings) can stand beside the main
        // window: the canvas covers all of them, or it would be cut off.
        let area = dialogs.reduce(window.frame) { $0.union($1.window.frame) }
        let scale = CGFloat(base.width) / window.frame.width
        let width = Int(ceil(area.width * scale)), height = Int(ceil(area.height * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Screen and CoreGraphics both count y from the bottom.
        func place(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - area.minX) * scale, y: (r.minY - area.minY) * scale,
                   width: r.width * scale, height: r.height * scale)
        }
        ctx.draw(base, in: place(window.frame))
        for layer in dialogs {
            let w = layer.window
            guard let image = WindowScreenshot.bitmap(of: w)?.cgImage else { return nil } // fail closed
            ctx.draw(image, in: place(w.frame))
            let s = CGFloat(image.width) / w.frame.width
            for r in coverInputs ? inputRects(in: w) : [] {
                // `r` counts y from the bottom, the bitmap from the top.
                let top = CGRect(x: r.minX, y: w.frame.height - r.maxY, width: r.width, height: r.height)
                RedactionSmudge.draw(in: ctx, rect: place(r.offsetBy(dx: w.frame.minX, dy: w.frame.minY)),
                                     background: inputBackground(image, top, scale: s))
            }
        }
        return ctx.makeImage()
    }

    /// Text fields (search fields included), text views, pop-up menus and web
    /// pages (a bank or portal login) of `window`, in window coordinates.
    @MainActor
    private static func inputRects(in window: NSWindow) -> [CGRect] {
        views(of: window).compactMap { v in
            let isInput = (v as? NSTextField)?.isEditable == true || v is NSTextView || v is NSPopUpButton || v is WKWebView
            guard isInput, !v.isHiddenOrHasHiddenAncestor else { return nil }
            // `visibleRect` is the whole window for controls SwiftUI hosts:
            // clip the bounds to the scroll view they sit in instead
            var r = v.convert(v.bounds, to: nil)
            if let clip = v.enclosingScrollView { r = r.intersection(clip.convert(clip.bounds, to: nil)) }
            return r.isEmpty ? nil : r
        }
    }

    @MainActor
    static func searchFields(in window: NSWindow) -> [NSSearchField] {
        let toolbar = window.toolbar?.items.compactMap { ($0 as? NSSearchToolbarItem)?.searchField } ?? []
        let tree = views(of: window).compactMap { $0 as? NSSearchField }
        var seen = Set<ObjectIdentifier>()
        return (toolbar + tree).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// Every view of `window`, title bar included (the frame view).
    @MainActor
    private static func views(of window: NSWindow) -> [NSView] {
        var out: [NSView] = []
        func visit(_ v: NSView) { out.append(v); v.subviews.forEach(visit) }
        (window.contentView?.superview ?? window.contentView).map(visit)
        return out
    }
    #else
    /// The window that shows the vault in a foreground scene (an iPad may
    /// show several): the one the report sheet is presented in, as that is
    /// the scene the user asked from ("Hier aufnehmen"), else the key one.
    @MainActor
    static func mainWindow() -> UIWindow? {
        let windows = mainWindows()
            .filter { $0.windowScene?.activationState == .foregroundActive }
        let reports = trackers(.report).compactMap(\.window)
        return windows.first { w in reports.contains { $0 === w } }
            ?? windows.first(where: \.isKeyWindow) ?? windows.first
    }

    struct DialogLayer {
        let controller: UIViewController
        /// nil: not a capturable dialog (alert, system sheet).
        let tracker: Tracker?
    }

    /// The view controllers presented over the main view, bottom up, up to
    /// the report sheet (it and anything above it are never drawn).
    @MainActor
    private static func dialogLayers(over window: UIWindow) -> [DialogLayer] {
        let dialogs = trackers(.dialog), reports = trackers(.report)
        var layers: [DialogLayer] = []
        var current = window.rootViewController
        while let next = current?.presentedViewController {
            guard let view = next.viewIfLoaded else { break }
            if reports.contains(where: { $0.isDescendant(of: view) }) { break }
            layers.append(DialogLayer(controller: next, tracker: dialogs.first { $0.isDescendant(of: view) }))
            current = next
        }
        return layers
    }

    /// `hideSearch`: UIKit draws the search field. It gets an opaque cover
    /// for the snapshot instead of new text, so `.searchable` never sees a
    /// change. `dialogs` are drawn over the main view (sheets dimmed, as on
    /// screen), with their inputs covered when `coverInputs`.
    @MainActor
    private static func snapshot(_ window: UIWindow, dialogs: [DialogLayer], hideSearch: Bool, coverInputs: Bool) -> CGImage? {
        guard let view = window.rootViewController?.view else { return nil }
        let covers: [UIView] = hideSearch ? searchFields(in: view).compactMap { field in
            guard !(field.text ?? "").isEmpty, field.window != nil else { return nil }
            let cover = SmudgeView(frame: field.convert(field.bounds, to: view))
            cover.layer.cornerRadius = 6
            cover.clipsToBounds = true
            view.addSubview(cover)
            return cover
        } : []
        defer { covers.forEach { $0.removeFromSuperview() } }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { ctx in
            view.drawHierarchy(in: view.convert(view.bounds, to: window), afterScreenUpdates: true)
            for layer in dialogs {
                let dialog = layer.controller.view!
                if !isPopover(layer.controller, in: window) { // the system dims below a sheet only
                    UIColor.black.withAlphaComponent(0.2).setFill()
                    ctx.fill(window.bounds)
                }
                dialog.drawHierarchy(in: dialog.convert(dialog.bounds, to: window), afterScreenUpdates: true)
                let rects = coverInputs ? inputRects(in: dialog, window: window) : []
                guard !rects.isEmpty else { continue }
                let drawn = ctx.currentImage.cgImage
                for r in rects {
                    let bg = drawn.map { inputBackground($0, r, scale: format.scale) } ?? RedactionSmudge.fallback
                    RedactionSmudge.draw(in: ctx.cgContext, rect: r, background: bg)
                }
            }
        }
        return image.cgImage
    }

    /// A popover that stays one (not adapted to a sheet on a narrow screen).
    private static func isPopover(_ controller: UIViewController, in window: UIWindow) -> Bool {
        guard controller.modalPresentationStyle == .popover, let p = controller.presentationController else { return false }
        return p.adaptivePresentationStyle(for: window.traitCollection) == .none
    }

    /// Text fields (search fields included), text views and web pages (a
    /// bank or portal login) in `view`, in `window` coordinates, clipped to
    /// the scroll view they sit in (a field scrolled under the navigation bar
    /// must not cover it). A field inside a hidden or fully transparent
    /// container is not on screen and must not get a box over other content.
    private static func inputRects(in view: UIView, window: UIWindow) -> [CGRect] {
        descendants(of: view).compactMap { v in
            guard v is UITextField || v is UITextView || v is WKWebView, v.window != nil, !isEffectivelyHidden(v)
            else { return nil }
            var r = v.convert(v.bounds, to: window)
            var node = v.superview
            while let s = node, !(s is UIScrollView) { node = s.superview }
            // Its bounds reach under the bars; the insets are what they cover.
            if let clip = node as? UIScrollView {
                r = r.intersection(clip.convert(clip.bounds.inset(by: clip.adjustedContentInset), to: window))
            }
            return r.isEmpty ? nil : r
        }
    }

    /// Hidden, or inside a hidden/transparent ancestor (UIKit has no
    /// `isHiddenOrHasHiddenAncestor` as AppKit does).
    private static func isEffectivelyHidden(_ view: UIView) -> Bool {
        var node: UIView? = view
        while let v = node {
            if v.isHidden || v.alpha == 0 { return true }
            node = v.superview
        }
        return false
    }

    /// The smudge over a search field while the snapshot is drawn, on the
    /// background the field stands on.
    private final class SmudgeView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = true
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ rect: CGRect) {
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            RedactionSmudge.draw(in: ctx, rect: bounds, background: UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor)
        }
    }

    private static func searchFields(in view: UIView) -> [UISearchTextField] {
        descendants(of: view).compactMap { $0 as? UISearchTextField }
    }

    /// `view` and every view below it.
    private static func descendants(of view: UIView) -> [UIView] {
        var out: [UIView] = []
        func visit(_ v: UIView) { out.append(v); v.subviews.forEach(visit) }
        visit(view)
        return out
    }
    #endif

    /// `base` with black boxes over `masks` (unit rectangles, origin top left).
    static func compose(_ base: CGImage, masks: [CGRect]) -> CGImage? {
        let width = base.width, height = base.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(base, in: full)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for m in masks {
            // CoreGraphics counts y from the bottom.
            let r = CGRect(x: m.minX * full.width, y: (1 - m.maxY) * full.height,
                           width: m.width * full.width, height: m.height * full.height)
            ctx.fill(r.integral.intersection(full))
        }
        return ctx.makeImage()
    }

    /// The picture as it leaves the app (issue, file, share sheet): the
    /// redacted capture with the user's own boxes.
    static func finalPNG(base: CGImage, masks: [CGRect]) -> Data? {
        compose(base, masks: masks).flatMap(png)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    @MainActor
    static func copyToPasteboard(_ png: Data) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        #else
        UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
        #endif
    }

    // MARK: Diagnostics

    /// One Abrufprotokoll entry: `head` is built by the app from time,
    /// connector kind, trigger and result (no user data); `message` is the
    /// bank's text and the only part that passes the sanitizer.
    struct LogLine: Equatable, Sendable {
        var head: String
        var message: String
    }

    /// What the diagnostics block shows.
    struct Info: Equatable, Sendable {
        var appVersion: String
        var system: String
        var architecture: String
        var language: String
        var demo: Bool
        var connectors: [String]
        var logLines: [LogLine]
    }

    /// The diagnostics block. Only the log lines carry user data: they pass
    /// the core sanitizer with `knownTerms`; the header is built from
    /// version, system and connector names alone.
    static func diagnostics(_ info: Info, knownTerms: [String]) -> String {
        render(info, log: sanitizedLog(info.logLines, knownTerms: knownTerms))
    }

    /// The log lines with sanitized messages (IBANs, e-mails, amounts,
    /// secrets, long numbers and the vault's own names are replaced). The
    /// head is left alone: an account named like its bank ("PayPal") must not
    /// blank out the connector column.
    /// Pure and vault-free: run it off the main thread (thousands of terms).
    static func sanitizedLog(_ lines: [LogLine], knownTerms: [String]) -> [String] {
        guard !lines.isEmpty else { return [] }
        // One call for all messages (one regex build). The closing "." keeps a
        // trailing empty message from being dropped by the line split.
        let joined = (lines.map(\.message) + ["."]).joined(separator: "\n")
        var messages = sanitizeReportText(text: joined, knownTerms: knownTerms).components(separatedBy: "\n")
        messages.removeLast()
        guard messages.count == lines.count else {
            // never expected; fall back to one call per message
            return lines.map { line(head: $0.head, message: sanitizeReportText(text: $0.message, knownTerms: knownTerms)) }
        }
        return zip(lines, messages).map { line(head: $0.head, message: $1) }
    }

    private static func line(head: String, message: String) -> String {
        message.isEmpty ? head : "\(head) · \(message)"
    }

    static func render(_ info: Info, log: [String]) -> String {
        var lines = [
            "GiroCrab \(info.appVersion)",
            "\(info.system) · \(info.architecture)",
            String(localized: "Sprache: \(info.language) · Demo-Modus: \(info.demo ? String(localized: "ja") : String(localized: "nein"))"),
            String(localized: "Anbindungen: \(info.connectors.isEmpty ? "–" : info.connectors.joined(separator: ", "))"),
        ]
        if !log.isEmpty {
            lines.append("")
            lines.append(String(localized: "Abruf-Protokoll (neueste zuerst):"))
            lines.append(contentsOf: log)
        }
        return lines.joined(separator: "\n")
    }

    /// Counterparty names read from the vault at most (newest first).
    static let maxCounterpartyTerms: UInt32 = 5000

    /// Everything personal the vault knows that might turn up in a log line:
    /// own accounts, owners, IBANs and logins, and the counterparties of all
    /// bookings (`counterparties`, from `Vault.counterpartyNames`: a rejected
    /// transfer names its payee, whatever the list currently shows).
    @MainActor
    static func knownTerms(model: AppModel, counterparties: [String],
                           catalog: [BankDescriptor] = bankCatalog()) -> [String] {
        let accounts = model.accountsByID.values.flatMap { [$0.name, $0.owner, $0.iban, $0.accountNumber] }
        let connections = model.connections.flatMap { [$0.displayName, $0.loginName] }
        // Bank and connector names are not personal, and an account named like
        // its bank ("PayPal") must not blank the bank out of every message.
        let banks = Set((catalog.map(\.name) + model.accountsByID.values.map(\.bankName)).map(normalizedTerm))
        return publicTermsRemoved(accounts + connections + counterpartyTerms(counterparties), banks: banks)
    }

    /// Booking texts that stand where a payee would ("VISA", "Zinsen",
    /// "Entgelt"): as terms they would blank ordinary words in every log line.
    static let bookingWords: Set<String> = [
        "abbuchung", "abrechnung", "abschluss", "auszahlung", "bank", "bargeld", "bonus", "dauerauftrag",
        "einzahlung", "entgelt", "gebühr", "gebühren", "gehalt", "girocard", "gutschrift", "habenzinsen",
        "kartenzahlung", "kasse", "konto", "kontoführung", "kreditkarte", "lastschrift", "lohn",
        "mastercard", "miete", "online", "paypal", "rechnungsabschluss", "rente", "rücklastschrift",
        "sepa", "sollzinsen", "steuer", "storno", "transfer", "umbuchung", "visa", "zins", "zinsen",
        "überweisung",
    ]

    /// Counterparties as redaction terms: every name of two words or more,
    /// and single words of four letters or more ("Müller", "Meier") unless
    /// they are booking words. Better a blanked word than a published payee.
    static func counterpartyTerms(_ names: [String]) -> [String] {
        names.filter { name in
            let words = name.split { !$0.isLetter && !$0.isNumber }
            if words.count >= 2 { return true }
            guard let word = words.first, word.count >= 4 else { return false }
            return !bookingWords.contains(word.lowercased())
        }
    }

    static func publicTermsRemoved(_ terms: [String], banks: Set<String>) -> [String] {
        var seen = Set<String>()
        return terms.filter { t in
            let key = normalizedTerm(t)
            return !key.isEmpty && !banks.contains(key) && seen.insert(key).inserted
        }
    }

    private static func normalizedTerm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    @MainActor
    static func info(model: AppModel, log: [SyncLogEntry], catalog: [BankDescriptor] = bankCatalog()) -> Info {
        let connectorName = connectorNamer(catalog)
        return Info(
            appVersion: AppVersionDisplay.current(core: coreVersion()),
            system: systemDescription,
            architecture: architecture,
            language: Locale.current.identifier,
            demo: model.isDemo,
            connectors: Set(model.connections.map(\.connector)).map(connectorName).sorted(),
            logLines: logLines(model: model, entries: log, connectorName: connectorName)
        )
    }

    private static func connectorNamer(_ catalog: [BankDescriptor]) -> (ConnectorKind) -> String {
        { kind in
            guard let d = catalog.first(where: { $0.kind == kind }) else { return "\(kind)" }
            return d.protocol.isEmpty || d.protocol == d.name ? d.name : "\(d.name) (\(d.protocol))"
        }
    }

    @MainActor
    private static func logLines(model: AppModel, entries log: [SyncLogEntry],
                                 connectorName: (ConnectorKind) -> String) -> [LogLine] {
        let byConnection = Dictionary(model.connections.map { ($0.id, $0.connector) }, uniquingKeysWith: { a, _ in a })
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "yyyy-MM-dd HH:mm"
        return log.map { e in
            // The connection's own name is the user's; the connector kind is enough.
            let kind = e.connectionId.flatMap { byConnection[$0] }.map(connectorName) ?? "–"
            let date = time.string(from: Date(timeIntervalSince1970: TimeInterval(e.timestampMs) / 1000))
            var head = "\(date) · \(kind) · \(e.source) · \(e.outcome)"
            if e.imported > 0 { head += " · +\(e.imported)" }
            return LogLine(head: head, message: e.message.replacingOccurrences(of: "\n", with: " "))
        }
    }

    @MainActor
    private static var systemDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        #if os(macOS)
        return "macOS \(version)"
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac { return "iOS-App auf macOS \(version)" }
        return "\(UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS") \(version) · \(UIDevice.current.model)"
        #endif
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    // MARK: Issue

    static var pasteHint: String {
        #if os(macOS)
        String(localized: "📋 Der geschwärzte Screenshot liegt in deiner Zwischenablage – klicke hier ins Textfeld und drücke **⌘V**, um ihn einzufügen.")
        #else
        String(localized: "📋 Der geschwärzte Screenshot liegt in deiner Zwischenablage – tippe hier lange ins Textfeld und wähle **Einsetzen**.")
        #endif
    }

    /// Markdown body of the new issue. With `withScreenshot` false the paste
    /// hint is left out.
    static func issueBody(diagnostics: String, withScreenshot: Bool) -> String {
        var parts = [
            "### " + String(localized: "Was ist passiert?"),
            "",
            String(localized: "<!-- Beschreibe kurz das Problem: Was hast du getan, was hast du erwartet, was ist stattdessen passiert? Bitte keine echten IBANs, Namen oder Buchungsdaten. -->"),
            "",
        ]
        if withScreenshot {
            parts += ["### " + String(localized: "Screenshot"), "", pasteHint, ""]
        }
        // A fence longer than any backtick run in the text: a log line with
        // "```" must not end the block (and turn "@name" or "#123" live).
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(diagnostics) + 1))
        parts += ["### " + String(localized: "Diagnose (automatisch bereinigt)"), "", fence + "text", diagnostics, fence]
        return parts.joined(separator: "\n")
    }

    static func longestBacktickRun(_ s: String) -> Int {
        var longest = 0, run = 0
        for c in s {
            run = c == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }

    /// The prefilled `issues/new` URL. Drops log lines from the end (the
    /// oldest) until the encoded URL fits `maxURLLength`.
    static func issueURL(info: Info, knownTerms: [String], withScreenshot: Bool) -> URL {
        issueURL(info: info, sanitizedLog: sanitizedLog(info.logLines, knownTerms: knownTerms), withScreenshot: withScreenshot)
    }

    /// Same, with log lines already passed through `sanitizedLog`.
    static func issueURL(info: Info, sanitizedLog: [String], withScreenshot: Bool) -> URL {
        var log = sanitizedLog
        var body: String
        var url: URL
        repeat {
            body = issueBody(diagnostics: render(info, log: log), withScreenshot: withScreenshot)
            url = issueURL(body: body)
            if url.absoluteString.utf8.count <= maxURLLength || log.isEmpty { break }
            log.removeLast()
        } while true
        // Without any log line still too long (not expected): cut the text.
        while url.absoluteString.utf8.count > maxURLLength, !body.isEmpty {
            body = String(body.dropLast(max(1, body.count / 10)))
            url = issueURL(body: body)
        }
        return url
    }

    private static func issueURL(body: String) -> URL {
        var c = URLComponents(url: newIssue, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "title", value: "[BUG] "), URLQueryItem(name: "body", value: body)]
        // URLComponents leaves "+" alone, but GitHub decodes it as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }
}

struct PNGFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
