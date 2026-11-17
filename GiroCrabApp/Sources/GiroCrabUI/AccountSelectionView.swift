import SwiftUI
import GiroCrabCore

/// The selection of one login while it is edited: loaded once, then saved by the list's own
/// button or by the "Speichern" of the sheet around it, so a change is never lost.
@MainActor @Observable
final class AccountSelectionDraft {
    var choices: [ConnectionAccountChoice] = []
    var enabled: Set<String> = []
    var loaded = false
    var error: String?
    /// What was on when the list was loaded.
    private var original: Set<String> = []

    var hasChanges: Bool { loaded && enabled != original }

    /// Held-back accounts start as "Abrufen" off: the user has to opt in.
    func adopt(_ rows: [ConnectionAccountChoice]) {
        choices = rows
        original = Set(rows.filter(\.enabled).map(\.accountRef))
        enabled = original
        loaded = true
    }

    func load(model: AppModel, connectionId: Int64) async {
        guard !loaded else { return }
        if let rows = try? await model.vaultOffMain({ try $0.connectionAccountChoices(connectionId: connectionId) }) {
            adopt(rows)
        } else {
            loaded = true
        }
    }

    /// Saves the selection; false (with `error`) when it failed.
    func save(model: AppModel, connectionId: Int64) async -> Bool {
        let refs = Array(enabled)
        // accounts switched off by this save are archived, and archived accounts are hidden (#720)
        let switchedOff = AccountSelectionList.switchesAnythingOff(choices, enabled: enabled)
        do {
            _ = try await model.requireVaultOffMain { try $0.setConnectionAccountChoices(connectionId: connectionId, enabledRefs: refs) }
            if switchedOff { model.showArchivedAccounts = false }
            original = enabled
            error = nil
            model.reloadAll()
            return true
        } catch {
            self.error = describe(error)
            return false
        }
    }

    /// For a sheet's "Speichern": nothing to do (true) unless the selection was changed.
    func saveIfChanged(model: AppModel, connectionId: Int64) async -> Bool {
        hasChanges ? await save(model: model, connectionId: connectionId) : true
    }
}

/// Which accounts of one login are fetched (#346). Accounts that are already
/// reachable through another login are held back until the user decides; skipped
/// accounts stay listed so the choice can be changed later.
struct AccountSelectionList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reportRedaction) private var redaction
    let connection: BankConnection
    /// Called after a successful save (the sheet closes itself).
    var onSaved: () -> Void = {}
    var showsSaveButton = true
    var saveTitle: LocalizedStringKey = "Auswahl speichern"
    /// The edited selection. Without one, the list owns its own and saves it by its button.
    var draft: AccountSelectionDraft?
    @State private var ownDraft = AccountSelectionDraft()
    private var d: AccountSelectionDraft { draft ?? ownDraft }


    var body: some View {
        Group {
            if !d.loaded {
                ProgressView()
            } else if d.choices.isEmpty {
                Text("Noch keine Konten abgerufen.").foregroundStyle(.secondary)
            } else {
                ForEach(d.choices, id: \.accountRef) { c in
                    Toggle(isOn: Binding(
                        get: { d.enabled.contains(c.accountRef) },
                        set: { on in
                            if on { d.enabled.insert(c.accountRef) } else { d.enabled.remove(c.accountRef) }
                        })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).sensitive()
                            Text(detail(c)).appFont(.caption).foregroundStyle(.secondary).sensitive()
                            if c.pending, !c.existingConnection.isEmpty {
                                Label("Bereits über „\(redaction.masking(c.existingConnection))“ eingebunden", systemImage: "exclamationmark.triangle")
                                    .appFont(.caption).foregroundStyle(Theme.warning)
                            }
                        }
                    }
                }
                Text("Abrufen: Konto, Umsätze und Dokumente werden über diesen Zugang importiert. Überspringen: nichts davon; das Konto wird archiviert und ausgeblendet und behält seine gespeicherten Daten. Das Archiv-Symbol in der Seitenleiste zeigt archivierte Konten wieder an.")
                    .appFont(.caption).foregroundStyle(.secondary)
                if let error = d.error { Text(error).appFont(.caption).foregroundStyle(Theme.negative) }
                if showsSaveButton {
                    Button(saveTitle) { save() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .task { await d.load(model: model, connectionId: connection.id) }
    }

    private func detail(_ c: ConnectionAccountChoice) -> String {
        [c.number, c.owner].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// True when the save switches off an account that was on: it gets archived, and the sidebar
    /// then hides archived accounts so the account disappears (#720).
    static func switchesAnythingOff(_ choices: [ConnectionAccountChoice], enabled: Set<String>) -> Bool {
        choices.contains { $0.enabled && !enabled.contains($0.accountRef) }
    }

    func save() {
        Task {
            if await d.save(model: model, connectionId: connection.id) { onSaved() }
        }
    }
}

/// The choice itself: title, explanation, the list and "Später". Used as a sheet and
/// inside a running portal fetch (before documents are downloaded).
struct AccountSelectionPanel: View {
    @Environment(\.reportRedaction) private var redaction
    let connection: BankConnection
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if connection.connector == .americanExpress {
                    // several cards behind one login (#243)
                    Text("Welche Karten sollen abgerufen werden?").appFont(.title3, weight: .bold)
                    Text("Unter „\(redaction.masking(connection.displayName))“ gibt es mehrere Karten. Jede gewählte Karte wird ein eigenes Konto, nicht gewählte werden übersprungen.")
                        .appFont(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Konten auswählen – \(redaction.masking(connection.displayName))").appFont(.title3, weight: .bold)
                    Text("Einige Konten sind bereits über einen anderen Zugang eingebunden. Wählen Sie, welche über diesen Zugang abgerufen werden sollen. Ohne Auswahl werden sie übersprungen.")
                        .appFont(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            Divider()
            Form { AccountSelectionList(connection: connection, onSaved: onDone, saveTitle: "Übernehmen und fortfahren") }
                .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Später") { onDone() }
            }
            .padding(14)
        }
    }
}

/// Shown after a fetch when an account was found that another login already delivers.
struct AccountSelectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connection: BankConnection

    var body: some View {
        AccountSelectionPanel(connection: connection) {
            dismiss()
            model.checkPendingAccountSelection()
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 560)
    }
}
