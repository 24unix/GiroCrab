#if os(macOS)
import SwiftUI
import GiroCrabCore

/// Einstellungen › Externe Analyse (#136): read-only access for local programs
/// (analysis tools, AI assistants) over a local socket. Off by default; accounts
/// are an explicit selection, IBANs/account numbers and notes stay hidden unless
/// switched on. The access token is shown once, only its hash is stored.
struct ExternalAccessSettings: View {
    @Environment(AppModel.self) private var model
    @State private var scope: ShareScope?
    @State private var confirmRevoke = false

    var body: some View {
        Form {
            if !model.holdsRealData {
                Section {
                    Text("Die externe Analyse ist nur mit Ihrem eigenen, entsperrten Tresor verfügbar – nicht mit den Demo-Daten.")
                        .appFont(.callout).foregroundStyle(.secondary)
                } header: { Text("Externe Analyse").appSectionHeader() }
            } else if let scope {
                accessSection(scope)
                if scope.enabled {
                    accountsSection
                    fieldsSection
                    tokenSection
                }
            }
        }
        .formStyle(.grouped)
        .task(id: model.holdsRealData) { scope = await model.loadLocalApiScope() }
        .onDisappear { model.forgetNewLocalApiToken() }
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
                Button(model.localApiTokenHash.isEmpty ? "Zugangsschlüssel erzeugen" : "Neuen Schlüssel erzeugen") {
                    Task { await model.createLocalApiToken() }
                }
                if !model.localApiTokenHash.isEmpty {
                    Button("Zugriff widerrufen", role: .destructive) { confirmRevoke = true }
                }
            }
            LabeledContent("Socket", value: AppModel.localApiSocketPath)
                .textSelection(.enabled)
        } header: { Text("Zugangsschlüssel").appSectionHeader() }
    }

    private func status(_ scope: ShareScope) -> String {
        if model.localApiTokenHash.isEmpty { return String(localized: "Wartet auf einen Zugangsschlüssel") }
        if let error = model.localApiStartError { return String(localized: "Nicht gestartet: \(error)") }
        if scope.accountIds.isEmpty { return String(localized: "Aktiv, noch kein Konto geteilt") }
        return model.isLocalApiRunning ? String(localized: "Aktiv") : String(localized: "Wird gestartet …")
    }

    /// A switch of the scope; every change is saved at once.
    private func field(_ key: WritableKeyPath<ShareScope, Bool>) -> Binding<Bool> {
        Binding(
            get: { scope?[keyPath: key] ?? false },
            set: { on in
                guard var s = scope else { return }
                s[keyPath: key] = on
                save(s)
            })
    }

    private func accountBinding(_ id: Int64) -> Binding<Bool> {
        Binding(
            get: { scope?.accountIds.contains(id) ?? false },
            set: { on in
                guard var s = scope else { return }
                s.accountIds.removeAll { $0 == id }
                if on { s.accountIds.append(id) }
                save(s)
            })
    }

    /// Shown at once; if the write did not happen, the pane goes back to what is stored.
    private func save(_ s: ShareScope) {
        scope = s
        Task {
            if await !model.saveLocalApiScope(s) { scope = await model.loadLocalApiScope() }
        }
    }
}
#endif
