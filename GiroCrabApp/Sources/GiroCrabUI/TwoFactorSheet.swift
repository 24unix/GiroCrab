import SwiftUI
import GiroCrabCore

/// Native 2FA sheet: decoupled push-TAN (spinner + auto polling), code entry,
/// photoTAN image + code, or PSD2 browser redirect.
struct TwoFactorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var code = ""
    @State private var pulse = false
    /// The bank's consent page inside GiroCrab (PSD2 redirect).
    @State private var consent: ConsentBrowser?
    @State private var showManualRedirect = false

    var body: some View {
        if let active = model.activeChallenge {
            let c = active.challenge
            VStack(spacing: 18) {
                HStack(spacing: 10) {
                    SymbolTile(symbol: active.connection.sfSymbol, tint: active.connection.connector.tint, size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(active.connection.displayName).font(.headline)
                        Text(c.methodName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SyncBatchProgressLabel()
                }

                switch c.kind {
                case .decoupledPush:
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: true)
                        .padding(.top, 6)
                    Text(c.title).font(.title3.bold())
                    Text(c.message).multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let s = c.redirectUrl, let url = URL(string: s) {
                        Button { openURL(url) } label: { Label("Im Browser anmelden", systemImage: "safari") }
                            .buttonStyle(.borderedProminent)
                    }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(active.waiting ? "Warte auf Freigabe …" : "Push-Nachricht gesendet")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                case .code, .imageCode:
                    Image(systemName: c.kind == .imageCode ? "qrcode.viewfinder" : "lock.rotation")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.tint)
                    Text(c.title).font(.title3.bold())
                    if let data = c.image, let img = platformImage(data) {
                        img.resizable().interpolation(.none).scaledToFit().frame(maxWidth: 220, maxHeight: 220)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text(c.message).multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField("TAN / Code", text: $code)
                        .font(.title2.monospaced())
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        #endif
                        .onSubmit(submit)
                case .redirect:
                    if let consent {
                        // Bank login inside GiroCrab; closes itself on the redirect.
                        ConsentWebView(browser: consent)
                            .frame(minWidth: 760, minHeight: 560)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        Text("Bei der Bank anmelden und den Zugriff erlauben – das Fenster schließt sich danach von selbst.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "building.columns")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.tint)
                        Text(c.title).font(.title3.bold())
                        Text("Sie melden sich direkt bei Ihrer Bank an und erlauben den Zugriff. GiroCrab übernimmt das Ergebnis automatisch.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let s = c.redirectUrl, let url = URL(string: s) {
                            Button { openConsent(url) } label: { Label("Bei der Bank anmelden", systemImage: "lock.shield") }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        }
                    }
                    // Fallback for banks that block embedded browsers.
                    DisclosureGroup("Stattdessen im eigenen Browser anmelden", isExpanded: $showManualRedirect) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(c.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let s = c.redirectUrl, let url = URL(string: s) {
                                Button { openURL(url) } label: { Label("Zustimmungsseite öffnen", systemImage: "arrow.up.right.square") }
                                    .buttonStyle(.bordered)
                            }
                            TextField("Weitergeleitete Adresse hier einfügen", text: $code)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .onSubmit(submit)
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                }

                if let e = active.error {
                    Text(e).foregroundStyle(.red).font(.callout)
                }
                if let s = c.expiresInSeconds {
                    Text("Gültig noch etwa \(s / 60) Min.").font(.caption).foregroundStyle(.tertiary)
                }

                HStack {
                    if model.canSkipInSyncBatch {
                        // "Alle abrufen": no TAN device at hand only skips this login
                        // fixedSize: with up to four buttons the sheet widens
                        // instead of truncating titles
                        Button("Überspringen", role: .cancel) { model.skipCurrentSync() }
                            .keyboardShortcut(.cancelAction)
                            .help("Diesen Bankzugang auslassen und mit dem nächsten weitermachen.")
                            .fixedSize()
                        Button("Alle abbrechen") { model.cancelSync() }
                            .fixedSize()
                    } else {
                        Button("Abbrechen", role: .cancel) { model.skipCurrentSync() }
                            .keyboardShortcut(.cancelAction)
                    }
                    if active.connection.connector == .tradeRepublic && c.kind == .code {
                        Button("Code per SMS") { model.submitCode("SMS") }
                            .help("Kein Code in der App? Code per SMS anfordern.")
                            .fixedSize()
                    }
                    Spacer()
                    if c.kind == .code || c.kind == .imageCode || (c.kind == .redirect && showManualRedirect) {
                        Button("Weiter", action: submit)
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || active.busy)
                            .fixedSize()
                    }
                }
            }
            .padding(24)
            .macFrame(minWidth: 400, idealWidth: 420)
        }
    }

    private func submit() {
        let value = code
        code = ""
        model.submitCode(value)
    }

    private func openConsent(_ url: URL) {
        let redirect = model.settingEntry("enablebanking.redirect_url")?.value
            .trimmingCharacters(in: .whitespaces)
        consent = ConsentBrowser(
            url: url,
            redirect: (redirect?.isEmpty == false ? redirect : nil) ?? ConsentRedirect.defaultURL
        ) { result in
            consent = nil
            model.submitCode(result.absoluteString)
        }
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}


/// "Bankzugang 2 von 5" while "Alle abrufen" runs over several logins
/// (PIN and TAN sheets), so skipping one is an informed choice.
struct SyncBatchProgressLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let p = model.syncBatchProgress {
            Text("Bankzugang \(p.current) von \(p.total)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
