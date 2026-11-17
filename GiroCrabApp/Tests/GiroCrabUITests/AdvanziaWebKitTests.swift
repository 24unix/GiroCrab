#if os(macOS)
import XCTest
import SwiftUI
import WebKit
@testable import GiroCrabUI

/// Real WebKit, local HTML only, ephemeral storage, no network or bank profile.
@MainActor
final class AdvanziaWebKitTests: XCTestCase {
    func testActualAppOptionWithNestedTitleAndFictionalDeviceSubtitle() async throws {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 650), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        defer { web.stopLoading(); window.close() }
        let html = """
        <html><body>
        <script>window.fixtureReady=true;window.appClicks=0;window.smsClicks=0;</script>
        <div id="methods">
          <div role="button" onclick="window.smsClicks++">
            <span>SMS-Versand</span><p>Empfang von SMS mit Code</p>
          </div>
          <div role="button" onclick="window.appClicks++;document.getElementById('methods').hidden=true;document.getElementById('approval').hidden=false;">
            <p><span>Authentifizierung über <strong>App</strong></span></p><p>Fiktives Testgerät</p>
          </div>
        </div>
        <p id="approval" hidden>Bitte bestätigen Sie die Anmeldung in der Advanzia-App.</p>
        </body></html>
        """
        for method in ["app", "sms"] {
            web.loadHTMLString(html.replacingOccurrences(of: "fixtureReady=true", with: "fixtureReady=\"\(method)\""), baseURL: nil)
            var loaded = false
            for _ in 0..<200 {
                if (try? await web.evaluateJavaScript("window.fixtureReady") as? String) == method && !web.isLoading { loaded = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(loaded)
            // Only the test shadows the origin on about:blank; production always
            // checks the real origin. No URL, nonce, device name or login is captured.
            let origin: [String: String] = ["origin": "https://id.advanzia.com"]
            let state = try await web.callAsyncJavaScript(AdvanziaAuthenticationScripts.inspect,
                arguments: ["location": origin], in: nil, contentWorld: .page) as? String
            XCTAssertEqual(state, "method")
            let selected = try await web.callAsyncJavaScript(AdvanziaLoginScripts.method,
                arguments: ["method": method, "location": origin], in: nil, contentWorld: .page) as? Bool
            XCTAssertEqual(selected, true)
            let appClicks = try await web.evaluateJavaScript("window.appClicks") as? Int
            let smsClicks = try await web.evaluateJavaScript("window.smsClicks") as? Int
            XCTAssertEqual(appClicks, method == "app" ? 1 : 0)
            XCTAssertEqual(smsClicks, method == "sms" ? 1 : 0)
            if method == "app" {
                let waiting = try await web.callAsyncJavaScript(AdvanziaAuthenticationScripts.inspect,
                    arguments: ["location": origin], in: nil, contentWorld: .page) as? String
                XCTAssertEqual(waiting, "app")
            }
        }
    }
    func testInvisibleHostExecutesJavaScriptAndKeepsStateWhenMoved() async throws {
        _ = NSApplication.shared
        let browser = PortalBrowser(url: URL(string: "about:blank")!, domains: PortalDomains([]),
            captureTraffic: false, websiteDataStore: .nonPersistent())
        defer { browser.teardown() }
        let background = NSHostingView(rootView: AnyView(AdvanziaWebHost(browser: browser)
            .frame(width: 900, height: 650).frame(width: 0, height: 0).clipped().opacity(0)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = background
        defer { window.close() }
        background.layoutSubtreeIfNeeded()
        browser.webView.loadHTMLString("<html><body><input id='fictional-code'><script>window.fixtureState=42;</script></body></html>", baseURL: nil)
        var loaded = false
        for _ in 0..<200 {
            if (try? await browser.webView.evaluateJavaScript("window.fixtureState") as? Int) == 42 { loaded = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(loaded, "Local HTML must execute in the invisible host")
        let width = try await browser.webView.evaluateJavaScript("document.querySelector('input').getBoundingClientRect().width") as? Double
        XCTAssertGreaterThan(width ?? 0, 0, "Hidden hosting must preserve a usable form layout")
        background.rootView = AnyView(EmptyView())
        background.layoutSubtreeIfNeeded()
        let fallback = NSHostingView(rootView: AdvanziaWebHost(browser: browser).frame(width: 900, height: 650))
        window.contentView = fallback
        fallback.layoutSubtreeIfNeeded()
        let state = try await browser.webView.evaluateJavaScript("window.fixtureState") as? Int
        XCTAssertEqual(state, 42, "Moving to the fallback must not reload the session")
        XCTAssertEqual(browser.webView.url?.absoluteString, "about:blank")
    }
}
#endif
