import SwiftUI
import QuickLook
import GiroCrabCore

/// The app's scenes, shared by the macOS executable and the Xcode
/// multiplatform target.
public struct GiroCrabScenes: Scene {
    @State private var model: AppModel

    public init(options: LaunchOptions = .current) {
        _model = State(initialValue: AppModel(options: options))
    }

    public var body: some Scene {
        WindowGroup("GiroCrab", id: "main") {
            GiroCrabRootView()
                .environment(model)
                .preferredColorScheme(.light)
        }
        #if os(macOS)
        .defaultSize(width: 1500, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neue Überweisung …") { model.openTransfer() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.canTransfer)
                Button("Befehlspalette …") { model.showCommandPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.vault == nil)
                Button("Alle Konten abrufen") { model.requestSyncAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.vault == nil)
                Button("Regeln …") { model.openRuleEditor() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                    .disabled(model.vault == nil)
            }
            CommandMenu("Buchung") {
                Button("Kategorisieren …") { if model.selectedBooking != nil { model.showCategorizer = true } }
                    .disabled(model.selectedBooking == nil)
                Button("Regel für diesen Händler erstellen …") { model.openRuleEditor(from: model.selectedBooking) }
                    .disabled(model.selectedBooking == nil)
                Divider()
                Button("Nächste Buchung") { model.moveSelection(1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Vorherige Buchung") { model.moveSelection(-1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                ForEach(Array(BookingScope.ordered.enumerated()), id: \.offset) { i, s in
                    Button(s.title) { model.scope = s }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Tresor sperren") { model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                    .disabled(!model.hasOwnVault)
            }
            CommandGroup(after: .sidebar) {
                Button(model.demoActive ? "Eigenen Tresor anzeigen" : "Demo-Daten anzeigen") {
                    if model.demoActive { model.showOwnVault() } else { model.showDemo() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.vault == nil)
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.light)
                .frame(width: 760, height: 600)
        }
        #endif
    }
}

public struct GiroCrabRootView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        switch model.vaultState {
        case .open:
            MainSplitView()
        case .locked, .unlocking:
            LockView()
        case .failed(let message):
            LockView(error: message)
        }
    }
}

struct LockView: View {
    @Environment(AppModel.self) private var model
    var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(Theme.accent)
            Text("GiroCrab ist gesperrt")
                .font(.title.bold())
            Text("Ihre Buchungen liegen in einem verschlüsselten SQLCipher-Tresor.\nDer Schlüssel verlässt nie den Schlüsselbund dieses Geräts.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary)
            Button {
                model.unlock()
            } label: {
                Label("Mit \(VaultKeyManager.shared.biometryName) entsperren", systemImage: VaultKeyManager.shared.biometrySymbol)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.vaultState == .unlocking)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Button("Ohne Entsperren: Demo-Daten ansehen") { model.showDemo() }
                .buttonStyle(.borderless)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .task {
            if model.vaultState == .locked && error == nil { model.unlock() }
        }
    }
}

struct MainSplitView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } content: {
            Group {
                if model.sidebarSelection == .documents {
                    DocumentsView()
                } else {
                    BookingStreamView()
                }
            }
            .navigationSplitViewColumnWidth(min: 520, ideal: 820)
        } detail: {
            InspectorView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 340, max: 420)
        }
        .navigationSplitViewStyle(.balanced)
        .quickLookPreview($model.quickLookURL)
        .sheet(isPresented: $model.showRuleEditor) {
            RuleEditorView(initialDraft: model.ruleDraft)
                .environment(model)
        }
        .sheet(isPresented: $model.showCommandPalette) {
            CommandPaletteView()
                .environment(model)
        }
        .sheet(isPresented: $model.showCategorizer) {
            CategorizerSheet()
                .environment(model)
        }
        .sheet(isPresented: $model.showTransferSheet) {
            TransferSheetView()
                .environment(model)
                .interactiveDismissDisabled(model.transferBusy)
        }
        .sheet(item: $model.activeChallenge) { _ in
            TwoFactorSheet()
                .environment(model)
                .interactiveDismissDisabled()
        }
        .sheet(item: $model.webLoginConnection) { c in
            Group {
                if c.connector == .tradeRepublic { WebLoginSheet(connection: c) } else { PortalWebSheet(connection: c) }
            }
            .environment(model)
        }
        .sheet(item: $model.setupRequest) { req in
            BankSetupSheet(request: req)
                .environment(model)
        }
        .sheet(item: $model.pendingLogin) { login in
            PinSheet(connection: login.connection)
                .environment(model)
        }
        #if os(iOS)
        .sheet(isPresented: $model.showSettings) {
            NavigationStack { SettingsView() }
                .environment(model)
        }
        #endif
        .alert("Etwas ist schiefgelaufen", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        withAnimation { model.toast = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast)
    }
}
