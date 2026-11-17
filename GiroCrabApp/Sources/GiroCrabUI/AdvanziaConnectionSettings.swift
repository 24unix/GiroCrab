import SwiftUI
import GiroCrabCore

@MainActor
@Observable
final class AdvanziaConnectionSettingsState {
    var password = ""
    var storePassword = false
    var authMethod = AdvanziaAuthMethod.sms
    private(set) var hasSavedPassword = false
    private(set) var busy = false
    private(set) var loaded = false
    private(set) var error: String?
    private var profile: AdvanziaProfile?
    private var pin: VaultPin?
    private let keychain: AdvanziaKeychainClient
    init(keychain: AdvanziaKeychainClient = .system) { self.keychain = keychain }

    func load(connectionID: Int64, model: AppModel) async {
        guard let pin = model.pinVault() else { return }
        self.pin = pin; busy = true
        defer { busy = false }
        do {
            let profile = try await pin.run { try $0.advanziaProfile(connectionId: connectionID) }
            let keychain = keychain, profileID = profile.profileId
            let hasPassword = try await Task.detached { try AdvanziaLocalSecrets.hasPassword(profileID, using: keychain) }.value
            guard model.isCurrent(pin), !Task.isCancelled else { return }
            self.profile = profile
            hasSavedPassword = hasPassword; storePassword = hasPassword
            authMethod = AdvanziaAuthMethod(rawValue: profile.authMethod) ?? .sms
            loaded = true; error = nil
        } catch {
            self.error = String(localized: "Advanzia-Einstellungen konnten nicht geladen werden. Bitte das Fenster erneut öffnen.")
        }
    }

    func save(connection: BankConnection, name: String, login: String, model: AppModel) async -> BankConnection? {
        guard loaded, !busy, let pin, let oldProfile = profile, model.isCurrent(pin) else { return nil }
        let login = login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else { error = String(localized: "Bitte den Advanzia-Benutzernamen eintragen."); return nil }
        if storePassword && password.isEmpty && (!hasSavedPassword || login != connection.loginName) {
            error = String(localized: "Bitte das zu speichernde Advanzia-Passwort eingeben."); return nil
        }
        busy = true; error = nil
        defer { busy = false }
        if login != connection.loginName, model.advanziaWorkflow?.connection.id == connection.id {
            model.advanziaWorkflow?.cancel()
        }
        do {
            let id = connection.id, method = authMethod.rawValue
            let updated = try await pin.run { v -> AdvanziaProfile in
                let duplicate = try v.listBankConnections().contains { $0.id != id && $0.connector == .advanzia && $0.loginName == login }
                if duplicate { throw AdvanziaBrowserError(code: "DUPLICATE_LOGIN") }
                try v.updateBankConnection(connectionId: id, displayName: name, loginName: login)
                try v.setAdvanziaAuthMethod(connectionId: id, method: method)
                return try v.advanziaProfile(connectionId: id)
            }
            guard model.isCurrent(pin), !Task.isCancelled else { return nil }
            profile = updated
            let keychain = keychain, profileID = updated.profileId, oldID = oldProfile.profileId
            let value = password, store = storePassword
            try await Task.detached {
                if store, !value.isEmpty { try AdvanziaLocalSecrets.save(password: value, for: profileID, using: keychain) }
                if !store || oldID != profileID { try AdvanziaLocalSecrets.delete(oldID, using: keychain) }
                if !store, oldID != profileID { try AdvanziaLocalSecrets.delete(profileID, using: keychain) }
            }.value
            password = ""
            hasSavedPassword = store
            await model.advanziaSettingsDidSave(pin: pin)
            guard model.isCurrent(pin), !Task.isCancelled else { return nil }
            return model.connections.first { $0.id == id }
        } catch {
            self.error = String(localized: "Advanzia-Einstellungen konnten nicht vollständig gespeichert werden. Prüfen Sie Benutzername und Passwort und versuchen Sie es erneut.")
            return nil
        }
    }
    func removePassword(model: AppModel) async {
        guard !busy, let profile, let pin, model.isCurrent(pin) else { return }
        busy = true; defer { busy = false }
        do {
            let id = profile.profileId, keychain = keychain
            try await Task.detached { try AdvanziaLocalSecrets.delete(id, using: keychain) }.value
            password = ""; hasSavedPassword = false; storePassword = false; error = nil
        } catch { self.error = String(localized: "Das Advanzia-Passwort konnte nicht gelöscht werden.") }
    }
    func clearSession(model: AppModel) async {
        guard let profile, let pin, model.isCurrent(pin) else { return }
        busy = true; defer { busy = false }
        await AdvanziaLocalSession.clear(profile: profile.profileId)
    }
}

struct AdvanziaConnectionFields: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: AdvanziaConnectionSettingsState
    @State private var confirmClear = false
    var body: some View {
        Section {
            Toggle("Passwort lokal im Schlüsselbund speichern", isOn: $state.storePassword)
            if state.storePassword {
                SecureField(state.hasSavedPassword ? String(localized: "Neues Passwort (leer = unverändert)") : String(localized: "Advanzia-Passwort"), text: $state.password)
                    .textContentType(.password).sensitive()
                if state.hasSavedPassword {
                    Text("Ein Passwort ist gespeichert.").appFont(.caption).foregroundStyle(Theme.secondary)
                    Button("Gespeichertes Passwort löschen", role: .destructive) { Task { await state.removePassword(model: model) } }
                }
            }
            Picker("Freigabeverfahren", selection: $state.authMethod) {
                ForEach(AdvanziaAuthMethod.allCases) { method in Text(method.title).tag(method) }
            }
            Text("GiroCrab meldet sich mit den gespeicherten Zugangsdaten an. Geben Sie anschließend den SMS-Code ein oder bestätigen Sie die Freigabe in der Advanzia-App. Danach werden die Umsätze automatisch übernommen.")
                .appFont(.caption).foregroundStyle(Theme.secondary)
            Button("Web-Sitzung löschen …", role: .destructive) { confirmClear = true }
            if state.busy { ProgressView().controlSize(.small) }
            if let error = state.error { Text(error).appFont(.caption).foregroundStyle(.red) }
        } header: { Text("Advanzia-Anmeldung").appSectionHeader() }
        .disabled(state.busy || !state.loaded)
        .alert("Lokale Sitzung löschen?", isPresented: $confirmClear) {
            Button("Abbrechen", role: .cancel) {}
            Button("Sitzung löschen", role: .destructive) { Task { await state.clearSession(model: model) } }
        } message: { Text("Beim nächsten Abruf ist eine neue Anmeldung mit dem gewählten Freigabeverfahren erforderlich.") }
    }
}
