import SwiftUI
import UniformTypeIdentifiers

/// Rules and names for „Tresor sichern …“ (see `AppModel+Backup.swift`).
enum VaultBackup {
    static let minPasswordLength = 8
    static let contentType = UTType(filenameExtension: "girocrab-backup", conformingTo: .data) ?? .data

    /// Long enough and typed the same twice.
    static func acceptable(_ password: String, repeated: String) -> Bool {
        password.count >= minPasswordLength && password == repeated
    }

    /// „Passwort vorschlagen“: lower-case letters and digits without
    /// look-alikes (l/1, o/0), easy to read and type if it must be.
    static let passwordAlphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")

    /// Three groups of six like the Passwords app, e.g. "kawxe7-hupdyq-bomtiz":
    /// 18 characters from 32, about 90 bits, from the system's secure generator.
    static func suggestedPassword() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<3).map { _ in
            String((0..<6).map { _ in passwordAlphabet.randomElement(using: &rng)! })
        }.joined(separator: "-")
    }

    /// E.g. "GiroCrab-Sicherung 2026-11-15.girocrab-backup".
    static func fileName(date: Date = .now) -> String {
        let day = date.formatted(.iso8601.year().month().day())
        return "GiroCrab-Sicherung \(day).girocrab-backup"
    }
}

/// The backup handed to `.fileExporter`.
struct VaultBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [VaultBackup.contentType] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Einstellungen › Sicherheit: save the own vault with a password, or replace
/// it with such a backup.
struct VaultBackupSection: View {
    @Environment(AppModel.self) private var model
    private enum Step: Identifiable {
        case backup
        case restore(URL)
        var id: String { if case .restore(let url) = self { url.path } else { "backup" } }
    }
    @State private var step: Step?
    @State private var document: VaultBackupDocument?
    @State private var exporting = false
    @State private var importing = false

    var body: some View {
        Section {
            Button("Tresor sichern …", systemImage: "externaldrive.badge.plus") { step = .backup }
            Button("Tresor wiederherstellen …", systemImage: "clock.arrow.circlepath") { importing = true }
            Text("Die Sicherung enthält alle Konten, Buchungen, Kategorien, Regeln und Einstellungen des Tresors, verschlüsselt mit einem Passwort Ihrer Wahl. Sie lässt sich auf jedem Gerät wiederherstellen, auch ohne diesen Schlüsselbund – aber nicht ohne das Passwort.")
                .appFont(.callout).foregroundStyle(.secondary)
        } header: { Text("Sicherung").appSectionHeader() }
        .sheet(item: $step) { step in
            switch step {
            case .backup:
                BackupPasswordSheet(restoring: false) { password in
                    Task {
                        guard let data = await model.makeBackup(password: password) else { return }
                        document = VaultBackupDocument(data: data)
                        exporting = true
                    }
                }
            case .restore(let url):
                BackupPasswordSheet(restoring: true) { password in
                    Task { _ = await model.restoreBackup(from: url, password: password) }
                }
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: VaultBackup.contentType,
                      defaultFilename: VaultBackup.fileName()) { result in
            if case .success = result { model.toast = String(localized: "Sicherung gespeichert") }
            document = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [VaultBackup.contentType, .data]) { result in
            if case .success(let url) = result { step = .restore(url) }
        }
    }
}

/// Asks for the backup password: twice when saving, once (with a warning)
/// when restoring.
private struct BackupPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let restoring: Bool
    let confirm: (String) -> Void
    @State private var password = ""
    @State private var repeated = ""
    /// Shown while both fields still hold the suggested password.
    @State private var suggestion: String?
    @State private var copied = false

    private var ready: Bool {
        restoring ? !password.isEmpty : VaultBackup.acceptable(password, repeated: repeated)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(restoring ? "Tresor wiederherstellen" : "Tresor sichern").appFont(.headline)
            SecureField("Passwort", text: $password)
                // AutoFill from the Passwords app (or another password manager) instead of typing.
                .textContentType(.password)
            if restoring {
                Text("Ersetzt alle Daten dieses Tresors durch die Sicherung. Ist iCloud Sync aktiv, kommen Änderungen Ihrer anderen Geräte beim nächsten Abgleich wieder hinzu.")
                    .appFont(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SecureField("Passwort wiederholen", text: $repeated)
                Button("Passwort vorschlagen", systemImage: "key") {
                    let p = VaultBackup.suggestedPassword()
                    password = p; repeated = p; suggestion = p; copied = false
                }
                if let suggestion {
                    HStack {
                        Text(suggestion).appFont(.body, design: .monospaced).textSelection(.enabled)
                        Spacer()
                        Button(copied ? "Kopiert" : "Kopieren", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            VaultKeyManager.copyToPasteboard(suggestion)
                            copied = true
                        }
                    }
                    Text("Sichern Sie das Passwort jetzt in der Passwörter-App oder Ihrem Passwortmanager. Die Zwischenablage wird nach 60 Sekunden geleert.")
                        .appFont(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Mindestens \(VaultBackup.minPasswordLength) Zeichen. Ohne dieses Passwort lässt sich die Sicherung nicht öffnen – auch nicht von GiroCrab.")
                    .appFont(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(restoring ? "Wiederherstellen" : "Sichern", role: restoring ? .destructive : nil) {
                    confirm(password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(minWidth: 360)
        // typed over the suggestion: it no longer applies
        .onChange(of: password) { _, p in if p != suggestion { suggestion = nil } }
    }
}
