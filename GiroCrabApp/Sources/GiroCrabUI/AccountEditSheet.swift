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

    private var account: Account? { model.account(for: accountID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Konto bearbeiten").appFont(.title3, weight: .bold)
            Form {
                TextField("Kontoname", text: $name).sensitive()
                TextField("Name des Kontoinhabers", text: $owner).sensitive()
                Picker("Kontoart", selection: $kind) {
                    ForEach(AccountKind.importChoices, id: \.self) { k in Text(k.label).tag(k) }
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
                Button("Sichern") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .macFrame(width: 440)
        .onAppear {
            guard let a = account else { return }
            name = a.name; owner = a.owner; kind = a.kind; note = model.accountNote(for: a.id)
        }
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
