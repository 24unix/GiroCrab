import Foundation
import WebKit
import GiroCrabCore

struct AdvanziaBrowserError: Error { let code: String }
struct AdvanziaCapture: Sendable { let bodies: [String]; let balance: String }

/// Exactly one automatic attempt after readiness. A failure requires an explicit
/// retry, so wrong credentials and API errors cannot cause an endless request loop.
struct AdvanziaAutomaticImport: Sendable {
    enum State { case waiting, running, finished, failed }
    private(set) var state = State.waiting
    mutating func claim(ready: Bool, targetSelected: Bool) -> Bool {
        guard state == .waiting, ready, targetSelected else { return false }
        state = .running; return true
    }
    mutating func finish(success: Bool) { state = success ? .finished : .failed }
    mutating func retry() { if state == .failed { state = .waiting } }
}

@MainActor
protocol AdvanziaSessionDriving: AnyObject {
    var profile: AdvanziaProfile { get }
    var portal: PortalBrowser? { get }
    var accountID: String? { get }
    var ready: Bool { get }
    var error: String? { get }
    var authentication: AdvanziaAuthentication { get }
    func tick(loginName: String) async
    func submitSMS(_ code: String) async throws
    func submitCredentials(loginName: String, password: String) async throws
    func collect() async throws -> AdvanziaCapture
    func stop()
}

@MainActor
@Observable
final class AdvanziaBrowserSession: AdvanziaSessionDriving {
    var profile: AdvanziaProfile
    let pin: VaultPin
    let browser: PortalBrowser
    private(set) var accountID: String?
    private(set) var ready = false
    private(set) var error: String?
    var portal: PortalBrowser? { browser }
    private(set) var authentication = AdvanziaAuthentication.loading
    private(set) var loginSubmitted = false
    private(set) var methodSelected = false
    private var savedPassword: String?
    private var openedTransactions = false
    private var stablePortalTicks = 0
    private var accountConflict = false
    init(profile: AdvanziaProfile, pin: VaultPin, savedPassword: String?) {
        self.profile = profile; self.pin = pin; self.savedPassword = savedPassword
        accountID = profile.bankAccountId
        browser = PortalBrowser(url: URL(string: "https://mein.advanzia.com/")!,
            domains: PortalDomains(["mein.advanzia.com"], includeBaseDomains: false),
            captureTraffic: false, userScript: AdvanziaScripts.hook,
            websiteDataStore: AdvanziaLocalSession.dataStore(profile: profile.profileId))
    }
    var method: AdvanziaAuthMethod { AdvanziaAuthMethod(rawValue: profile.authMethod) ?? .sms }
    func tick(loginName: String) async {
        ready = false
        if AdvanziaSecurity.isLoginURL(browser.currentURL) {
            stablePortalTicks = 0
            let status = try? await browser.webView.callAsyncJavaScript(AdvanziaAuthenticationScripts.inspect,
                arguments: [:], in: nil, contentWorld: .page) as? String
            authentication = status.flatMap(AdvanziaAuthentication.init(rawValue:)) ?? .unknown
            guard authentication != .rejected else { return }
            let mayAutomate = authentication == .credentials || authentication == .method || authentication == .unknown
            let step = mayAutomate ? await AdvanziaLoginAutomation.step(webView: browser.webView, loginName: loginName,
                password: savedPassword, method: method, loginSubmitted: loginSubmitted, methodSelected: methodSelected) : 0
            if step == 1 { loginSubmitted = true; savedPassword = nil }
            if step == 2 { methodSelected = true }
            if authentication == .unknown && methodSelected && method == .app { authentication = .app }
        }
        if !AdvanziaSecurity.isLoginURL(browser.currentURL), !browser.loading {
            authentication = AdvanziaSecurity.isPortalURL(browser.currentURL) ? .loading : .unknown
        }
        guard AdvanziaSecurity.isPortalURL(browser.currentURL), !browser.loading, !browser.onLoginPage, !accountConflict else { return }
        // Also install after a portal redirect / late WebKit initialization. The hook is idempotent.
        do {
            _ = try await browser.webView.evaluateJavaScript(AdvanziaScripts.hook)
            let script = "if(location.origin !== 'https://mein.advanzia.com') return []; return window.__gcAdvanzia?.discover() ?? [];"
            let value = try await browser.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
            guard let ids = value as? [String] else { throw AdvanziaBrowserError(code: "SCHEMA") }
            let normalized = Set(ids.compactMap(AdvanziaSecurity.account))
            guard normalized.count <= 1, normalized.allSatisfy({ profile.bankAccountId == nil || $0 == profile.bankAccountId }) else {
                accountID = nil; accountConflict = true; error = AdvanziaSecurity.errorMessage("ACCOUNT"); return
            }
            if let found = normalized.first { accountID = found }
            stablePortalTicks += 1
            if accountID == nil, !openedTransactions {
                openedTransactions = (try? await browser.webView.callAsyncJavaScript("return window.__gcAdvanzia?.openTransactions() ?? false;", arguments: [:], in: nil, contentWorld: .page) as? Bool) == true
            }
            ready = accountID != nil && stablePortalTicks >= 2
            if accountID == nil && stablePortalTicks >= 10 { error = AdvanziaSecurity.errorMessage("DISCOVERY") }
            if ready { error = nil }
        } catch { self.error = AdvanziaSecurity.errorMessage("SCHEMA") }
    }
    func submitCredentials(loginName: String, password: String) async throws {
        guard AdvanziaSecurity.isLoginURL(browser.currentURL), !password.isEmpty,
              authentication == .credentials || authentication == .rejected else { throw AdvanziaBrowserError(code: "AUTH") }
        let sent = try? await browser.webView.callAsyncJavaScript(AdvanziaLoginScripts.credentials,
            arguments: ["username": loginName, "password": password], in: nil, contentWorld: .page) as? Bool
        guard sent == true else { throw AdvanziaBrowserError(code: "AUTH") }
        loginSubmitted = true; savedPassword = nil; methodSelected = false
    }
    func submitSMS(_ code: String) async throws {
        guard authentication == .sms, AdvanziaSecurity.isLoginURL(browser.currentURL) else { throw AdvanziaBrowserError(code: "OTP") }
        let sent = try? await browser.webView.callAsyncJavaScript(AdvanziaAuthenticationScripts.submit,
            arguments: ["code": code], in: nil, contentWorld: .page) as? Bool
        guard sent == true else { throw AdvanziaBrowserError(code: "OTP") }
    }
    func stop() {
        savedPassword = nil
        browser.webView.evaluateJavaScript("window.__gcAdvanzia?.cancel()", completionHandler: nil)
        browser.teardown()
    }
    func collect() async throws -> AdvanziaCapture {
        guard ready, !accountConflict, let accountID, AdvanziaSecurity.isPortalURL(browser.currentURL) else { throw AdvanziaBrowserError(code: "ACCOUNT") }
        let script = "if(location.origin !== 'https://mein.advanzia.com' || !window.__gcAdvanzia) return {error:'AUTH'}; return await window.__gcAdvanzia.collect(account);"
        let result: Any?
        do { result = try await browser.webView.callAsyncJavaScript(script, arguments: ["account": accountID], in: nil, contentWorld: .page) }
        catch { throw AdvanziaBrowserError(code: "NETWORK") }
        guard let fields = result as? [String: Any] else { throw AdvanziaBrowserError(code: "SCHEMA") }
        if let code = fields["error"] as? String { throw AdvanziaBrowserError(code: code) }
        guard let bodies = fields["bodies"] as? [String], let balance = fields["balance"] as? String else { throw AdvanziaBrowserError(code: "SCHEMA") }
        return AdvanziaCapture(bodies: bodies, balance: balance)
    }
}
