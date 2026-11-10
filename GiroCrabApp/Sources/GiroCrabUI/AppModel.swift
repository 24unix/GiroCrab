import Foundation
import SwiftUI
import Observation
import UniformTypeIdentifiers
import GiroCrabCore

enum SidebarItem: Hashable {
    case allAccounts
    case group(Int64)
    case account(Int64)
    case category(Int64)
    case uncategorized
    /// "Belege & PostBox"
    case documents
}

enum Period: String, CaseIterable, Identifiable {
    case all = "Gesamter Zeitraum"
    case thisMonth = "Dieser Monat"
    case lastMonth = "Letzter Monat"
    case last3Months = "Letzte 3 Monate"
    case thisQuarter = "Dieses Quartal"
    case thisYear = "Dieses Jahr"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "Gesamter Zeitraum")
        case .thisMonth: return String(localized: "Dieser Monat")
        case .lastMonth: return String(localized: "Letzter Monat")
        case .last3Months: return String(localized: "Letzte 3 Monate")
        case .thisQuarter: return String(localized: "Dieses Quartal")
        case .thisYear: return String(localized: "Dieses Jahr")
        }
    }

    var range: (String?, String?) {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        switch self {
        case .all: return (nil, nil)
        case .thisMonth: return (DateText.iso(startOfMonth), nil)
        case .lastMonth:
            let start = cal.date(byAdding: .month, value: -1, to: startOfMonth)!
            let end = cal.date(byAdding: .day, value: -1, to: startOfMonth)!
            return (DateText.iso(start), DateText.iso(end))
        case .last3Months: return (DateText.iso(cal.date(byAdding: .month, value: -2, to: startOfMonth)!), nil)
        case .thisQuarter:
            let c = cal.dateComponents([.year, .month], from: now)
            let qStart = cal.date(from: DateComponents(year: c.year, month: ((c.month ?? 1) - 1) / 3 * 3 + 1, day: 1))!
            return (DateText.iso(qStart), nil)
        case .thisYear: return (DateText.iso(cal.date(from: cal.dateComponents([.year], from: now))!), nil)
        }
    }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "Alle"
    case new = "Neu"
    case checked = "Geprüft"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "Alle")
        case .new: return String(localized: "Neu")
        case .checked: return String(localized: "Geprüft")
        }
    }
}

extension BookingScope {
    var title: String {
        switch self {
        case .all: return String(localized: "Alle Buchungen")
        case .everyday: return String(localized: "Alltag & Konsum")
        case .investments: return String(localized: "Sparpläne & Perks")
        }
    }
    static let ordered: [BookingScope] = [.all, .everyday, .investments]
}

struct DayJump: Equatable {
    let day: String
    let token = UUID()
}

struct DayGroup: Identifiable {
    let date: String
    let bookings: [Booking]
    var id: String { date }
    var sum: Int64 { bookings.reduce(0) { $0 + $1.amountCents } }
}

struct ActiveChallenge: Identifiable {
    let id = UUID()
    let connection: BankConnection
    var challenge: Challenge
    var waiting: Bool
    var busy: Bool = false
    var error: String?
}

/// Missing FinTS product ID / API keys for a bank: shown as a setup form.
struct SetupRequest: Identifiable {
    let id = UUID()
    let connection: BankConnection
    let keys: [String]
}

/// Form state of "Neue Überweisung" (kept while the TAN sheet is shown).
/// CSV handed to `.fileExporter`.
struct CSVFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct TransferDraft {
    var accountID: Int64?
    var name = ""
    var iban = ""
    var bic = ""
    var amountText = ""
    var purpose = ""
    var pin = ""
    /// SEPA Instant ("Echtzeitüberweisung", FinTS only).
    var instant = false
    /// Terminüberweisung: when on, `executionDate` is sent (FinTS only).
    var scheduled = false
    var executionDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()

    /// `YYYY-MM-DD` for the core, or nil when not scheduled.
    var executionDateISO: String? {
        guard scheduled && !instant else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: executionDate)
    }
}

struct PendingLogin: Identifiable {
    let id = UUID()
    let connection: BankConnection
}

struct CategoryNode: Identifiable, Hashable {
    let category: GiroCrabCore.Category
    var children: [CategoryNode]?
    var id: Int64 { category.id }
}

@MainActor
@Observable
public final class AppModel {
    enum VaultState: Equatable {
        case locked
        case unlocking
        case open
        case failed(String)
    }

    let options: LaunchOptions
    private(set) var vault: Vault?
    var vaultState: VaultState = .locked

    // Data
    var groups: [AccountGroup] = []
    var categories: [GiroCrabCore.Category] = []
    var categoryTree: [CategoryNode] = []
    var bookings: [Booking] = []
    var page: BookingPage?
    /// Flows of the selected account/group in the selected period; nil = not loaded yet.
    var selectionFlow: (consumption: Int64, invested: Int64, income: Int64)?
    var dashboard: InvestmentDashboard?
    var merchantStats: MerchantStats?
    var rules: [Rule] = []
    var history: [DailyBalance] = []
    var connections: [BankConnection] = []
    var settings: [SettingEntry] = []
    var onlineLogos = false
    private var logoCache: [String: (image: Image, pixels: Int)] = [:]

    // UI state
    var sidebarSelection: SidebarItem? = .allAccounts { didSet { listLimit = Self.defaultListLimit; reloadBookings(); reloadHistory() } }
    var scope: BookingScope = .all { didSet { listLimit = Self.defaultListLimit; reloadBookings() } }
    var period: Period = .all { didSet { listLimit = Self.defaultListLimit; reloadCategories(); reloadBookings(); reloadHistory() } }
    var statusFilter: StatusFilter = .all
    var searchText: String = "" { didSet { scheduleSearch() } }
    var selectedBookingID: Booking.ID? { didSet { reloadMerchantStats() } }
    var collapsedGroups: Set<Int64> = []
    var expandedCategories: Set<Int64> = []
    var showRuleEditor = false
    var ruleDraft: Rule?
    var showSettings = false
    var showCommandPalette = false
    var showCategorizer = false
    var showMoneyMoneyImport = false
    /// (demo, `--demo-sheet moneymoney`) canned preview so the sheet can be shown without a file.
    var demoImportPreview: MoneyMoneyImportPreview?
    /// (demo, `--demo-sheet moneymoney-db`) canned database preview with invented data.
    var demoDbPreview: MoneyMoneyDbPreview?
    var pendingLogin: PendingLogin?
    var setupRequest: SetupRequest?
    /// Trade Republic in-app browser login (WKWebView).
    var webLoginConnection: BankConnection?
    /// Showing the throw-away demo vault (also when the own vault is still empty).
    var demoActive = false
    /// The personal vault while demo data is shown (nil if never unlocked).
    private(set) var ownVault: Vault?
    var activeChallenge: ActiveChallenge?
    var syncingConnectionID: Int64?
    var toast: String?
    var errorMessage: String?

    private var activeSession: SyncSession?
    private var activeTransfer: TransferSession?
    var showTransferSheet = false
    var csvExport = CSVFileDocument(data: Data())
    var showCSVExporter = false
    var transferDraft = TransferDraft()
    var transferError: String?
    var splitBooking: Booking?
    var transferBusy = false
    private var syncQueue: [BankConnection] = []
    private var pollTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    public init(options: LaunchOptions = .current) {
        self.options = options
        // Core texts follow the language the app bundle actually resolved, so
        // UI and core never disagree (German without an .app bundle).
        GiroCrabCore.setLanguage(code: Bundle.main.preferredLocalizations.first ?? "de")
        if options.freshVault {
            openFreshVault()
            return
        }
        if options.demoSeed {
            openDemoVault()
            switch options.initialView {
            case "alltag": scope = .everyday
            case "sparplaene", "sparpläne", "investments": scope = .investments
            default: break
            }
            if let q = options.selectAccount, let a = allAccounts.first(where: { $0.name.lowercased().contains(q) }) {
                sidebarSelection = .account(a.id)
                selectedBookingID = bookings.first?.id
            }
            reloadBookings()
            if let q = options.pickBooking, let b = bookings.first(where: { $0.merchantName.lowercased().contains(q) || $0.counterparty.lowercased().contains(q) }) {
                selectedBookingID = b.id
            }
            if let sheet = options.demoSheet {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    self?.presentDemoSheet(sheet)
                }
            }
            if options.demoSync {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    self?.requestSyncAll()
                }
            }
        }
    }

    /// Screenshot helper: open a sheet pre-filled with fictional data.
    private func presentDemoSheet(_ name: String) {
        switch name {
        case "transfer":
            if let a = transferAccounts.first { sidebarSelection = .account(a.id) }
            openTransfer()
            transferDraft.name = "Stadtwerke München"
            transferDraft.iban = TransferSheetView.groupedIBAN("DE89370400440532013000")
            transferDraft.amountText = Money.plain(8500)
            transferDraft.purpose = "Abschlag Strom Kd-Nr 482910"
        case "moneymoney":
            demoImportPreview = MoneyMoneyImportPreview(
                totalRows: 4820, newBookings: 4820, duplicatesSkippedOrEnriched: 0, notesCount: 312,
                dateRangeStart: "2012-01-03", dateRangeEnd: "2026-10-30",
                detectedCategories: ["Haushalt > Lebensmittel", "Gehalt", "Steuern", "Wohnen > Miete", "Mobilität > Tanken", "Freizeit > Restaurants", "Versicherungen", "Reisen"],
                sampleBookings: [], suggestedAccountName: "MoneyMoney-Archiv")
            showMoneyMoneyImport = true
        case "moneymoney-db":
            #if os(macOS)
            demoDbPreview = Self.demoMoneyMoneyDbPreview(existingGiro: allAccounts.first { $0.kind == .checking })
            #endif
            showMoneyMoneyImport = true
        default: break
        }
    }

    /// Opens the MoneyMoney import. An import belongs in the own vault, so the
    /// demo data an empty vault starts with is left first.
    func openMoneyMoneyImport() {
        if isDemo && !options.demoSeed { showOwnVault() }
        showMoneyMoneyImport = true
    }

    var isDemo: Bool { demoActive }
    var hasOwnVault: Bool { ownVault != nil }

    // MARK: - Vault lifecycle

    private func openDemoVault() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GiroCrab-Demo.girocrab")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        // Throw-away demo key (the demo vault holds only fictitious data).
        let key = Data((0..<32).map { UInt8(($0 * 7 + 3) & 0xFF) })
        do {
            let v = try Vault.open(path: url.path, key: key)
            _ = try v.seedDemoData()
            vault = v
            demoActive = true
            vaultState = .open
            selectedBookingID = nil
            sidebarSelection = .allAccounts
            reloadAll()
            selectedBookingID = (bookings.first(where: { $0.flow == .consumption && $0.documentCount > 0 }) ?? bookings.first(where: { $0.flow == .consumption }))?.id
        } catch {
            vaultState = .failed(describe(error))
        }
    }

    /// Developer switch --fresh-vault: empty personal vault without Keychain.
    private func openFreshVault() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GiroCrab-Fresh.girocrab")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        do {
            let v = try Vault.open(path: url.path, key: Data(repeating: 0x5A, count: 32))
            _ = try v.seedStarterCategories()
            ownVault = v
            useVault(v, demo: false)
            if let bank = options.tryAddBank,
               let kind = bankCatalog().first(where: { $0.name.lowercased().contains(bank) })?.kind {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self?.addConnection(kind, login: "kunde-4711")
                }
            }
        } catch {
            vaultState = .failed(describe(error))
        }
    }

    /// Structural trace (no secrets) shared with the core's depot debug log.
    static func debugLog(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/girocrab-depot-debug.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static var vaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GiroCrab", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("tresor.girocrab")
    }

    func unlock() {
        guard vaultState != .unlocking else { return }
        vaultState = .unlocking
        Task {
            do {
                var key = try await VaultKeyManager.shared.unlock()
                defer { key.resetBytes(in: 0..<key.count) }
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: Self.vaultURL.path)[.size] as? Int) ?? -1
                Self.debugLog("unlock: vault=\(Self.vaultURL.lastPathComponent) size=\(fileSize) key_created_new=\(VaultKeyManager.shared.lastUnlockCreatedKey)")
                let v = try Vault.open(path: Self.vaultURL.path, key: key)
                _ = try v.seedStarterCategories()
                self.ownVault = v
                if try v.accountCount() == 0 && self.connectionsExist(v) == false {
                    // Nothing synced yet: show demo bookings so the UI can be judged.
                    self.openDemoVault()
                    self.toast = String(localized: "Ihr Tresor ist noch leer – Sie sehen Demo-Daten")
                } else {
                    self.useVault(v, demo: false)
                }
                // Auto-sync with the key already unlocked (no second biometric prompt).
                if CloudSyncManager.shared.isEnabled {
                        await self.performSyncOrAutoAdopt(vault: v, key: key)
                    }
            } catch {
                self.vaultState = .failed(describe(error))
            }
        }
    }

    /// Merge with the iCloud copy and write the result back (asks for biometrics to get the key).
    func syncNow() {
        guard let v = ownVault else { return }
        Task {
            do {
                var key = try await VaultKeyManager.shared.unlock()
                defer { key.resetBytes(in: 0..<key.count) }
                await self.performSyncOrAutoAdopt(vault: v, key: key)
            } catch {
                self.toast = describe(error)
            }
        }
    }

    /// Secondary device: the user pasted the vault key of the iCloud snapshot.
    /// Merges the snapshot with it, then switches this device's vault and
    /// keychain to that key so both devices share one key from now on.
    func adoptSyncKey(_ text: String) {
        guard let v = ownVault else { return }
        Task {
            do {
                let pasted = try VaultKeyManager.parseKey(text)
                let current = try await VaultKeyManager.shared.unlock()
                let cloud = CloudSyncManager.shared
                await cloud.sync(vault: v, localPath: Self.vaultURL.path, key: current, remoteKey: pasted, mergeOnly: true)
                guard cloud.lastError == nil else { self.toast = cloud.lastError; return }
                if pasted != current {
                    try v.rekey(newKey: pasted)
                    do {
                        try VaultKeyManager.shared.importKey(pasted)
                    } catch {
                        try? v.rekey(newKey: current)   // keep vault and keychain consistent
                        throw error
                    }
                }
                await cloud.sync(vault: v, localPath: Self.vaultURL.path, key: pasted)
                self.reloadAll()
                self.toast = String(localized: "Tresor-Schlüssel übernommen – iCloud Sync aktiv")
            } catch {
                self.toast = describe(error)
            }
        }
    }

    private func performSyncOrAutoAdopt(vault v: Vault, key: Data) async {
        await CloudSyncManager.shared.sync(vault: v, localPath: Self.vaultURL.path, key: key)
        if ((try? v.accountCount()) ?? 0) > 0 || self.connectionsExist(v) {
            if self.demoActive {
                self.useVault(v, demo: false)
            } else {
                self.reloadAll()
            }
        } else {
            self.reloadAll()
        }
    }

    private func connectionsExist(_ v: Vault) -> Bool {
        ((try? v.listBankConnections()) ?? []).isEmpty == false
    }

    private func useVault(_ v: Vault, demo: Bool) {
        vault = v
        demoActive = demo
        vaultState = .open
        selectedBookingID = nil
        sidebarSelection = .allAccounts
        logoCache = [:]
        reloadAll()
        selectedBookingID = bookings.first?.id
    }

    /// Switch to the demo data (own vault stays unlocked in the background).
    func showDemo() {
        guard !demoActive else { return }
        openDemoVault()
    }

    /// Switch back to the personal vault (unlocks it first if needed).
    func showOwnVault() {
        if let ov = ownVault {
            useVault(ov, demo: false)
        } else {
            vaultState = .locked
            unlock()
        }
    }

    func lock() {
        guard ownVault != nil else { return }
        ownVault = nil
        demoActive = false
        vault = nil
        groups = []; bookings = []; categories = []; categoryTree = []; rules = []; connections = []; settings = []
        page = nil; dashboard = nil; merchantStats = nil; logoCache = [:]
        vaultState = .locked
    }

    // MARK: - Loading

    func reloadAll() {
        reloadAccounts()
        reloadHistory()
        reloadCategories()
        reloadBookings()
        reloadRules()
        reloadSettings()
        reloadDashboard()
    }

    func reloadAccounts() {
        guard let vault else { return }
        run {
            groups = try vault.listAccountGroups()
            connections = try vault.listBankConnections()
        }
    }

    func reloadCategories() {
        guard let vault else { return }
        let (from, to) = period.range
        run {
            categories = try vault.listCategories(dateFrom: from, dateTo: to)
            categoryTree = Self.buildTree(categories)
        }
    }

    func reloadDashboard() {
        guard let vault else { return }
        run { dashboard = try vault.investmentDashboard(months: 6) }
    }

    func reloadMerchantStats() {
        guard let vault, let b = selectedBooking else { merchantStats = nil; return }
        merchantStats = try? vault.merchantStats(merchantKey: b.merchant.key)
    }

    static func buildTree(_ flat: [GiroCrabCore.Category]) -> [CategoryNode] {
        func children(of parent: Int64?) -> [CategoryNode] {
            flat.filter { $0.parentId == parent }.map { c in
                let kids = children(of: c.id)
                return CategoryNode(category: c, children: kids.isEmpty ? nil : kids)
            }
        }
        return children(of: nil)
    }

    /// The stream loads the newest bookings only; a click on an older day in
    /// the balance chart raises the limit until that day is loaded.
    static let defaultListLimit: UInt32 = 3000
    var listLimit: UInt32 = AppModel.defaultListLimit

    var currentFilter: BookingFilter {
        let (from, to) = period.range
        var accountIDs: [Int64] = []
        var category: Int64?
        var uncategorized = false
        switch sidebarSelection {
        case .account(let id): accountIDs = [id]
        case .group(let gid): accountIDs = groups.first(where: { $0.id == gid })?.accounts.map(\.id) ?? []
        case .category(let id): category = id
        case .uncategorized: uncategorized = true
        case .allAccounts, .documents, .none: break
        }
        return BookingFilter(
            accountIds: accountIDs,
            categoryId: category,
            includeSubcategories: true,
            uncategorizedOnly: uncategorized,
            search: searchText.isEmpty ? nil : searchText,
            dateFrom: from,
            dateTo: to,
            limit: listLimit,
            offset: 0,
            scope: scope,
            merchantKey: nil
        )
    }

    /// Exports every booking matching the current list filter as Excel-friendly CSV.
    func exportFilteredBookingsCSV() {
        guard let vault else { return }
        do {
            let csv = try vault.exportBookingsCsv(filter: currentFilter)
            csvExport = CSVFileDocument(data: Data(csv.utf8))
            showCSVExporter = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadBookings() {
        guard let vault else { return }
        run {
            let p = try vault.listTransactions(filter: currentFilter)
            page = p
            bookings = p.transactions
        }
        if let sel = selectedBookingID, !bookings.contains(where: { $0.id == sel }) {
            selectedBookingID = bookings.first?.id
        }
        reloadSelectionKPIs()
    }

    /// KPI tiles: same flow rules as the dashboard, but for the selected
    /// period and account/group (no account selected = all accounts).
    func reloadSelectionKPIs() {
        guard let vault else { selectionFlow = nil; return }
        let (from, to) = period.range
        let filter = BookingFilter(
            accountIds: currentFilter.accountIds, categoryId: nil, includeSubcategories: true, uncategorizedOnly: false,
            search: nil, dateFrom: from, dateTo: to, limit: 0, offset: 0,
            scope: .all, merchantKey: nil
        )
        run {
            let p = try vault.listTransactions(filter: filter)
            var consumption: Int64 = 0, invested: Int64 = 0, income: Int64 = 0
            for b in p.transactions {
                switch b.flow {
                case .consumption: consumption += -b.amountCents
                case .investment: invested += -b.amountCents
                case .perk where b.amountCents < 0: invested += -b.amountCents
                case .income: income += b.amountCents
                default: break
                }
            }
            selectionFlow = (consumption, invested, income)
        }
    }

    func reloadHistory() {
        guard let vault else { return }
        var ids: [Int64]
        switch sidebarSelection {
        case .account(let id): ids = [id]
        case .group(let gid): ids = groups.first(where: { $0.id == gid })?.accounts.map(\.id) ?? []
        default: ids = liquidAccounts.map(\.id)
        }
        if ids.isEmpty { ids = [-1] }
        // The chart follows the selected period. "Gesamter Zeitraum": up to ~15 years back,
        // then the flat lead-in before the first booking is cut off.
        let (from, to) = period.range
        let today = Calendar.current.startOfDay(for: Date())
        let start = from.flatMap(DateText.date) ?? Calendar.current.date(byAdding: .year, value: -15, to: today)!
        let days = max(2, (Calendar.current.dateComponents([.day], from: start, to: today).day ?? 120) + 1)
        run {
            var points = try vault.balanceHistory(accountIds: ids, days: UInt32(days))
            if let to { points = points.filter { $0.date <= to } }
            if from == nil,
               let firstChange = points.indices.dropFirst().first(where: { points[$0].balanceCents != points[$0 - 1].balanceCents }) {
                // keep one point before the first change
                points = Array(points[(firstChange - 1)...])
            }
            history = points
        }
    }

    func reloadRules() {
        guard let vault else { return }
        run { rules = try vault.listRules() }
    }

    func reloadSettings() {
        guard let vault else { return }
        run {
            settings = try vault.listSettings()
            onlineLogos = try vault.onlineLogosEnabled()
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.reloadBookings()
        }
    }

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { errorMessage = describe(error) }
    }

    // MARK: - Logos (Tier 2)

    /// Bumped whenever a domain override changes -> signets refetch.
    var logoVersion = 0
    private var logoInflight: [String: Task<(image: Image, pixels: Int)?, Never>] = [:]

    /// Dual-source pipeline, stage 2: cached PNG/ICO from the vault or the
    /// Google S2 / DuckDuckGo favicon for the first candidate domain that
    /// yields a real logo (default globe rejected in Rust). Requests for the
    /// same merchant are shared; results pop into every row automatically.
    func logo(for merchant: MerchantInfo) async -> (image: Image, pixels: Int)? {
        var candidates = merchant.domainCandidates
        if candidates.isEmpty && !merchant.domain.isEmpty { candidates = [merchant.domain] }
        guard !candidates.isEmpty, let vault else { return nil }
        let key = candidates.joined(separator: "|")
        if let hit = logoCache[key] { return hit }
        if let running = logoInflight[key] { return await running.value }
        let online = onlineLogos
        let task = Task<(image: Image, pixels: Int)?, Never> { @MainActor in
            var data: Data?
            for d in candidates {
                if let cached = try? vault.getMerchantLogoPng(domain: d) { data = cached; break }
            }
            if data == nil, online {
                data = (try? await vault.fetchMerchantLogo(candidates: candidates))??.bytes
            }
            guard let data, let img = AppModel.image(from: data) else { return nil }
            return (image: img, pixels: AppModel.pixelWidth(of: data))
        }
        logoInflight[key] = task
        let result = await task.value
        logoInflight[key] = nil
        if let result { logoCache[key] = result }
        return result
    }

    /// Kept for callers that only know a domain.
    func logo(for domain: String) async -> (image: Image, pixels: Int)? {
        guard !domain.isEmpty, let vault else { return nil }
        if let hit = logoCache[domain] { return hit }
        var data = try? vault.getMerchantLogoPng(domain: domain)
        if data == nil, onlineLogos { data = try? await vault.fetchLogo(domain: domain) }
        guard let data, let img = Self.image(from: data) else { return nil }
        let entry = (image: img, pixels: Self.pixelWidth(of: data))
        logoCache[domain] = entry
        return entry
    }

    /// Sets / clears the original loan amount ("Ursprünglicher Kreditbetrag").
    func setAccountInitialBalance(_ accountId: Int64, cents: Int64?) {
        guard let vault else { return }
        run { try vault.setAccountInitialBalance(accountId: accountId, cents: cents) }
        reloadAccounts()
    }

    /// Manual domain from the inspector; nil/empty removes the override.
    func setMerchantDomain(_ merchant: MerchantInfo, _ domain: String?) {
        guard let vault else { return }
        run {
            let stored = try vault.setMerchantDomain(merchantKey: merchant.key, domain: domain)
            toast = stored.map { String(localized: "Domain für \(merchant.name): \($0) – Logo wird geladen") } ?? String(localized: "Domain-Zuordnung entfernt")
        }
        logoCache = [:]
        logoVersion += 1
        reloadBookings()
        reloadMerchantStats()
    }

    static func pixelWidth(of data: Data) -> Int {
        #if os(macOS)
        return NSImage(data: data)?.representations.map(\.pixelsWide).max() ?? 0
        #else
        return UIImage(data: data).map { Int($0.size.width * $0.scale) } ?? 0
        #endif
    }

    static func image(from data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }

    func clearLogoCache() {
        guard let vault else { return }
        run { _ = try vault.clearLogoCache() }
        logoCache = [:]
        toast = String(localized: "Logo-Cache geleert")
    }

    // MARK: - Derived

    var visibleBookings: [Booking] {
        bookings.filter { b in
            switch statusFilter {
            case .all: return true
            case .new: return !b.checked
            case .checked: return b.checked
            }
        }
    }

    /// Day card the stream should scroll to (set by a click in the balance chart);
    /// a fresh token per click, so clicking the same day again scrolls again.
    var scrollToDay: DayJump?

    /// Jump to `date` in the booking stream: that day, or the nearest earlier
    /// day with bookings (the balance of a quiet day comes from there).
    func jumpToDay(_ date: Date) {
        let day = DateText.iso(date)
        if let vault, let oldest = dayGroups.last?.date, day < oldest,
           let total = page?.totalCount, UInt32(bookings.count) < total {
            // count the bookings from that day on, then load them plus some older context
            var f = currentFilter
            if f.dateFrom.map({ $0 < day }) ?? true { f.dateFrom = day }
            f.limit = 1
            if let newer = try? vault.listTransactions(filter: f).totalCount {
                listLimit = max(listLimit, newer + 200)
                reloadBookings()
            }
        }
        let groups = dayGroups // newest first
        guard let target = groups.first(where: { $0.date <= day }) ?? groups.last else { return }
        scrollToDay = DayJump(day: target.date)
    }

    var dayGroups: [DayGroup] {
        var out: [DayGroup] = []
        var current: [Booking] = []
        var day = ""
        for b in visibleBookings {
            if b.bookingDate != day, !current.isEmpty {
                out.append(DayGroup(date: day, bookings: current))
                current = []
            }
            day = b.bookingDate
            current.append(b)
        }
        if !current.isEmpty { out.append(DayGroup(date: day, bookings: current)) }
        return out
    }

    var selectedBooking: Booking? {
        guard let id = selectedBookingID else { return nil }
        return bookings.first { $0.id == id }
    }

    var allAccounts: [Account] { groups.flatMap(\.accounts) }
    var liquidAccounts: [Account] { allAccounts.filter { [.checking, .savings, .paymentService, .creditCard, .cash].contains($0.kind) } }
    var liquidBalance: Int64 { liquidAccounts.reduce(0) { $0 + $1.balanceCents } }
    var newCount: Int { allAccounts.reduce(0) { $0 + Int($1.newCount) } }
    var uncategorizedCount: Int { allAccounts.filter { $0.kind != .loan }.reduce(0) { $0 + Int($1.uncategorizedCount) } }

    /// Everyday spending this month (never includes ETF plans / perks).
    /// Selected account/group and period; falls back to the dashboard month.
    var consumptionThisMonth: Int64 { selectionFlow?.consumption ?? dashboard?.monthly.last?.consumptionCents ?? 0 }
    var investedThisMonth: Int64 { selectionFlow?.invested ?? dashboard?.monthly.last?.investmentCents ?? 0 }
    var incomeThisMonth: Int64 { selectionFlow?.income ?? dashboard?.monthly.last?.incomeCents ?? 0 }

    /// Number of bookings matching the list filter (the list itself loads at most 3000).
    var bookingCountLabel: Int {
        statusFilter == .all ? Int(page?.totalCount ?? UInt32(visibleBookings.count)) : visibleBookings.count
    }

    var title: String {
        switch sidebarSelection {
        case .allAccounts, .none: return String(localized: "Übersicht")
        case .group(let id): return groups.first { $0.id == id }?.name ?? String(localized: "Gruppe")
        case .account(let id): return allAccounts.first { $0.id == id }?.name ?? String(localized: "Konto")
        case .category(let id): return categories.first { $0.id == id }?.path ?? String(localized: "Kategorie")
        case .uncategorized: return String(localized: "Ohne Kategorie")
        case .documents: return String(localized: "Belege & PostBox")
        }
    }

    var headerBalance: (label: String, cents: Int64)? {
        switch sidebarSelection {
        case .account(let id): return allAccounts.first { $0.id == id }.map { (String(localized: "Kontostand"), $0.balanceCents) }
        case .group(let id): return groups.first { $0.id == id }.map { (String(localized: "Summe"), $0.balanceCents) }
        case .allAccounts, .none: return (String(localized: "Verfügbar (Giro, Tagesgeld, Karten)"), liquidBalance)
        case .category(let id): return categories.first { $0.id == id }.map { (String(localized: "Summe im Zeitraum"), $0.totalCents) }
        case .uncategorized, .documents: return nil
        }
    }

    var lastSyncText: String {
        let latest = connections.compactMap(\.lastSyncUnix).max()
        guard let latest else { return String(localized: "Noch nie aktualisiert") }
        let f = RelativeDateTimeFormatter()
        f.locale = .autoupdatingCurrent
        f.unitsStyle = .full
        let relative = f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(latest)), relativeTo: Date())
        return String(localized: "Aktualisiert \(relative)")
    }

    func account(for id: Int64) -> Account? { allAccounts.first { $0.id == id } }

    // MARK: - Keyboard navigation

    func moveSelection(_ delta: Int) {
        let list = visibleBookings
        guard !list.isEmpty else { return }
        let idx = selectedBookingID.flatMap { id in list.firstIndex { $0.id == id } } ?? -1
        let next = max(0, min(list.count - 1, idx + delta))
        selectedBookingID = list[next].id
    }

    // MARK: - Editing

    func setCategory(_ categoryID: Int64?, for booking: Booking) {
        guard let vault else { return }
        run { try vault.setTransactionCategory(transactionId: booking.id, categoryId: categoryID) }
        reloadBookings(); reloadCategories(); reloadAccounts(); reloadRules(); reloadDashboard(); reloadMerchantStats()
    }

    func setChecked(_ checked: Bool, for booking: Booking) {
        guard let vault else { return }
        run { try vault.setTransactionChecked(transactionId: booking.id, checked: checked) }
        reloadBookings(); reloadAccounts()
    }

    func updateText(counterparty: String, purpose: String, for booking: Booking) {
        guard let vault else { return }
        run { try vault.updateTransactionText(transactionId: booking.id, counterparty: counterparty, purpose: purpose) }
        reloadBookings(); reloadMerchantStats()
    }

    func updateNote(_ note: String, for booking: Booking) {
        guard let vault else { return }
        run { try vault.updateTransactionNote(transactionId: booking.id, note: note) }
        reloadBookings()
    }

    func createCategory(name: String, parent: Int64?, symbol: String, color: String) {
        guard let vault else { return }
        run { _ = try vault.createCategory(name: name, parentId: parent, sfSymbol: symbol, colorHex: color) }
        reloadCategories()
    }

    func deleteCategory(_ id: Int64) {
        guard let vault else { return }
        run { try vault.deleteCategory(id: id) }
        if sidebarSelection == .category(id) { sidebarSelection = .allAccounts }
        reloadAll()
    }

    func newRuleDraft(from booking: Booking? = nil) -> Rule {
        Rule(
            id: 0,
            name: booking.map { "\($0.merchant.name)" } ?? String(localized: "Neue Regel"),
            categoryId: booking?.categoryId ?? categories.first(where: { $0.depth > 0 })?.id ?? categories.first?.id ?? 0,
            field: booking == nil ? .any : .counterparty,
            matchKind: .keyword,
            pattern: booking.map { $0.merchant.known ? $0.merchant.name : $0.counterparty.split(separator: " ").prefix(2).joined(separator: " ") } ?? "",
            caseSensitive: false,
            minAmountCents: nil,
            maxAmountCents: booking.map { $0.amountCents < 0 ? 0 : nil } ?? nil,
            accountId: nil,
            priority: Int32((rules.map(\.priority).max() ?? 0) + 10),
            enabled: true,
            matchCount: 0
        )
    }

    func openRuleEditor(from booking: Booking? = nil) {
        ruleDraft = booking.map { newRuleDraft(from: $0) }
        showRuleEditor = true
    }

    @discardableResult
    func saveRule(_ rule: Rule) -> Int64? {
        guard let vault else { return nil }
        do {
            let id = try vault.saveRule(rule: rule)
            _ = try vault.applyRules(onlyUncategorized: false)
            reloadAll()
            return id
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    func deleteRule(_ id: Int64) {
        guard let vault else { return }
        run { try vault.deleteRule(ruleId: id) }
        reloadAll()
    }

    func preview(_ rule: Rule) -> (matches: [Booking], error: String?) {
        guard let vault else { return ([], nil) }
        do { return (try vault.previewRule(rule: rule, limit: 200), nil) } catch { return ([], describe(error)) }
    }

    func applyAllRules() {
        guard let vault else { return }
        run {
            let n = try vault.applyRules(onlyUncategorized: false)
            toast = String(localized: "Regeln angewendet – \(n) Buchungen neu zugeordnet")
        }
        reloadAll()
    }

    func saveSetting(_ key: String, _ value: String) {
        guard let vault else { return }
        run { try vault.setSetting(key: key, value: value) }
        reloadSettings()
    }

    /// Adds a bank login. While demo data is shown, the login goes into the
    /// personal vault (switching to it), then setup / PIN entry starts.
    func addConnection(_ kind: ConnectorKind, login: String) {
        if demoActive, let ov = ownVault {
            useVault(ov, demo: false)
        }
        guard let vault else { return }
        var newID: Int64?
        run { newID = try vault.addBankConnection(connector: kind, displayName: "", loginName: login) }
        reloadAccounts()
        if let id = newID, let conn = connections.first(where: { $0.id == id }) {
            toast = String(localized: "\(conn.displayName) hinzugefügt")
            requestSync(conn)
        }
    }

    /// Adds a login at any FinTS 3.0 bank (BLZ + https URL), then starts setup / PIN entry.
    func addFinTsConnection(name: String, blz: String, url: String, login: String, tanMedium: String = "") {
        if demoActive, let ov = ownVault {
            useVault(ov, demo: false)
        }
        guard let vault else { return }
        var newID: Int64?
        run { newID = try vault.addFintsConnection(blz: blz, url: url, displayName: name, loginName: login, tanMedium: tanMedium) }
        reloadSettings()
        reloadAccounts()
        if let id = newID, let conn = connections.first(where: { $0.id == id }) {
            toast = String(localized: "\(conn.displayName) hinzugefügt")
            requestSync(conn)
        }
    }

    /// Adds a login at a bank reached via Enable Banking (PSD2), then starts the
    /// setup (Enable Banking credentials, if missing) and the consent redirect.
    func addEnableBankingConnection(aspsp: String, country: String, name: String, label: String) {
        if demoActive, let ov = ownVault {
            useVault(ov, demo: false)
        }
        guard let vault else { return }
        var newID: Int64?
        run { newID = try vault.addEnableBankingConnection(aspsp: aspsp, country: country, displayName: name, loginName: label) }
        reloadAccounts()
        if let id = newID, let conn = connections.first(where: { $0.id == id }) {
            toast = String(localized: "\(conn.displayName) hinzugefügt")
            requestSync(conn)
        }
    }

    /// All banks Enable Banking offers (`GET /aspsps`); empty until loaded or without credentials.
    var livePsd2Banks: [Psd2Bank] = []

    /// Loads the live ASPSP list when the user's Enable Banking credentials are set.
    func loadLivePsd2Banks() {
        guard let vault, livePsd2Banks.isEmpty, !isDemo,
              settingEntry("enablebanking.application_id")?.hasValue == true,
              settingEntry("enablebanking.private_key_pem")?.hasValue == true else { return }
        Task { [weak self] in
            let list = (try? await vault.listEnableBankingAspsps(country: "")) ?? []
            await MainActor.run { self?.livePsd2Banks = list }
        }
    }

    /// Setting keys a bank still needs (FinTS product ID, API keys …).
    func missingSettings(for connection: BankConnection) -> [String] {
        guard let d = bankCatalog().first(where: { $0.kind == connection.connector }) else { return [] }
        return d.requiredSettings.filter { key in !(settings.first { $0.key == key }?.hasValue ?? false) }
    }

    func settingEntry(_ key: String) -> SettingEntry? { settings.first { $0.key == key } }

    /// Saves the setup form and continues with the sync.
    func completeSetup(_ request: SetupRequest, values: [String: String]) {
        for (k, v) in values where !v.trimmingCharacters(in: .whitespaces).isEmpty {
            saveSetting(k, v)
        }
        setupRequest = nil
        let still = missingSettings(for: request.connection)
        if still.isEmpty {
            requestSync(request.connection)
        } else {
            setupRequest = SetupRequest(connection: request.connection, keys: still)
        }
    }

    func holdings(for accountID: Int64) -> [Holding] {
        (try? vault?.listHoldings(accountId: accountID)) ?? []
    }

    /// Deletes one account incl. bookings/documents/holdings (and its connection if it was the last account).
    func deleteAccount(_ id: Int64) {
        guard let vault else { return }
        run { try vault.deleteAccount(accountId: id) }
        if sidebarSelection == .account(id) { sidebarSelection = .allAccounts }
        reloadAll()
    }

    func removeConnection(_ id: Int64) {
        guard let vault else { return }
        run { try vault.deleteBankConnection(connectionId: id) }
        reloadAll()
    }

    // MARK: - Sync (two-phase)

    // MARK: - Belege & PostBox

    var documentsVersion = 0
    /// Account whose statements (HKEKA) are being fetched by the running session.
    var statementsAccountID: Int64?
    private var statementsCountBefore = 0

    func accountDocuments(_ accountID: Int64) -> [DocumentInfo] {
        _ = documentsVersion
        let f = DocumentFilter(accountId: accountID, docType: nil, search: nil, unlinkedOnly: false)
        return (try? vault?.listAllDocuments(filter: f)) ?? []
    }

    func canFetchStatements(_ account: Account) -> Bool {
        guard let c = account.connector, account.kind != .loan else { return false }
        return [.volksbankKasselGoettingen, .direkt1822, .finTsGeneric].contains(c)
    }

    /// Explicit "Kontoauszüge abrufen": regular syncs never fetch statements (speed, no extra TAN).
    func fetchStatements(for account: Account) {
        guard syncingConnectionID == nil,
              let cid = account.connectionId,
              let connection = connections.first(where: { $0.id == cid }) else { return }
        statementsAccountID = account.id
        statementsCountBefore = accountDocuments(account.id).count
        requestSync(connection)
    }

    var quickLookURL: URL?

    func documents(for booking: Booking) -> [DocumentInfo] {
        _ = documentsVersion
        return (try? vault?.listDocumentsForBooking(bookingId: booking.id)) ?? []
    }

    func allDocuments(search: String = "", unlinkedOnly: Bool = false) -> [DocumentInfo] {
        _ = documentsVersion
        let f = DocumentFilter(accountId: nil, docType: nil, search: search.isEmpty ? nil : search, unlinkedOnly: unlinkedOnly)
        return (try? vault?.listAllDocuments(filter: f)) ?? []
    }

    func documentData(_ doc: DocumentInfo) -> Data? {
        try? vault?.getDocumentBytes(docId: doc.id)
    }

    private func documentsChanged() {
        documentsVersion += 1
        reloadBookings()
    }

    /// Dropped onto a booking row / the inspector drop zone.
    func attach(_ urls: [URL], to booking: Booking) {
        guard let vault else { return }
        var n = 0
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            run { _ = try vault.attachDocumentToBooking(bookingId: booking.id, fileName: url.lastPathComponent, bytes: data); n += 1 }
        }
        if n > 0 { toast = String(localized: "\(n) Belege an „\(booking.merchantName)“ angehängt") }
        documentsChanged()
    }

    /// Dropped anywhere: Rust matches amount/date/merchant (with PDFKit/Vision text as hint).
    func dropAnywhere(_ urls: [URL]) {
        guard let vault else { return }
        Task {
            var linked: [String] = []
            var unmatched = 0
            for url in urls {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                let text = await ReceiptText.extract(data: data, fileName: url.lastPathComponent)
                do {
                    if let hit = try vault.autoMatchDocument(fileName: url.lastPathComponent, bytes: data, textHint: text) {
                        linked.append(hit)
                    } else {
                        unmatched += 1
                    }
                } catch {
                    errorMessage = describe(error)
                }
            }
            if !linked.isEmpty {
                toast = String(localized: "Beleg zugeordnet: \(linked.joined(separator: ", "))")
            } else if unmatched > 0 {
                toast = String(localized: "Kein passender Umsatz gefunden – in „Belege & PostBox“ abgelegt")
            }
            documentsChanged()
        }
    }

    func deleteDocument(_ doc: DocumentInfo) {
        guard let vault else { return }
        run { try vault.deleteDocument(docId: doc.id) }
        documentsChanged()
    }

    func linkDocument(_ doc: DocumentInfo, to booking: Booking?) {
        guard let vault else { return }
        run { try vault.linkDocument(docId: doc.id, bookingId: booking?.id) }
        documentsChanged()
    }

    /// Writes the document to a temp file and shows it in QuickLook.
    func quickLook(_ doc: DocumentInfo) {
        guard let data = documentData(doc) else { return }
        let ext = ["image/png": "png", "image/jpeg": "jpg", "image/heic": "heic"][doc.mimeType] ?? "pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GiroCrab-Beleg-\(doc.id).\(ext)")
        try? data.write(to: url)
        quickLookURL = url
    }

    func exportAllDocuments(to folder: URL) {
        guard let vault else { return }
        let ok = folder.startAccessingSecurityScopedResource()
        defer { if ok { folder.stopAccessingSecurityScopedResource() } }
        run {
            let n = try vault.exportAllDocuments(destDir: folder.path)
            toast = String(localized: "\(n) Belege nach „\(folder.lastPathComponent)/GiroCrab-Belege“ exportiert")
        }
    }

    func connectionStatus(_ id: Int64) -> ConnectionStatus? {
        try? vault?.connectionStatus(connectionId: id)
    }

    func updateConnection(_ id: Int64, name: String, login: String) {
        guard let vault else { return }
        run { try vault.updateBankConnection(connectionId: id, displayName: name, loginName: login) }
        reloadAccounts()
    }

    func setConnectionPin(_ id: Int64, _ pin: String?) {
        guard let vault else { return }
        run { try vault.setConnectionPin(connectionId: id, pin: pin) }
    }

    func clearSession(_ id: Int64) {
        guard let vault else { return }
        run { try vault.clearConnectionSession(connectionId: id) }
        toast = String(localized: "Sitzung gelöscht")
    }

    func revealSetting(_ key: String) -> String {
        ((try? vault?.getSetting(key: key)) ?? nil) ?? ""
    }

    /// Cookies from the in-app browser login -> vault -> sync without 2FA.
    func applyBrowserSession(_ connection: BankConnection, cookies: String) {
        guard let vault else { return }
        webLoginConnection = nil
        do {
            try vault.setConnectionSession(connectionId: connection.id, cookies: cookies)
            toast = String(localized: "Trade-Republic-Sitzung übernommen")
            startSync(connection, secret: "")
        } catch {
            errorMessage = describe(error)
        }
    }

    func requestSync(_ connection: BankConnection) {
        // Amex / Amazon Visa: embedded web-portal login (no API keys needed).
        if usesPortal(connection) {
            webLoginConnection = connection
            return
        }
        // Trade Republic: AWS WAF blocks raw logins – without a stored
        // session the in-app browser login is the default flow.
        if !isDemo, connection.connector == .tradeRepublic, !(connectionStatus(connection.id)?.hasSession ?? false) {
            webLoginConnection = connection
            return
        }
        if !isDemo, let st = connectionStatus(connection.id), (st.hasPin || (connection.connector == .tradeRepublic && st.hasSession)),
           missingSettings(for: connection).isEmpty {
            startSync(connection, secret: "")
            return
        }
        if !isDemo {
            let missing = missingSettings(for: connection)
            if !missing.isEmpty {
                setupRequest = SetupRequest(connection: connection, keys: missing)
                return
            }
        }
        let needsSecret = !(bankCatalog().first { $0.kind == connection.connector }?.secretLabel.hasPrefix("(") ?? false)
        if isDemo || !needsSecret {
            startSync(connection, secret: isDemo ? "demo" : "")
        } else {
            pendingLogin = PendingLogin(connection: connection)
        }
    }

    func requestSyncAll() {
        guard syncingConnectionID == nil else { return }
        // portal connections need an interactive login – not part of "sync all"
        let batch = connections.filter { !usesPortal($0) }
        guard let head = batch.first else { return }
        syncQueue = Array(batch.dropFirst())
        requestSync(head)
    }

    private func syncNextInQueue() {
        guard !syncQueue.isEmpty else { return }
        requestSync(syncQueue.removeFirst())
    }

    func startSync(_ connection: BankConnection, secret: String) {
        guard let vault else { return }
        if usesPortal(connection) { webLoginConnection = connection; return }
        pendingLogin = nil
        syncingConnectionID = connection.id
        Task {
            do {
                let session: SyncSession
                if let accountID = self.statementsAccountID {
                    session = try vault.fetchAccountStatements(accountId: accountID, secret: secret, demo: isDemo)
                } else {
                    session = try vault.beginSync(connectionId: connection.id, secret: secret, demo: isDemo)
                }
                self.activeSession = session
                let step = try await session.start()
                self.handle(step, connection: connection)
            } catch {
                self.finishSync(error: error)
            }
        }
    }

    private func handle(_ step: SyncStep, connection: BankConnection) {
        switch step {
        case .needsChallenge(let c):
            activeChallenge = ActiveChallenge(connection: connection, challenge: c, waiting: false)
            if c.kind == .decoupledPush { schedulePoll(connection: connection, interval: c.pollIntervalSeconds) }
        case .stillWaiting(let c):
            if activeChallenge == nil {
                activeChallenge = ActiveChallenge(connection: connection, challenge: c, waiting: true)
            } else {
                activeChallenge?.waiting = true
                activeChallenge?.busy = false
            }
            schedulePoll(connection: connection, interval: c.pollIntervalSeconds)
        case .finished(let s):
            activeChallenge = nil
            syncingConnectionID = nil
            activeSession = nil
            if let accountID = statementsAccountID {
                statementsAccountID = nil
                documentsVersion += 1
                let n = max(0, accountDocuments(accountID).count - statementsCountBefore)
                toast = String(localized: "\(connection.displayName): \(n) neue Kontoauszüge")
            } else {
                toast = String(localized: "\(connection.displayName): \(s.transactionsImported) neue Buchungen, \(s.transactionsCategorized) kategorisiert")
            }
            reloadAll()
            syncNextInQueue()
        }
    }

    fileprivate func schedulePoll(connection: BankConnection, interval: UInt32) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(interval, 1)) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if let transfer = self.activeTransfer {
                do {
                    self.handleTransfer(try await transfer.poll(), connection: connection)
                } catch {
                    self.finishTransfer(error: error)
                }
                return
            }
            guard let session = self.activeSession else { return }
            do {
                let step = try await session.poll()
                self.handle(step, connection: connection)
            } catch {
                self.finishSync(error: error)
            }
        }
    }

    func submitCode(_ code: String) {
        if let transfer = activeTransfer, let ch = activeChallenge {
            activeChallenge?.busy = true
            activeChallenge?.error = nil
            Task {
                do {
                    self.handleTransfer(try await transfer.submitCode(code: code), connection: ch.connection)
                } catch {
                    self.finishTransfer(error: error)
                }
            }
            return
        }
        guard let session = activeSession, let ch = activeChallenge else { return }
        activeChallenge?.busy = true
        activeChallenge?.error = nil
        Task {
            do {
                let step = try await session.submitCode(code: code)
                self.handle(step, connection: ch.connection)
            } catch {
                self.finishSync(error: error)
            }
        }
    }

    func cancelSync() {
        pollTask?.cancel()
        if let t = activeTransfer {
            activeTransfer = nil
            activeChallenge = nil
            transferBusy = false
            transferError = String(localized: "Überweisung abgebrochen – es wurde nichts gesendet, solange die TAN nicht bestätigt wurde.")
            showTransferSheet = true
            Task { await t.cancel() }
            return
        }
        let s = activeSession
        activeSession = nil
        activeChallenge = nil
        syncingConnectionID = nil
        statementsAccountID = nil
        syncQueue = []
        Task { await s?.cancel() }
    }

    private var syncingConnectionIDBeforeError: Int64?

    private func finishSync(error: Error) {
        statementsAccountID = nil
        syncingConnectionIDBeforeError = syncingConnectionID
        pollTask?.cancel()
        activeSession = nil
        activeChallenge = nil
        syncingConnectionID = nil
        syncQueue = []
        if let ce = error as? CoreError, case .BrowserLoginRequired(let m) = ce,
           let conn = connections.first(where: { $0.id == syncingConnectionIDBeforeError }) {
            toast = m
            webLoginConnection = conn
            return
        }
        if let ce = error as? CoreError, case .MissingSetting(let key) = ce,
           let conn = connections.first(where: { $0.id == syncingConnectionIDBeforeError }) {
            var keys = missingSettings(for: conn)
            if !keys.contains(key) { keys.insert(key, at: 0) }
            setupRequest = SetupRequest(connection: conn, keys: keys)
            return
        }
        errorMessage = describe(error)
    }
}

// MARK: - SEPA-Überweisung

extension AppModel {
    /// Checking accounts that are connected via FinTS (HKCCS-capable banks).
    var transferAccounts: [Account] {
        allAccounts.filter {
            $0.kind == .checking && !$0.iban.isEmpty
                && [.volksbankKasselGoettingen, .direkt1822, .finTsGeneric, .bunq].contains($0.connector)
        }
    }

    var canTransfer: Bool { vault != nil && !transferAccounts.isEmpty && syncingConnectionID == nil && activeTransfer == nil }

    /// Pre-selects the sidebar account if it can send transfers, else the first one.
    func openTransfer() {
        guard canTransfer else { return }
        var selected: Int64?
        if case .account(let id) = sidebarSelection, transferAccounts.contains(where: { $0.id == id }) { selected = id }
        if transferDraft.accountID == nil || !transferAccounts.contains(where: { $0.id == transferDraft.accountID }) {
            transferDraft.accountID = selected ?? transferAccounts.first?.id
        } else if let selected {
            transferDraft.accountID = selected
        }
        transferError = nil
        showTransferSheet = true
    }

    /// Context menu: new transfer pre-filled from a booking.
    func openTransfer(from b: Booking) {
        guard canTransfer else { return }
        transferDraft.name = b.counterparty.isEmpty ? b.merchantName : b.counterparty
        transferDraft.iban = TransferSheetView.groupedIBAN(b.counterpartyIban)
        transferDraft.bic = ""
        transferDraft.amountText = Money.plain(abs(b.amountCents))
        transferDraft.purpose = String(b.purpose.prefix(140))
        openTransfer()
    }

    func suggestRecipients(_ query: String) -> [KnownRecipient] {
        (try? vault?.suggestRecipients(query: query, limit: 6)) ?? []
    }

    func startTransfer() {
        guard let vault, let accID = transferDraft.accountID,
              let account = allAccounts.first(where: { $0.id == accID }),
              let connection = connections.first(where: { $0.id == account.connectionId }) else { return }
        do {
            let cents = try parseAmountToCents(text: transferDraft.amountText)
            let bic = transferDraft.bic.trimmingCharacters(in: .whitespaces)
            let request = SepaTransferRequest(
                accountId: accID,
                recipientName: transferDraft.name,
                recipientIban: transferDraft.iban,
                recipientBic: bic.isEmpty ? nil : bic,
                amountCents: cents,
                purpose: transferDraft.purpose,
                instant: transferDraft.instant,
                executionDate: transferDraft.executionDateISO)
            let stored = connectionStatus(connection.id)?.hasPin ?? false
            if !isDemo && !stored && transferDraft.pin.isEmpty {
                transferError = String(localized: "Bitte die Banking-PIN eingeben.")
                return
            }
            let session = try vault.beginTransfer(request: request, secret: isDemo ? "demo" : transferDraft.pin, demo: isDemo)
            transferError = nil
            transferBusy = true
            showTransferSheet = false
            activeTransfer = session
            Task {
                do {
                    self.handleTransfer(try await session.start(), connection: connection)
                } catch {
                    self.finishTransfer(error: error)
                }
            }
        } catch {
            transferError = describe(error)
        }
    }

    fileprivate func handleTransfer(_ step: TransferStep, connection: BankConnection) {
        switch step {
        case .needsChallenge(let c):
            activeChallenge = ActiveChallenge(connection: connection, challenge: c, waiting: false)
            if c.kind == .decoupledPush { schedulePoll(connection: connection, interval: c.pollIntervalSeconds) }
        case .stillWaiting(let c):
            if activeChallenge == nil {
                activeChallenge = ActiveChallenge(connection: connection, challenge: c, waiting: true)
            } else {
                activeChallenge?.waiting = true
                activeChallenge?.busy = false
            }
            schedulePoll(connection: connection, interval: c.pollIntervalSeconds)
        case .finished:
            pollTask?.cancel()
            activeChallenge = nil
            activeTransfer = nil
            transferBusy = false
            transferDraft = TransferDraft(accountID: transferDraft.accountID)
            toast = String(localized: "Überweisung freigegeben und vorgemerkt")
            reloadAll()
        }
    }

    fileprivate func finishTransfer(error: Error) {
        pollTask?.cancel()
        activeChallenge = nil
        activeTransfer = nil
        transferBusy = false
        transferDraft.pin = ""
        transferError = describe(error)
        showTransferSheet = true
    }
}

/// Human-readable (localised) text for core errors (instead of
/// "GiroCrabCore.CoreError.MissingSetting(key: …)").
func describe(_ error: Error) -> String {
    guard let e = error as? CoreError else { return error.localizedDescription }
    switch e {
    case .Database(let m): return String(localized: "Datenbankfehler: \(m)")
    case .WrongKey: return String(localized: "Der Tresor konnte nicht entsperrt werden (falscher Schlüssel oder beschädigte Datei).")
    case .NotFound(let what): return String(localized: "Nicht gefunden: \(what)")
    case .InvalidInput(let m): return String(localized: "Ungültige Eingabe: \(m)")
    case .MissingSetting(let key):
        let label = settingLabels[key] ?? key
        return String(localized: "Für diese Bank fehlt noch eine Einstellung: \(label). Bitte in den Einstellungen unter „FinTS & API-Schlüssel“ eintragen.")
    case .Network(let m): return String(localized: "Netzwerkfehler: \(m)")
    case .Bank(let code, let m): return String(localized: "Die Bank hat abgelehnt (\(code)): \(m)")
    case .Authentication(let m): return String(localized: "Anmeldung fehlgeschlagen: \(m)")
    case .Protocol(let m): return String(localized: "Protokollfehler: \(m)")
    case .SessionClosed: return String(localized: "Dieser Abruf ist nicht mehr aktiv.")
    case .BrowserLoginRequired(let m): return m
    }
}

let settingLabels: [String: String] = [
    "fints.product_id": String(localized: "FinTS-Produktregistrierung"),
    "fints.url.52090000": String(localized: "FinTS-Server Volksbank Kassel Göttingen"),
    "fints.url.50050201": String(localized: "FinTS-Server 1822direkt"),
    "comdirect.client_id": String(localized: "comdirect Client-ID"),
    "comdirect.client_secret": String(localized: "comdirect Client-Secret"),
    "paypal.client_id": String(localized: "PayPal Client-ID"),
    "paypal.client_secret": String(localized: "PayPal Secret"),
    "enablebanking.application_id": String(localized: "Enable Banking Application-ID"),
    "enablebanking.private_key_pem": String(localized: "Enable Banking Private Key"),
    "enablebanking.redirect_url": String(localized: "Enable Banking Redirect-URL"),
]

func formatIBAN(_ iban: String) -> String {
    var out = ""
    for (i, ch) in iban.enumerated() {
        if i > 0 && i % 4 == 0 { out.append(" ") }
        out.append(ch)
    }
    return out
}
