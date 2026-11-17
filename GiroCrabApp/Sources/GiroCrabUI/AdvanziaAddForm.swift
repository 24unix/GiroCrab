import SwiftUI
import GiroCrabCore

/// The first login is prepared completely before any browser or sync starts.
@MainActor
@Observable
final class AdvanziaAddState {
    var login = ""
    var password = ""
    var storePassword = true
    var method = AdvanziaAuthMethod.sms
    private(set) var busy = false
    private(set) var error: String?
    private let keychain: AdvanziaKeychainClient
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var canAdd: Bool { !busy && !login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty }
    init(keychain: AdvanziaKeychainClient = .system) { self.keychain = keychain }

    func begin(model: AppModel, onAdded: @escaping () -> Void) {
        guard canAdd else { return }
        busy = true; error = nil
        let token = generation
        model.prepareAdvanziaAdd(login: login) { [weak self, weak model] pin in
            guard let self, let model, generation == token else { return }
            guard let pin else {
                busy = false; error = String(localized: "Der Advanzia-Zugang konnte nicht vorbereitet werden. Bitte den Tresor und die Sicherheitshinweise prüfen."); return
            }
            task = Task {
                defer { self.busy = false; self.task = nil }
                let secret = self.password
                guard let connection = await self.persist(pin: pin, model: model, token: token) else { return }
                guard self.generation == token, model.isCurrent(pin), !Task.isCancelled else { return }
                self.password = ""
                // Start is deferred until the add sheet has dismissed, so the first
                // native challenge uses exactly the same presenter as a later sync.
                model.startAdvanzia(connection, password: secret)
                onAdded()
            }
        }
    }
    /// Also exercised directly against a demo vault and an in-memory keychain.
    func save(pin: VaultPin, model: AppModel) async -> BankConnection? {
        guard canAdd else { return nil }
        busy = true; error = nil
        defer { busy = false }
        let result = await persist(pin: pin, model: model, token: generation)
        if result != nil { password = "" }
        return result
    }
    private func persist(pin: VaultPin, model: AppModel, token: UUID) async -> BankConnection? {
        guard model.isCurrent(pin), generation == token, !Task.isCancelled else { return nil }
        let username = login.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password, method = method.rawValue, store = storePassword
        guard !username.isEmpty, !secret.isEmpty else { return nil }
        do {
            let result = try await pin.run { vault -> (BankConnection, AdvanziaProfile) in
                let id = try vault.addBankConnection(connector: .advanzia, displayName: "", loginName: username)
                try vault.setAdvanziaAuthMethod(connectionId: id, method: method)
                let profile = try vault.advanziaProfile(connectionId: id)
                guard let connection = try vault.listBankConnections().first(where: { $0.id == id }) else { throw AdvanziaBrowserError(code: "ACCOUNT") }
                return (connection, profile)
            }
            await pin.checkpoint()
            guard model.isCurrent(pin), generation == token, !Task.isCancelled else { return nil }
            let profileID = result.1.profileId, keychain = keychain
            try await Task.detached {
                if store { try AdvanziaLocalSecrets.save(password: secret, for: profileID, using: keychain) }
                else { try AdvanziaLocalSecrets.delete(profileID, using: keychain) }
            }.value
            guard model.isCurrent(pin), generation == token, !Task.isCancelled else { return nil }
            await model.advanziaSettingsDidSave(pin: pin)
            guard model.isCurrent(pin), generation == token, !Task.isCancelled else { return nil }
            return result.0
        } catch {
            guard model.isCurrent(pin), generation == token, !Task.isCancelled else { return nil }
            self.error = String(localized: "Der Advanzia-Zugang konnte nicht vollständig gespeichert werden. Bitte erneut versuchen. Der Abruf wurde noch nicht gestartet.")
            return nil
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; password = ""; busy = false }
}

struct AdvanziaAddForm: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AdvanziaAddState()
    let onAdded: () -> Void
    var submit: AddBankSubmit?
    var body: some View {
        Section {
            if model.demoActive { DemoHintBanner(style: .credentials) { draft.login = "demo"; draft.password = "demo"; draft.storePassword = false } }
            TextField("Advanzia-Benutzername", text: $draft.login)
                .textContentType(.username).autocorrectionDisabled().sensitive()
            SecureField("Advanzia-Passwort", text: $draft.password).textContentType(.password).sensitive()
            Toggle("Passwort lokal im Schlüsselbund speichern", isOn: $draft.storePassword)
            Picker("Freigabeverfahren", selection: $draft.method) {
                ForEach(AdvanziaAuthMethod.allCases) { method in Text(method.title).tag(method) }
            }
            if draft.busy { ProgressView().controlSize(.small) }
            if let error = draft.error { Text(error).appFont(.caption).foregroundStyle(.red) }
            if submit == nil { Button("Bank hinzufügen", action: commit).disabled(!draft.canAdd) }
        } header: { Text("Advanzia-Anmeldung").appSectionHeader() }
        footer: {
            VStack(alignment: .leading, spacing: 4) {
            Text("Für Karten mit Zugang über mein.advanzia.com. Nach dem Hinzufügen läuft die Anmeldung im Hintergrund; nur eine erforderliche Freigabe wird angezeigt.")
            Text(draft.storePassword
                 ? String(localized: "Das Passwort wird lokal im Schlüsselbund gespeichert und für spätere Abrufe verwendet.")
                 : String(localized: "Das Passwort wird nur für diesen Abruf verwendet. Bei einem späteren Abruf kann GiroCrab erneut danach fragen."))
            }.appFont(.caption).foregroundStyle(.secondary).leadingFooter()
        }
        .disabled(draft.busy)
        .onChange(of: draft.canAdd, initial: true) { _, ready in submit?.update(ready, commit) }
        .onDisappear { draft.cancel() }
    }
    private func commit() { draft.begin(model: model, onAdded: onAdded) }
}
