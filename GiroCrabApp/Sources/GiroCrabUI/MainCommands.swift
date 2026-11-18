import SwiftUI
import GiroCrabCore

#if os(macOS)
// Menu bar commands of the main window, one `Commands` type per menu area.
//
// They are separate types instead of a `.commands { … }` closure in `GiroCrabScenes.body`
// because that closure runs as part of the scene's body: every model property it read
// (`selectedBooking`, `presentation`, `canTransfer`, …) made the scene body depend on it, so each
// selection change re-ran the scene, re-created the window's root view and, through the
// `@AppStorage` wrappers on the way down, re-rendered and re-laid out every column of the window.
// A `Commands` type tracks what its own `body` reads, so a change updates only its menu.

/// Ablage (new, import/export, print) and the Konten menu.
struct FileCommands: Commands {
    let model: AppModel

    var body: some Commands {
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
                .keyboardShortcut("e", modifiers: [.command, .shift])
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
    }
}

/// The Buchung menu: follows the selected booking.
struct BookingCommands: Commands {
    let model: AppModel

    var body: some Commands {
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
            // the booking's own count: a vault query here ran on every selection change
            .disabled((model.selectedBooking?.documentCount ?? 0) == 0)
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
    }
}

/// App menu additions, Hilfe and Bearbeiten › Suchen.
struct AppCommands: Commands {
    let model: AppModel
    let openWindow: OpenWindowAction

    var body: some Commands {
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
    }
}

/// Darstellung: panes, list and chart options, text size, account view.
struct ViewCommands: Commands {
    let model: AppModel
    @AppStorage(ViewLayout.inspectorKey) private var showInspector = true
    @AppStorage(ViewLayout.statisticsKey) private var showStatistics = true
    @AppStorage(ViewLayout.budgetsKey) private var showBudgets = true
    @AppStorage(ViewLayout.runningBalanceKey) private var showRunningBalance = false
    @AppStorage(ViewLayout.lastFetchKey) private var showLastFetch = false
    @AppStorage(ViewLayout.compactHeaderKey) private var compactHeader = false
    @AppStorage(BalanceChartStyle.defaultsKey) private var chartStyle: BalanceChartStyle = .line
    @AppStorage(ViewLayout.headerChartCollapsedKey) private var chartCollapsed = false
    @AppStorage(AppTextSize.defaultsKey) private var textSize: AppTextSize = .standard
    @AppStorage(PrivacyMode.enabledKey) private var privacyMode = false

    var body: some Commands {
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
            Toggle("Letzten Abruf anzeigen", isOn: $showLastFetch)
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
}
#endif
