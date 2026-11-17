import SwiftUI
import GiroCrabCore

/// "Konto bearbeiten …" (#639, #605): name, owner, account type and note in one place.
struct AccountEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountID: Int64
    @State private var name = ""
    @State private var owner = ""
    @State private var kind: AccountKind = .checking
    @State private var note = ""
    @State private var login = ""
    @State private var advanziaSettings = AdvanziaConnectionSettingsState()

    private var advanziaConnection: BankConnection? {
        guard let a = account, a.connector == .advanzia, let id = a.connectionId else { return nil }
        return model.connections.first { $0.id == id }
    }
    private var account: Account? { model.account(for: accountID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Konto bearbeiten").appFont(.title3, weight: .bold)
            Form {
                TextField("Kontoname", text: $name).sensitive()
                TextField("Name des Kontoinhabers", text: $owner).sensitive()
                // an offline account is always cash (#679)
                if !model.isOffline(accountID) {
                    Picker("Kontoart", selection: $kind) {
                        ForEach(AccountKind.importChoices, id: \.self) { k in Text(k.label).tag(k) }
                    }
                }
                if advanziaConnection != nil {
                    TextField("Advanzia-Benutzername", text: $login).autocorrectionDisabled().sensitive()
                    AdvanziaConnectionFields(state: advanziaSettings)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Konto-Notiz")
                    TextEditor(text: $note)
                        .appFont(.body)
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.tertiary.opacity(0.5)))
                        .sensitive()
                    Text("Erscheint unter dem Kontonamen in der Kontoansicht.")
                        .appFont(.caption).foregroundStyle(Theme.tertiary)
                }
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sichern") { saveAndFinish() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (advanziaConnection != nil && (advanziaSettings.busy || !advanziaSettings.loaded)))
            }
        }
        .padding(22)
        .macFrame(width: advanziaConnection == nil ? 440 : 560)
        .task {
            if let c = advanziaConnection {
                login = c.loginName
                await advanziaSettings.load(connectionID: c.id, model: model)
            }
        }
        .onAppear {
            guard let a = account else { return }
            name = a.name; owner = a.owner; kind = a.kind; note = model.accountNote(for: a.id)
        }
    }

    private func saveAndFinish() {
        if let c = advanziaConnection {
            Task {
                guard await advanziaSettings.save(connection: c, name: c.displayName, login: login, model: model) != nil else { return }
                save(); dismiss()
            }
        } else { save(); dismiss() }
    }
    private func save() {
        guard let a = account else { return }
        let newName = name.trimmingCharacters(in: .whitespaces)
        if newName != a.name { model.renameAccount(a.id, to: newName) }
        if owner.trimmingCharacters(in: .whitespaces) != a.owner { model.setAccountOwner(a.id, to: owner) }
        if kind != a.kind { model.setAccountKind(a.id, to: kind) }
        if note.trimmingCharacters(in: .whitespacesAndNewlines) != model.accountNote(for: a.id) {
            model.setAccountNote(note, for: a.id)
        }
    }
}
