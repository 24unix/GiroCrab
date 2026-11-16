pragma Singleton
import QtQuick
import QtCore
import GiroCrab

// AppModel.swift: app state and core bridge. Names follow the Swift model so
// the views read the same (`model.title`, `model.headerBalance`, …).
// Sidebar selection is a string key: "all", "documents", "uncategorized",
// "group:<id>", "userGroup:<uuid>", "account:<id>", "category:<id>".
QtObject {
    id: model

    // MARK: core bridge
    function core(method, args) {
        const r = JSON.parse(Core.call(method, JSON.stringify(args || {})))
        if (r.err !== undefined) throw new Error(r.err)
        return r.ok
    }
    /// `offMain` / `vaultOffMain`: runs on a worker thread, `done(result)` on the GUI thread.
    property var pendingCalls: ({})
    property Connections coreReplies: Connections {
        target: Core
        function onFinished(ticket, result) {
            const cb = model.pendingCalls[ticket]
            delete model.pendingCalls[ticket]
            if (cb) cb(JSON.parse(result))
        }
    }
    function coreAsync(method, args, done, failed) {
        const t = Core.callAsync(method, JSON.stringify(args || {}))
        pendingCalls[t] = r => {
            if (r.err !== undefined) { if (failed) failed(r.err); else errorMessage = r.err }
            else if (done) done(r.ok)
        }
    }

    /// UserDefaults → QSettings (~/.config/GiroCrab/GiroCrab.conf).
    property Settings defaults: Settings {
        /// `girocrab.hasRealData`: "" = never answered, "true" / "false".
        property string hasRealData: ""
        /// AccountSidebarMode choice; "" = none yet (then "byGroup" once groups exist).
        property string accountView: ""
        property bool showInspector: true
        property bool showStatistics: true
        // Also read/written by key (`value` / `setValue`): `bookings/autoReviewDelay`,
        // `period/customFrom`, `period/customTo` (the keys of the former separate Settings).
    }

    /// `run { … }` in the Swift model: errors end up in the alert.
    function run(fn) {
        try { return fn() } catch (e) { errorMessage = e.message; console.warn(e.message, e.stack); return undefined }
    }

    // MARK: vault state ("starting", "locked", "unlocking", "open", "failed")
    property string vaultState: "starting"
    property string failure: ""
    property bool demoActive: false
    readonly property bool isUnlocked: vaultState === "open"
    readonly property bool isDemo: demoActive
    /// `ownVault != nil`: the personal vault is unlocked (maybe in the background of the demo).
    property bool hasOwnVault: false
    property bool unlockCelebrating: false
    /// Demo only: the lock screen shown once so the protection can be tried out.
    property bool lockPreview: false
    /// Set when the user left the demo to the lock screen: no automatic prompt then.
    property bool demoDismissedLock: false
    /// The personal vault is what is shown (not the demo).
    readonly property bool holdsRealData: hasOwnVault && !demoActive
    property var vaultInfo: ({ path: "", size: -1, keychain_bypassed: false, demo_seed: false })
    property string errorMessage: ""
    property string errorTitle: ""
    property string toast: ""
    property bool showAddBank: false
    property bool showMoneyMoneyImport: false

    // MARK: data
    property var groups: []          // [AccountGroup] (by kind)
    property var userGroups: []      // [UserGroup]
    property var accountsByID: ({})
    property var accountMarkers: ({})
    property var categories: []
    property var categoryTree: []
    property var bookings: []
    property var dayGroups: []
    property var streamItems: []     // flattened: {type:"header", day} | {type:"row", booking, isLast}
    // Model of the booking list: one empty row per stream item; the delegate reads
    // streamItems[index]. Only the count is synced, so paging appends rows instead of
    // resetting the view (which would jump back to the top).
    readonly property ListModel streamModel: ListModel {}
    property var page: null
    property var selectionFlow: null
    property var history: []
    property var connections: []
    property var recurring: []
    property var recurringMonth: null
    property var merchantStats: null
    property var budgets: []
    property var cashflow: []

    // MARK: UI state
    property string sidebarSelection: "all"
    onSidebarSelectionChanged: { listLimit = defaultListLimit; reloadSelection(false) }
    property string scope: "All"               // BookingScope
    onScopeChanged: { listLimit = defaultListLimit; if (scope === "Investments") reloadDashboard(); reloadBookings() }
    property string period: "all"
    onPeriodChanged: { listLimit = defaultListLimit; reloadSelection(true) }
    property string customPeriodFrom: ""
    property string customPeriodTo: ""
    property string statusFilter: "all"        // all | new | checked
    onStatusFilterChanged: { listLimit = defaultListLimit; reloadBookings() }
    property string directionFilter: "All"     // BookingDirection
    onDirectionFilterChanged: { listLimit = defaultListLimit; reloadBookings() }
    property string searchText: ""
    property Timer searchTimer: Timer { interval: 250; onTriggered: model.reloadBookings() }
    onSearchTextChanged: searchTimer.restart()
    /// AccountSidebarMode (byGroup | byKind): the explicit choice, else "Nach Gruppe" once a group exists.
    /// Set it with `setAccountView` (AccountGroupsModel.swift › accountView).
    readonly property string accountView: defaults.accountView !== "" ? defaults.accountView : (hasUserGroups ? "byGroup" : "byKind")
    function setAccountView(v) { defaults.accountView = v }
    // sidebar state, kept like the Swift UserDefaults (see MARK: account groups)
    property var collapsedGroups: sidebarDefaults.loadSet("collapsedKindGroups")
    onCollapsedGroupsChanged: sidebarDefaults.setValue("collapsedKindGroups", JSON.stringify(Object.keys(collapsedGroups).map(Number)))
    property var collapsedUserGroups: sidebarDefaults.loadSet("collapsedUserGroups")
    onCollapsedUserGroupsChanged: sidebarDefaults.setValue("collapsedUserGroups", JSON.stringify(Object.keys(collapsedUserGroups)))
    property var expandedCategories: ({})
    property bool showArchivedAccounts: String(sidebarDefaults.value("showArchived", true)) !== "false"
    onShowArchivedAccountsChanged: sidebarDefaults.setValue("showArchived", showArchivedAccounts)
    property bool showInspector: defaults.showInspector
    onShowInspectorChanged: defaults.showInspector = showInspector
    property bool showStatistics: defaults.showStatistics
    onShowStatisticsChanged: defaults.showStatistics = showStatistics

    property var selectedBookingID: null
    property var selectedBookingIDs: ({})
    onSelectedBookingIDChanged: {
        if (stickyBooking !== null && stickyBooking.id !== selectedBookingID) stickyBooking = null
        const ids = {}
        if (selectedBookingID !== null) ids[selectedBookingID] = true
        if (selectedBookingID === null || !selectedBookingIDs[selectedBookingID]) selectedBookingIDs = ids
        loadMerchantStats()
    }
    /// A booking that left the filtered list because the user just edited it
    /// (e.g. "Geprüft" under "Neu", "kein Gehalt" in the salary period). It stays
    /// selected and visible in the inspector until the user selects something else.
    property var stickyBooking: null
    /// Booking whose inspector note field should take focus (double-click / Return in the list).
    property var pendingNoteFocus: null
    /// Hands keyboard focus back to the booking list (Esc in the note field).
    signal focusList()
    /// Day card the stream should scroll to (click in the balance chart).
    signal scrollToDay(string day)
    /// The start-up preselection must not scroll the list (SwiftUI sets it before the view appears).
    property bool scrollOnSelect: true
    readonly property int defaultListLimit: 300
    property int listLimit: defaultListLimit

    // MARK: enums (titles as in the Swift extensions)
    readonly property var periods: [
        { id: "all", title: qsTr("Gesamter Zeitraum") }, { id: "thisMonth", title: qsTr("Dieser Monat") },
        { id: "lastMonth", title: qsTr("Letzter Monat") }, { id: "last3Months", title: qsTr("Letzte 3 Monate") },
        { id: "last12Months", title: qsTr("Letzte 12 Monate") }, { id: "thisQuarter", title: qsTr("Dieses Quartal") },
        { id: "thisYear", title: qsTr("Dieses Jahr") }, { id: "lastYear", title: qsTr("Letztes Jahr") },
        { id: "sinceSalary", title: qsTr("Seit letztem Gehalt") }]
    readonly property var scopes: [
        { id: "All", title: qsTr("Alle Buchungen"), shortTitle: qsTr("Alle") },
        { id: "Everyday", title: qsTr("Alltag & Konsum"), shortTitle: qsTr("Alltag") },
        { id: "Investments", title: qsTr("Sparpläne & Perks"), shortTitle: qsTr("Sparpläne") }]
    readonly property var statusFilters: [
        { id: "all", title: qsTr("Alle") }, { id: "new", title: qsTr("Neu") }, { id: "checked", title: qsTr("Geprüft") }]
    readonly property var directions: [
        { id: "All", title: qsTr("Einnahmen und Ausgaben") }, { id: "Income", title: qsTr("Nur Einnahmen") },
        { id: "Expense", title: qsTr("Nur Ausgaben") }]
    function titleOf(list, id) { for (const x of list) if (x.id === id) return x.title; return id }

    // MARK: launch options (LaunchOptions.swift: the same switches as the Mac app)
    readonly property var launchArgs: Qt.application.arguments
    /// The value after `flag`, lowercased like LaunchOptions.swift ("" = not given).
    function launchValue(flag) { const i = launchArgs.indexOf(flag); return i >= 0 && i + 1 < launchArgs.length ? launchArgs[i + 1].toLowerCase() : "" }
    /// `--demo-sync`: "Alle abrufen" right away (simulated PIN / TAN dialogs).
    readonly property bool optionDemoSync: launchArgs.indexOf("--demo-sync") >= 0
    /// `--demo-sheet <name>`, `--demo-settings <tab>[:edit|add|remove]` (opened by presentLaunchOptions).
    readonly property string demoSheet: launchValue("--demo-sheet")
    readonly property string demoSettings: launchValue("--demo-settings")
    /// `--demo-seed` or GIROCRAB_DEMO_SEED=1|true|yes; `--screenshot`, `--demo-sync`,
    /// `--demo-sheet` and `--demo-settings` imply it (reproducible pictures).
    readonly property bool optionDemoSeed: launchArgs.indexOf("--demo-seed") >= 0 || vaultInfo.demo_seed === true
        || screenshotMode || optionDemoSync || demoSheet !== "" || demoSettings !== ""

    // MARK: - Vault lifecycle

    /// Real data may exist in the (encrypted, hence unreadable while locked) vault.
    /// Without a stored answer, an existing vault file counts as real data.
    function vaultMayHoldRealData() {
        if (defaults.hasRealData !== "") return defaults.hasRealData === "true"
        return vaultInfo.size > 0
    }

    /// Called once by the root view: decides lock vs. demo.
    function bootstrap() {
        if (vaultState !== "starting") return
        withFreshBankingPolicy(null)
        vaultInfo = core("vault_info")
        if (optionDemoSeed) {
            openDemo()
            applyLaunchSelection()
            // --demo-sheet / --demo-settings: presentLaunchOptions() once the vault is open
            return
        }
        if (vaultMayHoldRealData()) {
            vaultState = "locked"
            unlock()
        } else {
            openDemo()
        }
    }

    /// `openDemoVault()`: throw-away demo vault; the personal vault stays open in the background.
    function openDemo() {
        try {
            core("open_demo")
            lockPreview = false
            demoActive = true
            vaultState = "open"
            selectedBookingID = null
            sidebarSelection = "all"
            reloadAll()
            // macOS: preselect a consumption booking with a document, else the first one.
            let pick = bookings.find(b => b.flow === "Consumption" && b.document_count > 0)
                    || bookings.find(b => b.flow === "Consumption")
            scrollOnSelect = false
            selectedBookingID = pick ? pick.id : null
            scrollOnSelect = true
        } catch (e) {
            failure = e.message
            vaultState = "failed"
        }
    }

    /// Unlock: key from the Secret Service (the keyring may ask for its password),
    /// open the vault off the GUI thread. A new key only while no vault file exists.
    function unlock() {
        if (vaultState === "unlocking") return
        demoDismissedLock = false
        lockPreview = false
        vaultState = "unlocking"
        unlockPhase = "keyring"
        vaultInfo = core("vault_info")
        coreAsync("unlock_own", { allow_create: vaultInfo.size <= 0 }, r => {
            hasOwnVault = true
            vaultInfo = core("vault_info")
            unlockCelebrating = true
            celebrationTimer.restart()
            if (r.account_count === 0 && !r.has_connections) {
                // Nothing synced yet: show demo bookings so the UI can be judged.
                defaults.hasRealData = "false"
                openDemo()
                toast = qsTr("Ihr Tresor ist noch leer – Sie sehen Demo-Daten")
            } else {
                // The key is there; loading the vault happens on this thread. Show
                // "Buchungen werden geladen …" first and give it a frame to appear.
                unlockPhase = "loading"
                openVaultTimer.restart()
            }
        }, err => {
            if (!hasOwnVault && !vaultMayHoldRealData()) {
                // Cancelled before any real data exists: back to the demo, never a dead end.
                openDemo()
                toast = err
            } else {
                failure = err
                vaultState = "failed"
            }
        })
    }
    property Timer celebrationTimer: Timer { interval: 320; onTriggered: model.unlockCelebrating = false }
    /// "keyring" while the key comes from the Secret Service, "loading" while the vault loads.
    property string unlockPhase: "keyring"
    property Timer openVaultTimer: Timer { interval: 60; onTriggered: model.useVault(false) }

    /// `useVault(_:demo:)` for the personal vault.
    function useVault(demo) {
        if (!run(() => { core("use_own"); return true })) return
        demoActive = demo
        if (!demo) defaults.hasRealData = "true"
        vaultState = "open"
        selectedBookingID = null
        sidebarSelection = "all"
        reloadAll()
        selectedBookingID = bookings.length ? bookings[0].id : null
    }
    /// Switch to the demo data (own vault stays unlocked in the background).
    function showDemo() { if (!demoActive) openDemo() }
    /// Switch back to the personal vault (unlocks it first if needed).
    function showOwnVault() {
        if (hasOwnVault) useVault(false)
        else { vaultState = "locked"; unlock() }
    }
    function previewLock() {
        if (!demoActive || hasOwnVault || vaultMayHoldRealData()) return
        lockPreview = true
        demoDismissedLock = true
        vaultState = "locked"
    }
    function endLockPreview() {
        if (!lockPreview || vaultMayHoldRealData()) return
        lockPreview = false
        openDemo()
    }
    function lock() {
        if (!holdsRealData) return
        demoDismissedLock = true
        endBankDialogsForLock()
        run(() => core("lock"))   // also cancels every bank dialog in the core (src/sessions.rs)
        hasOwnVault = false
        demoActive = false
        groups = []; userGroups = []; accountsByID = ({}); accountMarkers = ({}); bookings = []; categories = []; categoryTree = []
        connections = []; page = null; merchantStats = null; streamItems = []; streamModel.clear(); dayGroups = []; history = []
        rules = []; settings = []; dashboard = null; budgets = []; recurring = []; recurringMonth = null; recurringHidden = []
        selectedBookingID = null; stickyBooking = null; salaryCycle = null
        ++loanGeneration; loans = []; loanLinks = ({}); loanEditor = null; openingBalanceRequest = null
        vaultState = "locked"
    }

    // MARK: loading
    function reloadAll() {
        reloadSettings()
        reloadAccounts()
        refreshSalaryCycle()
        refreshRecurring()
        reloadHistory()
        reloadCategories()
        reloadBookings()
        reloadRules()
        reloadPlanning()
        reloadDashboard()
    }
    function reloadAccounts() {
        run(() => {
            groups = core("list_account_groups")
            userGroups = core("list_user_groups")
            connections = core("list_bank_connections")
            if (sidebarSelection.startsWith("userGroup:") && !userGroups.some(g => "userGroup:" + g.uuid === sidebarSelection))
                sidebarSelection = "all"
            rebuildAccountIndex()
        })
    }
    function rebuildAccountIndex() {
        reloadLoans()
        const byID = {}, markers = {}, count = {}
        const accounts = allAccounts
        const base = a => a.name.replace(" (MoneyMoney)", "")
        for (const a of accounts) { byID[a.id] = a; const k = base(a).toLowerCase(); count[k] = (count[k] || 0) + 1 }
        for (const a of accounts) {
            let label = base(a)
            if (count[label.toLowerCase()] > 1) {
                const digits = (a.iban || a.account_number).replace(/\D/g, "").slice(-4)
                if (digits && label.indexOf(digits) < 0) label += " ··" + digits
            }
            markers[a.id] = { label: label, color: Theme.readable(a.color_hex), symbol: a.sf_symbol }
        }
        accountsByID = byID
        accountMarkers = markers
    }
    function reloadCategories() {
        const r = periodRange()
        run(() => {
            categories = core("list_categories", { date_from: r[0], date_to: r[1] })
            categoryTree = buildTree(categories)
        })
    }
    /// Category tree from the flat list in one pass (grouped by parent first; the
    /// former per-node filter was quadratic and slow with large MoneyMoney imports).
    /// Order within a level stays the order of `flat`.
    function buildTree(flat) {
        const byParent = {}
        for (const c of flat) {
            const key = c.parent_id === null ? "root" : String(c.parent_id)
            ;(byParent[key] || (byParent[key] = [])).push(c)
        }
        function children(key) {
            return (byParent[key] || []).map(c => {
                const kids = children(String(c.id))
                return { category: c, children: kids.length ? kids : null }
            })
        }
        return children("root")
    }
    function reloadBookings() {
        if (!isUnlocked) return
        ++selectionLoadGeneration   // a pending off-main list must not overwrite this one
        run(() => {
            const p = core("list_transactions", { filter: currentFilter() })
            publish(p)
        })
        // the sticky booking is not in the list: re-read it so the inspector shows the edit
        if (stickyBooking !== null && !bookings.some(b => b.id === stickyBooking.id))
            stickyBooking = freshBooking(stickyBooking) || stickyBooking
        reloadSelectionKPIs()
        loadMerchantStats()
    }
    /// Shows a freshly loaded list page. A selected booking the page no longer
    /// contains falls back to the first row, unless it is sticky.
    function publish(p) {
        listGeneration++
        isLoadingMoreBookings = false
        page = p
        bookings = p.transactions
        const sticky = stickyBooking !== null && stickyBooking.id === selectedBookingID
        if (selectedBookingID !== null && !sticky && !bookings.some(b => b.id === selectedBookingID))
            selectedBookingID = bookings.length ? bookings[0].id : null
        pruneMultiSelection()
        rebuildStream()
    }
    /// After a reload: the multiple selection keeps only bookings the list still
    /// shows (plus the inspector's own booking, which may be sticky).
    function pruneMultiSelection() {
        const keys = Object.keys(selectedBookingIDs)
        if (!keys.length) return
        const visible = {}
        for (const b of bookings) visible[b.id] = true
        const kept = {}
        let n = 0
        for (const k of keys) if (visible[k] || Number(k) === selectedBookingID) { kept[k] = true; n++ }
        if (n !== keys.length) selectedBookingIDs = kept
    }
    /// Re-reads one booking from the vault (independent of the list filter).
    function freshBooking(b) {
        if (!b || !isUnlocked) return null
        try {
            const f = { account_ids: [b.account_id], category_id: null, include_subcategories: true, uncategorized_only: false,
                        search: null, date_from: b.booking_date, date_to: b.booking_date, limit: 0, offset: 0,
                        scope: "All", merchant_key: null, direction: "All", checked: null, whole_days: false }
            return core("list_transactions", { filter: f }).transactions.find(x => x.id === b.id) || null
        } catch (e) { return null }
    }
    /// dayGroups / streamItems from `bookings` (`StreamItem.flatten`).
    function rebuildStream() {
        const days = []
        let current = null
        for (const b of bookings) {
            if (!current || current.date !== b.booking_date) {
                current = { date: b.booking_date, bookings: [], sum: 0 }
                days.push(current)
            }
            current.bookings.push(b)
            current.sum += b.amount_cents
        }
        dayGroups = days
        const items = []
        for (const d of days) {
            items.push({ type: "header", day: d, key: "d" + d.date })
            d.bookings.forEach((b, i) => items.push({ type: "row", booking: b, isLast: i === d.bookings.length - 1, key: "b" + b.id }))
        }
        streamItems = items
        const n = items.length, have = streamModel.count
        if (n < have) streamModel.remove(n, have - n)
        else if (n > have) streamModel.append(Array.from({ length: n - have }, () => ({ s: 0 })))
    }

    // MARK: paging (loadMoreBookings / loadAllBookings)
    property int listGeneration: 0
    property bool isLoadingMoreBookings: false
    readonly property bool hasMoreBookings: page !== null && bookings.length < page.total_count
    readonly property int remainingBookingCount: page ? Math.max(0, page.total_count - bookings.length) : 0
    function loadMoreBookings(count) {
        if (!isUnlocked || !hasMoreBookings || isLoadingMoreBookings) return
        const f = currentFilter()
        f.offset = bookings.length
        f.limit = count > 0 ? count : defaultListLimit
        const generation = listGeneration
        isLoadingMoreBookings = true
        coreAsync("list_transactions", { filter: f }, next => {
            if (generation !== listGeneration) return
            isLoadingMoreBookings = false
            if (!next.transactions.length) return
            bookings = bookings.concat(next.transactions)
            listLimit = bookings.length
            rebuildStream()
        }, err => { isLoadingMoreBookings = false; errorMessage = err })
    }
    function loadAllBookings() {
        listLimit = Math.max(listLimit, page ? page.total_count : listLimit)
        reloadBookings()
    }

    function reloadSelectionKPIs() {
        const f = currentFilter()
        if (page && f.search === null && f.checked === null && f.direction === "All" && f.scope === "All"
                && f.category_id === null && !f.uncategorized_only) {
            selectionFlow = { consumption: page.flow.consumption_cents, invested: page.flow.invested_cents, income: page.flow.income_cents }
            return
        }
        const r = periodRange()
        run(() => {
            const s = core("selection_flow", { account_ids: f.account_ids, date_from: r[0], date_to: r[1] })
            selectionFlow = { consumption: s.consumption_cents, invested: s.invested_cents, income: s.income_cents }
        })
    }
    function reloadHistory() {
        const req = historyRequest()
        const r = periodRange()
        ++historyLoadGeneration   // a pending off-main answer must not overwrite this one
        run(() => { history = trimHistory(core("balance_history", { account_ids: req.ids, days: req.days }), r) })
    }
    function trimHistory(pts, r) {
        if (r[1]) pts = pts.filter(p => p.date <= r[1])
        if (!r[0]) {
            let first = -1
            for (let i = 1; i < pts.length; i++) if (pts[i].balance_cents !== pts[i - 1].balance_cents) { first = i; break }
            if (first > 0) pts = pts.slice(first - 1)
        }
        return pts
    }
    function historyRequest() {
        let ids = []
        const sel = sidebarSelection
        if (sel.startsWith("account:")) ids = [Number(sel.slice(8))]
        else if (sel.startsWith("group:")) {
            const g = groups.find(g => "group:" + g.id === sel)
            ids = g ? g.accounts.filter(a => a.archived_unix === null).map(a => a.id) : []
        } else if (sel.startsWith("userGroup:")) ids = userGroupBalanceAccountIDs(sel.slice(10))
        else ids = liquidAccounts.map(a => a.id)
        if (!ids.length) ids = [-1]
        const today = new Date(); today.setHours(0, 0, 0, 0)
        const from = periodRange()[0]
        const start = from ? Fmt.date(from) : new Date(today.getFullYear() - 15, today.getMonth(), today.getDate())
        const days = Math.max(2, Math.round((today - start) / 86400000) + 1)
        return { ids: ids, days: days }
    }
    /// Series, hidden series and this month's overview from one `recurring_snapshot` call.
    function refreshRecurring() {
        if (!isUnlocked) { recurring = []; recurringHidden = []; recurringMonth = null; return }
        const now = new Date()
        run(() => {
            const s = core("recurring_snapshot", { account_ids: selectionAccountIDs(), year: now.getFullYear(), month: now.getMonth() + 1 })
            recurring = s.series
            recurringHidden = s.ignored
            recurringMonth = s.month
        })
    }
    /// Pay cycle of the selection: `.sinceSalary` derives the period from it.
    property var salaryCycle: null
    function refreshSalaryCycle() {
        if (!isUnlocked) { salaryCycle = null; return }
        run(() => { salaryCycle = core("salary_cycle", { account_ids: selectionAccountIDs() }) })
    }
    function reloadPlanning() {
        const now = new Date()
        run(() => { budgets = core("list_category_budget_progress", { year: now.getFullYear(), month: now.getMonth() + 1 }) })
    }
    function loadMerchantStats() {
        // Not `selectedBooking`: inside onSelectedBookingIDChanged that binding may
        // not be re-evaluated yet and still answer the previous (or no) booking.
        const b = bookingByID(selectedBookingID)
        if (!b || !b.merchant.key) { merchantStats = null; return }
        run(() => { merchantStats = core("merchant_stats", { merchant_key: b.merchant.key }) })
    }
    function reloadSelection(periodChanged) {
        if (!isUnlocked) return
        refreshSalaryCycle()
        if (periodChanged) reloadCategories(); else refreshRecurring()
        // AppModel.offMain: list and balance history load on a worker thread (each holds
        // the vault for a while with many bookings); a newer selection drops older answers.
        reloadBookingsOffMain()
        reloadHistoryOffMain()
    }
    property int selectionLoadGeneration: 0
    property int historyLoadGeneration: 0
    function reloadBookingsOffMain() {
        if (!isUnlocked) return
        const gen = ++selectionLoadGeneration
        coreAsync("list_transactions", { filter: currentFilter() }, p => {
            if (gen !== selectionLoadGeneration || !isUnlocked) return
            publish(p)
            if (stickyBooking !== null && !bookings.some(b => b.id === stickyBooking.id))
                stickyBooking = freshBooking(stickyBooking) || stickyBooking
            reloadSelectionKPIs()
            loadMerchantStats()
        }, err => { if (gen === selectionLoadGeneration) errorMessage = parseCoreError(err).message })
    }
    function reloadHistoryOffMain() {
        if (!isUnlocked) return
        const gen = ++historyLoadGeneration
        const req = historyRequest()
        const r = periodRange()
        coreAsync("balance_history", { account_ids: req.ids, days: req.days }, pts => {
            if (gen !== historyLoadGeneration || !isUnlocked) return
            history = trimHistory(pts, r)
        }, () => {})
    }

    // MARK: filter
    function periodRange(p) {
        p = p || period
        const now = new Date()
        const som = new Date(now.getFullYear(), now.getMonth(), 1)
        const soy = new Date(now.getFullYear(), 0, 1)
        const I = Fmt.iso
        switch (p) {
        case "sinceSalary": return salaryCycle ? [salaryCycle.last_date, null] : [I(som), null]
        case "thisMonth": return [I(som), null]
        case "lastMonth": return [I(new Date(now.getFullYear(), now.getMonth() - 1, 1)), I(new Date(now.getFullYear(), now.getMonth(), 0))]
        case "last3Months": return [I(new Date(now.getFullYear(), now.getMonth() - 2, 1)), null]
        case "last12Months": return [I(new Date(now.getFullYear(), now.getMonth() - 11, 1)), null]
        case "thisQuarter": return [I(new Date(now.getFullYear(), Math.floor(now.getMonth() / 3) * 3, 1)), null]
        case "thisYear": return [I(soy), null]
        case "lastYear": return [I(new Date(now.getFullYear() - 1, 0, 1)), I(new Date(now.getFullYear() - 1, 11, 31))]
        case "custom": return [customPeriodFrom || null, customPeriodTo || null]
        default: return [null, null]
        }
    }
    function selectionAccountIDs() {
        const sel = sidebarSelection
        if (sel.startsWith("account:")) return [Number(sel.slice(8))]
        if (sel.startsWith("group:")) { const g = groups.find(g => "group:" + g.id === sel); return g ? g.accounts.map(a => a.id) : [] }
        if (sel.startsWith("userGroup:")) return userGroupAccountIDs(sel.slice(10))
        return []
    }
    function currentFilter() {
        const r = periodRange()
        const sel = sidebarSelection
        return {
            account_ids: selectionAccountIDs(),
            category_id: sel.startsWith("category:") ? Number(sel.slice(9)) : null,
            include_subcategories: true,
            uncategorized_only: sel === "uncategorized",
            search: searchText === "" ? null : searchText,
            date_from: r[0], date_to: r[1],
            limit: listLimit, offset: 0,
            scope: scope,
            merchant_key: null,
            direction: directionFilter,
            checked: statusFilter === "all" ? null : statusFilter === "checked",
            whole_days: true
        }
    }

    // MARK: user groups (AccountGroupsModel.swift)
    function userGroupSubtree(uuid) {
        const i = userGroups.findIndex(g => g.uuid === uuid)
        if (uuid === "" || i < 0) return userGroups.filter(g => g.uuid === uuid)
        const out = [userGroups[i]]
        for (let j = i + 1; j < userGroups.length && userGroups[j].depth > userGroups[i].depth && !userGroups[j].is_ungrouped; j++)
            out.push(userGroups[j])
        return out
    }
    function userGroupAccountIDs(uuid) { return [].concat(...userGroupSubtree(uuid).map(g => g.accounts.map(a => a.id))) }
    function userGroupBalanceAccountIDs(uuid) {
        let skipBelow = null, ids = []
        userGroupSubtree(uuid).forEach((g, n) => {
            if (skipBelow !== null) { if (g.depth > skipBelow) return; skipBelow = null }
            if (n > 0 && !g.include_in_total) { skipBelow = g.depth; return }
            ids = ids.concat(g.accounts.filter(a => a.archived_unix === null).map(a => a.id))
        })
        return ids
    }
    function isUserGroupVisible(g) {
        let parent = g.parent_uuid
        while (parent) {
            if (collapsedUserGroups[parent]) return false
            const p = userGroups.find(x => x.uuid === parent)
            parent = p ? p.parent_uuid : null
        }
        return true
    }
    function toggleCollapsedUserGroup(uuid) {
        const c = Object.assign({}, collapsedUserGroups)
        if (c[uuid]) delete c[uuid]; else c[uuid] = true
        collapsedUserGroups = c
    }
    function toggleCollapsedGroup(id) {
        const c = Object.assign({}, collapsedGroups)
        if (c[id]) delete c[id]; else c[id] = true
        collapsedGroups = c
    }
    function toggleExpandedCategory(id) {
        const c = Object.assign({}, expandedCategories)
        if (c[id]) delete c[id]; else c[id] = true
        expandedCategories = c
    }

    // MARK: computed (AppModel.swift › MARK: derived values)
    readonly property var allAccounts: [].concat(...groups.map(g => g.accounts))
    readonly property var liquidAccounts: allAccounts.filter(a => a.in_total && ["Checking", "Savings", "PaymentService", "CreditCard", "Cash"].indexOf(a.kind) >= 0)
    readonly property int liquidBalance: liquidAccounts.reduce((s, a) => s + a.balance_cents, 0)
    readonly property int newCount: allAccounts.reduce((s, a) => s + a.new_count, 0)
    readonly property int uncategorizedCount: allAccounts.filter(a => a.kind !== "Loan").reduce((s, a) => s + a.uncategorized_count, 0)
    readonly property real consumptionThisMonth: selectionFlow ? selectionFlow.consumption : 0
    readonly property real investedThisMonth: selectionFlow ? selectionFlow.invested : 0
    readonly property real incomeThisMonth: selectionFlow ? selectionFlow.income : 0
    readonly property int bookingCountLabel: page ? page.total_count : bookings.length
    readonly property var selectedBooking: bookingByID(selectedBookingID)
    /// The listed booking with this id, or the sticky one (see stickyBooking).
    function bookingByID(id) {
        if (id === null || id === undefined) return null
        return bookings.find(b => b.id === id) || (stickyBooking !== null && stickyBooking.id === id ? stickyBooking : null)
    }
    readonly property var selectedAccount: sidebarSelection.startsWith("account:") ? (accountsByID[Number(sidebarSelection.slice(8))] || null) : null

    readonly property string title: {
        const sel = sidebarSelection
        if (sel === "all") return qsTr("Übersicht")
        if (sel === "uncategorized") return qsTr("Ohne Kategorie")
        if (sel === "documents") return qsTr("Belege & PostBox")
        if (sel.startsWith("group:")) { const g = groups.find(g => "group:" + g.id === sel); return g ? g.name : qsTr("Gruppe") }
        if (sel.startsWith("userGroup:")) { const g = userGroups.find(g => "userGroup:" + g.uuid === sel); return g ? g.name : qsTr("Gruppe") }
        if (sel.startsWith("account:")) { const a = accountsByID[Number(sel.slice(8))]; return a ? a.name : qsTr("Konto") }
        if (sel.startsWith("category:")) { const c = categories.find(c => "category:" + c.id === sel); return c ? c.path : qsTr("Kategorie") }
        return ""
    }
    readonly property var headerBalance: {
        const sel = sidebarSelection
        if (sel === "all") return { label: qsTr("Verfügbar (Giro, Tagesgeld, Karten)"), cents: liquidBalance }
        if (sel.startsWith("account:")) { const a = accountsByID[Number(sel.slice(8))]; return a ? { label: qsTr("Kontostand"), cents: a.balance_cents } : null }
        if (sel.startsWith("group:")) { const g = groups.find(g => "group:" + g.id === sel); return g ? { label: qsTr("Summe"), cents: g.balance_cents } : null }
        if (sel.startsWith("userGroup:")) { const g = userGroups.find(g => "userGroup:" + g.uuid === sel); return g ? { label: qsTr("Summe"), cents: g.balance_cents } : null }
        if (sel.startsWith("category:")) { const c = categories.find(c => "category:" + c.id === sel); return c ? { label: qsTr("Summe im Zeitraum"), cents: c.total_cents } : null }
        return null
    }
    readonly property string lastSyncText: {
        const latest = connections.reduce((m, c) => c.last_sync_unix !== null && c.last_sync_unix > m ? c.last_sync_unix : m, 0)
        return latest ? qsTr("Aktualisiert %1").arg(Fmt.relative(latest)) : qsTr("Noch nie aktualisiert")
    }
    readonly property string periodTitle: period === "custom"
        ? Fmt.medium(customPeriodFrom) + " – " + Fmt.medium(customPeriodTo) : titleOf(periods, period)
    /// Subtitle of the period-based KPI tiles.
    readonly property string periodSubtitle: period !== "sinceSalary" ? periodTitle
        : salaryCycle ? qsTr("Seit Gehalt am %1").arg(Fmt.medium(salaryCycle.last_date)) : qsTr("Monat (kein Gehalt)")
    readonly property string filterTitle: {
        if (directionFilter === "All") return qsTr("Status: %1").arg(titleOf(statusFilters, statusFilter))
        const kind = directionFilter === "Income" ? qsTr("Einnahmen") : qsTr("Ausgaben")
        return statusFilter === "all" ? kind : titleOf(statusFilters, statusFilter) + " · " + kind
    }
    readonly property bool showsAccountMarkers: {
        const sel = sidebarSelection
        if (sel.startsWith("account:")) return false
        if (sel.startsWith("group:")) { const g = groups.find(g => "group:" + g.id === sel); return g ? g.accounts.length > 1 : false }
        if (sel.startsWith("userGroup:")) return userGroupAccountIDs(sel.slice(10)).length > 1
        return Object.keys(accountMarkers).length > 1
    }
    function accountColor(id) { const m = accountMarkers[id]; return m ? m.color : Theme.tertiary }
    function accountSymbol(id) { const m = accountMarkers[id]; return m ? m.symbol : "building.columns" }
    function accountShortLabel(id) { const m = accountMarkers[id]; return m ? m.label : "" }
    function recurringSeries(b) {
        if (!b.recurrence_key) return null
        return recurring.find(s => s.base_key === b.recurrence_key
            && (!s.amount_specific || Math.abs(b.amount_cents - s.amount_cents) * 100 <= Math.abs(s.amount_cents) * 15)) || null
    }

    /// LaunchOptions --screenshot <path>: hides the demo banners (marketing shots).
    readonly property string screenshotPath: {
        const a = Qt.application.arguments, i = a.indexOf("--screenshot")
        return i >= 0 && i + 1 < a.length ? a[i + 1] : ""
    }
    readonly property bool screenshotMode: screenshotPath !== ""

    property TextEdit clipboardHelper: TextEdit { visible: false }
    function copyToClipboard(s) { clipboardHelper.text = s; clipboardHelper.selectAll(); clipboardHelper.copy() }
    /// Booking.clipboardLine (Formatting.swift): tab-separated for spreadsheets.
    function clipboardLine(b) {
        return [Fmt.medium(b.booking_date), b.counterparty || b.merchant_name, b.purpose, b.category_name, b.note, Fmt.clipboard(b.amount_cents)]
            .map(x => (x || "").replace(/[\t\n]/g, " ")).join("\t")
    }

    // MARK: selection / editing
    function selectBooking(id, toggle, extend) {
        const list = bookings.map(b => b.id)
        if (extend && selectedBookingID !== null) {
            const a = list.indexOf(selectedBookingID), b = list.indexOf(id)
            const ids = {}
            for (let i = Math.min(a, b); i <= Math.max(a, b); i++) ids[list[i]] = true
            selectedBookingIDs = ids
            selectedBookingID = id
        } else if (toggle) {
            const ids = Object.assign({}, selectedBookingIDs)
            if (ids[id]) { delete ids[id]; selectedBookingIDs = ids; if (selectedBookingID === id) selectedBookingID = list.find(x => ids[x]) ?? null }
            else { ids[id] = true; selectedBookingIDs = ids; selectedBookingID = id }
        } else {
            const ids = {}; ids[id] = true
            selectedBookingIDs = ids
            selectedBookingID = id
        }
    }
    /// Bearbeiten › Alles auswählen (Strg+A) in the booking list.
    function selectAllBookings() {
        if (!bookings.length || sidebarSelection === "documents") return
        const ids = {}
        for (const b of bookings) ids[b.id] = true
        selectedBookingIDs = ids
        if (selectedBookingID === null || !ids[selectedBookingID]) selectedBookingID = bookings[0].id
    }
    function moveSelection(delta) {
        if (!bookings.length) return
        const i = bookings.findIndex(b => b.id === selectedBookingID)
        const j = Math.max(0, Math.min(bookings.length - 1, i + delta))
        // a plain move replaces a multiple selection (also at the ends of the list)
        const ids = {}
        ids[bookings[j].id] = true
        selectedBookingIDs = ids
        selectedBookingID = bookings[j].id
    }
    /// Select the booking and put the cursor into its note field in the inspector.
    function editNote(b) {
        if (!b) return
        showInspector = true
        selectedBookingID = b.id
        pendingNoteFocus = b.id
    }
    /// Jump to `day` in the booking stream: that day, or the nearest earlier
    /// day with bookings (the balance of a quiet day comes from there).
    function jumpToDay(day) {
        loadBookingsThrough(day)
        const target = dayGroups.find(g => g.date <= day) || dayGroups[dayGroups.length - 1]
        if (target) scrollToDay(target.date)
    }
    /// Raises the list limit so the list reaches back to `day`.
    function loadBookingsThrough(day) {
        if (!isUnlocked || !page || bookings.length >= page.total_count) return
        if (dayGroups.length && day >= dayGroups[dayGroups.length - 1].date) return
        const f = currentFilter()
        if (f.date_from === null || f.date_from < day) f.date_from = day
        const newer = run(() => core("count_transactions", { filter: f }))
        if (newer === undefined) return
        listLimit = Math.max(listLimit, newer + 200)
        reloadBookings()
    }
    function setChecked(on, b) {
        run(() => core("set_transaction_checked", { transaction_id: b.id, checked: on }))
        // With "Neu" / "Geprüft" active the booking leaves the list: keep it in the inspector.
        if (statusFilter !== "all" && selectedBookingID === b.id) stickyBooking = freshBooking(b)
        reloadBookings(); reloadAccounts()
    }
    /// The Buchung menu entry: nothing to do without new bookings, and not in
    /// Belege (there the list would silently mean every account).
    readonly property bool canMarkAllChecked: isUnlocked && newCount > 0 && sidebarSelection !== "documents"
    /// "Alle als gelesen markieren": everything new in the list as filtered now, or –
    /// with `accountIDs`, from a sidebar entry – in those accounts regardless of
    /// period, search and scope. One SQL update off the GUI thread.
    function markAllChecked(accountIDs) {
        if (!isUnlocked) return
        if (!accountIDs && sidebarSelection === "documents") return
        const f = currentFilter()
        if (accountIDs) {
            f.account_ids = accountIDs; f.category_id = null; f.uncategorized_only = false
            f.search = null; f.date_from = null; f.date_to = null; f.direction = "All"
            f.scope = "All"; f.merchant_key = null
        }
        f.checked = false; f.limit = 0; f.offset = 0; f.whole_days = false
        const demo = demoActive
        coreAsync("set_checked_for_filter", { filter: f, checked: true }, ids => {
            if (!isUnlocked || demoActive !== demo) return
            if (!ids.length) { toast = qsTr("Keine neuen Umsätze"); return }
            toast = qsTr("%1 Umsätze als gelesen markiert").arg(ids.length)
            // the selected booking leaves a "Neu" list: keep it in the inspector (like setChecked)
            const b = selectedBooking
            if (statusFilter !== "all" && b && ids.indexOf(b.id) >= 0) stickyBooking = freshBooking(b)
            reloadBookings(); reloadAccounts()
        })
    }
    function setCategory(b, categoryID) { setCategoryFor([b], categoryID) }
    function updateNote(b, note) {
        run(() => core("update_transaction_note", { transaction_id: b.id, note: note }))
        reloadBookings()
    }
    function updateText(b, counterparty, purpose) {
        run(() => core("update_transaction_text", { transaction_id: b.id, counterparty: counterparty, purpose: purpose }))
        reloadBookings()
    }
    function setSalaryFlag(b, flag) {
        run(() => core("set_booking_salary_flag", { booking_id: b.id, flag: flag }))
        // keep the edited booking selected even if it leaves the period
        if (selectedBookingID === b.id) stickyBooking = freshBooking(b)
        refreshSalaryCycle()
        if (period === "sinceSalary") { reloadCategories(); reloadHistory() }
        reloadBookings()
    }
    /// `dates` (MM-DD) only for the interval "Custom".
    function markRecurring(b, interval, dates) {
        run(() => core("mark_booking_recurring", { booking_id: b.id, interval: interval, custom_dates: dates || [] }))
        refreshRecurring(); reloadBookings()
    }
    /// Back to automatic detection (also shows a hidden series again).
    function resetRecurring(seriesKey) { run(() => core("reset_recurring", { series_key: seriesKey })); refreshRecurring(); reloadBookings() }
    function ignoreRecurring(s) { run(() => core("ignore_recurring", { series_key: s.series_key })); refreshRecurring(); reloadBookings() }
    /// [CategoryNode].node(_:) – depth-first lookup.
    function categoryNode(id, nodes) {
        for (const n of (nodes || categoryTree)) {
            if (n.category.id === id) return n
            if (n.children) { const hit = categoryNode(id, n.children); if (hit) return hit }
        }
        return null
    }
    readonly property var selectedBookings: bookings.filter(b => !!selectedBookingIDs[b.id])
    readonly property bool isMultiSelection: Object.keys(selectedBookingIDs).length > 1
    readonly property var flowLabels: ({ Consumption: qsTr("Konsum"), Income: qsTr("Einnahme"), Investment: qsTr("Investment"),
                                         Perk: qsTr("Perk"), Transfer: qsTr("Umbuchung"), Loan: qsTr("Darlehen") })
    readonly property var intervalLabels: ({ Monthly: qsTr("Monatlich"), Quarterly: qsTr("Vierteljährlich"), HalfYearly: qsTr("Halbjährlich"),
                                             Yearly: qsTr("Jährlich"), Custom: qsTr("Individuell") })

    // MARK: - Settings (vault/settings.rs)
    property var settings: []
    function reloadSettings() { run(() => { settings = core("list_settings"); fintsProductIDSource = core("fints_product_id_source") }) }
    property string fintsProductIDSource: ""
    function settingEntry(key) { return settings.find(e => e.key === key) || null }
    function saveSetting(key, value) { run(() => core("set_setting", { key: key, value: value })); reloadSettings() }

    // MARK: - Bank catalog
    readonly property var bankCatalog: core("bank_catalog")
    function descriptor(kind) { return bankCatalog.find(d => d.kind === kind) || null }
    function isMagicDemoLogin(login) { return (login || "").trim().toLowerCase() === "demo" }
    /// Settings a connector still needs (`AppModel.missingSettings(for:)`).
    function missingSettings(c) {
        if (isMagicDemoLogin(c.login_name)) return []
        const d = descriptor(c.connector)
        if (!d) return []
        return d.required_settings.filter(key => {
            if (key === "fints.product_id" && fintsProductIDSource !== "") return false
            const e = settingEntry(key)
            return !(e && e.has_value)
        })
    }
    function connectionStatus(id) { return run(() => core("connection_status", { connection_id: id })) || null }
    /// Amex / Amazon Visa / FNZ / Quirion / Amazon orders: embedded web-portal login.
    function usesPortal(c) { return usesPortalLogin(c) }   // MARK: Web logins

    // MARK: - Adding banks
    /// Adds a login at any FinTS 3.0 bank once the banking policy is fresh and allows it.
    function addFinTsConnection(name, blz, url, login, tanMedium) {
        withFreshBankingPolicy(() => {
            if (!isMagicDemoLogin(login) && !bankingAllowsAdding(bankingGateForKey("fints:" + (blz || "").trim()))) return
            addFinTsConnectionChecked(name, blz, url, login, tanMedium)
        })
    }
    function addConnection(kind, login) {
        withFreshBankingPolicy(() => {
            if (!isMagicDemoLogin(login) && !bankingAllowsAdding(bankingGateForNew(kind))) return
            addConnectionChecked(kind, login)
        })
    }
    function addEnableBankingConnection(aspsp, country, name, label) {
        withFreshBankingPolicy(() => {
            if (!isMagicDemoLogin(label) && !bankingAllowsAdding(bankingGateForNew("EnableBanking"))) return
            addEnableBankingConnectionChecked(aspsp, country, name, label)
        })
    }
    function addFinTsConnectionChecked(name, blz, url, login, tanMedium) {
        if (demoActive && hasOwnVault) useVault(false)
        const id = run(() => core("add_fints_connection", { blz: blz, url: url, display_name: name, login_name: login, tan_medium: tanMedium || "" }))
        afterAdd(id)
    }
    function addConnectionChecked(kind, login) {
        if (demoActive && hasOwnVault) useVault(false)
        const id = run(() => core("add_bank_connection", { connector: kind, display_name: "", login_name: login }))
        afterAdd(id)
    }
    function addEnableBankingConnectionChecked(aspsp, country, name, label) {
        if (demoActive && hasOwnVault) useVault(false)
        const id = run(() => core("add_enable_banking_connection", { aspsp: aspsp, country: country, display_name: name, login_name: label }))
        afterAdd(id)
    }
    /// Fixed catalog entry "Demo-Bank (Test & Vorschau)".
    function addDemoBank() { addFinTsConnection("Demo-Bank", "99999999", "https://demo.invalid/fints", "demo") }
    function afterAdd(id) {
        reloadSettings(); reloadAccounts()
        const conn = connections.find(c => c.id === id)
        if (conn) { toast = qsTr("%1 hinzugefügt").arg(conn.display_name); requestSync(conn) }
    }
    function removeConnection(id) {
        // Its browser session goes too: cookies in the profile and in the vault (MARK: Web logins)
        if (webLoginConnection && webLoginConnection.id === id) webLoginConnection = null
        if ((connections.find(c => c.id === id) || {}).connector === "TradeRepublic") clearTradeRepublicWebData(false, id)
        forgetWebCookies(id)
        run(() => core("delete_bank_connection", { connection_id: id })); reloadAll()
    }
    /// comdirect: switch the login between FinTS and comdirect's own API (keeps accounts, categories, notes).
    function switchComdirectAccess(id) { run(() => core("switch_comdirect_access", { connection_id: id })); reloadAll() }
    function updateConnection(id, name, login) { run(() => core("update_bank_connection", { connection_id: id, display_name: name, login_name: login })); reloadAccounts() }
    function setConnectionPin(id, pin) { run(() => core("set_connection_pin", { connection_id: id, pin: pin })) }

    // MARK: - Sync (AppModel.swift › requestSync … finishSync)
    property var syncingConnectionID: null
    /// The bank dialog in progress (session handle of src/sessions.rs).
    property var activeSession: null
    /// { connection, challenge, waiting, busy, error }
    property var activeChallenge: null
    property var pendingLogin: null          // BankConnection asking for the PIN
    property var setupRequest: null          // { connection, keys }
    property var webLoginConnection: null    // portal login (QtWebEngine)
    property var syncQueue: []
    property int syncBatchTotal: 0
    property var syncBatchSkipped: []
    property int syncGeneration: 0
    readonly property var syncBatchProgress: syncBatchTotal > 1 ? { current: syncBatchTotal - syncQueue.length, total: syncBatchTotal } : null
    readonly property bool canSkipInSyncBatch: syncQueue.length > 0
    property Timer pollTimer: Timer { property var connection; onTriggered: model.pollSession(connection) }

    function requestSync(connection) {
        withFreshBankingPolicy(() => {
            const gate = bankingGate(connection)
            if (gate) {
                statementsAccountID = null
                if (syncBatchTotal > 1 && !gate.all) {
                    syncBatchSkipped = syncBatchSkipped.concat([qsTr("%1 (Sicherheitssperre)").arg(connection.display_name)])
                    syncNextInQueue()
                } else {
                    resetSyncBatch()
                    showBankingGate(gate)
                }
                return
            }
            requestSyncChecked(connection)
        })
    }
    function requestSyncChecked(connection) {
        if (usesPortal(connection)) { webLoginConnection = connection; return }
        const magicDemo = isMagicDemoLogin(connection.login_name)
        if (!isDemo && !magicDemo && connection.connector === "TradeRepublic") {
            const st = connectionStatus(connection.id)
            if (!(st && st.has_session)) { webLoginConnection = connection; return }
        }
        if (!isDemo) {
            const st = connectionStatus(connection.id)
            const missing = missingSettings(connection)
            if (st && (st.has_pin || (connection.connector === "TradeRepublic" && st.has_session)) && missing.length === 0) {
                startSync(connection, ""); return
            }
            if (missing.length) { setupRequest = { connection: connection, keys: missing }; return }
        }
        const d = descriptor(connection.connector)
        const needsSecret = !(d && d.secret_label.startsWith("("))
        if (isDemo || !needsSecret) startSync(connection, isDemo ? "demo" : "")
        else pendingLogin = connection
    }
    function requestSyncAll() {
        requestSyncBatch(connections.filter(c => !usesPortal(c) && !c.all_accounts_archived))
    }
    function requestSyncBatch(batch) {
        if (syncingConnectionID !== null || !batch.length) return
        withFreshBankingPolicy(() => {
            // a sync may have started while the policy was checked
            if (syncingConnectionID !== null) return
            // Logins the banking policy blocks are skipped and named at the end.
            const blocked = batch.filter(c => bankingGate(c) !== null)
            const allowed = batch.filter(c => bankingGate(c) === null)
            if (!allowed.length) {
                if (blocked.length) showBankingGate(bankingGate(blocked[0]))
                return
            }
            syncQueue = allowed.slice(1)
            syncBatchTotal = allowed.length
            syncBatchSkipped = blocked.map(c => qsTr("%1 (Sicherheitssperre)").arg(c.display_name))
            requestSyncChecked(allowed[0])
        })
    }
    function resetSyncBatch() { syncQueue = []; syncBatchTotal = 0; syncBatchSkipped = [] }
    function syncNextInQueue() {
        if (syncQueue.length) {
            const next = syncQueue[0]
            syncQueue = syncQueue.slice(1)
            requestSync(next)   // re-checks the banking policy for every login
            return
        }
        if (syncBatchSkipped.length) {
            const note = qsTr("Übersprungen: %1").arg(syncBatchSkipped.join(", "))
            toast = toast ? toast + " · " + note : note
        }
        resetSyncBatch()
    }
    function startSync(connection, secret) {
        if (usesPortal(connection)) { webLoginConnection = connection; return }
        pendingLogin = null
        syncingConnectionID = connection.id
        const gen = ++syncGeneration
        // Statements only for an account of exactly this login: a stale value
        // would hand this login's PIN to another bank.
        if (statementsAccountID !== null && (!accountsByID[statementsAccountID] || accountsByID[statementsAccountID].connection_id !== connection.id))
            statementsAccountID = null
        const statementsFor = statementsAccountID
        // Kept for the "GiroCrab-Registrierung" retry of a rejected product ID, so the
        // login is not asked again; finishSync takes it and clears it.
        const keepSecret = () => { if (statementsFor === null) failedSyncSecret = secret }
        let id
        try {
            id = statementsFor !== null
                ? core("fetch_account_statements", { account_id: statementsFor, secret: secret, demo: isDemo })
                : core("begin_sync", { connection_id: connection.id, secret: secret, demo: isDemo })
        } catch (e) {
            keepSecret()
            finishSync(e.message, connection)
            return
        }
        activeSession = id
        coreAsync("session_start", { session: id }, step => {
            if (activeSession !== id || gen !== syncGeneration) return   // skipped / cancelled meanwhile
            handleStep(step, connection)
        }, err => { if (activeSession === id) { keepSecret(); finishSync(err, connection) } })
    }
    function handleStep(step, connection) {
        if (step.NeedsChallenge) {
            const c = step.NeedsChallenge.challenge
            activeChallenge = { connection: connection, challenge: c, waiting: false, busy: false, error: "" }
            if (c.kind === "DecoupledPush") schedulePoll(connection, c.poll_interval_seconds)
        } else if (step.StillWaiting) {
            const c = step.StillWaiting.challenge
            activeChallenge = activeChallenge === null
                ? { connection: connection, challenge: c, waiting: true, busy: false, error: "" }
                : Object.assign({}, activeChallenge, { waiting: true, busy: false })
            schedulePoll(connection, c.poll_interval_seconds)
        } else if (step.Finished) {
            const s = step.Finished.summary
            logSync(connection.id, "Ok", "", s.transactions_imported, syncLogSource())
            activeChallenge = null
            syncingConnectionID = null
            activeSession = null
            if (statementsAccountID !== null) {
                const n = Math.max(0, accountDocuments(statementsAccountID).length - statementsCountBefore)
                statementsAccountID = null
                documentsVersion++
                toast = qsTr("%1: %2 neue Kontoauszüge").arg(connection.display_name).arg(n)
            } else {
                toast = syncNotice(connection, s)
            }
            reloadAll()
            syncNextInQueue()
        }
    }
    function syncNotice(connection, s) {
        const parts = [qsTr("%1: %2 neue Buchungen, %3 kategorisiert").arg(connection.display_name).arg(s.transactions_imported).arg(s.transactions_categorized)]
        if (s.new_accounts.length) parts.push(qsTr("Neue Konten: %1").arg(s.new_accounts.join(", ")))
        if (s.revoked_accounts.length) parts.push(qsTr("Kein Zugriff mehr: %1").arg(s.revoked_accounts.join(", ")))
        let text = parts.join(" · ")
        if (s.transactions_skipped_archived) text += " · " + qsTr("%1 Buchungen archivierter Konten übersprungen").arg(s.transactions_skipped_archived)
        return text
    }
    function schedulePoll(connection, interval) {
        pollTimer.stop()
        pollTimer.connection = connection
        pollTimer.interval = Math.max(interval || 1, 1) * 1000
        pollTimer.start()
    }
    function pollSession(connection) {
        if (activeTransfer !== null) { pollTransfer(connection); return }
        const id = activeSession
        if (id === null) return
        coreAsync("session_poll", { session: id }, step => { if (activeSession === id) handleStep(step, connection) },
                  err => { if (activeSession === id) finishSync(err, connection) })
    }
    function submitCode(code) {
        if (activeTransfer !== null && activeChallenge) { submitTransferCode(code); return }
        const id = activeSession, ch = activeChallenge
        if (id === null || !ch) return
        activeChallenge = Object.assign({}, ch, { busy: true, error: "" })
        coreAsync("session_submit", { session: id, code: code }, step => { if (activeSession === id) handleStep(step, ch.connection) },
                  err => { if (activeSession === id) finishSync(err, ch.connection) })
    }
    /// Cancel button of the TAN sheet: in a batch drop this login and go on.
    function skipCurrentSync() {
        if (syncBatchTotal <= 1 || activeTransfer !== null) { cancelSync(); return }
        const current = connections.find(c => c.id === syncingConnectionID)
        const name = activeChallenge ? activeChallenge.connection.display_name : (current ? current.display_name : "")
        if (name) syncBatchSkipped = syncBatchSkipped.concat([name])
        pollTimer.stop()
        const s = activeSession
        activeSession = null; activeChallenge = null
        statementsAccountID = null
        const gen = ++syncGeneration
        // End the bank dialog first (the next login may be the same bank); syncingConnectionID
        // stays set until then. "Alle abbrechen", a lock or a new sync meanwhile own the state.
        const next = () => {
            if (gen !== syncGeneration) return
            syncingConnectionID = null
            syncNextInQueue()
        }
        if (s === null) { next(); return }
        coreAsync("session_cancel", { session: s }, next, next)
    }
    function cancelAllSync() { setupRequest = null; webLoginConnection = null; cancelSync() }
    function cancelSync() {
        if (activeTransfer !== null) { cancelTransfer(); return }
        pollTimer.stop()
        const s = activeSession
        if (s !== null && syncingConnectionID !== null)
            logSync(syncingConnectionID, "Cancelled", qsTr("Vom Benutzer abgebrochen"), 0, syncLogSource())
        activeSession = null; activeChallenge = null; pendingLogin = null; syncingConnectionID = null
        statementsAccountID = null
        syncGeneration++
        resetSyncBatch()
        if (s !== null) coreAsync("session_cancel", { session: s }, null, () => {})
    }
    function cancelPendingLogin() { const c = pendingLogin; pendingLogin = null; skipPrompt(c) }
    function cancelSetupRequest() { const r = setupRequest; setupRequest = null; skipPrompt(r ? r.connection : null) }
    function cancelWebLogin() { const c = webLoginConnection; webLoginConnection = null; skipPrompt(c) }
    function skipPrompt(connection) {
        // A cancelled "Kontoauszüge abrufen" must never carry over to the next sync:
        // it would send that login's PIN for another bank's account.
        statementsAccountID = null
        if (syncBatchTotal <= 1) { resetSyncBatch(); return }
        if (connection) syncBatchSkipped = syncBatchSkipped.concat([connection.display_name])
        syncNextInQueue()
    }
    /// "Speichern & abrufen" in the setup sheet.
    function completeSetup(request, values) {
        for (const k in values) if ((values[k] || "").trim() !== "") run(() => core("set_setting", { key: k, value: values[k] }))
        reloadSettings()
        setupRequest = null
        const c = connections.find(x => x.id === request.connection.id) || request.connection
        requestSync(c)
    }
    /// Errors of a step: `\u0001{json}` keeps the CoreError kind (see dispatch.rs).
    function parseCoreError(err) {
        if (typeof err === "string" && err.charCodeAt(0) === 1) { try { return JSON.parse(err.slice(1)) } catch (e) {} }
        return { kind: "", message: String(err) }
    }
    property var errorRetry: null
    /// Extra actions of the error alert ([{ title, action }]) after the bank rejected the
    /// FinTS registration in use: replace the own one, or switch to the other one.
    property var errorAlternatives: []
    /// PIN of the sync that just failed (memory only, cleared in finishSync).
    property string failedSyncSecret: ""
    function finishSync(err, connection) {
        const e = parseCoreError(err)
        logSync(connection.id, "Error", e.message, 0, syncLogSource())   // source before statementsAccountID is cleared
        const retrySecret = failedSyncSecret
        failedSyncSecret = ""
        statementsAccountID = null
        pollTimer.stop()
        activeSession = null; activeChallenge = null; syncingConnectionID = null
        resetSyncBatch()
        if (e.kind === "BrowserLoginRequired") { toast = e.message; webLoginConnection = connection; return }
        if (e.kind === "MissingSetting") {
            const keys = missingSettings(connection)
            const m = /key: "([^"]+)"/.exec(e.debug || "")
            if (m && keys.indexOf(m[1]) < 0) keys.unshift(m[1])
            setupRequest = { connection: connection, keys: keys }
            return
        }
        errorTitle = qsTr("Abruf von „%1“ fehlgeschlagen").arg(connection.display_name)
        errorRetry = () => { const c = connections.find(x => x.id === connection.id); if (c) requestSync(c) }
        errorAlternatives = productIDAlternatives(connection, e, retrySecret)
        errorMessage = e.message
    }
    /// The bank refused the FinTS product registration (9078, or 9010 as some banks answer).
    /// The core reports the FIRST code of the reply, so both are also looked for in the message.
    function isProductIDRejection(e) { return e.kind === "Bank" && /9010|9078/.test((e.debug || "") + " " + (e.message || "")) }
    /// "Mit … erneut versuchen" after a bank rejected the FinTS registration in use.
    function productIDAlternatives(conn, e, secret) {
        const d = descriptor(conn.connector)
        if (!isProductIDRejection(e) || !d || d.required_settings.indexOf("fints.product_id") < 0) return []
        const own = settingEntry("fints.product_id")
        const hasOwn = !!(own && own.has_value)
        const out = []
        if (fintsProductIDSource === "builtin") {
            // GiroCrab's registration was refused: the own one goes into Settings, then the account is fetched again by hand.
            out.push({ title: hasOwn ? qsTr("Eigene Registrierung ersetzen …") : qsTr("Eigene Registrierung eintragen …"), action: enterOwnProductID })
        } else if (fintsProductIDSource === "own") {
            out.push({ title: qsTr("Eigene Registrierung ersetzen …"), action: enterOwnProductID })
            if (fintsBuiltinAvailable) {
                out.push({ title: qsTr("Mit GiroCrab-Registrierung erneut versuchen"), action: () => {
                    setFintsProductIDMode("builtin")
                    const c = connections.find(x => x.id === conn.id)
                    if (!c) return
                    // Same login and PIN as the failed attempt: only the registration changes.
                    if (secret !== "" && bankingGate(c) === null) startSync(c, secret)
                    else requestSync(c)
                } })
            }
        }
        return out
    }
    /// After a rejected registration: switch to the own one and open Settings › Banken.
    function enterOwnProductID() {
        setFintsProductIDMode("own")
        openSettings("banks")
    }

    /// Enable Banking redirect (ConsentRedirect.defaultURL unless configured).
    function consentRedirectURL() {
        const e = settingEntry("enablebanking.redirect_url")
        const v = e ? (e.value || "").trim() : ""
        return v || "https://localhost/girocrab/callback"
    }

    // MARK: - Depot, loans, investment dashboard
    property var dashboard: null
    function reloadDashboard() { run(() => { dashboard = core("investment_dashboard", { months: 6 }) }) }
    function holdings(accountID) { return run(() => core("list_holdings", { account_id: accountID })) || [] }
    function setAccountInitialBalance(accountID, cents) {
        run(() => core("set_account_initial_balance", { account_id: accountID, cents: cents }))
        reloadAccounts()
    }
    function isDepot(a) { return a !== null && (a.kind === "Brokerage" || a.name.toLowerCase().indexOf("depot") >= 0) }

    // MARK: - Manual loans (ManualLoansUI.swift) and Startsaldo (OpeningBalanceUI.swift)
    // A manual loan has no account at the bank: the core keeps a Stand (balance at the
    // end of a date), an optional interest rate and a search rule; bookings are linked
    // by the rule or by hand. Undo (Bearbeiten › Widerrufen) is not ported.

    /// ManualLoanStore: [ManualLoan] and transaction id -> LoanLink, refreshed with the accounts.
    property var loans: []
    property var loanLinks: ({})
    /// LoanEditorRequest { mode: "create" | "edit" | "anchor", accountId, draft } or null.
    property var loanEditor: null
    /// OpeningBalanceRequest { accountId } or null.
    property var openingBalanceRequest: null
    property int loanGeneration: 0
    function indexLoanLinks(links) {
        const m = {}
        for (const l of links) if (m[l.transaction_id] === undefined) m[l.transaction_id] = l
        return m
    }
    /// Off the GUI thread (both calls walk every loan's bookings); the last call wins.
    function reloadLoans() {
        if (!isUnlocked) return
        const gen = ++loanGeneration
        coreAsync("list_manual_loans", {}, l => {
            if (gen !== loanGeneration) return
            coreAsync("list_loan_links", {}, links => {
                if (gen !== loanGeneration) return
                loans = l
                loanLinks = indexLoanLinks(links)
            })
        })
    }
    /// Synchronous reload after a loan edit; cancels a running background reload.
    function reloadLoansNow() {
        ++loanGeneration
        if (!isUnlocked) return
        run(() => {
            loans = core("list_manual_loans")
            loanLinks = indexLoanLinks(core("list_loan_links"))
        })
    }
    function manualLoan(accountId) { return loans.find(l => l.account_id === accountId) || null }
    /// Manual loans that bookings can be assigned to (not archived).
    readonly property var assignableLoans: loans.filter(l => { const a = accountsByID[l.account_id]; return a ? a.archived_unix === null : false })
    function loanLink(b) { return b ? (loanLinks[b.id] || null) : null }
    /// Links (or with `null` unlinks) a booking.
    function assignLoan(loanId, b) {
        const link = loanLink(b)
        const previous = link ? link.loan_account_id : null
        if (previous === loanId) return
        if (run(() => { core("set_booking_loan", { transaction_id: b.id, loan_account_id: loanId }); return true }) === undefined) return
        const name = b.merchant.name === "" ? b.counterparty : b.merchant.name
        const loan = loanId !== null ? manualLoan(loanId) : null
        toast = loan ? qsTr("„%1“ dem Darlehen „%2“ zugeordnet").arg(name).arg(loan.setup.name)
                     : qsTr("Zuordnung von „%1“ aufgehoben").arg(name)
        reloadAccounts(); reloadLoansNow(); reloadBookings()
    }
    /// Creates or changes a manual loan; returns the account id. Throws on failure.
    function saveLoan(setup, accountId) {
        let id = accountId
        if (accountId !== null) core("update_manual_loan", { account_id: accountId, setup: setup })
        else id = core("create_manual_loan", { setup: setup })
        reloadAccounts(); reloadLoansNow(); reloadBookings(); reloadHistory()
        return id
    }
    function openLoanEditor(mode, accountId, draft) {
        loanEditor = { mode: mode, accountId: accountId === undefined ? null : accountId, draft: draft || null }
    }
    /// "Neues Darlehen aus Buchung …": name and rule taken from the counterparty.
    function openLoanEditorFromBooking(b) {
        const name = b.counterparty === "" ? b.merchant.name : b.counterparty
        const quoted = name.replace(/"/g, "")
        const d = Fmt.date(b.booking_date)
        if (d) d.setDate(d.getDate() - 1)
        openLoanEditor("create", null, {
            name: name, original_cents: null,
            anchor_date: Fmt.iso(d || new Date()),
            anchor_balance_cents: 0, interest_rate_ppm: null,
            match_expr: quoted === "" ? "" : "name:\"" + quoted + "\""
        })
    }
    /// ManualLoanAccountMenu: "Darlehen bearbeiten …" / "Stand neu setzen …" apply.
    function isEditableManualLoan(a) { return !!a && a.kind === "Loan" && manualLoan(a.id) !== null && a.archived_unix === null }

    /// OpeningBalanceMenuItem: "Startsaldo …" applies to computed balances only.
    function canSetOpeningBalance(a) { return !!a && a.balance_derived && a.archived_unix === null }
    function openOpeningBalance(a) { openingBalanceRequest = { accountId: a.id } }
    /// Sets (or clears with `null`) the Startsaldo; `date` "" = all bookings. Throws on failure.
    function setOpeningBalance(accountId, cents, date) {
        core("set_account_opening_balance", { account_id: accountId, cents: cents, date: date })
        reloadAccounts(); reloadHistory()
    }
    /// What a Startsaldo at `date` would count, off the GUI thread; nothing is stored.
    function previewOpeningBalance(accountId, date, done, failed) {
        coreAsync("preview_account_opening_balance", { account_id: accountId, date: date }, done, failed)
    }

    // MARK: - Documents (DocumentsUI.swift / AccountDocumentsUI.swift)
    /// Bumped whenever documents change, so lists re-read them.
    property int documentsVersion: 0
    property var documentsAccountFilter: null
    property var statementsAccountID: null
    property int statementsCountBefore: 0
    property var accountDocumentsFor: null      // AccountDocumentsSheet
    function openAccountDocuments(a) { accountDocumentsFor = a }
    function documents(b) { void documentsVersion; return b && isUnlocked ? (run(() => core("list_documents_for_booking", { booking_id: b.id })) || []) : [] }
    function allDocuments(search, unlinkedOnly, accountId) {
        void documentsVersion
        if (!isUnlocked) return []
        return run(() => core("list_all_documents", { filter: { account_id: accountId, doc_type: null, search: search || null, unlinked_only: unlinkedOnly } })) || []
    }
    function accountDocuments(accountID) { return allDocuments("", false, accountID) }
    function documentsChanged() { documentsVersion++; reloadBookings() }
    /// QuickLook: a private copy opened in the default viewer.
    function quickLook(d) {
        const path = run(() => core("document_temp_file", { doc_id: d.id, mime_type: d.mime_type }))
        if (path) Qt.openUrlExternally("file://" + path)
    }
    /// Space in the list / Buchung › Beleg in Quick Look anzeigen: the booking's first document.
    /// `false` when it has none.
    function quickLookFirstDocument(b) {
        const d = documents(b)[0]
        if (!d) return false
        quickLook(d)
        return true
    }
    function documentFileURL(d) {
        const path = run(() => core("document_temp_file", { doc_id: d.id, mime_type: d.mime_type }))
        return path ? "file://" + path : ""
    }
    /// DocumentPreviewSheet "Sichern …": writes the document to `path`.
    function exportDocument(d, path) {
        try {
            core("export_document", { doc_id: d.id, dest_path: path })
        } catch (e) {
            errorTitle = qsTr("Dokument konnte nicht gesichert werden")
            errorMessage = e.message
        }
    }
    function linkDocument(d, bookingID) { run(() => core("link_document", { doc_id: d.id, booking_id: bookingID })); documentsChanged() }
    function deleteDocument(d) { run(() => core("delete_document", { doc_id: d.id })); documentsChanged() }
    function exportAllDocuments(folderPath) {
        const n = run(() => core("export_all_documents", { dest_dir: folderPath }))
        if (n !== undefined) toast = qsTr("%1 Belege nach „%2/GiroCrab-Belege“ exportiert").arg(n).arg(folderPath.split("/").pop())
    }
    function localPath(url) { return decodeURIComponent(String(url).replace(/^file:\/\//, "")) }
    function attach(urls, b) {
        let n = 0
        for (const u of urls) if (run(() => core("attach_file_to_booking", { booking_id: b.id, path: localPath(u) })) !== undefined) n++
        if (n > 0) toast = qsTr("%1 Belege an „%2“ angehängt").arg(n).arg(b.merchant_name)
        documentsChanged()
    }
    /// Dropped anywhere: the core matches amount / date / merchant (PDF text, and for
    /// photos the tesseract OCR text, as hint). Off the GUI thread, one file after another.
    function dropAnywhere(urls) {
        const paths = urls.map(u => localPath(u))
        const linked = []
        let unmatched = 0
        const finish = () => {
            if (linked.length) toast = qsTr("Beleg zugeordnet: %1").arg(linked.join(", "))
            else if (unmatched > 0) toast = qsTr("Kein passender Umsatz gefunden – in „Belege & PostBox“ abgelegt")
            documentsChanged()
        }
        const next = i => {
            if (i >= paths.length) { finish(); return }
            coreAsync("auto_match_file", { path: paths[i] }, hit => {
                if (hit) linked.push(hit); else unmatched++
                next(i + 1)
            }, err => {
                errorTitle = qsTr("Beleg konnte nicht zugeordnet werden")
                errorMessage = parseCoreError(err).message
                next(i + 1)
            })
        }
        next(0)
    }
    function canFetchStatements(a) {
        return a && a.connector && a.kind !== "Loan" && ["VolksbankKasselGoettingen", "Direkt1822", "FinTsGeneric"].indexOf(a.connector) >= 0
    }
    function fetchStatements(a) {
        if (syncingConnectionID !== null) return
        const c = connections.find(x => x.id === a.connection_id)
        if (!c) return
        statementsAccountID = a.id
        statementsCountBefore = accountDocuments(a.id).length
        requestSync(c)
    }
    function autoStatements(a) { return run(() => core("auto_statements_enabled", { account_id: a.id })) || false }
    function setAutoStatements(a, on) { run(() => core("set_auto_statements", { account_id: a.id, enabled: on })) }
    function docSymbol(d) {
        switch (d.doc_type) {
        case "abrechnung": return "chart.line.uptrend.xyaxis.circle"
        case "kontoauszug": return "list.bullet.rectangle"
        case "postbox": return "tray.full"
        case "steuer": return "percent"
        default: return d.mime_type.startsWith("image") ? "photo" : "doc.text.fill"
        }
    }
    function byteCount(n) { return Fmt.byteCount(n) }

    // MARK: - Sidebar drag & drop (AccountGroupsModel.swift)
    readonly property var namedUserGroups: userGroups.filter(g => !g.is_ungrouped)
    function afterGroupChange() { reloadAccounts(); reloadHistory(); reloadBookings() }
    function moveAccount(accountID, uuid, index) {
        const target = uuid ? uuid : null
        if (run(() => { core("move_account_to_group", { account_id: accountID, group_uuid: target, index: index === undefined || index === null ? null : Math.max(0, index) }); return true }))
            afterGroupChange()
    }
    function setUserGroupParent(g, parent) {
        if (g.is_ungrouped) return
        if (run(() => { core("set_user_group_parent", { uuid: g.uuid, parent_uuid: parent }); return true })) {
            if (parent && collapsedUserGroups[parent]) toggleCollapsedUserGroup(parent)
            afterGroupChange()
        }
    }
    function reorderUserGroups(uuids) { run(() => core("reorder_user_groups", { uuids: uuids.filter(u => u) })); reloadAccounts() }
    function canDropGroup(uuid, target, into) {
        if (!uuid || userGroupSubtree(uuid).some(g => g.uuid === target.uuid)) return false
        return !(into && target.is_ungrouped)
    }
    /// A group dropped onto `target`: right above it as its sibling (`before`) or into it.
    function dropUserGroup(uuid, target, before) {
        const moving = userGroups.find(g => g.uuid === uuid)
        if (!uuid || uuid === target.uuid || !moving || userGroupSubtree(uuid).some(g => g.uuid === target.uuid)) return false
        const parent = target.is_ungrouped ? null : (before ? target.parent_uuid : target.uuid)
        if ((moving.parent_uuid || null) !== parent) setUserGroupParent(moving, parent)
        if (target.is_ungrouped || before) {
            const order = namedUserGroups.map(g => g.uuid).filter(u => u !== uuid)
            const at = target.is_ungrouped ? order.length : (order.indexOf(target.uuid) < 0 ? order.length : order.indexOf(target.uuid))
            order.splice(at, 0, uuid)
            reorderUserGroups(order)
        }
        return true
    }
    /// GroupDrag.insertionIndex
    function insertionIndex(row, below, from) {
        const at = below ? row + 1 : row
        return from !== null && from !== undefined && from >= 0 && from < at ? at - 1 : at
    }
    property var dragPayload: null
    property string dragLabel: ""
    property point dragScenePos: Qt.point(0, 0)
    property var dropLine: null
    /// The pointer was released: the sidebar's drag image delivers the drop, then clears the state.
    signal dragEnded()

    // MARK: - account groups (AccountGroupsModel.swift, SidebarView.swift, CommandPalette.swift)
    /// Sidebar state of AppModel.swift (UserDefaults keys `sidebar.*`).
    /// Read and written with value()/setValue(): bound properties of a Settings with a
    /// category got their declared default written back on exit.
    property Settings sidebarDefaults: Settings {
        category: "sidebar"
        /// stored JSON array → `{ key: true }` set
        function loadSet(key) {
            const out = {}
            try { for (const k of JSON.parse(value(key, "[]"))) out[k] = true } catch (e) {}
            return out
        }
    }
    /// `@AppStorage("showAccountAnalytics")` (BookingListView) and `@AppStorage("chartColorPalette")` (PlanningUI).
    property Settings uiDefaults: Settings {
        property bool showAccountAnalytics: false
        property string chartColorPalette: "girocrab"
    }
    readonly property bool hasUserGroups: userGroups.some(g => !g.is_ungrouped)
    readonly property bool hasArchivedAccounts: allAccounts.some(a => a.archived_unix !== null)
    /// GroupDialog: { kind: "create", movingAccount, parent } | { kind: "rename", group } | { kind: "renameAccount", account }
    /// | { kind: "delete", group } | { kind: "merge", from, into } – null = none.
    property var groupDialog: null
    /// SidebarDialog: { kind: "archiveAccount" | "deleteAccount", account } | { kind: "removeConnection", id } – null = none.
    property var sidebarDialog: null
    /// IconColorTarget of an account or group: { type: "account", id } | { type: "group", uuid } (categories: iconColorCategoryID).
    property var iconColorTarget: null
    property bool showGroupManager: false
    property bool showCommandPalette: false
    function openGroupManager() { showGroupManager = true }

    function userGroupByUUID(uuid) { return userGroups.find(g => g.uuid === uuid) || null }
    function account(id) { return accountsByID[id] || null }
    /// Groups `g` can be moved into: all but itself and its own subgroups.
    function parentCandidates(g) {
        const own = userGroupSubtree(g.uuid).map(x => x.uuid)
        return namedUserGroups.filter(x => own.indexOf(x.uuid) < 0)
    }
    /// A name in a MenuItem / Action text: a literal "&" must be "&&" (Qt reads "&" as a mnemonic).
    function menuText(s) { return (s || "").split("&").join("&&") }
    /// UserGroup.indentedName
    function indentedName(g) { return " ".repeat(g.depth) + g.name }
    /// Another group with this name (case-insensitive), if any.
    function userGroupNamed(name, exceptUUID) {
        const key = name.trim().toLowerCase()
        return namedUserGroups.find(g => g.uuid !== exceptUUID && g.name.toLowerCase() === key) || null
    }
    function uncollapseUserGroup(uuid) { if (collapsedUserGroups[uuid]) toggleCollapsedUserGroup(uuid) }

    /// Creates a group (and moves `accountID` into it). Returns the uuid.
    function createUserGroup(name, accountID, parent) {
        const uuid = run(() => {
            const u = core("create_user_group", { name: name, sf_symbol: "folder" })
            if (parent) { core("set_user_group_parent", { uuid: u, parent_uuid: parent }); uncollapseUserGroup(parent) }
            if (accountID !== null && accountID !== undefined) core("move_account_to_group", { account_id: accountID, group_uuid: u, index: null })
            return u
        })
        if (!uuid) return null
        setAccountView("byGroup")
        uncollapseUserGroup(uuid)
        afterGroupChange()
        return uuid
    }
    /// `changes`: { name, symbol, includeInTotal } (missing = unchanged).
    function updateUserGroup(g, changes) {
        if (g.is_ungrouped) return
        if (run(() => { core("update_user_group", { uuid: g.uuid, name: changes.name ?? g.name, sf_symbol: changes.symbol ?? g.sf_symbol,
                                                    include_in_total: changes.includeInTotal ?? g.include_in_total }); return true }))
            afterGroupChange()
    }
    function setUserGroupColor(g, hex) {
        if (g.is_ungrouped) return
        if (run(() => { core("set_user_group_color", { uuid: g.uuid, color_hex: hex }); return true })) afterGroupChange()
    }
    /// Renames a group; on a name clash nothing changes and the merge question is returned.
    function renameUserGroup(g, name) {
        const other = userGroupNamed(name, g.uuid)
        if (other) return { kind: "merge", from: g, into: other }
        updateUserGroup(g, { name: name })
        return null
    }
    function mergeUserGroups(from, into) {
        if (from.is_ungrouped || into.is_ungrouped) return
        if (!run(() => { core("merge_user_groups", { from_uuid: from.uuid, into_uuid: into.uuid }); return true })) return
        if (sidebarSelection === "userGroup:" + from.uuid) sidebarSelection = "userGroup:" + into.uuid
        if (collapsedUserGroups[from.uuid]) toggleCollapsedUserGroup(from.uuid)
        afterGroupChange()
        toast = qsTr("„%1“ mit „%2“ zusammengeführt").arg(from.name).arg(into.name)
    }
    function deleteUserGroup(g) {
        if (g.is_ungrouped) return
        if (!run(() => { core("delete_user_group", { uuid: g.uuid }); return true })) return
        if (sidebarSelection === "userGroup:" + g.uuid) sidebarSelection = "all"
        if (collapsedUserGroups[g.uuid]) toggleCollapsedUserGroup(g.uuid)
        afterGroupChange()
        toast = qsTr("Gruppe „%1“ gelöscht").arg(g.name)
    }
    function renameAccount(id, name) {
        if (run(() => { core("rename_account", { account_id: id, name: name }); return true })) { reloadAccounts(); reloadBookings() }
    }
    function setAccountColor(id, hex) {
        if (run(() => { core("set_account_color", { account_id: id, color_hex: hex }); return true })) { reloadAccounts(); reloadBookings() }
    }
    function setAccountSymbol(id, symbol) {
        if (run(() => { core("set_account_symbol", { account_id: id, sf_symbol: symbol }); return true })) { reloadAccounts(); reloadBookings() }
    }
    function resetAccountSymbol(id) {
        if (run(() => { core("reset_account_symbol", { account_id: id }); return true })) { reloadAccounts(); reloadBookings() }
    }
    /// Archives ("Das Konto wurde aufgelöst") or reactivates an account.
    function setAccountArchived(a, archived) {
        run(() => {
            core("set_account_archived", { account_id: a.id, archived: archived })
            toast = archived ? qsTr("„%1“ archiviert").arg(a.name) : qsTr("„%1“ reaktiviert").arg(a.name)
        })
        reloadAll()
    }
    /// Deletes one archived account incl. bookings/documents/holdings.
    function deleteAccount(id) {
        run(() => core("delete_account", { account_id: id }))
        if (sidebarSelection === "account:" + id) sidebarSelection = "all"
        reloadAll()
    }
    /// The accounts of group `uuid` in a new order (group manager).
    function reorderAccounts(uuid, ids) {
        run(() => core("reorder_accounts_in_group", { group_uuid: uuid ? uuid : null, account_ids: ids }))
        reloadAccounts()
    }
    /// "Konten abrufen" of a group: the logins behind its accounts (subgroups included), each once.
    function groupSyncConnections(g) {
        const ids = {}
        for (const x of userGroupSubtree(g.uuid))
            for (const a of x.accounts) if (a.archived_unix === null && a.connection_id !== null) ids[a.connection_id] = true
        return connections.filter(c => ids[c.id] && !usesPortal(c))
    }
    function requestSyncGroup(g) { requestSyncBatch(groupSyncConnections(g)) }
    /// "Ohne Gruppe" for the group manager: always there, also when every account is in a group.
    readonly property var ungroupedForSettings: userGroups.find(g => g.is_ungrouped) || {
        uuid: "", name: qsTr("Ohne Gruppe"), sf_symbol: "tray", color_hex: "", sort_order: 2147483647, include_in_total: true,
        in_total: true, is_ungrouped: true, parent_uuid: null, depth: 0, balance_cents: 0, accounts: [] }
    /// Accounts that can be added to group `uuid`: those without a group first, then
    /// the members of every other group; archived accounts are left out.
    function addableAccounts(uuid) {
        const others = userGroups.filter(g => g.uuid !== uuid)
        return others.filter(g => g.is_ungrouped).concat(others.filter(g => !g.is_ungrouped)).map(g => {
            const active = g.accounts.filter(a => a.archived_unix === null)
            return active.length ? { id: g.uuid, title: g.is_ungrouped ? qsTr("Ohne Gruppe") : g.name, accounts: active } : null
        }).filter(x => x)
    }
    /// IBAN, else account number, else bank.
    function accountIdentity(a) {
        if (a.iban) return Fmt.iban(a.iban)
        if (a.account_number) return qsTr("Konto %1").arg(a.account_number)
        return a.bank_name
    }
    function accountDetail(a) {
        const id = accountIdentity(a)
        return a.archived_unix !== null ? qsTr("Archiviert · %1").arg(id) : id
    }
    /// "Keine Konten" / "1 Konto" / "3 Konten".
    function accountCountText(n) { return n === 0 ? qsTr("Keine Konten") : n === 1 ? qsTr("1 Konto") : qsTr("%1 Konten").arg(n) }
    /// The confirmation text of "Gruppe löschen …" (AccountGroupsUI.swift › deleteMessage).
    function deleteMessage(g) {
        const parent = g.parent_uuid ? userGroupByUUID(g.parent_uuid) : null
        const subgroups = userGroupSubtree(g.uuid).length - 1
        const target = parent ? parent.name : qsTr("Ohne Gruppe")
        const parts = []
        const n = g.accounts.length
        if (n === 0) { if (subgroups === 0) return qsTr("Die Gruppe ist leer.") }
        else if (n === 1) parts.push(qsTr("Das Konto wird nach „%1“ verschoben.").arg(target))
        else parts.push(qsTr("%1 Konten werden nach „%2“ verschoben.").arg(n).arg(target))
        if (subgroups > 0)
            parts.push(parent ? qsTr("Die Untergruppen bleiben erhalten und rücken nach „%1“.").arg(target)
                              : qsTr("Die Untergruppen bleiben erhalten und rücken auf die oberste Ebene."))
        parts.push(qsTr("Es werden keine Konten oder Buchungen gelöscht."))
        return parts.join(" ")
    }
    /// AccountCopyMenu: BIC from the Bundesbank BLZ list (German IBANs only).
    function bicForIban(iban) { try { return iban ? core("bic_for_iban", { iban: iban }) : null } catch (e) { return null } }
    function accountBankDetails(a, bic) {
        const bank = bic && a.bank_name ? "BIC: " + bic + " (" + a.bank_name + ")" : bic ? "BIC: " + bic : a.bank_name ? "Bank: " + a.bank_name : ""
        return [a.owner ? "Name: " + a.owner : "", "IBAN: " + Fmt.iban(a.iban), bank].filter(x => x).join("\n")
    }

    // MARK: - Banking policy ("Sicherheitssperre", BankingPolicy.swift → src/banking_policy.rs)
    property var bankingPolicy: ({ enabled: false, gate: null, message: null })
    readonly property var bankingGateAll: bankingPolicy.gate
    property bool bankingPolicyChecking: false
    /// `withFreshBankingPolicy`: every bank entry point refreshes first (fresh for 15 min).
    function withFreshBankingPolicy(then, force) {
        bankingPolicyChecking = true
        coreAsync("banking_policy_refresh", { force: !!force }, st => { bankingPolicyChecking = false; bankingPolicy = st; if (then) then() },
                  err => { bankingPolicyChecking = false; if (then) then() })
    }
    /// The block for a connector key (`fints:<BLZ>`, `enablebanking:<country>:<bank>`, …) as
    /// { reason, all, …, title, detail, message } (BankingGate), or null.
    function bankingGateForKey(key) {
        const g = bankingPolicy.gate
        if (!g) return null
        const full = Object.assign({}, g, { title: bankingPolicy.title, detail: bankingPolicy.detail, message: bankingPolicy.message })
        if (g.all) return full
        return g.connector_ids.some(id => { id = id.trim(); return id !== "" && (key === id || key.startsWith(id + ":")) }) ? full : null
    }
    /// Why this login may not contact its bank (null = allowed).
    function bankingGate(connection) {
        if (!connection || isMagicDemoLogin(connection.login_name) || !bankingPolicy.gate) return null
        let key
        try { key = core("connection_key", { connection_id: connection.id }) }
        catch (e) { key = core("connector_kind_key", { kind: connection.connector }) }
        return bankingGateForKey(key)
    }
    /// Block for the login of an account (transfers).
    function bankingGateForAccount(accountID) {
        const a = accountID === null || accountID === undefined ? null : accountsByID[accountID]
        const c = a ? connections.find(x => x.id === a.connection_id) : null
        return c ? bankingGate(c) : null
    }
    /// Block for a login that is about to be added.
    function bankingGateForNew(kind) { return bankingPolicy.gate ? bankingGateForKey(core("connector_kind_key", { kind: kind })) : null }
    /// Shows the reason and returns false if adding is blocked.
    function bankingAllowsAdding(gate) {
        if (!gate) return true
        showBankingGate(gate)
        return false
    }
    /// showError(gate.title, gate.detail)
    function showBankingGate(gate) {
        errorTitle = gate.title || bankingGateTitle(gate)
        errorMessage = gate.detail || gate.message || ""
    }
    readonly property bool bankingBlocksAll: bankingPolicy.gate !== null && bankingPolicy.gate !== undefined && bankingPolicy.gate.all
    function bankingGateTitle(g) { return g.reason === "checkUnavailable" ? qsTr("Sicherheitsprüfung nicht möglich") : qsTr("Bankverbindungen gesperrt") }
    // MARK: - Rules & categories
    // CategorizerSheet, RuleEditorView, NewCategoryDialog, category context menu,
    // BudgetEditorSheet, SplitSheet (AppModel.swift › Editing, PlanningUI.swift).

    property bool showCategorizer: false
    property bool showRuleEditor: false
    /// Rule the editor opens with (`openRuleEditor(from:)`), null = none selected.
    property var ruleDraft: null
    property var rules: []
    /// NewCategoryRequest: `{ parent: id | null }`, null = no sheet.
    property var newCategoryRequest: null
    /// Category whose "Umbenennen …" / "Kategorie löschen …" dialog is open.
    property var renameCategoryTarget: null
    property var deleteCategoryTarget: null
    /// Category whose BudgetEditorSheet is open.
    property var budgetCategoryID: null
    /// Category whose "Symbol & Farbe" popover is open.
    property var iconColorCategoryID: null
    /// The booking whose SplitSheet is open.
    property var splitBooking: null
    readonly property var colorPalette: core("account_color_palette")
    /// AccountColorNames.names
    readonly property var colorNames: ({
        "#2563EB": qsTr("Blau"), "#D97706": qsTr("Bernstein"), "#059669": qsTr("Grün"), "#DB2777": qsTr("Pink"),
        "#7C3AED": qsTr("Violett"), "#0891B2": qsTr("Cyan"), "#DC2626": qsTr("Rot"), "#65A30D": qsTr("Limette"),
        "#C026D3": qsTr("Fuchsia"), "#EA580C": qsTr("Orange"), "#4F46E5": qsTr("Indigo"), "#0D9488": qsTr("Petrol")
    })

    function reloadRules() {
        if (!isUnlocked) return
        run(() => { rules = core("list_rules") })
    }
    function categoryByID(id) { return id === null || id === undefined ? null : (categories.find(c => c.id === id) || null) }

    /// One category for several bookings (multiple selection).
    function setCategoryFor(list, categoryID) {
        if (!list.length) return
        run(() => { for (const b of list) core("set_transaction_category", { transaction_id: b.id, category_id: categoryID }) })
        reloadAccounts(); reloadCategories(); reloadBookings(); reloadPlanning()
        // rule counts and the investment dashboard (Swift: rulesStale / dashboardStale)
        if (showRuleEditor) reloadRules()
        if (scope === "Investments") reloadDashboard()
    }

    function createCategory(name, parent, symbol, color) {
        run(() => core("create_category", { name: name, parent_id: parent, sf_symbol: symbol, color_hex: color }))
        reloadCategories()
    }
    /// Changes one property of a category and keeps the others (the core only
    /// updates a category as a whole).
    function editCategory(id, change) {
        const c0 = categoryByID(id)
        if (!c0) return
        const c = Object.assign({}, c0)
        change(c)
        run(() => core("update_category", { id: c.id, name: c.name, parent_id: c.parent_id, sf_symbol: c.sf_symbol, color_hex: c.color_hex }))
        reloadCategories()
        reloadBookings() // the booking list shows a category's name, symbol and colour
        reloadPlanning() // budget cards show name, symbol, colour and the parent
    }
    function renameCategory(id, name) {
        const t = (name || "").trim()
        if (t === "") return
        editCategory(id, c => { c.name = t })
    }
    /// "Verschieben nach ▸": under another category, or to the top level (null).
    function moveCategory(id, parent) {
        editCategory(id, c => { c.parent_id = parent })
        if (parent !== null && !expandedCategories[parent]) toggleExpandedCategory(parent) // keep it in view
    }
    function setCategorySymbol(id, symbol) { editCategory(id, c => { c.sf_symbol = symbol }) }
    function setCategoryColor(id, hex) { editCategory(id, c => { c.color_hex = hex }) }
    /// Where a category can move: every category except itself and its own sub-categories.
    function categoryMoveTargets(id) {
        const byID = {}
        for (const c of categories) byID[c.id] = c
        return categories.filter(c => {
            let cur = c.id
            for (let steps = 0; cur !== null && cur !== undefined && steps < 64; steps++) {
                if (cur === id) return false
                cur = byID[cur] ? byID[cur].parent_id : null
            }
            return true
        })
    }
    function categoryPath(id) { const c = categoryByID(id); return c ? c.path : null }
    function deleteCategory(id) {
        run(() => core("delete_category", { id: id }))
        if (sidebarSelection === "category:" + id) sidebarSelection = "all"
        reloadAll()
    }

    // PlanningUI.swift › AppModel extension
    function setBudget(cents, categoryID) {
        run(() => core("set_category_budget", { category_id: categoryID, budget_cents: cents }))
        reloadCategories(); reloadPlanning()
    }
    /// parseAmountToCents(text:): null when not a valid amount.
    function parseCents(text) {
        try { return core("parse_amount_to_cents", { text: text }) } catch (e) { return null }
    }
    /// `done(null)` = could not be read – not the same as "not split".
    function splits(booking, done) {
        coreAsync("list_transaction_splits", { transaction_id: booking.id }, r => done(r), () => done(null))
    }
    /// Error text, or "" on success.
    function saveSplits(parts, booking) {
        try { core("set_transaction_splits", { transaction_id: booking.id, splits: parts }) } catch (e) { return e.message }
        reloadBookings(); reloadCategories(); reloadAccounts(); reloadPlanning()
        return ""
    }

    function newRuleDraft(booking) {
        const b = booking || null
        const firstSub = categories.find(c => c.depth > 0)
        const known = b && b.merchant && b.merchant.known
        return {
            id: 0,
            name: b ? b.merchant.name : qsTr("Neue Regel"),
            category_id: b && b.category_id !== null ? b.category_id : (firstSub ? firstSub.id : (categories.length ? categories[0].id : 0)),
            field: b ? "Counterparty" : "Any",
            match_kind: "Keyword",
            pattern: b ? (known ? b.merchant.name : b.counterparty.split(" ").filter(x => x !== "").slice(0, 2).join(" ")) : "",
            case_sensitive: false,
            min_amount_cents: null,
            max_amount_cents: b && b.amount_cents < 0 ? 0 : null,
            account_ids: [],
            priority: rules.reduce((m, r) => Math.max(m, r.priority), 0) + 10,
            enabled: true,
            match_count: 0
        }
    }
    function openRuleEditor(booking) {
        reloadRules()
        ruleDraft = booking ? newRuleDraft(booking) : null
        showRuleEditor = true
    }
    /// The id of the saved rule, else null (error shown).
    function saveRule(rule) {
        try {
            const id = core("save_rule", { rule: rule })
            core("apply_rules", { only_uncategorized: false })
            reloadAll()
            return id
        } catch (e) {
            errorTitle = qsTr("Regel konnte nicht gespeichert werden")
            errorMessage = e.message
            return null
        }
    }
    function deleteRule(id) {
        run(() => core("delete_rule", { rule_id: id }))
        reloadAll()
    }
    /// `{ matches, error }` of the live preview.
    function preview(rule) {
        try { return { matches: core("preview_rule", { rule: rule, limit: 200 }), error: "" } }
        catch (e) { return { matches: [], error: e.message } }
    }
    function applyAllRules() {
        run(() => {
            const n = core("apply_rules", { only_uncategorized: false })
            toast = qsTr("Regeln angewendet – %1 Buchungen neu zugeordnet").arg(n)
        })
        reloadAll()
    }


    // MARK: - Import & export

    /// (demo, `--demo-sheet moneymoney`) canned preview so the sheet can be shown without a file.
    property var demoImportPreview: null
    /// (demo, `--demo-sheet moneymoney-db`) canned database preview with invented data.
    property var demoDbPreview: null
    /// Enable Banking connections the last MoneyMoney import set up, with the
    /// accounts to link to the user's application.
    property var psd2LinkHints: []
    property bool showPrintSheet: false
    property bool showCSVExporter: false

    /// Opens the MoneyMoney import. An import belongs in the own vault, so the
    /// demo data an empty vault starts with is left first.
    function openMoneyMoneyImport() {
        if (isDemo && !optionDemoSeed) showOwnVault()
        showMoneyMoneyImport = true
    }

    function finishMoneyMoneyImport(r) {
        reloadAll()
        if (r.account_created) sidebarSelection = "account:" + r.account_id
        toast = qsTr("Import: %1 Buchungen importiert").arg(r.imported)
            + (r.enriched > 0 ? qsTr(", %1 ergänzt").arg(r.enriched) : "")
            + (r.duplicates > 0 ? qsTr(", %1 bereits vorhanden").arg(r.duplicates) : "")
    }

    function finishMoneyMoneyDbImport(r) {
        reloadAll()
        if (r.psd2_connections.length) psd2LinkHints = r.psd2_connections
        toast = qsTr("Import: %1 Buchungen in %2 Konten importiert").arg(r.bookings_new).arg(r.accounts_created + r.accounts_merged)
            + (r.bookings_duplicates > 0 ? qsTr(", %1 bereits vorhanden").arg(r.bookings_duplicates) : "")
    }

    /// Exports every booking matching the current list filter as Excel-friendly
    /// CSV: the save dialog (Main.qml) calls `writeFilteredBookingsCSV`.
    function exportFilteredBookingsCSV() { if (isUnlocked) showCSVExporter = true }
    function writeFilteredBookingsCSV(path) {
        try {
            core("export_bookings_csv_file", { filter: currentFilter(), path: path })
        } catch (e) {
            errorTitle = qsTr("Export fehlgeschlagen")
            errorMessage = e.message
        }
    }

    // Printing (GitHub #53)

    /// Everything the list shows (account, period, search, scope, status) without the list limit.
    function printSource() {
        if (!isUnlocked) return null
        const filter = currentFilter()
        filter.limit = 0
        try {
            const rows = core("list_transactions", { filter: filter }).transactions.map(b => PrintReport.rowFromBooking(b))
            const accounts = allAccounts.map(a => ({ id: a.id, name: a.name, iban: a.iban, balance_cents: a.balance_cents,
                                                     balance_date: a.balance_date, currency: a.currency }))
            // The list's own income/expense filter is named in the printout header.
            const notes = directionFilter === "Income" ? [PrintReport.directionTitle("income")]
                        : directionFilter === "Expense" ? [PrintReport.directionTitle("expenses")] : []
            return { title: title, period_label: periodTitle, rows: rows, accounts: accounts, daily_balances: ({}),
                     generated_at: new Date(), filter_notes: notes }
        } catch (e) {
            errorTitle = qsTr("Drucken nicht möglich")
            errorMessage = e.message
            return null
        }
    }

    /// End-of-day balances since `from` for each account (key = id) and combined (key 0).
    function printDailyBalances(accountIds, from) {
        if (!accountIds.length) return ({})
        const today = new Date(); today.setHours(0, 0, 0, 0)
        const start = Fmt.date(from) || today
        const days = Math.max(1, Math.round((today - start) / 86400000) + 1)
        function map(ids) {
            const out = {}
            try { for (const p of core("balance_history", { account_ids: ids, days: days })) out[p.date] = p.balance_cents } catch (e) {}
            return out
        }
        const out = { 0: map(accountIds) }
        for (const id of accountIds) out[id] = map([id])
        return out
    }

    /// PrintSheet › print(): the report of the selected rows to the print dialog. QtWebEngine
    /// lays it out like WebKit on the Mac (Main.qml › WebPrinter.qml renders `printJob`
    /// into a PDF), then finishPrintJob() hands the PDF to the print dialog.
    property var printJob: null   // { html, path, job_name } while the report is rendered
    function printReport(report, options) {
        const r = Object.assign({}, report, { generated_at: new Date() })
        if (options.show_daily_balance && r.rows.length) {
            const earliest = r.rows.map(x => x.date).reduce((a, b) => (a < b ? a : b))
            const ids = Object.keys(r.rows.reduce((m, x) => { m[x.account_id] = true; return m }, {})).map(Number).sort((a, b) => a - b)
            r.daily_balances = printDailyBalances(ids, earliest)
        }
        let assets
        try {
            assets = core("print_web_assets")
        } catch (e) {
            errorTitle = qsTr("Drucken nicht möglich"); errorMessage = e.message
            return null
        }
        if (!assets.pdf_supported) {
            errorTitle = qsTr("Drucken nicht möglich")
            errorMessage = qsTr("Zum Drucken fehlt das PDF-Modul von Qt (Paket „qt6-image-formats-plugin-pdf“).")
            return null
        }
        const tmp = decodeURIComponent(String(StandardPaths.writableLocation(StandardPaths.TempLocation)).replace(/^file:\/\//, ""))
        printJob = {
            html: PrintReport.html(r, options, "qrc:/qt/qml/GiroCrab/assets/app-icon.png", assets),
            path: tmp + "/girocrab-druck-" + Date.now() + ".pdf",
            job_name: "GiroCrab – " + r.title + " – " + r.period_label
        }
        return "rendering"
    }
    /// WebPrinter.qml is done (or could not be loaded): print dialog, or the reason it failed.
    function finishPrintJob(ok, failure) {
        const job = printJob
        printJob = null
        if (!job) return
        if (!ok) {
            errorTitle = qsTr("Drucken nicht möglich")
            errorMessage = failure || qsTr("Der Bericht konnte nicht gesetzt werden.")
            return
        }
        try {
            core("print_pdf", { path: job.path, job_name: job.job_name })
        } catch (e) {
            errorTitle = qsTr("Drucken nicht möglich")
            errorMessage = e.message
        }
    }

    /// Invented MoneyMoney database (public example IBANs, fictional names) for
    /// `--demo-sheet moneymoney-db` screenshots.
    function demoMoneyMoneyDbPreview(existingGiro) {
        function acc(id, name, bank, code, o) {
            return {
                mm_id: id, name: name, iban: o.iban || "", account_number: o.number || "", currency: o.currency || "EUR",
                bank_code: code, bank_name: bank, owner: "Max Mustermann", group_name: o.group !== undefined ? o.group : "Privat",
                mm_bank_id: o.bankId, is_portfolio: !!o.portfolio, suggested_kind: o.kind,
                existing_account_id: o.existing ? o.existing.id : null, existing_account_name: o.existing ? o.existing.name : null,
                booking_count: o.count, pending_count: o.pending || 0, holding_count: o.portfolio ? 3 : 0, notes_count: 0,
                first_date: o.from || null, last_date: o.to || null, statement_count: o.kind === "Checking" ? 48 : 0,
                computed_balance_cents: o.balance, balance_source: "Anfangssaldo laut MoneyMoney-Saldenverlauf + Umsätze"
            }
        }
        const accounts = [
            acc(1, "Girokonto", "comdirect", "20041111", { iban: "DE89370400440532013000", kind: "Checking", existing: existingGiro,
                count: 4812, pending: 3, from: "2009-04-01", to: "2026-11-09", balance: 324518, bankId: 1 }),
            acc(2, "Visa-Karte", "comdirect", "20041111", { number: "4871 •••• 1234", kind: "CreditCard", count: 1204, pending: 2,
                from: "2011-02-14", to: "2026-11-08", balance: -41290, bankId: 1 }),
            acc(3, "Tagesgeld", "1822direkt", "50050201", { iban: "DE02120300000000202051", kind: "Savings", count: 96,
                from: "2014-06-30", to: "2026-10-31", balance: 1250000, group: "Sparen", bankId: 2 }),
            acc(4, "Depot", "comdirect", "20041111", { number: "123456789", kind: "Brokerage", portfolio: true, count: 0,
                balance: 0, group: "Sparen", bankId: 1 }),
            acc(5, "PayPal", "PayPal", "", { number: "max@example.com", kind: "PaymentService", count: 640,
                from: "2013-08-02", to: "2026-11-05", balance: 2345, bankId: 3 }),
            acc(6, "Reisekasse USD", "Musterbank", "12345678", { number: "1000200", currency: "USD", kind: "Checking", count: 38,
                from: "2019-07-10", to: "2025-09-22", balance: 31075, group: "", bankId: 4 }),
            acc(7, "C24 Smartkonto", "C24 Bank", "50024024", { iban: "DE02500105170137075030", kind: "Checking", count: 57,
                from: "2024-03-01", to: "2026-11-07", balance: 184012, bankId: 5 })
        ]
        function direct(via, kind, key) { return { via: via, connector: kind, key: key, psd2_bank: null } }
        function bank(id, code, name, login, customer, connector, pin, count, options) {
            return { mm_id: id, bank_code: code, name: name, login_name: login, customer_id: customer, connector: connector,
                     existing_connection_id: null, account_count: count, connection_options: options }
        }
        let psd2 = []
        try { psd2 = core("psd2_catalog") } catch (e) {}
        const banks = [
            bank(1, "20041111", "comdirect", "12345678", "12345678", "Comdirect", true, 3, [direct("OwnApi", "Comdirect", "comdirect")]),
            bank(2, "50050201", "1822direkt", "max.mustermann", "", "Direkt1822", true, 1, [direct("FinTs", "Direkt1822", "direkt1822")]),
            bank(3, "", "PayPal", "max@example.com", "", "PayPal", false, 1, [direct("OwnApi", "PayPal", "paypal")]),
            bank(4, "12345678", "Musterbank", "mustermann", "", null, false, 1, []),
            // no own connector, but reachable through Enable Banking (PSD2)
            bank(5, "50024024", "C24 Bank", "max.mustermann", "", null, false, 1, psd2.filter(b => b.aspsp === "C24").map(b => ({
                via: "EnableBanking", connector: "EnableBanking", key: "enablebanking:" + b.country + ":" + b.aspsp, psd2_bank: b })))
        ]
        const categories = ["Gehalt", "Haushalt › Lebensmittel", "Haushalt › Drogerie", "Wohnen › Miete", "Wohnen › Nebenkosten › Strom",
                            "Mobilität › Tanken", "Mobilität › ÖPNV", "Freizeit › Restaurants", "Freizeit › Sport", "Versicherungen",
                            "Steuern", "Reisen", "Abos", "Gesundheit", "Geschenke", "Sparen"]
        const statements = accounts.reduce((s, a) => s + a.statement_count, 0)
        return {
            accounts: accounts, banks: banks, category_paths: categories,
            total_bookings: accounts.reduce((s, a) => s + a.booking_count, 0),
            pending_bookings: 5, notes_count: 312, split_parts: 14,
            date_range_start: "2009-04-01", date_range_end: "2026-11-09", replaces_starter_categories: true,
            database_path: "MoneyMoney.sqlite", statement_count: statements, statements_dir: "Statements",
            statements_found: statements, statements_bytes: 38400000
        }
    }

    /// What the result looks like, for the demo (nothing is read or stored).
    function demoMoneyMoneyDbResult(p, statements, psd2) {
        return {
            accounts_created: p.accounts.length, accounts_merged: 0, groups_created: 2, bookings_new: p.total_bookings,
            bookings_duplicates: 0, bookings_enriched: 0, pending_skipped: p.pending_bookings, notes_imported: p.notes_count,
            categories_created: p.category_paths.length, connections_created: 4, connections_existing: 0,
            banks_skipped_unsupported: 1, banks_skipped_names: ["Musterbank"], documents_imported: statements ? p.statements_found : 0,
            documents_existing: 0, documents_missing: 0, documents_mismatched: 0, documents_too_large: 0, documents_unlisted: 0,
            holdings_imported: 3, rules_created: 0, rules_disabled: 0,
            account_checks: p.accounts.map(a => ({
                mm_id: a.mm_id, account_id: 0, name: a.name, currency: a.currency, mm_bookings: a.booking_count,
                found_bookings: a.booking_count, deleted_bookings: 0, other_bookings: 0,
                mm_balance_cents: a.computed_balance_cents, mm_balance_shown: true,
                girocrab_balance_cents: a.computed_balance_cents, balance_from_bank: false, ok: true })),
            psd2_connections: psd2
        }
    }

    // MARK: - SEPA-Überweisung

    /// TransferDraft (AppModel.swift). Replaced as a whole (`setDraft`) so bindings update.
    function newTransferDraft(accountID) {
        const t = new Date(); t.setDate(t.getDate() + 1)
        return { account_id: accountID === undefined ? null : accountID, name: "", iban: "", bic: "", amountText: "",
                 purpose: "", pin: "",
                 // SEPA Instant: off by default; if the bank declines, nothing is sent automatically.
                 instant: false,
                 // Terminüberweisung: `executionDate` (YYYY-MM-DD) is sent when on (FinTS only).
                 scheduled: false, executionDate: Fmt.iso(t) }
    }
    property var transferDraft: newTransferDraft(null)
    function setDraft(patch) { transferDraft = Object.assign({}, transferDraft, patch) }
    /// `YYYY-MM-DD` for the core, or null when not scheduled.
    function executionDateISO(d) { d = d || transferDraft; return d.scheduled && !d.instant ? d.executionDate : null }
    property bool showTransferSheet: false
    property string transferError: ""
    /// Instant was not possible and nothing was sent: the bank's reason (null = none).
    property var transferInstantDeclined: null
    /// The order reached the bank but its result is unclear: { reason, end_to_end_id }.
    property var transferUnknown: null
    property bool transferBusy: false
    /// Handle of the running TransferSession (src/sessions.rs).
    property var activeTransfer: null
    /// Name check (Verification of Payee) awaiting the user's decision: { connection, check, busy }.
    property var payeeCheck: null

    /// ConnectorKind.offersInstantChoice: FinTS banks; bunq decides on its own.
    function offersInstantChoice(connector) { return ["VolksbankKasselGoettingen", "Direkt1822", "FinTsGeneric"].indexOf(connector) >= 0 }
    /// Checking accounts that are connected via FinTS (HKCCS-capable banks) or bunq.
    readonly property var transferAccounts: allAccounts.filter(a => a.kind === "Checking" && a.iban !== "" && a.archived_unix === null
        && ["VolksbankKasselGoettingen", "Direkt1822", "FinTsGeneric", "Bunq"].indexOf(a.connector) >= 0)
    /// Checking accounts GiroCrab cannot send from (e.g. C24 via Enable Banking):
    /// the form ends with a GiroCode to scan in the bank's app instead of a TAN.
    readonly property var giroCodeAccounts: allAccounts.filter(a => a.kind === "Checking" && a.iban !== "" && a.archived_unix === null
        && !transferAccounts.some(t => t.id === a.id))
    /// Accounts offered in the transfer form: sending ones first.
    readonly property var transferFormAccounts: transferAccounts.concat(giroCodeAccounts)
    function canSendTransfer(accountID) { void bankingPolicy; return transferAccounts.some(a => a.id === accountID) && bankingGateForAccount(accountID) === null }
    readonly property bool canTransfer: isUnlocked && transferFormAccounts.length > 0 && syncingConnectionID === null && activeTransfer === null

    /// TransferSheetView.groupedIBAN: upper-case, only A–Z/0–9, groups of four.
    function groupedIBAN(raw) { return (raw || "").toUpperCase().replace(/[^A-Z0-9]/g, "").replace(/(.{4})(?=.)/g, "$1 ") }
    function looksLikeBIC(s) { return /^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$/.test((s || "").toUpperCase()) }
    function validateIban(iban) { try { return core("validate_iban", { iban: iban }) } catch (e) { return false } }
    /// parseAmountToCents: null when unparsable.
    function clipboardText() { clipboardHelper.text = ""; clipboardHelper.paste(); const t = clipboardHelper.text; clipboardHelper.text = ""; return t }

    /// Pre-selects the sidebar account if it is offered in the form, else the first one.
    function openTransfer() {
        if (!canTransfer) return
        const offered = transferFormAccounts
        const has = id => offered.some(a => a.id === id)
        const selected = sidebarSelection.startsWith("account:") && has(Number(sidebarSelection.slice(8))) ? Number(sidebarSelection.slice(8)) : null
        if (transferDraft.account_id === null || !has(transferDraft.account_id))
            setDraft({ account_id: selected !== null ? selected : (offered.length ? offered[0].id : null) })
        else if (selected !== null)
            setDraft({ account_id: selected })
        transferError = ""
        transferInstantDeclined = null
        showTransferSheet = true
    }
    /// After an instant transfer was declined (nothing sent): send the same draft
    /// as a regular SEPA transfer – a new order with its own approval.
    function sendAsRegularTransfer() {
        transferInstantDeclined = null
        setDraft({ instant: false })
        startTransfer()
    }
    /// Context menu: new transfer pre-filled from a booking.
    function openTransferFrom(b) {
        if (!canTransfer) return
        setDraft({ name: b.counterparty === "" ? b.merchant_name : b.counterparty, iban: groupedIBAN(b.counterparty_iban), bic: "",
                   amountText: Fmt.plain(Math.abs(b.amount_cents)), purpose: (b.purpose || "").slice(0, 140) })
        openTransfer()
    }
    function suggestRecipients(query) { try { return core("suggest_recipients", { query: query, limit: 6 }) } catch (e) { return [] } }

    function startTransfer() {
        withFreshBankingPolicy(() => {
            const gate = bankingGateForAccount(transferDraft.account_id)
            if (gate) { transferError = gate.message; return }
            startTransferChecked()
        })
    }
    function startTransferChecked() {
        const d = transferDraft
        const accID = d.account_id
        if (accID === null || !canSendTransfer(accID)) return
        const account = accountsByID[accID]
        const connection = account ? connections.find(c => c.id === account.connection_id) : null
        if (!connection) return
        let cents
        try { cents = core("parse_amount_to_cents", { text: d.amountText }) } catch (e) { transferError = e.message; return }
        const bic = d.bic.trim()
        // Instant and scheduled transfers are FinTS-only.
        const offersInstant = offersInstantChoice(account.connector)
        const request = { account_id: accID, recipient_name: d.name, recipient_iban: d.iban, recipient_bic: bic === "" ? null : bic,
                          amount_cents: cents, purpose: d.purpose, instant: d.instant && offersInstant,
                          execution_date: offersInstant ? executionDateISO(d) : null }
        const st = connectionStatus(connection.id)
        const stored = st ? st.has_pin : false
        if (!isDemo && !stored && d.pin === "") { transferError = qsTr("Bitte die Banking-PIN eingeben."); return }
        let session
        try { session = core("begin_transfer", { request: request, secret: isDemo ? "demo" : d.pin, demo: isDemo }) }
        catch (e) { transferError = e.message; return }
        transferError = ""
        transferInstantDeclined = null
        transferBusy = true
        showTransferSheet = false
        activeTransfer = session
        coreAsync("session_start", { session: session }, step => { if (activeTransfer === session) handleTransfer(step, connection) },
                  err => { if (activeTransfer === session) finishTransfer(err) })
    }

    function handleTransfer(step, connection) {
        if (!step.NeedsPayeeConfirmation) payeeCheck = null
        if (step.NeedsPayeeConfirmation) {
            pollTimer.stop()
            activeChallenge = null
            payeeCheck = { connection: connection, check: step.NeedsPayeeConfirmation.check, busy: false }
        } else if (step.NeedsChallenge) {
            const c = step.NeedsChallenge.challenge
            activeChallenge = { connection: connection, challenge: c, waiting: false, busy: false, error: "" }
            if (c.kind === "DecoupledPush") schedulePoll(connection, c.poll_interval_seconds)
        } else if (step.StillWaiting) {
            const c = step.StillWaiting.challenge
            if (activeChallenge === null) activeChallenge = { connection: connection, challenge: c, waiting: true, busy: false, error: "" }
            else activeChallenge = Object.assign({}, activeChallenge, { waiting: true, busy: false })
            schedulePoll(connection, c.poll_interval_seconds)
        } else if (step.Finished) {
            pollTimer.stop()
            activeChallenge = null; activeTransfer = null; transferBusy = false
            transferDraft = newTransferDraft(transferDraft.account_id)
            toast = step.Finished.outcome.instant ? qsTr("Echtzeitüberweisung freigegeben und vorgemerkt")
                                                  : qsTr("Überweisung freigegeben und vorgemerkt")
            reloadAll()
        } else if (step.InstantDeclined) {
            // Nothing was sent. Keep the draft and let the user decide.
            pollTimer.stop()
            activeChallenge = null; activeTransfer = null; transferBusy = false
            transferError = ""
            transferInstantDeclined = step.InstantDeclined.reason
            showTransferSheet = true
        } else if (step.OutcomeUnknown) {
            // May have been executed: no retry button, clear the draft so it
            // cannot be resent with one click, and say so clearly.
            pollTimer.stop()
            activeChallenge = null; activeTransfer = null; transferBusy = false
            transferDraft = newTransferDraft(transferDraft.account_id)
            transferUnknown = { reason: step.OutcomeUnknown.reason, end_to_end_id: step.OutcomeUnknown.end_to_end_id }
            reloadAll()
        }
    }
    /// schedulePoll / submitCode / cancelSync: transfer branches.
    function pollTransfer(connection) {
        const t = activeTransfer
        coreAsync("session_poll", { session: t }, step => { if (activeTransfer === t) handleTransfer(step, connection) },
                  err => { if (activeTransfer === t) finishTransfer(err) })
    }
    function submitTransferCode(code) {
        const t = activeTransfer, ch = activeChallenge
        activeChallenge = Object.assign({}, ch, { busy: true, error: "" })
        // cancelled while the TAN was on its way: the cancel notice owns the sheet
        coreAsync("session_submit", { session: t, code: code }, step => { if (activeTransfer === t) handleTransfer(step, ch.connection) },
                  err => { if (activeTransfer === t) finishTransfer(err) })
    }
    function cancelTransfer() {
        pollTimer.stop()
        const t = activeTransfer
        activeTransfer = null; activeChallenge = null; transferBusy = false
        transferError = ""
        // The bank has to confirm: a bunq draft stays approvable until it is rejected.
        cancelTransferSession(t, qsTr("Überweisung abgebrochen – es wurde nichts gesendet, solange die TAN nicht bestätigt wurde."))
    }

    // MARK: transfer cancellation (AppModel+Transfer.swift › cancelTransferSession,
    // AppModelTypes.swift › UnconfirmedTransferCancel, RootView "Stornierung nicht bestätigt")
    /// `{ session, outcome, busy }` while the bank has not confirmed a cancellation.
    property var transferCancelNotice: null
    /// Cancels the session and tells apart a confirmed cancellation from one the bank has
    /// not confirmed. `confirmedMessage` replaces the sheet's error line only when confirmed.
    function cancelTransferSession(session, confirmedMessage) {
        if (session === null || session === undefined) return
        coreAsync("session_cancel", { session: session },
                  r => settleTransferCancel(session, r ? r.outcome : null, confirmedMessage),
                  () => settleTransferCancel(session, null, confirmedMessage))
    }
    function settleTransferCancel(session, outcome, confirmedMessage) {
        if (outcome === null || outcome === undefined || outcome === "Cancelled") {
            transferCancelNotice = null
            if (confirmedMessage) { transferError = confirmedMessage; showTransferSheet = true }
        } else {
            transferError = ""
            transferCancelNotice = { session: session, outcome: outcome, busy: false }
        }
    }
    /// "Status erneut prüfen": cancel again; the core re-queries before it resends anything.
    function recheckTransferCancel() {
        const n = transferCancelNotice
        if (!n || n.busy) return
        transferCancelNotice = Object.assign({}, n, { busy: true })
        cancelTransferSession(n.session, qsTr("Überweisung bei bunq storniert (bestätigt)."))
    }
    function transferCancelMessage(outcome) {
        if (!outcome || outcome === "Cancelled") return ""
        const kind = Object.keys(outcome)[0], reason = outcome[kind].reason || ""
        const head = kind === "CancellationPending" ? qsTr("Die Stornierung wurde von der Bank angenommen, aber noch nicht bestätigt.")
                   : kind === "CancellationUnknown" ? qsTr("Es ist unklar, ob die Überweisung storniert wurde (keine eindeutige Antwort der Bank).")
                   : qsTr("Die Überweisung konnte nicht storniert werden.")
        const advice = qsTr("Sie kann möglicherweise noch in der bunq-App freigegeben werden. Prüfen Sie den Status erneut oder lehnen Sie sie dort ab.")
        return head + "\n\n" + reason + "\n\n" + advice
    }

    /// Name check: send anyway (the bank then asks for the approval).
    function confirmPayee() {
        const t = activeTransfer, pending = payeeCheck
        if (t === null || !pending) return
        payeeCheck = Object.assign({}, pending, { busy: true })
        coreAsync("session_confirm_payee", { session: t }, step => { if (activeTransfer === t) handleTransfer(step, pending.connection) },
                  err => { if (activeTransfer === t) finishTransfer(err) })
    }
    /// Name check: do not send. `useBankName` takes over the account holder's
    /// name reported by the bank and reopens the form.
    function cancelPayee(useBankName) {
        const pending = payeeCheck
        if (!pending) return
        const t = activeTransfer
        payeeCheck = null; activeTransfer = null; transferBusy = false
        if (useBankName && pending.check.bank_name) {
            setDraft({ name: pending.check.bank_name })
            transferError = qsTr("Name des Kontoinhabers übernommen – bitte prüfen und erneut freigeben. Es wurde nichts gesendet.")
        } else {
            transferError = qsTr("Überweisung abgebrochen – es wurde nichts gesendet.")
        }
        showTransferSheet = true
        if (t !== null) cancelTransferSession(t, null)
    }
    function finishTransfer(err) {
        pollTimer.stop()
        payeeCheck = null; activeChallenge = null; activeTransfer = null; transferBusy = false
        setDraft({ pin: "" })
        transferError = parseCoreError(err).message
        showTransferSheet = true
    }
    /// endBankDialogsForLock (transfer part): no session keeps running, no PIN stays in memory.
    function endTransferForLock() {
        pollTimer.stop()
        const t = activeTransfer
        if (t !== null) activeChallenge = null
        activeTransfer = null; payeeCheck = null; transferBusy = false; showTransferSheet = false
        setDraft({ pin: "" })
        if (t !== null) coreAsync("session_cancel", { session: t }, null, () => {})
    }

    /// AppModel.endBankDialogsForLock: locking ends every bank dialog – no session keeps
    /// writing into the vault, no PIN/TAN prompt comes back after unlocking, no PIN stays
    /// in memory. The core cancels the sessions themselves in `lock` (sessions::cancel_all).
    function endBankDialogsForLock() {
        pollTimer.stop()
        const s = activeSession
        endTransferForLock()
        transferCancelNotice = null
        activeSession = null; activeChallenge = null; payeeCheck = null
        pendingLogin = null; setupRequest = null; webLoginConnection = null
        syncingConnectionID = null; statementsAccountID = null
        failedSyncSecret = ""
        syncGeneration++
        resetSyncBatch()
        if (s !== null) coreAsync("session_cancel", { session: s }, null, () => {})
    }

    // Transfer templates (PlanningUI.swift)
    function transferTemplates() { try { return core("list_transfer_templates") } catch (e) { return [] } }
    function saveTransferTemplate(name) {
        const d = transferDraft
        const c = parseCents(d.amountText)
        const t = { id: 0, name: name, recipient_name: d.name, recipient_iban: d.iban, recipient_bic: d.bic,
                    default_amount_cents: c !== null && c > 0 ? c : null, default_purpose: d.purpose }
        try { core("save_transfer_template", { template: t }) } catch (e) { transferError = e.message }
    }
    function applyTransferTemplate(t) {
        setDraft({ name: t.recipient_name, iban: groupedIBAN(t.recipient_iban), bic: t.recipient_bic,
                   amountText: t.default_amount_cents !== null ? Fmt.plain(t.default_amount_cents) : "",
                   purpose: t.default_purpose.slice(0, 140) })
    }
    function deleteTransferTemplate(id) { try { core("delete_transfer_template", { id: id }) } catch (e) {} }

    // MARK: - Settings & recurring
    // SettingsView.swift, ConnectionsUI.swift (edit sheet), RecurringUI.swift,
    // PlanningUI.swift › CustomPeriodForm, SyncLog.swift, HelpView.swift, AutoReview.swift.

    /// The settings window (macOS `Settings` scene) and its tab: general | banks | security.
    property bool showSettings: false
    property string settingsTab: "general"
    /// `--demo-settings banks:edit|add|remove`: sheet the bank settings open on appear.
    property string demoSettingsSheet: ""
    function openSettings(tab) { if (tab) settingsTab = tab; showSettings = true }
    property bool showSyncLog: false
    property bool showHelp: false
    property bool showRecurringSheet: false
    /// Booking whose custom recurrence dates are being edited (CustomDatesSheet).
    property var customRecurringBooking: null
    /// The start/end date dialog of the period filter.
    property bool showCustomPeriod: false
    /// Title of the separate window `--screenshot` grabs ("" = main window).
    property string screenshotWindow: ""

    // AutoReview.swift: "Als geprüft markieren" (per device, like UserDefaults).
    readonly property var autoReviewDelays: [
        { id: "manual", title: qsTr("Nur manuell"), seconds: -1 }, { id: "now", title: qsTr("Sofort"), seconds: 0 },
        { id: "1s", title: qsTr("Nach 1 Sekunde"), seconds: 1 }, { id: "5s", title: qsTr("Nach 5 Sekunden"), seconds: 5 }]
    property string autoReviewDelay: String(defaults.value("bookings/autoReviewDelay", "manual"))
    // Only stored: a new delay applies from the next selection on (AutoReview.swift).
    onAutoReviewDelayChanged: defaults.setValue("bookings/autoReviewDelay", autoReviewDelay)
    property Timer autoReviewTimer: Timer {
        property var bookingID: null
        onTriggered: {
            const b = model.selectedBooking
            if (model.selectedBookingID === bookingID && !model.isMultiSelection && b && !b.checked) model.setChecked(true, b)
        }
    }
    property Connections autoReviewHook: Connections {
        target: model
        function onSelectedBookingIDChanged() { model.scheduleAutoReview() }
    }
    /// Marks the selected booking as checked after `autoReviewDelay`, unless the
    /// selection moved on (or became a multiple one) in the meantime.
    function scheduleAutoReview() {
        autoReviewTimer.stop()
        const d = autoReviewDelays.find(x => x.id === autoReviewDelay)
        const b = bookingByID(selectedBookingID)   // the binding may still be stale here
        if (!d || d.seconds < 0 || selectedBookingID === null || isMultiSelection || !b || b.checked) return
        autoReviewTimer.bookingID = selectedBookingID
        autoReviewTimer.interval = Math.max(1, d.seconds * 1000)
        autoReviewTimer.start()
    }

    // Custom period (GitHub #53): remembered across launches.
    Component.onCompleted: {
        const d = periodRange("lastMonth")
        customPeriodFrom = String(defaults.value("period/customFrom", "")) || d[0]
        customPeriodTo = String(defaults.value("period/customTo", "")) || d[1]
    }
    /// Switches to the user-defined period; swaps the dates if needed (ISO strings).
    function applyCustomPeriod(from, to) {
        const a = from <= to ? from : to, b = from <= to ? to : from
        customPeriodFrom = a
        customPeriodTo = b
        defaults.setValue("period/customFrom", a)
        defaults.setValue("period/customTo", b)
        if (period === "custom") { listLimit = defaultListLimit; reloadSelection(true) } else period = "custom"
    }

    // FinTS product registration (GiroCrab's own vs. the user's).
    readonly property bool fintsBuiltinAvailable: core("fints_builtin_product_id_available")
    /// Stored choice: "builtin", "own" or "" (not decided yet).
    property string fintsProductIDMode: ""
    property bool offerProductIDChoice: false
    onSettingsChanged: reloadProductIDState()
    /// New users start with GiroCrab's registration; users who already entered their own are asked once.
    function reloadProductIDState() {
        if (!isUnlocked) return
        try {
            let mode = core("fints_product_id_mode")
            const own = settingEntry("fints.product_id")
            const hasOwn = !!(own && own.has_value)
            if (fintsBuiltinAvailable && mode === "" && !hasOwn && !isDemo) {
                core("set_fints_product_id_mode", { mode: "builtin" })
                mode = "builtin"
                fintsProductIDSource = core("fints_product_id_source")
            }
            fintsProductIDMode = mode
            offerProductIDChoice = fintsBuiltinAvailable && mode === "" && hasOwn && !isDemo
        } catch (e) { console.warn(e.message) }
    }
    /// Stores the choice. The user's own ID always stays in the vault.
    function setFintsProductIDMode(mode) {
        run(() => core("set_fints_product_id_mode", { mode: mode }))
        offerProductIDChoice = false
        reloadSettings()
    }

    readonly property var settingLabels: ({
        "fints.product_id": qsTr("FinTS-Produktregistrierung"),
        "fints.url.52090000": qsTr("FinTS-Server Volksbank Kassel Göttingen"),
        "fints.url.50050201": qsTr("FinTS-Server 1822direkt"),
        "comdirect.client_id": qsTr("comdirect Client-ID"),
        "comdirect.client_secret": qsTr("comdirect Client-Secret"),
        "paypal.client_id": qsTr("PayPal Client-ID"),
        "paypal.client_secret": qsTr("PayPal Secret"),
        "enablebanking.application_id": qsTr("Enable Banking Application-ID"),
        "enablebanking.private_key_pem": qsTr("Enable Banking Private Key"),
        "enablebanking.redirect_url": qsTr("Enable Banking Redirect-URL") })
    function settingLabel(key) {
        const e = settingEntry(key)
        return e ? e.label : (settingLabels[key] || (key.startsWith("fints.url.") ? qsTr("FinTS-URL") : key))
    }
    /// Value of a (secret) setting, "" when unset.
    function revealSetting(key) { try { return core("get_setting", { key: key }) || "" } catch (e) { return "" } }
    function clearSession(id) { run(() => core("clear_connection_session", { connection_id: id })); toast = qsTr("Sitzung gelöscht") }
    /// PSD2Consent.swift › reconnect: new consent at the bank.
    function reconnect(connection) {
        if (!run(() => { core("clear_connection_session", { connection_id: connection.id }); return true })) return
        requestSync(connections.find(c => c.id === connection.id) || connection)
    }
    /// Enable Banking: checks application ID + key before the first bank login (network, off the GUI thread).
    function checkEnableBankingApplication(id, pem, redirect, done, failed) {
        coreAsync("check_enable_banking_application", { application_id: id, private_key_pem: pem, redirect_url: redirect }, done, failed)
    }

    /// EnableBankingKeyFile.read: PEM text and, if the file name carries it, the application ID.
    /// Throws a readable message for anything else.
    function readEnableBankingKeyFile(url) {
        const path = localPath(url)
        const text = core("read_text_file", { path: path })
        if (text.indexOf("-----BEGIN") < 0 || text.indexOf("PRIVATE KEY-----") < 0)
            throw new Error(qsTr("Das ist kein privater Schlüssel. Bitte die .pem-Datei wählen, die enablebanking.com beim Registrieren heruntergeladen hat."))
        const name = path.split("/").pop()
        const m = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/.exec(name)
        return { pem: text.trim(), applicationID: m ? m[0].toLowerCase() : null }
    }

    // Vault key (VaultKeyManager): Secret Service instead of the Keychain.
    /// Base64 key for the backup; `done(key)`. The keyring may ask for its password.
    function exportVaultKey(done) { coreAsync("export_key", {}, done) }
    /// Clipboard that forgets the key after 60 s (VaultKeyManager.copyToPasteboard).
    function copySecret(text) { run(() => core("copy_secret", { text: text })) }
    /// Restores / adopts a key: rekeys the open vault, or checks it against the locked vault file.
    function importVaultKey(text, done, failed) {
        coreAsync("import_key", { text: text }, () => {
            toast = qsTr("Tresor-Schlüssel übernommen")
            vaultInfo = core("vault_info")
            if (done) done()
            // restored while locked: open the vault with it right away
            if (!hasOwnVault && (vaultState === "locked" || vaultState === "failed")) { vaultState = "locked"; unlock() }
        }, failed)
    }

    // Recurring (RecurringUI.swift): series hidden with "Nicht wiederkehrend".
    /// Set by refreshRecurring() (`recurring_snapshot`).
    property var recurringHidden: []
    /// "Monatlich" or "Individuell (15.03., 15.08.)".
    function intervalText(s) {
        if (s.interval !== "Custom" || !s.custom_dates || !s.custom_dates.length) return intervalLabels[s.interval]
        return intervalLabels[s.interval] + " (" + s.custom_dates.map(customDateShort).join(", ") + ")"
    }
    /// "15.03." for "03-15".
    function customDateShort(mmdd) { const p = mmdd.split("-"); return p.length === 2 ? p[1] + "." + p[0] + "." : mmdd }
    /// "15. März" for "03-15".
    function customDateDisplay(mmdd) {
        const p = mmdd.split("-").map(Number)
        if (p.length !== 2 || isNaN(p[0]) || isNaN(p[1])) return mmdd
        return new Date(2024, p[0] - 1, p[1]).toLocaleDateString(Fmt.locale, Fmt.pattern("d. MMMM"))
    }
    /// CustomDates.parse: "15.03.", "15.3", "03-15" → valid MM-DD (sorted) and unreadable tokens.
    function parseCustomDates(text) {
        const valid = [], invalid = []
        for (const token of text.split(/[,;\s]+/).filter(t => t !== "")) {
            const t = token.endsWith(".") ? token.slice(0, -1) : token
            let m = NaN, d = NaN
            if (t.indexOf("-") >= 0) { const p = t.split("-"); if (p.length === 2 && /^\d+$/.test(p[0]) && /^\d+$/.test(p[1])) { m = Number(p[0]); d = Number(p[1]) } }
            else { const p = t.split("."); if (p.length === 2 && /^\d+$/.test(p[0]) && /^\d+$/.test(p[1])) { d = Number(p[0]); m = Number(p[1]) } }
            // a leap year accepts 29.02.
            const date = new Date(2024, m - 1, d)
            if (m >= 1 && m <= 12 && d >= 1 && date.getMonth() === m - 1 && date.getDate() === d) {
                const key = (m < 10 ? "0" : "") + m + "-" + (d < 10 ? "0" : "") + d
                if (valid.indexOf(key) < 0) valid.push(key)
            } else invalid.push(token)
        }
        return { valid: valid.sort(), invalid: invalid }
    }
    /// Selects a booking in the list, widening the filters if it is not loaded.
    function revealBooking(id) {
        if (!bookings.some(b => b.id === id)) {
            sidebarSelection = "all"; period = "all"; directionFilter = "All"; statusFilter = "all"; searchText = ""
        }
        revealTimer.bookingID = id
        revealTimer.restart()
    }
    property Timer revealTimer: Timer {
        property var bookingID: null
        interval: 350
        onTriggered: {
            // an older booking is not on the first page: load back to its day
            if (!model.bookings.some(b => b.id === bookingID)) {
                const day = model.run(() => model.core("booking_date", { booking_id: bookingID }))
                if (day && model.page) { model.listLimit = Math.max(model.listLimit, model.page.total_count); model.reloadBookings() }
            }
            model.selectBooking(bookingID, false, false)
        }
    }

    // Abruf-Protokoll (SyncLog.swift, GitHub #238)
    /// Bumped whenever a sync wrote a row; the log window reloads on it.
    property int syncLogVersion: 0
    /// Appends a finished sync; the core scrubs logins, PINs, TANs and long numbers.
    /// SyncLog.swift › syncLogSource: what started the running sync (no scheduled syncs on Linux).
    function syncLogSource() { return statementsAccountID !== null ? "Statements" : "Manual" }
    function logSync(connectionID, outcome, message, imported, source) {
        if (!isUnlocked) return
        try {
            core("log_sync", { connection_id: connectionID, source: source || syncLogSource(), outcome: outcome, message: message || "", imported: Math.max(0, imported || 0) })
            syncLogVersion++
        } catch (e) { /* the log must never get in the way of a sync */ }
    }
    readonly property var syncLogOutcomeTitles: ({ Ok: qsTr("Erfolgreich"), Error: qsTr("Fehler"), Cancelled: qsTr("Abgebrochen") })
    readonly property var syncLogSourceTitles: ({ Manual: qsTr("Manuell"), Automatic: qsTr("Automatisch"), Statements: qsTr("Kontoauszüge") })
    /// CSV of the rows the log window shows.
    function syncLogCSV(entries) {
        const field = s => "\"" + String(s).replace(/"/g, "\"\"") + "\""
        const pad = n => (n < 10 ? "0" : "") + n
        const lines = ["Zeit;Konto;Auslöser;Ergebnis;Neue Buchungen;Meldung"]
        for (const e of entries) {
            const d = new Date(e.timestamp_ms)
            const off = -d.getTimezoneOffset(), sign = off >= 0 ? "+" : "-"
            const date = Fmt.iso(d) + "T" + pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds())
                + sign + pad(Math.floor(Math.abs(off) / 60)) + ":" + pad(Math.abs(off) % 60)
            lines.push([date, field(e.connection_name), syncLogSourceTitles[e.source], syncLogOutcomeTitles[e.outcome], String(e.imported), field(e.message)].join(";"))
        }
        return lines.join("\n") + "\n"
    }

    // MARK: - Demo launch options (LaunchOptions.swift, AppModel.swift › init)
    /// `--view`, `--select`, `--demo-filter`, `--pick`, `--demo-sync`: right after the demo opened.
    function applyLaunchSelection() {
        switch (launchValue("--view")) {
        case "alltag": scope = "Everyday"; break
        case "sparplaene": case "sparpläne": case "investments": scope = "Investments"; break
        case "belege": case "documents": sidebarSelection = "documents"; break
        }
        const q = launchValue("--select")
        const account = q ? allAccounts.find(a => a.name.toLowerCase().includes(q)) : null
        if (account) {
            sidebarSelection = "account:" + account.id
            selectedBookingID = null
        }
        switch (launchValue("--demo-filter")) {
        case "income": directionFilter = "Income"; break
        case "expense": case "expenses": directionFilter = "Expense"; break
        }
        reloadBookings()
        if (account && selectedBookingID === null && bookings.length) selectedBookingID = bookings[0].id
        const p = launchValue("--pick")
        const pick = p ? bookings.find(b => (b.merchant_name || "").toLowerCase().includes(p) || (b.counterparty || "").toLowerCase().includes(p)) : null
        if (pick) selectedBookingID = pick.id
        if (optionDemoSync) Qt.callLater(requestSyncAll)
    }
    /// `--demo-sheet` / `--demo-settings`: presented once, shortly after the vault is open.
    property bool demoDialogsPresented: false
    property Timer demoDialogTimer: Timer {
        interval: 600
        running: model.vaultState === "open" && !model.demoDialogsPresented
        onTriggered: model.presentLaunchOptions()
    }
    function presentLaunchOptions() {
        demoDialogsPresented = true
        if (demoSettings !== "") {
            const parts = demoSettings.split(":")
            if (parts[0] === "groups") {
                // the group editor is a sheet of the main window (Swift: showGroupManager)
                showGroupManager = true
            } else {
                const tabs = { general: "general", banks: "banks", security: "security" }
                settingsTab = tabs[parts[0]] || "general"
                demoSettingsSheet = parts.length > 1 ? parts[1] : ""
                showSettings = true
                screenshotWindow = qsTr("Einstellungen")
            }
        }
        if (demoSheet !== "") presentDemoSheet(demoSheet)
    }
    /// The one switch for `--demo-sheet <name>` (AppModel.swift › presentDemoSheet):
    /// opens that sheet pre-filled with fictional data.
    function presentDemoSheet(name) {
        const top = categories.find(c => c.depth === 0)
        switch (name) {
        case "icon-color": {
            // the "Symbol & Farbe" popover of the first account (#167)
            const a = allAccounts.length ? allAccounts[0] : null
            if (a) iconColorTarget = { type: "account", id: a.id }
            break
        }
        case "icon-color-category": if (top) iconColorCategoryID = top.id; break
        case "category": if (top) newCategoryRequest = { parent: top.id }; break
        case "print":
            // Print dialog (GitHub #53) on last month's demo bookings.
            period = "lastMonth"
            showPrintSheet = true
            break
        case "transfer":
            if (transferAccounts.length) sidebarSelection = "account:" + transferAccounts[0].id
            openTransfer()
            setDraft({ name: "Stadtwerke München", iban: groupedIBAN("DE89370400440532013000"), amountText: Fmt.plain(8500),
                       purpose: "Abschlag Strom Kd-Nr 482910" })
            break
        case "moneymoney":
            demoImportPreview = {
                total_rows: 4820, new_bookings: 4820, duplicates_skipped_or_enriched: 0, notes_count: 312,
                date_range_start: "2012-01-03", date_range_end: "2026-10-30",
                detected_categories: ["Haushalt > Lebensmittel", "Gehalt", "Steuern", "Wohnen > Miete", "Mobilität > Tanken", "Freizeit > Restaurants", "Versicherungen", "Reisen"],
                sample_bookings: [], suggested_account_name: "MoneyMoney-Archiv", suggested_account_id: null
            }
            showMoneyMoneyImport = true
            break
        case "moneymoney-db":
            demoDbPreview = demoMoneyMoneyDbPreview(allAccounts.find(a => a.kind === "Checking") || null)
            showMoneyMoneyImport = true
            break
        case "recurring": showRecurringSheet = true; break
        case "rules": openRuleEditor(null); break
        case "rule-edit": reloadRules(); ruleDraft = rules.length ? rules[0] : null; showRuleEditor = true; break
        case "palette": showCommandPalette = true; break
        case "categorizer":
            if (selectedBookingID === null && bookings.length) selectedBookingID = bookings[0].id
            showCategorizer = true
            break
        case "error":
            // the sync error alert of a rejected FinTS registration (product-ID alternatives)
            if (!connections.length) break
            errorTitle = qsTr("Abruf von „%1“ fehlgeschlagen").arg(connections[0].display_name)
            errorRetry = () => {}
            errorAlternatives = [{ title: qsTr("Eigene Registrierung ersetzen …"), action: enterOwnProductID },
                                 { title: qsTr("Mit GiroCrab-Registrierung erneut versuchen"), action: () => {} }]
            errorMessage = "Bank meldet 9078: Das Produkt ist nicht registriert."
            break
        case "payee-match": case "payee-close": case "payee-nomatch": {
            const connection = connections.length ? connections[0] : null
            if (!connection) break
            const result = name === "payee-match" ? "Match" : name === "payee-close" ? "CloseMatch" : "NoMatch"
            payeeCheck = { connection: connection, busy: false, check: {
                result: result, entered_name: "Stadtwerke Muenchen", iban: "DE89370400440532013000",
                bank_name: result === "CloseMatch" ? "Stadtwerke München GmbH" : null, reason: null,
                notice: result === "NoMatch" ? "Wenn Sie die Überweisung trotzdem freigeben, kann das Geld an einen anderen Empfänger gehen." : null } }
            break
        }
        }
    }

    // MARK: - Web logins
    // AppModel.swift › webLoginConnection, applyBrowserSession, PortalUI.swift (model glue),
    // AmazonUI.swift › importAmazonOrders. The sheet is WebLoginSheet.qml (loaded on demand
    // by Main.qml, QtWebEngine stays optional). Cookies stay in the off-the-record browser
    // profile and, for Trade Republic, in the vault; QML never sees them.
    function cardUsesEnableBanking(optIn, hasApp, hasKey) { return (optIn || "").trim() === "1" && hasApp && hasKey }
    function enableBankingOptInKey(kind) { return kind === "AmazonVisa" ? "enablebanking.use.amazonvisa" : "enablebanking.use.amex" }
    /// ConnectorKind.portalURL (+ the Trade Republic login page of WebLoginSheet).
    function portalURL(kind) {
        switch (kind) {
        case "AmericanExpress": return "https://global.americanexpress.com/activity/recent"
        // Amazon Visa customer portal (Open Bank / Zinia); www.openbank.de has no card login.
        case "AmazonVisa": return "https://kunden.openbankpay.com/amazon/login"
        case "Quirion": return "https://banking.quirion.de/login/"
        case "Fnz": return "https://portal.fnz.de/"
        case "AmazonOrders": return "https://www.amazon.de/gp/css/order-history"
        case "TradeRepublic": return "https://app.traderepublic.com/login"
        default: return ""
        }
    }
    /// ConnectorKind.portalTransactionsURL: opened once after sign-in when the portal lands elsewhere.
    function portalTransactionsURL(kind) { return kind === "AmazonVisa" ? "https://kunden.openbankpay.com/amazon/transactions" : "" }
    /// ConnectorKind.portalHosts
    function portalHosts(kind) {
        switch (kind) {
        case "AmericanExpress": return ["americanexpress.com", "aexp.com"]
        case "AmazonVisa": return ["openbankpay.com", "openbank.de", "openbank.com", "zinia.de", "zinia.com"]
        case "AmazonOrders": return ["amazon.de", "amazon.com"]
        case "Fnz": return ["portal.fnz.de"]
        case "Quirion": return ["banking.quirion.de"]
        case "TradeRepublic": return ["traderepublic.com"]
        default: return []
        }
    }
    /// PortalDomains(kind:): the portal's hosts, its start page's host and the base domain of each.
    function portalDomains(kind) {
        const all = {}
        let hosts = portalHosts(kind)
        if (kind !== "AmazonOrders" && portalURL(kind)) hosts = hosts.concat([new URL(portalURL(kind)).hostname])
        for (const h0 of hosts) {
            const h = h0.toLowerCase()
            if (!h) continue
            all[h] = true
            all[h.split(".").slice(-2).join(".")] = true
        }
        return Object.keys(all).sort()
    }
    /// PortalDomains.allows: matched on label boundaries (`openbankpay.com.evil.io` is not allowed).
    function domainAllows(domains, host) {
        let h = (host || "").toLowerCase()
        if (!h) return false
        if (h.endsWith(".")) h = h.slice(0, -1)
        return domains.some(d => h === d || h.endsWith("." + d))
    }

    /// Embedded web-portal login unless the card was switched to Enable Banking (PSD2)
    /// under "Erweitert" *and* the credentials are set (PortalUI.swift › usesPortal).
    function usesPortalLogin(c) {
        if (isMagicDemoLogin(c.login_name)) return false
        if (!isDemo && ["AmazonOrders", "Fnz", "Quirion"].indexOf(c.connector) >= 0) return true
        if (isDemo || (c.connector !== "AmericanExpress" && c.connector !== "AmazonVisa")) return false
        const optIn = settingEntry(enableBankingOptInKey(c.connector))
        const app = settingEntry("enablebanking.application_id"), key = settingEntry("enablebanking.private_key_pem")
        return !cardUsesEnableBanking(optIn ? optIn.value : "", !!(app && app.has_value), !!(key && key.has_value))
    }

    /// Not opened while the banking policy blocks this login (security lock); a lock
    /// or vault switch ends the browser login like every other bank dialog.
    property Connections webLoginWatch: Connections {
        target: model
        function onWebLoginConnectionChanged() {
            const c = model.webLoginConnection
            if (!c) return
            const gate = model.bankingGate(c)
            if (gate) {
                model.webLoginConnection = null
                model.errorTitle = model.bankingGateTitle(gate)
                model.errorMessage = model.bankingPolicy.message
            }
        }
        function onVaultStateChanged() { if (model.vaultState !== "open") model.webLoginConnection = null }
    }

    /// Portal sheet closed after its work (Swift: `model.webLoginConnection = nil`): a batch
    /// ("Konten abrufen" of a group) goes on with the next login instead of stalling.
    function closeWebLogin() {
        webLoginConnection = null
        if (syncBatchTotal > 1) syncNextInQueue()
        else resetSyncBatch()
    }

    /// Trade Republic: cookies of the browser login -> vault -> sync without 2FA.
    function applyBrowserSession(connection) {
        webLoginConnection = null
        try {
            core("apply_web_session", { connection_id: connection.id, domains: portalHosts("TradeRepublic") })
            toast = qsTr("Trade-Republic-Sitzung übernommen")
            startSync(connections.find(c => c.id === connection.id) || connection, "")
        } catch (e) {
            resetSyncBatch()   // like any sync error: ends "Alle abrufen" instead of stalling it
            errorTitle = qsTr("Anmeldung konnte nicht übernommen werden")
            errorMessage = e.message
        }
    }
    /// WebLoginSheet.removeSessionCookies (`sessionOnly`) / clearAllTradeRepublicWebData
    /// (with `connectionId`: also the cookies kept in the vault for that login).
    function clearTradeRepublicWebData(sessionOnly, connectionId) {
        try {
            core("web_clear_cookies", { domains: portalHosts("TradeRepublic"), name: sessionOnly ? "tr_session" : null,
                                        connection_id: sessionOnly ? null : (connectionId === undefined ? null : connectionId) })
        } catch (e) {}
    }
    /// clearPortalSession(kind): the portal's cookies in the browser profile and in the vault.
    function clearPortalSession(kind, connectionId) {
        try { core("web_clear_cookies", { domains: portalDomains(kind), name: null, connection_id: connectionId === undefined ? null : connectionId }) } catch (e) {}
    }
    // Web sessions across restarts (WKWebsiteDataStore.default() on the Mac): the portal's
    // cookies are kept encrypted in the vault per login and put back into the
    // off-the-record profile before the login page loads. Trade Republic's `tr_session`
    // has its own place (the connection's session), so it is left out here.
    function webCookieArgs(c) {
        return { connection_id: c.id, domains: portalDomains(c.connector), skip_names: c.connector === "TradeRepublic" ? ["tr_session"] : [] }
    }
    function saveWebCookies(c) { if (c && isUnlocked) { try { core("web_save_cookies", webCookieArgs(c)) } catch (e) { console.warn("web cookies not saved:", e.message) } } }
    function restoreWebCookies(c) { if (c && isUnlocked) { try { return core("web_restore_cookies", webCookieArgs(c)) } catch (e) { console.warn("web cookies not restored:", e.message) } } return 0 }
    function forgetWebCookies(id) { try { core("web_forget_cookies", { connection_id: id }) } catch (e) {} }
    /// Returns true when bookings were recognised (even if all were already known).
    function importPortalCapture(c, bodies, rowsJSON) {
        try {
            const s = core("import_portal_capture", { connection_id: c.id, json_bodies: bodies, dom_rows_json: rowsJSON })
            let text = qsTr("%1: %2 neue Buchungen, %3 kategorisiert").arg(c.display_name).arg(s.transactions_imported).arg(s.transactions_categorized)
            if (s.transactions_skipped_archived) text += " · " + qsTr("%1 Buchungen archivierter Konten übersprungen").arg(s.transactions_skipped_archived)
            toast = text
            saveWebCookies(c)   // signed in: keep the session
            reloadAll()
            return true
        } catch (e) {
            console.warn("portal import failed:", e.message)
            return false
        }
    }
    /// Number of bookings recognised in the capture right now (nothing stored), off the GUI thread.
    function previewPortalCapture(c, bodies, rowsJSON, done) {
        coreAsync("preview_portal_capture", { connection_id: c.id, json_bodies: bodies, dom_rows_json: rowsJSON },
                  n => done(n || 0), () => done(0))
    }
    /// PortalUI.swift › importStatement: CSV or PDF statement of a portal card.
    function importStatement(c, fileUrl) {
        const path = decodeURIComponent(String(fileUrl).replace(/^file:\/\//, ""))
        const name = path.split("/").pop()
        try {
            const s = core("import_statement_file", { connection_id: c.id, path: path })
            toast = qsTr("%1: %2 neue Buchungen aus %3").arg(c.display_name).arg(s.transactions_imported).arg(name)
            reloadAll()
        } catch (e) {
            if (e.message.startsWith("Ungültige Eingabe")) {
                errorTitle = qsTr("Keine Umsätze erkannt")
                errorMessage = qsTr("In %1 wurden keine Umsätze erkannt. Erwartet: CSV mit Datum, Beschreibung, Betrag oder ein Kontoauszug als PDF mit Textebene.").arg(name)
            } else {
                errorTitle = qsTr("Kontoauszug-Import fehlgeschlagen")
                errorMessage = e.message
            }
        }
    }
    /// AmazonUI.swift › importAmazonOrders. Returns true when orders were recognised.
    function importAmazonOrders(c, json) {
        try {
            const s = core("import_amazon_orders", { connection_id: c.id, orders_json: json })
            toast = qsTr("%1: %2 neue Buchungen, %3 kategorisiert").arg(c.display_name).arg(s.transactions_imported).arg(s.transactions_categorized)
            saveWebCookies(c)   // signed in: keep the session
            reloadAll()
            return true
        } catch (e) {
            errorTitle = qsTr("Amazon-Bestellungen konnten nicht übernommen werden")
            errorMessage = e.message
            return false
        }
    }
    /// `coreAsync` as a promise (FNZ / quirion import steps).
    function corePromise(method, args) {
        return new Promise((resolve, reject) => coreAsync(method, args, resolve, e => reject(new Error(parseCoreError(e).message))))
    }
}
