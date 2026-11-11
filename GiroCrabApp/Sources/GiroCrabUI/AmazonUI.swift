import SwiftUI
import WebKit
import GiroCrabCore

// MARK: - Model glue (Amazon customer account: order history)

extension AppModel {
    /// Hands the scraped order JSON to the core. Returns true when orders were recognised.
    @discardableResult
    func importAmazonOrders(_ c: BankConnection, json: String) -> Bool {
        guard let vault else { return false }
        do {
            let s = try vault.importAmazonOrders(connectionId: c.id, ordersJson: json)
            toast = String(localized: "\(c.displayName): \(s.transactionsImported) neue Buchungen, \(s.transactionsCategorized) kategorisiert")
            reloadAll()
            return true
        } catch {
            AppModel.debugLog("amazon import failed: \(describe(error))")
            errorMessage = describe(error)
            return false
        }
    }
}

// MARK: - Scraper scripts (run inside the logged-in amazon.de page)

/// Same-origin `fetch` + `DOMParser`: the page's own session cookies authenticate the
/// requests, so no credentials ever leave the web view. Each script returns a JSON string.
private enum AmazonScripts {
    static let codeRegex = "[D\\\\d]\\\\d\\\\d-\\\\d{7}-\\\\d{7}"

    /// args: filter ("year-2025" / "months-3"). Returns {"codes":[…]} or {"error":"login"}.
    static let orderCodes = """
    const re = new RegExp("\(codeRegex)");
    const codes = [];
    let url = "/your-orders/orders?timeFilter=" + encodeURIComponent(filter);
    for (let page = 0; page < 60 && url; page++) {
      const r = await fetch(url, {credentials: "same-origin"});
      const html = await r.text();
      if (/ap\\/signin|name="signIn"/.test(r.url + html.slice(0, 20000))) return JSON.stringify({error: "login"});
      const doc = new DOMParser().parseFromString(html, "text/html");
      doc.querySelectorAll('div.order-card, [class*="order-card"]').forEach(function(card) {
        const m = re.exec(card.getAttribute("data-csa-c-slot-id") || "") || re.exec(card.innerHTML);
        if (m && codes.indexOf(m[0]) < 0) codes.push(m[0]);
      });
      const next = doc.querySelector("li.a-last a[href]");
      url = next ? next.getAttribute("href") : null;
    }
    return JSON.stringify({codes: codes});
    """

    /// args: code. Returns one order object understood by `amazon_orders::Order`.
    static let orderDetails = """
    const r = await fetch("/your-orders/order-details?orderID=" + encodeURIComponent(code), {credentials: "same-origin"});
    const html = await r.text();
    if (/ap\\/signin|name="signIn"/.test(r.url + html.slice(0, 20000))) return JSON.stringify({error: "login"});
    const doc = new DOMParser().parseFromString(html, "text/html");
    const root = doc.querySelector('div[id*="orderDetails"]') || doc.body;
    const txt = function(n) { return n ? (n.textContent || "").replace(/\\s+/g, " ").trim() : ""; };
    let date = txt(root.querySelector('[data-component="orderDate"]'));
    if (!date) {
      const m = /\\d{1,2}\\.\\s*[A-Za-zÄÖÜäöüß]+\\s+\\d{4}|\\d{1,2}\\.\\d{1,2}\\.\\d{4}|[A-Z][a-z]+ \\d{1,2}, \\d{4}/.exec(txt(root));
      date = m ? m[0] : "";
    }
    const items = [];
    root.querySelectorAll('[data-component="purchasedItemsRightGrid"]').forEach(function(it) {
      const title = txt(it.querySelector('[data-component="itemTitle"]'));
      const grid = it.closest(".a-fixed-left-grid-inner");
      const q = txt((grid && grid.querySelector(".od-item-view-qty")) || it.querySelector('[data-component="quantity"]'));
      const qm = /\\d+/.exec(q);
      if (title) items.push({title: title, qty: qm ? parseInt(qm[0], 10) : 1});
    });
    const rows = [];
    root.querySelectorAll(".od-line-item-row").forEach(function(row) {
      const label = txt(row.querySelector(".od-line-item-row-label"));
      const value = txt(row.querySelector(".od-line-item-row-content"));
      if (label && value) rows.push({label: label, value: value, bold: !!row.querySelector(".a-text-bold")});
    });
    const all = txt(root);
    const cancelled = /wurde storniert|order was cancelled|Bestellung storniert/i.test(all) && !rows.some(function(x) { return /gesamtsumme|grand total/i.test(x.label); });
    return JSON.stringify({code: code, date: date, items: items, rows: rows, cancelled: cancelled});
    """
}

// MARK: - Popups / dialogs

/// Amazon's sign-in may open pop-ups or use JS dialogs. A bare WKWebView silently drops
/// both, which can leave the form hanging: open pop-ups in the same view, answer dialogs.
final class AmazonUIDelegate: NSObject, WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
}

// MARK: - Sheet

struct AmazonWebSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connection: BankConnection
    @State private var browser = PortalBrowser(url: URL(string: "https://www.amazon.de/gp/css/order-history")!, captureTraffic: false)
    @State private var years = 2
    @State private var running = false
    @State private var progress = ""
    @State private var task: Task<Void, Never>?

    @State private var pageIsOrders = false
    @State private var uiDelegate = AmazonUIDelegate()
    @State private var notice: String?

    /// Signed in only when the page is an account/order page without any sign-in,
    /// 2FA or captcha form. (URL hints alone miss Amazon's /ap/ verification pages.)
    private var ready: Bool { pageIsOrders }

    private static let probe = """
    (function() {
      var p = location.pathname;
      if (p.indexOf('/ap/') === 0 || p.indexOf('/a/') === 0) return false;
      if (!/order-history|your-orders|\\/gp\\/css\\/|your-account/.test(p)) return false;
      return !document.querySelector('form[name="signIn"], #ap_password, #auth-mfa-form, input[name="otpCode"], input[name="code"], #auth-captcha-image');
    })()
    """

    private var info: String {
        if running { return progress }
        if let notice { return notice }
        if ready { return String(localized: "Angemeldet – „Bestellungen abrufen“ liest Ihre Bestellhistorie.") }
        return String(localized: "Melden Sie sich bei Amazon an (Passwort, Captcha, 2FA wie gewohnt).")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SymbolTile(symbol: "shippingbox.fill", tint: connection.connector.tint, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(connection.displayName) – Amazon-Konto").font(.headline)
                    Text(info).font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if running || browser.loading { ProgressView().controlSize(.small) }
            }
            .padding(14)
            Divider()
            PortalWebView(browser: browser)
                .macFrame(minWidth: 760, minHeight: 520)
            Divider()
            HStack {
                Button("Abbrechen", role: .cancel) { task?.cancel(); close() }
                    .keyboardShortcut(.cancelAction)
                Picker("Zeitraum", selection: $years) {
                    Text("Dieses Jahr").tag(1)
                    Text("Letzte 2 Jahre").tag(2)
                    Text("Letzte 5 Jahre").tag(5)
                    Text("Alles").tag(25)
                }
                .fixedSize()
                .disabled(running)
                Spacer()
                Button("Bestellungen abrufen") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!ready || running)
            }
            .padding(12)
        }
        .task {
            browser.webView.uiDelegate = uiDelegate
            while !Task.isCancelled {
                let host = browser.currentURL?.host ?? ""
                let ok = host.contains("amazon.")
                    ? ((try? await browser.webView.evaluateJavaScript(Self.probe)) as? Bool ?? false)
                    : false
                if ok != pageIsOrders { pageIsOrders = ok }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .onDisappear { task?.cancel(); browser.teardown() }
    }

    private func close() {
        model.webLoginConnection = nil
        dismiss()
    }

    private func start() {
        running = true
        notice = nil
        task = Task {
            defer { running = false }
            do {
                let json = try await scrape()
                if model.importAmazonOrders(connection, json: json) { close() }
            } catch is CancellationError {
            } catch AmazonError.loggedOut {
                // Session expired (the page may just be a cached copy): show the sign-in page.
                notice = String(localized: "Sitzung abgelaufen – bitte neu anmelden (Haken bei „Angemeldet bleiben“ setzen).")
                pageIsOrders = false
                browser.webView.load(URLRequest(url: URL(string: "https://www.amazon.de/gp/css/order-history")!))
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func run(_ script: String, _ args: [String: Any]) async throws -> [String: Any] {
        let res = try await browser.webView.callAsyncJavaScript(script, arguments: args, in: nil, contentWorld: .page)
        guard let s = res as? String, let d = s.data(using: .utf8),
              let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw AmazonError.unreadable
        }
        if o["error"] as? String == "login" { throw AmazonError.loggedOut }
        return o
    }

    /// Order list (per year, newest first) -> order codes -> one detail page each.
    private func scrape() async throws -> String {
        let thisYear = Calendar.current.component(.year, from: Date())
        var codes: [String] = []
        var emptyYears = 0
        for y in 0..<years {
            try Task.checkCancellation()
            progress = String(localized: "Bestellliste \(String(thisYear - y)) …")
            let r = try await run(AmazonScripts.orderCodes, ["filter": "year-\(thisYear - y)"])
            let found = (r["codes"] as? [String] ?? []).filter { !codes.contains($0) }
            codes += found
            emptyYears = found.isEmpty ? emptyYears + 1 : 0
            if years > 5 && emptyYears >= 2 { break }
        }
        if codes.isEmpty { throw AmazonError.noOrders }
        var orders: [[String: Any]] = []
        for (i, code) in codes.enumerated() {
            try Task.checkCancellation()
            progress = String(localized: "Bestellung \(i + 1) von \(codes.count) …")
            orders.append(try await run(AmazonScripts.orderDetails, ["code": code]))
        }
        let data = try JSONSerialization.data(withJSONObject: ["orders": orders])
        return String(decoding: data, as: UTF8.self)
    }
}

private enum AmazonError: LocalizedError {
    case loggedOut, noOrders, unreadable
    var errorDescription: String? {
        switch self {
        case .loggedOut: return String(localized: "Die Amazon-Sitzung ist abgelaufen. Bitte erneut anmelden.")
        case .noOrders: return String(localized: "Keine Bestellungen im gewählten Zeitraum gefunden.")
        case .unreadable: return String(localized: "Amazon hat eine unerwartete Antwort geliefert.")
        }
    }
}
