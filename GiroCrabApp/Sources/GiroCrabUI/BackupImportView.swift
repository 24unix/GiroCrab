import SwiftUI

/// „Vorhandene Daten importieren“ › Datenbank › GiroCrab: restores a backup
/// from „Tresor sichern …“, like Einstellungen › Sicherheit › „Tresor
/// wiederherstellen …“. Unlike the other sources it replaces the vault.
struct BackupImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Tells the sheet that the restore is running (it locks the source switch).
    @Binding var running: Bool
    @Binding var source: MoneyMoneyImportSheet.Source

    @State private var fileURL: URL?
    @State private var password = ""
    @State private var picking = false
    @State private var confirming = false
    @State private var restoring = false
    @State private var error: String?

    /// The vault already holds accounts that the backup would replace.
    private var replacesAccounts: Bool { model.hasOwnVault && !model.demoActive && !model.allAccounts.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ImportAssistantHeader(title: String(localized: "Vorhandene Daten importieren"),
                                  subtitle: String(localized: "Wählen Sie, woher die Daten kommen. Die Originaldaten bleiben unverändert."))
            Form {
                ImportSourceSection(source: $source).disabled(restoring)
                Section {
                    ImportFileRow(title: "Sicherung", url: fileURL, name: fileURL?.lastPathComponent ?? "") { picking = true }
                    SecureField("Passwort", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Datei").appSectionHeader()
                } footer: {
                    Text("Ersetzt alle Daten dieses Tresors durch die Sicherung. Ist iCloud Sync aktiv, kommen Änderungen Ihrer anderen Geräte beim nächsten Abgleich wieder hinzu.")
                        .appFont(.caption).foregroundStyle(Theme.secondary)
                        .leadingFooter()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden) // flush with the sheet, like the other sources
            .scrollDisabled(true)
            #if os(macOS)
            .frame(maxWidth: .infinity, minHeight: 470, maxHeight: 470, alignment: .top)
            #endif
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .appFont(.callout).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            AssistantFooter(cancelDisabled: restoring, cancel: { dismiss() },
                            nextTitle: "Wiederherstellen",
                            nextDisabled: fileURL == nil || password.isEmpty || restoring,
                            busy: restoring) {
                if replacesAccounts { confirming = true } else { restore() }
            }
        }
        .interactiveDismissDisabled(restoring)
        .onChange(of: restoring) { _, now in running = now }
        .fileImporter(isPresented: $picking, allowedContentTypes: [VaultBackup.contentType, .data]) { result in
            if case .success(let url) = result { fileURL = url; error = nil }
        }
        .confirmationDialog("Tresor ersetzen?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Ersetzen", role: .destructive) { restore() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Ihr Tresor enthält bereits Konten. Sie werden durch den Inhalt der Sicherung ersetzt.")
        }
    }

    private func restore() {
        guard let url = fileURL else { return }
        restoring = true; error = nil
        Task {
            let ok = await model.restoreBackup(from: url, password: password)
            restoring = false
            if ok { dismiss() } else { error = model.toast; model.toast = nil }
        }
    }
}
