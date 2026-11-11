import SwiftUI
import WebKit

/// Matches the bank's redirect back to the Enable Banking "Redirect-URL"
/// (default `https://localhost/girocrab/callback?code=…&state=…`).
enum ConsentRedirect {
    static let defaultURL = "https://localhost/girocrab/callback"

    /// The URL is the configured redirect (same host and path, any scheme
    /// http/https) and carries the bank's answer (`code` or `error`).
    static func matches(_ url: URL, redirect: String) -> Bool {
        guard let r = URL(string: redirect.trimmingCharacters(in: .whitespaces)),
              let host = url.host?.lowercased(), host == r.host?.lowercased(),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return false }
        let want = r.path.isEmpty ? "/" : r.path
        let have = url.path.isEmpty ? "/" : url.path
        guard have == want || have == want + "/" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == "code" || $0.name == "error" }
    }
}

/// The bank's consent page inside GiroCrab. Nothing is stored (non-persistent
/// website data) and nothing is read from the pages; the window only waits for
/// the jump to the redirect URL, stops it before the browser would show "can't
/// connect", and hands the address to the sync.
@MainActor
final class ConsentBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let redirect: String
    private let onRedirect: (URL) -> Void
    private var done = false

    init(url: URL, redirect: String, onRedirect: @escaping (URL) -> Void) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: cfg)
        self.redirect = redirect
        self.onRedirect = onRedirect
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: url))
    }

    private func finish(_ url: URL) {
        guard !done else { return }
        done = true
        webView.stopLoading()
        onRedirect(url)
    }

    // Links and server redirects: catch the redirect URL before it loads.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url, ConsentRedirect.matches(u, redirect: redirect) {
            decisionHandler(.cancel)
            finish(u)
            return
        }
        decisionHandler(.allow)
    }

    // Fallback: the redirect failed to load (localhost isn't served).
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let failing = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
            ?? ((error as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        if let u = failing ?? webView.url, ConsentRedirect.matches(u, redirect: redirect) {
            finish(u)
        }
    }

    // Pages that open a new window (target=_blank): stay in this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

#if os(macOS)
struct ConsentWebView: NSViewRepresentable {
    let browser: ConsentBrowser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct ConsentWebView: UIViewRepresentable {
    let browser: ConsentBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
