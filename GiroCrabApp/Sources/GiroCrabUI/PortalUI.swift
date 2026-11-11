import SwiftUI
import WebKit
import PDFKit
import UniformTypeIdentifiers
import GiroCrabCore

// MARK: - Model glue (American Express / Amazon Visa: keyless import)

extension AppModel {
    /// Amex / Amazon Visa use the embedded web portal unless the user switched
    /// that card to Enable Banking (PSD2) under "Erweitert" *and* set the
    /// credentials. The credentials alone don't count: they are shared with
    /// PSD2 banks such as C24 and must not move the cards off the web login.
    func usesPortal(_ c: BankConnection) -> Bool {
        if !isDemo, c.connector == .amazonOrders { return true }
        guard !isDemo, c.connector == .americanExpress || c.connector == .amazonVisa else { return false }
        return !Self.cardUsesEnableBanking(
            optIn: settingEntry(Self.enableBankingOptInKey(c.connector))?.value,
            hasApp: settingEntry("enablebanking.application_id")?.hasValue ?? false,
            hasKey: settingEntry("enablebanking.private_key_pem")?.hasValue ?? false)
    }

    static func enableBankingOptInKey(_ kind: ConnectorKind) -> String {
        kind == .amazonVisa ? "enablebanking.use.amazonvisa" : "enablebanking.use.amex"
    }

    static func cardUsesEnableBanking(optIn: String?, hasApp: Bool, hasKey: Bool) -> Bool {
        optIn?.trimmingCharacters(in: .whitespaces) == "1" && hasApp && hasKey
    }

    /// Returns true when transactions were recognised (even if all were already known).
    @discardableResult
    func importPortalCapture(_ c: BankConnection, bodies: [String], domRowsJSON: String) -> Bool {
        guard let vault else { return false }
        do {
            let s = try vault.importPortalCapture(connectionId: c.id, jsonBodies: bodies, domRowsJson: domRowsJSON)
            toast = String(localized: "\(c.displayName): \(s.transactionsImported) neue Buchungen, \(s.transactionsCategorized) kategorisiert")
                + Self.skippedArchivedNote(s)
            reloadAll()
            return true
        } catch {
            AppModel.debugLog("portal import failed: \(describe(error))")
            return false
        }
    }

    /// Number of bookings currently recognised in the captured JSON / visible table (nothing stored).
    func previewPortalCapture(_ c: BankConnection, bodies: [String], domRowsJSON: String) -> Int {
        guard let vault else { return 0 }
        return Int((try? vault.previewPortalCapture(connectionId: c.id, jsonBodies: bodies, domRowsJson: domRowsJSON)) ?? 0)
    }

    func importStatement(_ c: BankConnection, url: URL) {
        guard let vault else { return }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            var hint = ""
            if data.starts(with: Array("%PDF".utf8)) { hint = PDFDocument(data: data)?.string ?? "" }
            let s = try vault.importStatement(connectionId: c.id, fileName: url.lastPathComponent, bytes: data, pdfTextHint: hint)
            toast = String(localized: "\(c.displayName): \(s.transactionsImported) neue Buchungen aus \(url.lastPathComponent)")
            reloadAll()
        } catch let e as CoreError {
            if case .InvalidInput = e {
                errorMessage = String(localized: "In \(url.lastPathComponent) wurden keine Umsätze erkannt. Erwartet: CSV mit Datum, Beschreibung, Betrag oder ein Kontoauszug als PDF mit Textebene.")
            } else {
                errorMessage = describe(e)
            }
        } catch {
            errorMessage = describe(error)
        }
    }
}

extension ConnectorKind {
    var portalURL: URL? {
        switch self {
        case .americanExpress: return URL(string: "https://global.americanexpress.com/activity/recent")
        case .amazonVisa: return URL(string: "https://www.openbank.de")
        case .amazonOrders: return URL(string: "https://www.amazon.de/gp/css/order-history")
        default: return nil
        }
    }
    var portalHosts: [String] {
        switch self {
        case .americanExpress: return ["americanexpress.com", "aexp.com"]
        case .amazonVisa: return ["openbank.de", "openbank.com", "zinia.de", "zinia.com"]
        case .amazonOrders: return ["amazon.de", "amazon.com"]
        default: return []
        }
    }
}

/// Removes the persisted web-portal cookies/session for this connector.
@MainActor
func clearPortalSession(_ kind: ConnectorKind) async {
    let store = WKWebsiteDataStore.default()
    let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
    let hosts = kind.portalHosts
    await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records.filter { r in hosts.contains { r.displayName.contains($0) } })
}

// MARK: - Embedded browser

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: PortalBrowser?
    init(_ t: PortalBrowser) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any], let body = d["body"] as? String else { return }
        Task { @MainActor in self.target?.captured(body) }
    }
}

/// Persistent (default) WKWebsiteDataStore: cookies survive restarts, so later
/// syncs reuse the session. A user script mirrors the portal's own JSON
/// fetch/XHR responses to the app.
@MainActor
@Observable
final class PortalBrowser {
    let webView: WKWebView
    private(set) var bodies: [String] = []
    private(set) var lastCapture: Date?
    private(set) var loading = true
    private(set) var currentURL: URL?
    private var observation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?

    /// Login / 2FA / consent pages: never auto-import while the user is on one of these.
    var onLoginPage: Bool {
        guard let u = currentURL else { return true }
        let s = (u.host ?? "") + u.path + "?" + (u.query ?? "")
        let hints = ["login", "logon", "signin", "sign-in", "sign_in", "authenticate", "auth/", "2fa", "mfa", "otp", "sso", "verify", "challenge",
                     "password", "passwort", "anmeld", "acceso", "tan", "freigabe", "consent"]
        return hints.contains { s.lowercased().contains($0) } || u.absoluteString == "about:blank"
    }

    static let hook = """
    (function(){
      if (window.__gcHooked) return; window.__gcHooked = true;
      var post = function(url, body) { try {
        if (!body || body.length > 3000000) return;
        var t = body.trim().charAt(0); if (t !== '{' && t !== '[') return;
        if (!/transaction|activity|balance|account|statement|card|umsa|booking|posting/i.test(String(url))) return;
        window.webkit.messageHandlers.girocrab.postMessage({url: String(url), body: body});
      } catch (e) {} };
      var of = window.fetch;
      if (of) { window.fetch = function() {
        var a = arguments, p = of.apply(this, a);
        p.then(function(r) { try { var u = (a[0] && a[0].url) || a[0]; r.clone().text().then(function(b) { post(u, b); }); } catch (e) {} }).catch(function(){});
        return p; }; }
      var ox = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u) {
        this.__gcu = u;
        this.addEventListener('load', function() { try { if (this.responseType === '' || this.responseType === 'text') post(this.__gcu, this.responseText); } catch (e) {} });
        return ox.apply(this, arguments); };
    })();
    """

    static let domRows = """
    (function(){ var rows = [];
      document.querySelectorAll('tr,[role="row"]').forEach(function(r) { var cells = [];
        r.querySelectorAll('td,th,[role="cell"],[role="gridcell"]').forEach(function(c) {
          var t = (c.innerText || '').trim().replace(/\\s+/g, ' '); if (t) cells.push(t); });
        if (cells.length >= 2) rows.push(cells); });
      return JSON.stringify(rows); })()
    """

    /// `captureTraffic: false` leaves the page untouched (no injected fetch/XHR hook) and
    /// identifies as desktop Safari – used for Amazon, whose sign-in is picky about both.
    init(url: URL, captureTraffic: Bool = true) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let ucc = WKUserContentController()
        if captureTraffic {
            ucc.addUserScript(WKUserScript(source: Self.hook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        cfg.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: cfg)
        if !captureTraffic {
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        }
        ucc.add(WeakHandler(self), name: "girocrab")
        observation = webView.observe(\.isLoading) { [weak self] w, _ in
            Task { @MainActor in self?.loading = w.isLoading }
        }
        urlObservation = webView.observe(\.url) { [weak self] w, _ in
            Task { @MainActor in self?.currentURL = w.url }
        }
        webView.load(URLRequest(url: url))
    }

    func captured(_ body: String) {
        bodies.append(body)
        if bodies.count > 60 { bodies.removeFirst(bodies.count - 60) }
        lastCapture = Date()
    }

    func domRowsJSON() async -> String {
        (try? await webView.evaluateJavaScript(Self.domRows) as? String) ?? "[]"
    }

    func teardown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "girocrab")
        observation = nil
        urlObservation = nil
    }
}

#if os(macOS)
struct PortalWebView: NSViewRepresentable {
    let browser: PortalBrowser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct PortalWebView: UIViewRepresentable {
    let browser: PortalBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

// MARK: - Sheet

struct PortalWebSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connection: BankConnection
    @State private var browser: PortalBrowser
    @State private var busy = false
    @State private var importing = false
    @State private var recognized = 0
    @State private var lastChange = Date()
    @State private var lastSeenCount = 0

    init(connection: BankConnection) {
        self.connection = connection
        _browser = State(initialValue: PortalBrowser(url: connection.connector.portalURL ?? URL(string: "about:blank")!))
    }

    private var info: String {
        if browser.onLoginPage { return String(localized: "Melden Sie sich wie gewohnt an (Benutzername, Passwort, 2FA) und öffnen Sie die Umsatzübersicht.") }
        if recognized == 0 { return String(localized: "Angemeldet – öffnen Sie die Umsatzübersicht, damit das Portal die Buchungen lädt.") }
        return String(localized: "\(recognized) Umsätze erkannt – Übernahme startet automatisch, sobald die Seite fertig geladen ist.")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SymbolTile(symbol: "safari", tint: connection.connector.tint, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(connection.displayName) – Direkt-Login").font(.headline)
                    Text(info).font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Label("Erkannte Umsätze: \(recognized)", systemImage: recognized > 0 ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(recognized > 0 ? Theme.inflow : Theme.secondary)
                if busy || browser.loading { ProgressView().controlSize(.small) }
            }
            .padding(14)
            Divider()
            PortalWebView(browser: browser)
                .macFrame(minWidth: 760, minHeight: 640)
            Divider()
            HStack {
                Button("Abbrechen", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button { importing = true } label: { Label("CSV- oder PDF-Kontoauszug importieren", systemImage: "doc.badge.plus") }
                if recognized == 0 && !browser.onLoginPage {
                    Button("Portal-Struktur prüfen") { Task { await dumpSchema() } }
                        .help("Speichert nur Feldnamen und Typen (keine Werte) nach /tmp/girocrab-portal-schema.json")
                }
                Spacer()
                Button("Umsätze übernehmen (\(recognized) erkannt)") { Task { await attempt() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || recognized == 0)
            }
            .padding(12)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .pdf, .data]) { result in
            if case .success(let url) = result {
                model.importStatement(connection, url: url)
                close()
            }
        }
        .task {
            // Count recognised bookings live; auto-import only when >= 1 booking is
            // recognised, the user is past login/2FA and the count has been stable for 4 s.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !busy else { continue }
                let rows = browser.onLoginPage ? "[]" : await browser.domRowsJSON()
                let n = browser.onLoginPage ? 0 : model.previewPortalCapture(connection, bodies: browser.bodies, domRowsJSON: rows)
                if n != lastSeenCount || n != recognized { lastSeenCount = n; lastChange = Date() }
                recognized = n
                if n > 0, !browser.onLoginPage, Date().timeIntervalSince(lastChange) > 4 {
                    if await attempt() { return }
                }
            }
        }
        .onDisappear { browser.teardown() }
    }

    @discardableResult
    private func attempt() async -> Bool {
        busy = true
        defer { busy = false }
        let rows = await browser.domRowsJSON()
        let ok = model.importPortalCapture(connection, bodies: browser.bodies, domRowsJSON: rows)
        if ok { close() }
        return ok
    }

    /// Keys-only structure dump (all strings/numbers masked) for debugging portal changes.
    private func dumpSchema() async {
        let rows = await browser.domRowsJSON()
        let dump = portalSchemaDump(jsonBodies: browser.bodies, domRowsJson: rows)
        do {
            try dump.write(toFile: "/tmp/girocrab-portal-schema.json", atomically: true, encoding: .utf8)
            model.toast = String(localized: "Struktur gespeichert: /tmp/girocrab-portal-schema.json (\(browser.bodies.count) Antworten, ohne Werte)")
        } catch {
            model.errorMessage = describe(error)
        }
    }

    private func close() {
        model.webLoginConnection = nil
        dismiss()
    }
}
