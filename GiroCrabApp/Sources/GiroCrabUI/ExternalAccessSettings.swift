#if os(macOS)
import SwiftUI
import GiroCrabCore

/// Einstellungen › Externe Analyse (#136): read-only access for local programs
/// (analysis tools, AI assistants) over a local socket. Off by default; accounts
/// are an explicit selection, IBANs/account numbers and notes stay hidden unless
/// switched on. The access token is shown once, only its hash is stored.
struct ExternalAccessSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRevoke = false
    /// The bundled MCP helper, looked up when the pane appears (not on every redraw).
    @State private var helper: URL?
    @State private var check: CheckState = .idle
    /// The running connection test; cancelling it also ends the helper process.
    @State private var checkTask: Task<Void, Never>?

    private enum CheckState: Equatable {
        case idle, running
        case done(LocalApiCheck)
    }

    var body: some View {
        Form {
            if !model.holdsRealData {
                Section {
                    Text("Die externe Analyse ist nur mit Ihrem eigenen, entsperrten Tresor verfügbar – nicht mit den Demo-Daten.")
                        .appFont(.callout).foregroundStyle(.secondary)
                } header: { Text("Externe Analyse").appSectionHeader() }
            } else if let scope = model.localApiScope {
                accessSection(scope)
                if scope.enabled {
                    accountsSection
                    fieldsSection
                    tokenSection
                    if hasToken { assistantSection }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { helper = AppModel.localApiHelperURL }
        .onDisappear {
            model.forgetNewLocalApiToken()
            forgetCheck()
        }
        // A new or revoked key makes an earlier (or running) test stale.
        .onChange(of: model.localApiNewToken) { forgetCheck() }
        .onChange(of: hasToken) { forgetCheck() }
        .confirmationDialog("Zugriff widerrufen?", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("Widerrufen", role: .destructive) {
                Task {
                    await model.revokeLocalApiToken()
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Programme mit dem bisherigen Zugangsschlüssel erhalten sofort keine Daten mehr. Für neuen Zugriff erzeugen Sie einen neuen Schlüssel.")
        }
    }

    private func accessSection(_ scope: ShareScope) -> some View {
        Section {
            Toggle("Lesenden Zugriff für Programme auf diesem Mac erlauben", isOn: field(\.enabled))
            Text("Programme auf diesem Mac, die Sie einrichten, können ausgewählte Konten, Buchungen, Kategorien und Summen lesen. Sie können nichts ändern, keine Zahlungen auslösen und sehen keine Zugangsdaten. Der Zugriff besteht nur, solange GiroCrab läuft und der Tresor entsperrt ist.")
                .appFont(.callout).foregroundStyle(.secondary)
            Label("Programme wie KI-Assistenten können die geteilten Daten an einen Cloud-Dienst übertragen. Teilen Sie nur, was dort verarbeitet werden darf.", systemImage: "exclamationmark.triangle")
                .appFont(.callout)
            Text("Beim Ausschalten wird der Zugangsschlüssel widerrufen. Zum erneuten Einschalten erzeugen Sie einen neuen.")
                .appFont(.callout).foregroundStyle(.secondary)
            if scope.enabled {
                LabeledContent("Status", value: status(scope))
            }
        } header: { Text("Externe Analyse").appSectionHeader() }
    }

    private var accountsSection: some View {
        Section {
            ForEach(model.groups, id: \.id) { group in
                ForEach(group.accounts, id: \.id) { account in
                    Toggle(isOn: accountBinding(account.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                            Text(group.name).appFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Neue Konten werden erst geteilt, wenn Sie sie hier auswählen.")
                .appFont(.callout).foregroundStyle(.secondary)
        } header: { Text("Geteilte Konten").appSectionHeader() }
    }

    private var fieldsSection: some View {
        Section {
            Toggle("Empfänger und Auftraggeber", isOn: field(\.shareCounterparty))
            Toggle("Verwendungszweck und Buchungstext", isOn: field(\.sharePurpose))
            Toggle("IBANs und Kontonummern", isOn: field(\.shareAccountNumbers))
            Toggle("Notizen", isOn: field(\.shareNotes))
            Text("Beträge, Daten, Kategorien und Salden werden immer geteilt. Ohne IBANs und Kontonummern werden auch lange Ziffernfolgen in Texten unkenntlich gemacht. Die Suche steht nur zur Verfügung, wenn die ersten drei Felder geteilt sind.")
                .appFont(.callout).foregroundStyle(.secondary)
        } header: { Text("Geteilte Felder").appSectionHeader() }
    }

    private var tokenSection: some View {
        Section {
            if let newToken = model.localApiNewToken {
                LabeledContent("Neuer Schlüssel") {
                    HStack {
                        Text(newToken).appFont(.caption, design: .monospaced).textSelection(.enabled)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Kopieren", systemImage: "doc.on.doc") { VaultKeyManager.copyToPasteboard(newToken) }
                            .labelStyle(.iconOnly)
                    }
                }
                Text("Der Schlüssel wird nur jetzt angezeigt. Tragen Sie ihn im Programm ein, das zugreifen soll. Kopiert bleibt er 60 Sekunden in der Zwischenablage.")
                    .appFont(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button(!hasToken ? "Zugangsschlüssel erzeugen" : "Neuen Schlüssel erzeugen") {
                    Task { await model.createLocalApiToken() }
                }
                if hasToken {
                    Button("Zugriff widerrufen", role: .destructive) { confirmRevoke = true }
                }
            }
            LabeledContent("Socket", value: AppModel.localApiSocketPath)
                .textSelection(.enabled)
        } header: { Text("Zugangsschlüssel").appSectionHeader() }
    }

    private func status(_ scope: ShareScope) -> String {
        if !hasToken { return String(localized: "Wartet auf einen Zugangsschlüssel") }
        if let error = model.localApiStartError { return String(localized: "Nicht gestartet: \(error)") }
        if scope.accountIds.isEmpty { return String(localized: "Aktiv, noch kein Konto geteilt") }
        return model.isLocalApiRunning ? String(localized: "Aktiv") : String(localized: "Wird gestartet …")
    }

    /// A switch of the scope; every change is saved at once.
    private func field(_ key: WritableKeyPath<ShareScope, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.localApiScope?[keyPath: key] ?? false },
            set: { on in
                guard var s = model.localApiScope else { return }
                s[keyPath: key] = on
                save(s)
            })
    }

    private func accountBinding(_ id: Int64) -> Binding<Bool> {
        Binding(
            get: { model.localApiScope?.accountIds.contains(id) ?? false },
            set: { on in
                guard var s = model.localApiScope else { return }
                s.accountIds.removeAll { $0 == id }
                if on { s.accountIds.append(id) }
                save(s)
            })
    }

    /// Setup for an MCP client (#136): the bundled helper, a ready entry for
    /// the client's configuration and a test of the whole path.
    private var assistantSection: some View {
        Section {
            Text("Für KI-Assistenten und andere MCP-Clients liegt GiroCrab ein Hilfsprogramm bei. Tragen Sie den folgenden Eintrag in die MCP-Konfiguration Ihres Programms ein; es startet das Hilfsprogramm dann selbst.")
                .appFont(.callout).foregroundStyle(.secondary)
            if let helper {
                if AppModel.localApiHelperIsTemporary(helper) {
                    Label("GiroCrab läuft aus einer vorübergehenden Kopie. Bewegen Sie die App in den Ordner „Programme“ und starten Sie sie neu, damit der Pfad im Eintrag dauerhaft gilt.", systemImage: "exclamationmark.triangle")
                        .appFont(.callout)
                }
                let token = model.localApiNewToken
                let config = AppModel.localApiClientConfig(helper: helper, token: token)
                Text(config)
                    .appFont(.caption, design: .monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if token == nil {
                    Text("Den Schlüssel sehen Sie nur direkt nach dem Erzeugen: Ersetzen Sie „gcapi_…“ durch Ihren Schlüssel, oder erzeugen Sie einen neuen, dann steht er bereits im Eintrag.")
                        .appFont(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Eintrag kopieren") {
                        // With the key in it: cleared from the clipboard after 60 s.
                        if token != nil { VaultKeyManager.copyToPasteboard(config) } else { copyToPasteboard(config) }
                    }
                    Button("Programmpfad kopieren") { copyToPasteboard(helper.path) }
                    Button("Verbindung testen") { startCheck(helper) }
                        .disabled(check == .running)
                }
                switch check {
                case .idle: EmptyView()
                case .running: ProgressView().controlSize(.small)
                case .done(let result):
                    Label(checkText(result), systemImage: result == .works ? "checkmark.circle" : "exclamationmark.triangle")
                        .appFont(.callout)
                }
            } else {
                #if DEBUG
                Text("Dieser Entwickler-Build enthält das Hilfsprogramm nicht. Bauen Sie es mit „cargo build --release -p girocrab-mcp“.")
                    .appFont(.callout).foregroundStyle(.secondary)
                #else
                Text("Das Hilfsprogramm ist in diesem Build nicht enthalten.")
                    .appFont(.callout).foregroundStyle(.secondary)
                #endif
            }
        } header: { Text("Für KI-Assistenten").appSectionHeader() }
    }

    private func startCheck(_ helper: URL) {
        checkTask?.cancel()
        check = .running
        checkTask = Task {
            let result = await model.checkLocalApiConnection(helper: helper)
            if !Task.isCancelled { check = .done(result) }
        }
    }

    private func forgetCheck() {
        checkTask?.cancel()
        checkTask = nil
        check = .idle
    }

    private func checkText(_ result: LocalApiCheck) -> String {
        switch result {
        case .works: String(localized: "Die Verbindung funktioniert: Das Hilfsprogramm erreicht GiroCrab, und der Schlüssel wird angenommen.")
        case .reachableWithoutKey: String(localized: "GiroCrab ist erreichbar. Den Schlüssel kann der Test nur direkt nach dem Erzeugen prüfen; ein falscher Schlüssel zeigt sich sonst beim ersten Abruf Ihres Programms.")
        case .notReachable: String(localized: "Nicht erreichbar: Die Schnittstelle läuft gerade nicht (siehe Status oben).")
        case .keyRejected: String(localized: "Der Schlüssel wird nicht angenommen. Erzeugen Sie einen neuen.")
        case .turnedOff: String(localized: "Die externe Analyse ist ausgeschaltet.")
        case .locked: String(localized: "GiroCrab ist gesperrt.")
        case .busy: String(localized: "Alle Verbindungen sind belegt. Versuchen Sie es gleich noch einmal.")
        case .noAnswer: String(localized: "Das Hilfsprogramm hat nicht rechtzeitig geantwortet. Versuchen Sie es noch einmal.")
        case .failed(let output): String(localized: "Der Test ist fehlgeschlagen: \(output)")
        }
    }

    private var hasToken: Bool { !(model.localApiScope?.tokenSha256 ?? "").isEmpty }

    /// Shown at once; if the write did not happen, the pane goes back to what is stored.
    private func save(_ s: ShareScope) {
        model.updateLocalApiScope(s)
    }
}
#endif
