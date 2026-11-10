import SwiftUI
import GiroCrabCore
#if os(macOS)
import AppKit
#endif

/// Einstellungen: Bankzugänge, eigene FinTS-Produkt-ID und API-Schlüssel
/// (im verschlüsselten SQLCipher-Tresor), Händler-Logos, Sicherheit.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            BankConnectionsSettings()
                .tabItem { Label("Banken", systemImage: "building.columns") }
            CredentialsSettings()
                .tabItem { Label("FinTS & API-Schlüssel", systemImage: "key.horizontal") }
            LogoSettings()
                .tabItem { Label("Händler-Logos", systemImage: "photo.on.rectangle") }
            SecuritySettings()
                .tabItem { Label("Sicherheit", systemImage: "lock.shield") }
        }
        .disabled(model.vault == nil)
        #if os(iOS)
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct BankConnectionsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var addKind: ConnectorKind = .volksbankKasselGoettingen
    @State private var login = ""
    @State private var editing: BankConnection?

    var body: some View {
        Form {
            if model.demoActive {
                Section {
                    Label(model.hasOwnVault
                          ? "Sie sehen gerade Demo-Daten. Neue Bankzugänge werden in Ihrem eigenen Tresor angelegt – die App wechselt dabei automatisch dorthin."
                          : "Demo-Modus: Bankzugänge werden hier nur simuliert. Für echte Konten zuerst den eigenen Tresor öffnen.",
                          systemImage: "theatermasks")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !model.hasOwnVault {
                        Button("Eigenen Tresor öffnen") { model.showOwnVault() }
                    }
                }
            }
            Section("Verbundene Banken") {
                if model.connections.isEmpty {
                    Text("Noch keine Bank hinzugefügt.").foregroundStyle(.secondary)
                }
                ForEach(model.connections) { c in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(c.connector.tint.opacity(0.12))
                            .overlay(Text(c.connector.monogram).font(.caption.bold()).foregroundStyle(c.connector.tint))
                            .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.displayName).fontWeight(.medium)
                            Text(protocolName(c.connector) + (c.loginName.isEmpty ? "" : " · \(c.loginName)"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let t = c.lastSyncUnix {
                            Text(Date(timeIntervalSince1970: TimeInterval(t)), style: .relative)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button { editing = c } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.borderless)
                            .help("Bearbeiten / Details")
                        Button { model.requestSync(c) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.borderless)
                            .help("Jetzt abrufen")
                        Button(role: .destructive) { model.removeConnection(c.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Bank und ihre Konten entfernen")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = c }
                }
            }
            Section("Bank hinzufügen") {
                Picker("Institut", selection: $addKind) {
                    ForEach(bankCatalog()) { d in
                        Text(d.name).tag(d.kind)
                    }
                }
                if let d = bankCatalog().first(where: { $0.kind == addKind }) {
                    TextField(d.loginLabel, text: $login)
                        .autocorrectionDisabled()
                    LabeledContent("Verfahren", value: d.protocol)
                    if !d.bankCode.isEmpty { LabeledContent("BLZ", value: d.bankCode) }
                    Text(d.note).font(.caption).foregroundStyle(.secondary)
                    let missing = d.requiredSettings.filter { key in !(model.settings.first { $0.key == key }?.hasValue ?? false) }
                    if !missing.isEmpty {
                        Label("Wird nach dem Hinzufügen abgefragt: \(missing.map { settingLabels[$0] ?? $0 }.joined(separator: ", "))", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Bank hinzufügen") {
                    model.addConnection(addKind, login: addKind == .tradeRepublic ? normalizePhoneNumber(input: login) : login)
                    login = ""
                }
                Text("Gibt es den Zugang schon (gleiche Bank, gleiche Kennung), wird er aktualisiert statt doppelt angelegt.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { c in
            ConnectionEditSheet(connection: c)
                .environment(model)
        }
    }

    private func protocolName(_ k: ConnectorKind) -> String {
        bankCatalog().first { $0.kind == k }?.protocol ?? ""
    }
}

struct CredentialsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Group by the core's stable group id, show its translated title, match
        // on keys (logo settings have their own tab) and keep the core's order.
        let entries = model.settings.filter { !$0.key.hasPrefix("merchants.") }
        let grouped = Dictionary(grouping: entries, by: \.group)
        let order = entries.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        Form {
            Section {
                Label("Nichts davon wird mit der App ausgeliefert. Registrieren Sie Ihr eigenes FinTS-Produkt und Ihre eigenen API-Anwendungen; die Werte liegen nur in Ihrem verschlüsselten Tresor.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(order.filter { grouped[$0] != nil }, id: \.self) { g in
                Section(grouped[g]?.first?.groupTitle ?? g) {
                    ForEach(grouped[g] ?? []) { entry in
                        SettingField(entry: entry)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SettingField: View {
    @Environment(AppModel.self) private var model
    let entry: SettingEntry
    @State private var text = ""
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.label)
                Spacer()
                if entry.isSecret {
                    if editing {
                        SecureField("", text: $text)
                            .frame(maxWidth: 280)
                            .onSubmit(save)
                        Button("Speichern", action: save)
                    } else {
                        Text(entry.hasValue ? "••••••••" : "nicht gesetzt").foregroundStyle(entry.hasValue ? .primary : .secondary)
                        Button(entry.hasValue ? "Ändern" : "Festlegen") { text = ""; editing = true }
                    }
                } else {
                    TextField("", text: $text, prompt: Text("nicht gesetzt"))
                        .frame(maxWidth: 340)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .onSubmit(save)
                }
            }
            Text(entry.help).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if !entry.isSecret { text = entry.value } }
        #if os(macOS)
        .onDisappear { if !entry.isSecret && text != entry.value { save() } }
        #endif
    }

    private func save() {
        model.saveSetting(entry.key, text)
        if entry.isSecret { text = ""; editing = false }
    }
}

struct LogoSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Händler-Logos") {
                LabeledContent("Stufe 1 – offline", value: String(localized: "Mitgelieferte Händlertabelle (Monogramm + Markenfarbe)"))
                LabeledContent("Stufe 1b – simple-icons", value: String(localized: "Vektor-Markenzeichen (CC0-Datensatz) für bekannte Marken"))
                Toggle("Stufe 2 – Logos online laden (Google-Favicon, Ersatz DuckDuckGo; Standard: an)", isOn: Binding(
                    get: { model.onlineLogos },
                    set: { model.saveSetting("merchants.online_logos", $0 ? "1" : "0") }
                ))
                Text("Lädt Favicons über google.com/s2/favicons bzw. icons.duckduckgo.com und speichert sie verschlüsselt in der Tabelle merchant_logo_cache. Übertragen wird nur die Händler-Domain (z. B. lidl.de) – keine Beträge, keine Kontodaten.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Stufe 3 – Rückfall", value: String(localized: "SF Symbol der Kategorie"))
                Button("Logo-Cache leeren", role: .destructive) { model.clearLogoCache() }
            }
        }
        .formStyle(.grouped)
    }
}

struct SecuritySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Tresor") {
                LabeledContent("Verschlüsselung", value: "SQLCipher 4 (AES-256)")
                LabeledContent("Hauptschlüssel", value: model.isDemo ? String(localized: "Demo-Schlüssel (Wegwerf)") : String(localized: "Schlüsselbund, geschützt durch \(VaultKeyManager.shared.biometryName)"))
                LabeledContent("Datei", value: model.vault?.filePath() ?? "–")
                    .textSelection(.enabled)
                LabeledContent("Core-Version", value: coreVersion())
            }
            ICloudSyncSection()
            Section("Datenschutz") {
                Text("GiroCrab verbindet sich direkt von diesem Gerät mit Ihren Banken. Es gibt keinen GiroCrab-Server, kein Tracking und keine Cloud-Synchronisation. PINs und TANs liegen nur für einen Abruf im Speicher und werden danach gelöscht.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.hasOwnVault && !model.isDemo {
                Section {
                    Button("Jetzt sperren", systemImage: "lock.fill") { model.lock() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Kompakter iCloud-Drive-Sync (nur die verschlüsselte Tresordatei).
struct ICloudSyncSection: View {
    @Environment(AppModel.self) private var model
    @State private var sync = CloudSyncManager.shared
    @State private var picking = false

    var body: some View {
        Section("iCloud Sync") {
            Toggle("Tresor über iCloud synchronisieren", isOn: Bindable(sync).isEnabled)
                .onChange(of: sync.isEnabled) { _, on in
                    if on { model.syncNow() }
                }
            if sync.isEnabled {
                LabeledContent("Ordner", value: sync.folderName ?? "iCloud Drive / GiroCrab")
                #if os(macOS)
                Button("Im Finder zeigen", systemImage: "folder") { revealFolder() }
                #else
                Button("Ordner wählen …", systemImage: "folder") { picking = true }
                #endif
                Button(sync.isSyncing ? "Synchronisiere …" : "Jetzt synchronisieren", systemImage: "arrow.triangle.2.circlepath") {
                    model.syncNow()
                }
                .disabled(sync.isSyncing)
                if sync.isSyncing { ProgressView().controlSize(.small) }
                if let d = sync.lastSync {
                    LabeledContent("Letzter Sync", value: d.formatted(date: .abbreviated, time: .shortened))
                }
                if let s = sync.lastStats { Text(s).font(.caption).foregroundStyle(.secondary) }
                if let e = sync.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Text("Synchronisiert Ihren verschlüsselten Tresor automatisch über iCloud Drive (Ordner „GiroCrab“).")
                .font(.caption).foregroundStyle(.secondary)
        }
        #if os(iOS)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r {
                do { try sync.setFolder(url); model.syncNow() } catch { }
            }
        }
        #endif
    }

    #if os(macOS)
    private func revealFolder() {
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let mm = cloudDocs.appendingPathComponent("moneymoney", isDirectory: true)
        let gc = cloudDocs.appendingPathComponent("GiroCrab", isDirectory: true)
        let url = FileManager.default.fileExists(atPath: mm.appendingPathComponent("tresor.girocrab").path) ? mm : gc
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(cloudDocs)
        }
    }
    #endif
}
