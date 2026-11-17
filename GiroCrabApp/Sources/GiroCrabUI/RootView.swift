import SwiftUI
import QuickLook
import GiroCrabCore
#if os(macOS)
import AppKit
#endif

/// The app's scenes, shared by the macOS executable and the Xcode
/// multiplatform target.
public struct GiroCrabScenes: Scene {
    @State private var model: AppModel
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .system
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @AppStorage(ViewLayout.inspectorKey) private var showInspector = true
    @AppStorage(ViewLayout.statisticsKey) private var showStatistics = true
    @AppStorage(ViewLayout.budgetsKey) private var showBudgets = true
    @AppStorage(ViewLayout.runningBalanceKey) private var showRunningBalance = false
    @AppStorage(ViewLayout.compactHeaderKey) private var compactHeader = false
    @AppStorage(BalanceChartStyle.defaultsKey) private var chartStyle: BalanceChartStyle = .line
    @AppStorage(ViewLayout.headerChartCollapsedKey) private var chartCollapsed = false
    @AppStorage(AppTextSize.defaultsKey) private var textSize: AppTextSize = .standard
    @AppStorage(PrivacyMode.enabledKey) private var privacyMode = false
    #endif

    public init(options: LaunchOptions = .current) {
        _model = State(initialValue: Self.prepare(options: options))
    }

    /// Creates the app's one model. Call it from the `App`'s `init`, not from its
    /// `body`: SwiftUI re-creates this struct on every evaluation of the app body,
    /// and a model built there (a) is built again each time – `AppModel.init`
    /// opens the vault and loads everything on the main thread – and (b) makes
    /// every property the init reads a dependency of the app body, so the
    /// model's own async loads re-evaluate the body and build the next model.
    /// A trace showed 10–13 such throw-away models per second.
    @discardableResult
    public static func prepare(options: LaunchOptions = .current) -> AppModel {
        if let model = sharedModel { return model }
        let model = AppModel(options: options)
        sharedModel = model
        GiroCrabTips.configure(options)
        return model
    }

    /// The one model of the app process; see `prepare`.
    @MainActor private static var sharedModel: AppModel?

    public var body: some Scene {
        WindowGroup("GiroCrab", id: "main") {
            // `GiroCrabRootView` sets the preferred colour scheme itself (dark on the
            // brand start/lock screen, otherwise the chosen appearance).
            GiroCrabRootView()
                .environment(model)
                .modifier(AutoLockOnBackground(model: model))
                .privacyModeEnvironment()
                #if os(macOS)
                .appTextSize(textSize.effective)
                .modifier(MenuBarBridge(model: model))
                // Keep the minimum independent of the split columns' ideal heights.
                .frame(minHeight: 480, maxHeight: .infinity)
                #endif
        }
        #if os(macOS)
        // Fits a 13" MacBook Air (1470 × 956 pt) with room for the Dock.
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            // Ablage › Neu: only commands that create something.
            CommandGroup(replacing: .newItem) {
                Button("Neue Überweisung …") { model.openTransfer() }
                    .keyboardShortcut("n", modifiers: .command)
                    // ⌘N in the tag sheet is „Neuer Tag …“ (TagManagerView's key monitor)
                    .disabled(!model.canTransfer || model.showTagManager)
                Button("Neue Kontogruppe …") { model.groupDialog = .create() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.isUnlocked)
                Button("Bank hinzufügen …") { model.showAddBank = true }
                    .disabled(!model.isUnlocked)
                Button("Neues Darlehen …") { model.openLoanEditor(.create) }
                    .disabled(!model.isUnlocked)
                Button("Neues Sachwerte-Konto …") { model.createTangibleAccount() }
                    .disabled(!model.isUnlocked)
                Button("Neues Offline-Konto …") { model.runInOwnVault { model.offlineStore.showNewAccount = true } }
                    .disabled(!model.isUnlocked)
                Button("Neue Hauptkategorie …") { model.newCategoryRequest = NewCategoryRequest(parent: nil) }
                    .disabled(!model.isUnlocked)
            }
            // Ablage › Import/Export (every toolbar command is also in the menu bar).
            CommandGroup(replacing: .importExport) {
                Button("Vorhandene Daten importieren …") { model.openMoneyMoneyImport() }
                    .disabled(!model.isUnlocked)
                Button("Umsätze exportieren …") { model.openBookingExport() }
                    .disabled(!model.isUnlocked)
                Button("Umsätze als CSV exportieren …") { model.exportFilteredBookingsCSV() }
                    .disabled(!model.isUnlocked)
            }
            CommandGroup(replacing: .printItem) {
                Button("Papierformat …") { PageSetup.run() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Drucken …") { model.showPrintSheet = true }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(!model.isUnlocked)
            }
            // "Bank hinzufügen …" lives in Ablage with the other "create" commands
            // (HIG: one command, one menu – Help search otherwise lists it twice).
            CommandMenu("Konten") {
                Button("Alle Konten abrufen") { model.requestSyncAll() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.isUnlocked || model.bankingBlocksAll)
                Divider()
                Button("Regeln …") { model.openRuleEditor() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                    .disabled(!model.isUnlocked)
                Button("Tags verwalten …") { model.showTagManager = true }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!model.isUnlocked)
                Button("Wiederkehrende Buchungen …") { model.showRecurringSheet = true }
                    .disabled(!model.isUnlocked)
            }
            CommandMenu("Buchung") {
                // Offline accounts (#679, #81): typed bookings
                Button("Neue Buchung …") { model.openManualBooking() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(!model.canAddManualBooking)
                Button("Buchung bearbeiten …") { if let b = model.selectedBooking { model.editManualBooking(b) } }
                    .disabled(model.selectedBooking.map { !model.isManuallyEditable($0) } ?? true)
                Button("Buchung löschen …") { if let b = model.selectedBooking { model.offlineStore.deleting = b } }
                    .disabled(model.selectedBooking.map { !model.isManuallyEditable($0) } ?? true)
                Divider()
                // In the list, the single keys C and R do the same (kept for speed).
                Button("Kategorisieren …") { if model.selectedBooking != nil { model.showCategorizer = true } }
                    .keyboardShortcut("c", modifiers: [.command, .control])
                    .disabled(model.selectedBooking == nil)
                Button("Regel für diesen Händler erstellen …") { model.openRuleEditor(from: model.selectedBooking) }
                    .keyboardShortcut("r", modifiers: [.command, .control])
                    .disabled(model.selectedBooking == nil)
                // A checkmark item like "Als Gehalt / Rente zählen"; ⇧⌘U as in Mail
                Toggle("Geprüft", isOn: Binding(
                    get: { model.selectedBooking?.checked ?? false },
                    set: { on in if let b = model.selectedBooking { model.setChecked(on, for: b) } }
                ))
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(model.selectedBooking == nil)
                // ⌥⇧⌘U as in Mail ("Alle Nachrichten als gelesen markieren"), next to ⇧⌘U
                Button("Alle Buchungen als gelesen markieren") { model.markAllChecked() }
                    .keyboardShortcut("u", modifiers: [.command, .shift, .option])
                    .disabled(!model.canMarkAllChecked)
                Button("Notiz bearbeiten") { if let b = model.selectedBooking { model.editNote(for: b) } }
                    .disabled(model.selectedBooking == nil)
                Button("Tags bearbeiten") { if let b = model.selectedBooking { model.editTags(for: b) } }
                    .disabled(model.selectedBooking == nil)
                // like the Finder (⌘Y); Space in the list does the same
                Button("Beleg in Quick Look anzeigen") {
                    if let b = model.selectedBooking, let d = model.documents(for: b).first { model.quickLook(d) }
                }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(model.selectedBooking.map { model.documents(for: $0).isEmpty } ?? true)
                Divider()
                RecurringMenu(model: model, booking: model.selectedBooking)
                    .disabled(model.selectedBooking == nil)
                Toggle("Als Gehalt / Rente zählen", isOn: Binding(
                    get: { model.selectedBooking?.isSalary ?? false },
                    set: { on in if let b = model.selectedBooking { model.setSalaryFlag(b, on) } }
                ))
                .disabled((model.selectedBooking?.amountCents ?? 0) <= 0)
                Divider()
                // ⌘↑/⌘↓ stay with text fields (start/end of text); ↑/↓ work in the list.
                Button("Nächste Buchung") { model.moveSelection(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                Button("Vorherige Buchung") { model.moveSelection(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                Divider()
                ForEach(Array(BookingScope.ordered.enumerated()), id: \.offset) { i, s in
                    Button(model.presentation.menuTitle(index: i, scope: s)) { model.applyScopeShortcut(index: i, scope: s) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
                Divider()
                LoanAssignMenu(model: model, booking: model.selectedBooking)
            }
            CommandGroup(after: .appInfo) {
                if AppUpdates.shared.isAvailable {
                    // Standard place: right below "About", own group (HIG).
                    Button("Nach Updates suchen …") { AppUpdates.shared.checkForUpdates() }
                        .disabled(!AppUpdates.shared.canCheckForUpdates)
                    Divider()
                }
                Button("Tresor sperren") { model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                    .disabled(!model.hasOwnVault)
            }
            // `Group`: a CommandsBuilder takes at most 10 children (older Xcode in CI).
            Group {
                // Hilfe › Mitteilungen …: ellipsis because a window opens.
                // Replaces the default Help menu ("Help isn't available for …").
                CommandGroup(replacing: .help) {
                    Button("GiroCrab-Hilfe") { openWindow(id: "help") }
                        .keyboardShortcut("?", modifiers: .command)
                    Divider()
                    Button("Mitteilungen …") { openWindow(id: "announcements") }
                    Divider()
                    // #301: redacted screenshot + scrubbed diagnostics, then a prefilled issue.
                    // While the report window is open, its "Neu aufnehmen" is
                    // the way to refresh the picture (markings would be lost).
                    Button("Problem melden …") { openWindow(id: "bug-report") }
                        .keyboardShortcut("b", modifiers: [.command, .option])
                        .disabled(model.isReportOpen)
                    Divider()
                    Link("Webseite & Dokumentation (girocrab.de)", destination: HelpLinks.website)
                    Link("Fehler melden / Issue erstellen (GitHub)", destination: HelpLinks.issues)
                    Link("Community & Diskussionen (GitHub)", destination: HelpLinks.discussions)
                }
                // Bearbeiten › Suchen …: focuses the toolbar search field.
                CommandGroup(after: .pasteboard) {
                    Divider()
                    Button("Suchen …") { ToolbarSearch.focus() }
                        .keyboardShortcut("f", modifiers: .command)
                        // not behind the tag sheet: the search field is hidden there
                        .disabled(!model.isUnlocked || model.showTagManager)
                }
            }
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(after: .sidebar) {
                Button(showInspector ? "Informationen ausblenden" : "Informationen einblenden") { showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .disabled(!model.isUnlocked)
                Toggle("Auswertungen anzeigen", isOn: $showStatistics)
                    .disabled(!model.isUnlocked)
                Toggle("Budgets anzeigen", isOn: $showBudgets)
                    .disabled(!model.isUnlocked)
                Toggle("Saldo anzeigen", isOn: $showRunningBalance)
                    .disabled(!model.isUnlocked)
                Toggle("Kopfbereich minimieren", isOn: $compactHeader)
                    .disabled(!model.isUnlocked)
                // the header chart (#634): same switches as its title row
                Toggle("Diagramm anzeigen", isOn: Binding(get: { !chartCollapsed }, set: { chartCollapsed = !$0 }))
                    .disabled(!model.isUnlocked)
                Picker("Diagramm", selection: $chartStyle) {
                    ForEach(BalanceChartStyle.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!model.isUnlocked)
                // Hides amounts (or all personal data, Einstellungen › Allgemein).
                Toggle("Privatmodus", isOn: $privacyMode)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                // Like Mail/Notes: text size of the whole app (#343).
                Button("Größer") { textSize = textSize.larger ?? textSize }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(textSize.larger == nil)
                Button("Kleiner") { textSize = textSize.smaller ?? textSize }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(textSize.smaller == nil)
                Button("Originalgröße") { textSize = .standard }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(textSize == .standard)
                Divider()
                Button("Befehlspalette …") { model.showCommandPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!model.isUnlocked)
                Divider()
                Picker("Konten anzeigen", selection: Binding(get: { model.accountView }, set: { model.accountView = $0 })) {
                    ForEach(AccountSidebarMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(!model.isUnlocked)
                Button("Kontogruppen bearbeiten …") { model.openGroupManager() }
                    .disabled(!model.isUnlocked)
                Divider()
                Button(model.demoActive ? "Eigenen Tresor anzeigen" : "Demo-Daten anzeigen") {
                    if model.demoActive { model.showOwnVault() } else { model.showDemo() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!model.isUnlocked)
            }
        }
        #endif

        #if os(macOS)
        Window("Mitteilungen", id: "announcements") {
            AnnouncementsListView()
                .appTextSize(textSize.effective)
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 460, height: 360)
        Window("Abruf-Protokoll", id: "sync-log") {
            SyncLogView()
                .environment(model)
                .privacyModeEnvironment()
                .appTextSize(textSize.effective)
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 900, height: 520)

        Window("Problem melden", id: "bug-report") {
            BugReportView()
                .environment(model)
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 760, height: 860)

        Window("GiroCrab-Hilfe", id: "help") {
            NavigationStack { HelpView() }
                .appTextSize(textSize.effective)
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 640, height: 720)
        Settings {
            // HIG: the Settings window fits each tab (SettingsView sizes them).
            // `reportCapturable`: "Problem melden" draws the Settings window
            // (a window of its own, like a sheet) over the main window, so its
            // views get the same redaction and mark personal data.
            SettingsView()
                .environment(model)
                .privacyModeEnvironment()
                .appTextSize(textSize.effective)
                .preferredColorScheme(appearance.colorScheme)
                .reportCapturable()
        }
        #endif
    }
}

public struct GiroCrabRootView: View {
    @Environment(AppModel.self) private var model
    /// Language question at start-up (#93, macOS only; iOS has a per-app
    /// language setting of its own). Skipped for developer/screenshot launches.
    @State private var languageQuestion: LanguageQuestion = {
        #if os(macOS)
        let o = LaunchOptions.current
        let developerLaunch = o.demoSeed || o.freshVault || o.screenshotPath != nil
        guard LanguagePreference.isAvailable, !developerLaunch || o.simulateSystemLanguage != nil else { return .none }
        return LanguagePreference.current.startupQuestion()
        #else
        return .none
        #endif
    }()
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    /// iOS cold start: keep the animated crab visible for ~1 s, even when the vault
    /// is ready earlier. Only the view is held back; `bootstrap()` runs immediately.
    #if os(iOS)
    @State private var splashHold = true
    #else
    @State private var splashHold = false
    /// `--demo-sheet report`: the report window was opened (see `MainSplitView`).
    @State private var demoReportShown = false
    #endif

    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .system

    public init() {}

    private var splash: some View { SplashView() }

    /// Colour scheme of the window. The brand start and lock screen (iOS, #505)
    /// are always dark, so the status bar (time, battery) stays white on the
    /// dark backdrop even when the device or the app runs in light mode. Set
    /// here in one place: a second `.preferredColorScheme` further out would
    /// override one on the screens themselves.
    static func preferredScheme(brand: Bool, splashHold: Bool, vaultOpen: Bool, appearance: ColorScheme?) -> ColorScheme? {
        brand && (splashHold || !vaultOpen) ? .dark : appearance
    }

    public var body: some View {
        Group {
            if splashHold && model.vaultState != .starting {
                splash.transition(.opacity)
            } else {
            switch model.vaultState {
            case .starting where languageQuestion == .chooseLanguage:
                LanguagePromptView { languageQuestion = .none }
            case .starting:
                // Same background + centred logo as the system launch screen (LaunchInfo.plist),
                // so there is no visual jump between the two.
                splash
                    .onAppear { model.bootstrap() }
            case .open:
                MainSplitView()
                    // the only window the bug report may capture; inside the
                    // redaction environment, so it can report what was built
                    .background(ReportWindowTracker(role: .main))
                    .transformEnvironment(\.reportRedaction) { $0.formUnion(model.reportRedaction.union(LaunchOptions.current.redaction)) }
                    .onAppear { StartupClock.mark("MainSplitView appear") }
                    #if os(macOS)
                    // screenshots: --demo-sheet report[:<sheet>] captures the open
                    // view or demo sheet, as "Problem melden" would; once, also
                    // after a lock/unlock brings this view back
                    .task(id: model.options.demoSheet) {
                        guard model.options.demoSheetOpensReport, !demoReportShown else { return }
                        demoReportShown = true
                        try? await Task.sleep(for: .milliseconds(2400))
                        openWindow(id: "bug-report")
                    }
                    #endif
                    #if os(iOS)
                    .onDisappear {
                        // #384: a pick with no scene left to pick in ends (iPad:
                        // scenes closed). Checked after this update, once the
                        // closed scene's views are gone.
                        Task { @MainActor in
                            if model.reportPick != nil, !BugReport.hasMainWindow { model.reportPick = nil }
                        }
                    }
                    #endif
                    // Asked only once the vault is open, so it never competes with Touch ID.
                    .modifier(SystemLanguageChangedAlert(newLanguage: Binding(
                        get: { if case .systemChanged(let to) = languageQuestion { to } else { nil } },
                        set: { if $0 == nil { languageQuestion = .none } }
                    )))
            case .locked, .unlocking:
                LockView()
            case .failed(let message):
                LockView(error: message)
            }
            }
        }
        .preferredColorScheme(Self.preferredScheme(
            brand: BrandBackdrop.isPlatformDefault, splashHold: splashHold,
            vaultOpen: model.vaultState == .open, appearance: appearance.colorScheme
        ))
        .animation(.easeOut(duration: 0.35), value: splashHold)
        .task {
            guard splashHold else { return }
            try? await Task.sleep(for: .seconds(1.0))
            splashHold = false
        }
        .onChange(of: scenePhase) { _, phase in CloudSyncManager.shared.sceneChanged(phase) }
    }
}

/// Locks the personal vault again after the app has been in the background
/// for a while, so the Face ID / passcode prompt returns on the next start.
struct AutoLockOnBackground: ViewModifier {
    let model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var backgroundedAt: Date?
    private let timeout: TimeInterval = 60

    func body(content: Content) -> some View {
        #if os(iOS)
        content.onChange(of: phase) { _, new in
            switch new {
            case .background:
                backgroundedAt = Date()
            case .active:
                if let t = backgroundedAt, Date().timeIntervalSince(t) >= timeout, model.holdsRealData { model.lock() }
                backgroundedAt = nil
            default: break
            }
        }
        #else
        content
        #endif
    }
}

/// Start screen: the system launch screen (LaunchInfo.plist) continued, so there is no jump.
struct SplashView: View {
    /// Dark brand backdrop with the large crab (iOS, #505) instead of the canvas.
    var brand = BrandBackdrop.isPlatformDefault

    var body: some View {
        ZStack {
            if brand {
                BrandBackdrop.color.ignoresSafeArea()
                BrandCrabLogo()
                ProgressView().tint(.white).offset(y: BrandBackdrop.logoSize * 0.5 + 44)
            } else {
                MacLaunchBackground()
                VStack(spacing: 20) {
                    MacHeroIcon(phase: .idle)
                    ProgressView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, brand ? .dark : scheme)
    }

    @Environment(\.colorScheme) private var scheme
}

struct LockView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    var error: String?
    /// Dark brand backdrop, large crab and one unlock control (iOS, #505).
    var brand = BrandBackdrop.isPlatformDefault
    /// The unlock has been waiting for a while: most likely a Touch ID or
    /// Keychain prompt the user hasn't noticed (behind the window, other screen).
    @State private var waitingLong = false

    private var waitingHint: LocalizedStringKey {
        #if os(iOS)
        "Bitte bestätigen Sie die Abfrage auf Ihrem Gerät (Face ID oder Code)."
        #else
        "Bitte bestätigen Sie die Abfrage von macOS (Touch ID oder Schlüsselbund). Sie kann hinter diesem Fenster oder auf einem anderen Bildschirm liegen."
        #endif
    }

    private var crabPhase: AnimatedCrabLogoView.Phase {
        if model.unlockCelebrating { return .unlocked }
        if error != nil { return .failed }
        if case .unlocking = model.vaultState { return .unlocking }
        return .idle
    }

    /// One control for both states (#505): the unlock button turns into the
    /// waiting status instead of a greyed-out button with a second line below.
    private var brandUnlockControl: some View {
        let waiting = model.vaultState == .unlocking
        let name = VaultKeyManager.shared.biometryName
        let title: LocalizedStringKey = waiting ? "Warten auf \(name) …" : "Mit \(name) entsperren"
        return Button {
            model.unlock()
        } label: {
            HStack(spacing: 10) {
                if waiting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: VaultKeyManager.shared.biometrySymbol)
                }
                Text(title)
            }
            .appFont(.headline)
            .foregroundStyle(Color.white.opacity(waiting ? 0.8 : 1))
            .padding(.horizontal, 20)
            .frame(maxWidth: 340, minHeight: 54)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(waiting ? AnyShapeStyle(Color.white.opacity(0.1)) : AnyShapeStyle(Theme.accent))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(waiting ? 0.22 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(waiting)
        .animation(Motion.animation(.easeInOut(duration: 0.2)), value: waiting)
    }

    private var brandBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            BrandCrabLogo(phase: crabPhase)
            Text("GiroCrab ist gesperrt")
                .appFont(.title, weight: .bold)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("Ihre Buchungen liegen in einem verschlüsselten Tresor.\nDer Schlüssel verlässt nie den Schlüsselbund dieses Geräts.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(.top, 10)
            Spacer(minLength: 24)
            VStack(spacing: 14) {
                if let error {
                    Text(error).appFont(.callout).foregroundStyle(Theme.charge).multilineTextAlignment(.center)
                }
                if waitingLong && model.vaultState == .unlocking {
                    Label(waitingHint, systemImage: "exclamationmark.bubble")
                        .appFont(.callout)
                        .foregroundStyle(Theme.warning)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                brandUnlockControl
                if model.lockPreview && !AppModel.vaultMayHoldRealData && model.vaultState != .unlocking {
                    Button("Zurück zur Demo") { model.endLockPreview() }
                        .buttonStyle(.borderless)
                        .tint(.white)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandBackdrop.color.ignoresSafeArea())
    }

    var body: some View {
        Group {
            if brand { brandBody } else { standardBody }
        }
        // Theme colours on the dark backdrop resolve to their dark variants.
        .environment(\.colorScheme, brand ? .dark : scheme)
        .task {
            if model.vaultState == .locked && error == nil && !model.demoDismissedLock { model.unlock() }
        }
        .task(id: model.vaultState == .unlocking) {
            waitingLong = false
            guard model.vaultState == .unlocking else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled && model.vaultState == .unlocking { waitingLong = true }
        }
    }

    private var standardBody: some View {
        VStack(spacing: 16) {
            MacHeroIcon(phase: crabPhase)
                .padding(.bottom, -22)
            Text("GiroCrab ist gesperrt")
                .appFont(.title, weight: .bold)
            Text("Ihre Buchungen liegen in einem verschlüsselten Tresor.\nDer Schlüssel verlässt nie den Schlüsselbund dieses Geräts.")
                .appFont(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary)
                .padding(.bottom, 6)
            Button {
                model.unlock()
            } label: {
                Label("Mit \(VaultKeyManager.shared.biometryName) entsperren", systemImage: VaultKeyManager.shared.biometrySymbol)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.vaultState == .unlocking)
            if model.vaultState == .unlocking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    #if os(iOS)
                    Text("Warten auf \(VaultKeyManager.shared.biometryName) …").foregroundStyle(Theme.secondary)
                    #else
                    Text("Warte auf macOS …").foregroundStyle(Theme.secondary)
                    #endif
                }
                if waitingLong {
                    Label(waitingHint, systemImage: "exclamationmark.bubble")
                        .appFont(.callout)
                        .foregroundStyle(Theme.warning)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }
            if let error {
                Text(error).appFont(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if model.lockPreview && !AppModel.vaultMayHoldRealData && model.vaultState != .unlocking {
                Button("Zurück zur Demo") { model.endLockPreview() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacLaunchBackground())
    }
}

struct MainSplitView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(EnableBankingKeySync.noticeSuppressedKey) private var enableBankingNoticeSuppressed = false
    @Environment(\.textScale) private var textScale
    #if os(macOS)
    @State private var columns: NavigationSplitViewVisibility = .all
    @AppStorage(ViewLayout.inspectorKey) private var showInspector = true
    @State private var inspectorWidth: CGFloat = 320
    @State private var inspectorDragStart: CGFloat?
    @Environment(\.openSettings) private var openSettings
    #else
    @State private var columns: NavigationSplitViewVisibility = .automatic
    #endif

    private var sidebar: some View {
        SidebarView()
            .frame(minHeight: 0, maxHeight: .infinity)
            // wider with larger text (#343): balances must not be cut off
            .macColumnWidth(min: 240 * textScale, ideal: 260 * textScale, max: 480 * textScale)
    }

    private var bookingColumn: some View {
        Group {
            if model.sidebarSelection == .documents {
                DocumentsView()
            } else if model.sidebarSelection == .planned {
                PlannedPaymentsView()
            } else if model.sidebarSelection == .directDebits {
                DirectDebitsView()
            } else if model.sidebarSelection == .wealth {
                WealthView()
            } else {
                accountColumn
            }
        }
        #if os(macOS)
        // The customizable toolbar belongs to the column, not to the view in
        // it: its items must stay when Belege replaces the booking list
        // (AppKit crashes on customizable items that come and go).
        .modifier(MainToolbar())
        // Window title for both views here too, so the toolbar keeps the same
        // compact style (and height) when switching to Belege.
        .modifier(WindowTitle(title: model.title))
        #endif
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    /// A securities depot and a Sachwerte account each have their own view on the shared holdings frame
    /// (`AssetAccountFrame`); everything else shows bookings. `.id` keeps no state of another account.
    @ViewBuilder
    private var accountColumn: some View {
        switch model.presentation {
        case .securities:
            if let depot = model.selectedSecuritiesDepot { DepotDetailView(account: depot).id(depot.id) }
        case .tangible:
            if let account = model.selectedTangibleAccount { TangibleAccountDetailView(account: account).id(account.id) }
        case .bookings:
            BookingStreamView()
        }
    }

    #if os(macOS)
    /// macOS: the right pane sits next to the booking column in the `detail`
    /// column instead of the system `.inspector`. On macOS 27 the inspector
    /// renders its content a few points below where it hit-tests, so clicks in
    /// it land one row off (#492); a plain view does not have that offset.
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            HStack(spacing: 0) {
                bookingColumn
                if showInspector {
                    inspectorSplitter
                    InspectorView()
                        .frame(width: inspectorWidth * textScale)
                        .frame(minHeight: 0, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            // min widths: 240 (sidebar) + 560 + 280 (inspector) keep the minimum window size
            .macColumnWidth(min: showInspector ? 560 + inspectorWidth : 560,
                            ideal: showInspector ? 700 + inspectorWidth : 700)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Draggable grip between the booking column and the inspector; the system
    /// `.inspector` provided one, so the replacement HStack re-implements it.
    private var inspectorSplitter: some View {
        ZStack {
            Color.clear.frame(width: 10)
            Color(nsColor: .separatorColor).frame(width: 1).frame(maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .frame(width: 10)
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if inspectorDragStart == nil { inspectorDragStart = inspectorWidth }
                    let proposed = (inspectorDragStart ?? inspectorWidth) - value.translation.width
                    inspectorWidth = min(380, max(280, proposed))
                }
                .onEnded { _ in inspectorDragStart = nil }
        )
    }
    #else
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } content: {
            bookingColumn
        } detail: {
            InspectorView()
                .frame(minHeight: 0, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }
    #endif

    var body: some View {
        @Bindable var model = model
        splitView
        .quickLookPreview($model.quickLookURL)
        .accountGroupDialogs($model.groupDialog)
        .newCategoryDialog()
        .manualLoanSheets(model)
        .openingBalanceSheet(model)
        .offlineAccountSheets(model)
        .tangibleAssetSheets(model)
        #if os(macOS)
        // AppModel.openSettings(_:), e.g. the merchant-logo tip → Settings › Händler-Logos
        .onChange(of: model.settingsRequested) { _, requested in
            guard requested else { return }
            model.settingsRequested = false
            openSettings()
        }
        #endif
        .capturableSheet(isPresented: $model.showGroupManager) {
            GroupManagerSheet()
                .environment(model)
        }
        #if os(macOS)
        // the draft is stored once the sheet is really gone, not when another
        // sheet opens on top of it
        .capturableSheet(isPresented: $model.showTagManager, onDismiss: { model.applyTagDraft() }) {
            TagManagerView()
                .environment(model)
        }
        #endif
        .capturableSheet(isPresented: $model.showRuleEditor) {
            RuleEditorView(initialDraft: model.ruleDraft)
                .environment(model)
        }
        .capturableSheet(isPresented: $model.showCommandPalette, onDismiss: {
            // Follow-up sheet/popover chosen in the palette: opened once the
            // palette is really gone, instead of after a guessed delay.
            let next = model.afterPaletteDismiss
            model.afterPaletteDismiss = nil
            next?()
        }) {
            CommandPaletteView()
                .environment(model)
        }
        .capturableSheet(item: $model.accountSelectionConnection) { c in
            AccountSelectionSheet(connection: c)
                .environment(model)
        }
        .capturableSheet(isPresented: $model.showAddBank) {
            AddBankSheet()
                .environment(model)
        }
        .capturableSheet(isPresented: $model.showMoneyMoneyImport) {
            MoneyMoneyImportSheet()
                .environment(model)
        }
        .capturableSheet(isPresented: $model.showRecurringSheet) {
            RecurringSheet()
                .environment(model)
        }
        .capturableSheet(item: $model.customRecurringBooking) { b in
            CustomDatesSheet(initialDates: model.recurringSeries(for: b).flatMap { $0.interval == .custom ? $0.customDates : nil } ?? []) { dates in
                model.markRecurring(b, .custom, customDates: dates)
            }
            .environment(model)
        }
        .capturableSheet(isPresented: $model.showCategorizer) {
            CategorizerSheet()
                .environment(model)
        }
        .capturableSheet(isPresented: $model.showBatchSheet) {
            BatchTransferSheet()
                .environment(model)
                .interactiveDismissDisabled(model.transferBusy)
        }
        .capturableSheet(isPresented: $model.showStandingSheet) {
            StandingOrderSheet()
                .environment(model)
                .interactiveDismissDisabled(model.transferBusy)
        }
        .alert("Status des Dauerauftrags unklar", isPresented: Binding(get: { model.standingUnknown != nil }, set: { if !$0 { model.standingUnknown = nil } })) {
            Button("Verstanden", role: .cancel) { model.standingUnknown = nil }
        } message: {
            Text("Der Auftrag hat die Bank erreicht, aber die Antwort ist nicht eindeutig. Bitte zuerst im Online-Banking prüfen, ob der Dauerauftrag angelegt, geändert oder gelöscht wurde, bevor Sie es erneut versuchen.\n\nBank: \(model.standingUnknown ?? "")")
        }
        .capturableSheet(isPresented: $model.showTransferSheet) {
            TransferSheetView()
                .environment(model)
                .interactiveDismissDisabled(model.transferBusy)
        }
        .capturableSheet(isPresented: Binding(get: { model.splitBooking != nil }, set: { if !$0 { model.splitBooking = nil } })) {
            if let b = model.splitBooking { SplitSheet(booking: b).environment(model) }
        }
        .capturableSheet(item: $model.payeeCheck) { _ in
            PayeeCheckSheet()
                .environment(model)
                .interactiveDismissDisabled()
        }
        .capturableSheet(item: $model.activeChallenge) { _ in
            TwoFactorSheet()
                .environment(model)
                .interactiveDismissDisabled()
        }
        .capturableSheet(item: $model.webLoginConnection) { c in
            Group {
                if c.connector == .tradeRepublic { WebLoginSheet(connection: c) }
                else if c.connector == .amazonOrders { AmazonWebSheet(connection: c) }
                else if c.connector == .fnz { FnzWebSheet(connection: c) }
                else if c.connector == .equatePlus { EquatePlusWebSheet(connection: c) }
                else if c.connector == .quirion { QuirionWebSheet(connection: c) }
                else if c.connector == .schwaebischHall { SchwaebischHallWebSheet(connection: c) }
                else { PortalWebSheet(connection: c) }
            }
            .environment(model)
        }
        .capturableSheet(item: $model.setupRequest) { req in
            BankSetupSheet(request: req)
                .environment(model)
        }
        .capturableSheet(item: $model.pendingLogin) { login in
            PinSheet(connection: login.connection)
                .environment(model)
        }
        #if os(iOS)
        .capturableSheet(isPresented: $model.showSettings) {
            NavigationStack { SettingsView() }
                .environment(model)
        }
        #endif
        .alert("Status der Überweisung unklar", isPresented: Binding(get: { model.transferUnknown != nil }, set: { if !$0 { model.transferUnknown = nil } })) {
            Button("Verstanden", role: .cancel) { model.transferUnknown = nil }
        } message: {
            if let u = model.transferUnknown {
                Text(String(format: String(localized: "Der Auftrag hat die Bank erreicht, aber die Antwort ist nicht eindeutig. Die Überweisung wurde möglicherweise bereits ausgeführt.\n\nBitte prüfen Sie zuerst Ihr Konto (Umsätze oder Online-Banking), bevor Sie sie erneut senden. In GiroCrab ist sie als „Status unklar“ vorgemerkt.\n\nReferenz (EndToEnd-ID): %@\nBank: %@"), u.endToEndId, u.reason))
            }
        }
        .alert("Stornierung nicht bestätigt", isPresented: Binding(get: { model.transferCancelNotice != nil }, set: { if !$0 { model.transferCancelNotice = nil } })) {
            Button("Status erneut prüfen") { model.recheckTransferCancel() }
            Button("Schließen", role: .cancel) { model.transferCancelNotice = nil }
        } message: {
            Text(model.transferCancelNotice?.message ?? "")
        }
        .alert(model.errorTitle ?? String(localized: "Etwas ist schiefgelaufen"),
               isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            if let retry = model.errorRetry {
                Button("Erneut versuchen") { model.errorMessage = nil; retry() }
            }
            ForEach(Array(model.errorAlternatives.enumerated()), id: \.offset) { _, alt in
                Button(alt.title) { model.errorMessage = nil; alt.action() }
            }
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // After the upgrade: GiroCrab's own FinTS registration or keep the user's (asked once).
        .alert("Welche FinTS-Registrierung soll GiroCrab verwenden?",
               isPresented: Binding(get: { model.offerProductIDChoice }, set: { _ in })) {
            Button("GiroCrab-Registrierung verwenden (empfohlen)") { model.setFintsProductIDMode("builtin") }
                .keyboardShortcut(.defaultAction)
            Button("Meine eigene behalten") { model.setFintsProductIDMode("own") }
        } message: {
            Text("GiroCrab hat jetzt eine eigene FinTS-Produktregistrierung. Sie müssen dafür nichts mehr tun. Ihre eigene Registrierung bleibt gespeichert, und Sie können jederzeit in den Einstellungen wechseln.")
        }
        // own host view: the "don't show again" toggle must not reach other dialogs
        .background {
            Color.clear
                .alert("Enable-Banking-Anwendung synchronisiert",
                       isPresented: Binding(get: { model.enableBankingAdoptNotice != nil },
                                            set: { if !$0 { model.enableBankingAdoptNotice = nil } }),
                       presenting: model.enableBankingAdoptNotice) { _ in
                    Button("OK") {}
                } message: { notice in
                    Text(notice.message)
                }
                .dialogSuppressionToggle(isSuppressed: $enableBankingNoticeSuppressed)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                    .padding(.bottom, 22)
                    .transition(Motion.slide(.bottom))
                    // id: a changed or extended notice gets its full time again
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        // replaced meanwhile: the new notice's own task takes over
                        guard !Task.isCancelled else { return }
                        withAnimation { model.toast = nil }
                    }
            }
        }
        .animation(Motion.animation(.spring(duration: 0.3)), value: model.toast)
    }
}

/// Full-window background of the Mac start and lock screen: soft light surface (#F8FAFC to #EEF2F6)
/// in Light Mode, deep slate navy (#0B1120 to #162033) in Dark Mode.
struct MacLaunchBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(hex: 0x0B1120), Color(hex: 0x162033)]
                : [Color(hex: 0xF8FAFC), Color(hex: 0xEEF2F6)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

/// Hero icon for start and lock screen in a Mac window: the cut-out crab (no app-icon squircle),
/// 270 pt wide, with a soft contact shadow; in Dark Mode with a subtle ambient glow.
struct MacHeroIcon: View {
    var phase: AnimatedCrabLogoView.Phase
    var size: CGFloat = 270
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            if dark {
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(hex: 0x3B4C6B, opacity: 0.45), Color(hex: 0x3B4C6B, opacity: 0)],
                        center: .center, startRadius: size * 0.1, endRadius: size * 0.95))
                    .frame(width: size * 2, height: size * 2)
                    .allowsHitTesting(false)
            }
            AnimatedCrabLogoView(size: size, phase: phase, showBackgroundSquircle: false)
                .shadow(color: .black.opacity(dark ? 0.45 : 0.20), radius: size * 0.074, x: 0, y: size * 0.063)
                .shadow(color: .black.opacity(dark ? 0.30 : 0.10), radius: size * 0.016, x: 0, y: size * 0.011)
        }
        .frame(width: size * 1.3, height: size * 1.3)
    }
}

#if os(macOS)
import AppKit

/// Bearbeiten › Suchen … (⌘F): puts the cursor into the window's toolbar search
/// field (`.searchable(placement: .toolbar)`; `searchFocused` needs macOS 15).
enum ToolbarSearch {
    @MainActor
    static func focus() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.toolbar != nil }
        guard let window, let item = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first else {
            FileHandle.standardError.write("ToolbarSearch: no search field\n".data(using: .utf8)!)
            return
        }
        window.makeFirstResponder(item.searchField)
    }
}
#endif
