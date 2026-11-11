import SwiftUI
import GiroCrabCore

/// Native 2FA sheet: decoupled push-TAN (spinner + auto polling), code entry,
/// photoTAN image + code, or PSD2 browser redirect.
struct TwoFactorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var code = ""
    @State private var pulse = false

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
                    Image(systemName: "safari")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.tint)
                    Text(c.title).font(.title3.bold())
                    Text(c.message).multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let s = c.redirectUrl, let url = URL(string: s) {
                        Button { openURL(url) } label: { Label("Zustimmungsseite öffnen", systemImage: "arrow.up.right.square") }
                            .buttonStyle(.bordered)
                    }
                    TextField("Weitergeleitete Adresse hier einfügen", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit(submit)
                }

                if let e = active.error {
                    Text(e).foregroundStyle(.red).font(.callout)
                }
                if let s = c.expiresInSeconds {
                    Text("Gültig noch etwa \(s / 60) Min.").font(.caption).foregroundStyle(.tertiary)
                }

                HStack {
                    Button("Abbrechen", role: .cancel) { model.cancelSync() }
                        .keyboardShortcut(.cancelAction)
                    if active.connection.connector == .tradeRepublic && c.kind == .code {
                        Button("Code per SMS") { model.submitCode("SMS") }
                            .help("Kein Code in der App? Code per SMS anfordern.")
                    }
                    Spacer()
                    if c.kind != .decoupledPush {
                        Button("Weiter", action: submit)
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || active.busy)
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

    private func platformImage(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}

