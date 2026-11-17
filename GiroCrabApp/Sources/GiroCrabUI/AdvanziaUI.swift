import SwiftUI
import WebKit
import GiroCrabCore

/// Keep WebKit mounted with a desktop layout, outside the visible content.
struct AdvanziaBackgroundModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content
            .background(alignment: .topLeading) {
                if let flow = model.advanziaWorkflow, let browser = flow.browser, !flow.showBrowser {
                    AdvanziaWebHost(browser: browser).frame(width: 900, height: 650)
                        .frame(width: 0, height: 0, alignment: .topLeading)
                        .clipped().opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottom) {
                if let flow = model.advanziaWorkflow {
                    HStack(spacing: 10) {
                        if flow.phase != .failed { ProgressView().controlSize(.small) }
                        Button("Advanzia-Abruf anzeigen") { flow.showPrompt = true }
                        Button("Abbrechen", role: .cancel) { flow.cancel() }
                    }.appFont(.caption).padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(8)
                }
            }
            .capturableSheet(isPresented: Binding(get: { model.advanziaWorkflow?.showPrompt ?? false },
                set: { model.advanziaWorkflow?.showPrompt = $0 })) {
                if let flow = model.advanziaWorkflow { AdvanziaPrompt(flow: flow).environment(model) }
            }
    }
}

struct AdvanziaPrompt: View {
    @Environment(\.textScale) private var textScale
    @Bindable var flow: AdvanziaWorkflow
    @State private var code = ""
    @State private var password = ""
    @State private var uiDelegate = AmazonUIDelegate()
    private var message: String {
        if flow.needsAccountChoice { return String(localized: "Bitte einmalig das Zielkonto auswählen. Danach beginnt die Übernahme automatisch.") }
        switch flow.phase {
        case .preparing, .signingIn: return String(localized: "Advanzia meldet sich an …")
        case .credentials: return String(localized: "Bitte das Advanzia-Passwort eingeben. Die Anmeldung wird im Hintergrund fortgesetzt.")
        case .sms: return String(localized: "Bitte den SMS-Code eingeben. Anschließend läuft der Abruf automatisch weiter.")
        case .app: return String(localized: "Bitte die Anmeldung in der Advanzia-App bestätigen. Danach läuft der Abruf automatisch weiter.")
        case .authorizing: return String(localized: "Die SMS-Freigabe wird geprüft …")
        case .importing: return String(localized: "Advanzia-Umsätze und Bankkontostand werden übernommen …")
        case .failed: return String(localized: "Der Advanzia-Abruf benötigt Ihre Aufmerksamkeit.")
        case .finished: return String(localized: "Advanzia-Abruf abgeschlossen.")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Advanzia – Anmeldung und Abruf", systemImage: "creditcard.fill").appFont(.headline)
            Text(message).appFont(.callout).fixedSize(horizontal: false, vertical: true)
            if flow.needsAccountChoice {
                if flow.session?.profile.legacyAccountId != nil {
                    Text("Dieses Konto stammt aus einer früheren Version. Wählen Sie es einmalig aus, um es mit seinen vorhandenen Umsätzen weiterzuverwenden.")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
                Picker("Kreditkartenkonto zuordnen", selection: $flow.target) {
                    Text("Bitte auswählen").tag(Int64(-1))
                    if flow.session?.profile.legacyAccountId == nil {
                        Text("Neues Kreditkartenkonto anlegen").tag(Int64(0))
                    }
                    ForEach(flow.candidates, id: \.id) { a in Text(a.name).sensitive().tag(a.id) }
                }.sensitive()
            }
            if !flow.showBrowser && flow.phase == .credentials {
                SecureField("Advanzia-Passwort", text: $password).textContentType(.password)
                    .textFieldStyle(.roundedBorder).sensitive().disabled(flow.submittingCode)
                    .onSubmit(submitPassword)
                Text("Das Passwort wird nur für diesen Abruf verwendet.").appFont(.caption).foregroundStyle(.secondary)
            }
            if !flow.showBrowser && flow.phase == .sms {
                TextField("SMS-Code", text: $code).textFieldStyle(.roundedBorder)
                    .appFont(.title2, design: .monospaced).textContentType(.oneTimeCode)
                    .autocorrectionDisabled().sensitive()
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .onSubmit(submitCode).disabled(!flow.canSubmitCode).frame(maxWidth: 260 * textScale)
            }
            if let error = flow.error {
                Text(error).appFont(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if flow.showBrowser, let browser = flow.browser {
                AdvanziaWebHost(browser: browser).sensitive().macFrame(minWidth: 760, minHeight: 480)
                Text("Zugangsdaten und Freigabeverfahren ändern Sie unter „Bankzugang bearbeiten“.")
                    .appFont(.caption).foregroundStyle(.secondary)
            } else if flow.phase == .app || flow.phase == .authorizing || flow.phase == .importing {
                ProgressView().controlSize(.small)
            }
            HStack {
                Button("Abbrechen", role: .cancel) { code = ""; flow.cancel() }.keyboardShortcut(.cancelAction)
                if flow.browser != nil && !flow.showBrowser {
                    Button("Bankseite öffnen") { code = ""; password = ""; flow.resumeInBrowser() }
                }
                Spacer()
                if flow.showBrowser {
                    Button("Bankseite ausblenden") { flow.showBrowser = false }
                } else if flow.phase == .credentials {
                    Button("Anmelden", action: submitPassword).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction).disabled(password.isEmpty || flow.submittingCode)
                } else if flow.phase == .sms {
                    Button("Bestätigen", action: submitCode).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!flow.canSubmitCode || code.range(of: "^[0-9]{4,10}$", options: .regularExpression) == nil)
                } else if flow.phase == .app {
                    Button("Im Hintergrund warten") { flow.showPrompt = false }
                }
                if flow.phase == .failed { Button("Erneut versuchen") { flow.restart() } }
            }
        }.padding(22).macFrame(minWidth: (flow.showBrowser ? 800 : 480) * textScale)
            .webPageDialogs(uiDelegate)
            .task(id: flow.showBrowser) { flow.browser?.webView.uiDelegate = uiDelegate }
            .onDisappear { code = ""; password = "" }
    }
    private func submitPassword() { let submitted = password; password = ""; flow.submitPassword(submitted) }
    private func submitCode() { let submitted = code; code = ""; flow.submitCode(submitted) }
}

#if os(macOS)
struct AdvanziaWebHost: NSViewRepresentable {
    let browser: PortalBrowser
    func makeNSView(context: Context) -> NSView { let view = NSView(); attach(to: view); return view }
    func updateNSView(_ view: NSView, context: Context) { attach(to: view) }
    private func attach(to view: NSView) {
        let web = browser.webView
        guard web.superview !== view else { return }
        web.removeFromSuperview(); web.frame = view.bounds
        web.autoresizingMask = [.width, .height]; view.addSubview(web)
    }
}
#else
struct AdvanziaWebHost: UIViewRepresentable {
    let browser: PortalBrowser
    func makeUIView(context: Context) -> UIView { let view = UIView(); attach(to: view); return view }
    func updateUIView(_ view: UIView, context: Context) { attach(to: view) }
    private func attach(to view: UIView) {
        let web = browser.webView
        guard web.superview !== view else { return }
        web.removeFromSuperview(); web.frame = view.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(web)
    }
}
#endif
