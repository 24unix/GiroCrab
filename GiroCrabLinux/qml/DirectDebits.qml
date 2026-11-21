pragma Singleton
import QtQuick

// State and logic of „Lastschriften“ (GitHub #143): AppModel+Mandates.swift (mandates of a
// creditor account, creditor ID, CSV / pain.008 import, CSV export, collection files),
// AppModel+DirectDebitSubmit.swift (submitting the files via FinTS, one TAN each) and
// DirectDebitTypes.swift (MandateDraft, CollectionLine, DebitRun). The submission runs as a
// TransferSession through AppModel.runPaymentSession(…, "debit"); AppModel.qml calls back
// here (finishGroup, outcomeUnknown, cancelRun, failRun, endForLock).
QtObject {
    id: dd

    // AppModel.swift › mandates, mandateAccountID, selectedMandateID, mandateDraft, …
    property var mandates: []
    /// After every reload (the view takes over the stored creditor ID into its field).
    signal reloaded()
    property var accountID: null
    property var selectedID: null
    /// MandateDraft being edited in MandateEditorSheet, or null.
    property var draft: null
    property string error: ""
    property string note: ""
    property int version: 0
    property string creditorID: ""
    property string suggestedCreditorID: ""
    /// Returned collections not yet marked as seen; the bookings of the selected mandate.
    property var openReturns: []
    property var bookings: []
    property bool showCollectionSheet: false
    /// CollectionLine: { mandateId, name, reference, sequenceText, nextSequence, included,
    /// amountText, purpose, lastCollection } – a ListModel, so typing keeps its field.
    property ListModel collectionLines: ListModel {}
    /// Bumped on every line change: counts and sums bind to it.
    property int linesRevision: 0
    property var collectionFiles: []
    /// CollectionSheet's `due`: five days ahead when the sheet opens.
    property date collectionDue: new Date()
    /// DebitRun while files are handed to the bank.
    property var debitRun: null
    /// The page is on screen: `.task(id:)` reloads only then.
    property bool active: false

    /// debitAccounts: accounts that can collect – current accounts with an IBAN.
    readonly property var debitAccounts: AppModel.allAccounts.filter(a => a.kind === "Checking" && a.iban !== "" && a.archived_unix === null)
    /// effectiveMandateAccount: the chosen account, else the first.
    readonly property var account: debitAccounts.find(a => a.id === accountID) || (debitAccounts.length ? debitAccounts[0] : null)
    readonly property var selected: { const id = selectedID; return id === null ? null : (mandates.find(m => m.id === id) || null) }
    readonly property int activeCount: mandates.filter(m => m.active).length

    function setAccount(id) {
        accountID = id
        error = ""; note = ""
        reload()
    }

    // MandateScheme.title, Mandate.sequenceText
    function schemeTitle(s) { return s === "Cor1" ? qsTr("COR1") : s === "B2b" ? qsTr("Firmenlastschrift") : qsTr("Basislastschrift") }
    function sequenceText(seq) { return seq === "OOFF" ? qsTr("Einmalig") : seq === "RCUR" ? qsTr("Folgeeinzug") : qsTr("Erster Einzug") }
    function statusText(m) { return m.active ? sequenceText(m.next_sequence) : qsTr("Inaktiv") }
    /// Mandate.typeText / typeHelp (#673): the abbreviations banks print on direct debits.
    function typeText(m) { return m.one_off ? qsTr("Einmalmandat (EM)") : qsTr("Dauermandat (AM)") }
    function typeHelp(m) {
        return m.one_off ? qsTr("EM = Einmalmandat: gilt nur für eine einzelne Lastschrift.")
                         : qsTr("AM = Dauermandat: gilt für wiederkehrende Lastschriften.")
    }

    /// reloadMandates: list, creditor ID, suggestion and open returns off the GUI thread.
    function reload() {
        if (!AppModel.isUnlocked) return
        const acc = account ? account.id : null
        if (acc === null) { mandates = []; creditorID = ""; return }
        AppModel.loadOffMain("mandates", () => ({
            calls: [["list_mandates", { account_id: acc }], ["creditor_id", { account_id: acc }],
                    ["suggested_creditor_id", {}], ["open_mandate_returns", { account_id: acc }]],
            ctx: acc
        }), (r, acc) => {
            if (!account || acc !== account.id) return
            mandates = r[0]
            creditorID = r[1] || ""
            suggestedCreditorID = r[2] || ""
            openReturns = r[3]
            if (selectedID !== null && !mandates.some(m => m.id === selectedID)) selectedID = null
            loadBookings()
            reloaded()
        }, e => { error = AppModel.parseCoreError(e).message })
    }
    /// Something changed: reload what is shown and the sidebar counter.
    function changed() {
        version++
        if (active) reload()
        SidebarModel.refreshCounts()
    }

    /// openReturns(of:): open returns of one mandate, newest first.
    function returnsOf(m) { return m ? openReturns.filter(r => r.mandate_id === m.id) : [] }

    /// loadMandateBookings
    property int bookingsGeneration: 0
    function loadBookings() {
        const m = selected
        const gen = ++bookingsGeneration
        if (!m) { bookings = []; return }
        AppModel.coreAsync("mandate_bookings", { mandate_id: m.id }, r => { if (gen === bookingsGeneration && selectedID === m.id) bookings = r },
                           () => { if (gen === bookingsGeneration) bookings = [] })
    }
    onSelectedIDChanged: loadBookings()

    /// acknowledgeReturns: the user looked at the returns of this mandate.
    function acknowledgeReturns(m) {
        AppModel.coreAsync("acknowledge_mandate_returns", { mandate_id: m.id }, () => changed(), () => changed())
    }

    /// moveMandateSelection: ↑/↓; stops at both ends like the booking list.
    function moveSelection(delta) {
        if (!mandates.length) return
        const idx = selectedID === null ? -1 : mandates.findIndex(m => m.id === selectedID)
        selectedID = mandates[Math.max(0, Math.min(mandates.length - 1, idx + delta))].id
    }

    // MARK: MandateDraft
    function newDraft(accountID) {
        return { id: null, account_id: accountID, name: "", iban: "", bic: "", reference: "", signed: new Date(),
                 scheme: "Core", oneOff: false, amountText: "", purpose: "", note: "", active: true }
    }
    function draftFrom(m) {
        return { id: m.id, account_id: m.account_id, name: m.debtor_name, iban: m.debtor_iban, bic: m.debtor_bic,
                 reference: m.reference, signed: Fmt.date(m.signed_date) || new Date(), scheme: m.scheme, oneOff: m.one_off,
                 amountText: m.default_amount_cents > 0 ? Fmt.plain(m.default_amount_cents) : "",
                 purpose: m.default_purpose, note: m.note, active: m.active }
    }
    function input(d) {
        const cents = Fmt.parseCents(d.amountText)
        return { account_id: d.account_id, debtor_name: d.name, debtor_iban: d.iban, debtor_bic: d.bic, reference: d.reference,
                 signed_date: Fmt.iso(d.signed), scheme: d.scheme, one_off: d.oneOff, default_amount_cents: cents === null ? 0 : cents,
                 default_purpose: d.purpose, note: d.note, active: d.active }
    }

    function newMandate() {
        if (!account) return
        error = ""
        draft = newDraft(account.id)
    }
    function editMandate(m) {
        error = ""
        draft = draftFrom(m)
    }
    /// saveMandateDraft: `d` is the sheet's copy.
    function saveDraft(d) {
        AppModel.coreAsync("save_mandate", { id: d.id, input: input(d) }, saved => {
            draft = null
            error = ""
            if (saved) selectedID = saved.id
            changed()
        }, e => { error = AppModel.parseCoreError(e).message })
    }
    function setActive(m, on) {
        const d = draftFrom(m)
        d.active = on
        AppModel.coreAsync("save_mandate", { id: m.id, input: input(d) }, () => changed(), () => changed())
    }
    function deleteMandate(m) {
        AppModel.coreAsync("delete_mandate", { id: m.id }, () => {
            if (selectedID === m.id) selectedID = null
            changed()
        }, () => changed())
    }
    /// saveCreditorID: "" removes it.
    function saveCreditorID(text) {
        if (!account) return
        AppModel.coreAsync("set_creditor_id", { account_id: account.id, creditor_id: text }, () => { error = ""; changed() },
                           e => { error = AppModel.parseCoreError(e).message; changed() })
    }

    // MARK: import / export
    function fileName(url) { const s = AppModel.localPath(url); return s.slice(s.lastIndexOf("/") + 1) }
    /// importMandateFile: a `pain.008` file (.xml) or a CSV member list.
    function importFile(url) {
        if (!account) return
        if (String(url).toLowerCase().endsWith(".xml")) importPain008(url); else importCSV(url)
    }
    function importNote(name, r) {
        let n = qsTr("„%1“: %2 neu, %3 aktualisiert").arg(name).arg(r.created).arg(r.updated)
        if (r.failed.length) n += qsTr(", %1 nicht übernommen (Zeile %2)").arg(r.failed.length).arg(r.failed[0])
        return n
    }
    function importPain008(url) {
        const acc = account.id, name = fileName(url)
        AppModel.coreAsync("read_text_file", { path: AppModel.localPath(url) }, xml => {
            AppModel.coreAsync("import_pain008", { account_id: acc, xml: xml }, r => {
                changed()
                note = importNote(name, r)
                error = ""
            }, e => { error = AppModel.parseCoreError(e).message })
        }, () => { error = qsTr("Die Datei konnte nicht gelesen werden.") })
    }
    function importCSV(url) {
        const acc = account.id, name = fileName(url)
        AppModel.coreAsync("read_mandate_csv", { path: AppModel.localPath(url) }, parsed => {
            if (parsed.problems.length) { error = parsed.problems[0]; return }
            AppModel.coreAsync("import_mandate_rows", { account_id: acc, rows: parsed.rows }, r => {
                changed()
                note = importNote(name, r)
                error = ""
            }, e => { error = AppModel.parseCoreError(e).message })
        }, e => { error = AppModel.parseCoreError(e).message })
    }
    /// exportMandates: the CSV of the account shown, written to `url` (file dialog).
    function exportTo(url) {
        if (!account) return
        AppModel.coreAsync("export_mandates_csv", { account_id: account.id }, csv => {
            AppModel.coreAsync("write_text_file", { path: AppModel.localPath(url), text: csv }, null,
                               e => { error = AppModel.parseCoreError(e).message })
        }, e => { error = AppModel.parseCoreError(e).message })
    }

    // MARK: Einzug (CollectionLine)
    function lineCents(l) { const c = Fmt.parseCents(l.amountText); return c !== null && c > 0 ? c : null }
    function lineAt(i) { return collectionLines.get(i) }
    function setLine(i, patch) { collectionLines.set(i, patch); linesRevision++ }
    readonly property var lineStats: {
        void linesRevision
        let count = 0, invalid = 0, total = 0
        for (let i = 0; i < collectionLines.count; ++i) {
            const l = collectionLines.get(i)
            if (!l.included) continue
            count++
            const c = lineCents(l)
            if (c === null) invalid++; else total += c
        }
        return { count: count, invalid: invalid, total: total }
    }
    function collectionItems() {
        const items = []
        for (let i = 0; i < collectionLines.count; ++i) {
            const l = collectionLines.get(i)
            const c = lineCents(l)
            if (l.included && c !== null) items.push({ mandate_id: l.mandateId, amount_cents: c, purpose: l.purpose, last_collection: l.lastCollection })
        }
        return items
    }

    /// openCollection
    function openCollection() {
        const act = mandates.filter(m => m.active)
        if (!act.length) return
        collectionLines.clear()
        for (const m of act)
            collectionLines.append({ mandateId: m.id, name: m.debtor_name, reference: m.reference, sequenceText: sequenceText(m.next_sequence),
                                     nextSequence: m.next_sequence, included: true,
                                     amountText: m.default_amount_cents > 0 ? Fmt.plain(m.default_amount_cents) : "",
                                     purpose: m.default_purpose, lastCollection: false })
        linesRevision++
        const due = new Date(); due.setHours(0, 0, 0, 0); due.setDate(due.getDate() + 5)
        collectionDue = due
        collectionFiles = []
        error = ""
        showCollectionSheet = true
    }
    /// buildCollection: the files for the included lines.
    function buildCollection(due) {
        if (!account) return
        AppModel.coreAsync("build_collection_files", { account_id: account.id, items: collectionItems(), collection_date: Fmt.iso(due) }, files => {
            collectionFiles = files
            error = ""
        }, e => { collectionFiles = []; error = AppModel.parseCoreError(e).message })
    }
    /// markCollected: after the files were handed to the bank by hand, the next collection of
    /// these mandates is a follow-up (`RCUR`); after the final one (`FNAL`) the mandate is done.
    function markCollected(files, due) {
        const ids = [].concat(...files.map(f => f.mandate_ids))
        AppModel.coreAsync("mark_collected", { mandate_ids: ids, due_date: Fmt.iso(due) }, () => finishMark(files), () => finishMark(files))
    }
    function finishMark(files) {
        for (const f of files) if (f.sequence === "FNAL")
            for (const id of f.mandate_ids) { const m = mandates.find(x => x.id === id); if (m) setActive(m, false) }
        showCollectionSheet = false
        collectionFiles = []
        changed()
    }

    // MARK: submit (AppModel+DirectDebitSubmit.swift)
    /// canSubmitDebits: the creditor account is a FinTS account that can send now.
    readonly property bool canSubmit: { void AppModel.bankingPolicy
        return account !== null && ["VolksbankKasselGoettingen", "Direkt1822", "FinTsGeneric"].indexOf(account.connector) >= 0
            && AppModel.canSendTransfer(account.id) && AppModel.activeTransfer === null }
    /// debitPinStored: the bank connection of the creditor account has a stored PIN.
    readonly property bool pinStored: {
        if (!account || account.connection_id === null) return false
        if (AppModel.isDemo) return true
        const st = AppModel.connectionStatus(account.connection_id)
        return st ? st.has_pin : false
    }

    /// submitCollection: every built file, one after the other (own TAN each).
    function submitCollection(due, b2bConfirmed, pin) {
        if (!account || !collectionFiles.length) return
        const acc = account.id
        debitRun = { accountID: acc, items: collectionItems(), due: Fmt.iso(due), remaining: collectionFiles.slice(),
                     total: collectionFiles.length, batchBooking: true, b2bConfirmed: b2bConfirmed, pin: pin }
        error = ""
        AppModel.withFreshBankingPolicy(() => {
            const gate = AppModel.bankingGateForAccount(acc)
            if (gate) { error = gate.message; debitRun = null; return }
            startNextGroup()
        })
    }
    function startNextGroup() {
        const run = debitRun
        if (!run || !run.remaining.length) return
        const file = run.remaining[0]
        const acct = AppModel.accountsByID[run.accountID]
        const connection = acct ? AppModel.connections.find(c => c.id === acct.connection_id) : null
        if (!connection) return
        if (!AppModel.isDemo && !pinStored && run.pin === "") {
            error = qsTr("Bitte die Banking-PIN eingeben.")
            debitRun = null
            return
        }
        const ids = file.mandate_ids
        const request = { account_id: run.accountID, items: run.items.filter(i => ids.indexOf(i.mandate_id) >= 0),
                          collection_date: run.due, sequence: file.sequence, b2b_confirmed: run.b2bConfirmed, batch_booking: run.batchBooking }
        let session
        try { session = AppModel.core("begin_direct_debit", { request: request, secret: AppModel.isDemo ? "demo" : run.pin, demo: AppModel.isDemo }) }
        catch (e) { error = AppModel.parseCoreError(e.message).message; debitRun = null; return }
        error = ""
        showCollectionSheet = false
        AppModel.runPaymentSession(session, connection, "debit")
    }
    /// finishDebitGroup: one group was accepted – next group, or done.
    function finishGroup() {
        Payments.plannedVersion++
        changed()
        const run = debitRun
        if (!run) return
        const rest = run.remaining.slice(1)
        if (!rest.length) {
            debitRun = null
            collectionFiles = []
            AppModel.toast = qsTr("Lastschriften eingereicht und unter „Geplant“ vorgemerkt")
            AppModel.reloadAll()
        } else {
            debitRun = Object.assign({}, run, { remaining: rest })
            startNextGroup()
        }
    }
    /// failDebitRun: the lines and files are still there.
    function failRun(message) {
        debitRun = null
        error = message
        showCollectionSheet = true
        changed()
    }
    /// debitOutcomeUnknown
    function outcomeUnknown(reason) {
        debitRun = null
        collectionFiles = []
        error = qsTr("Ob die Bank den Einzug angenommen hat, ist unklar. Bitte erst im Online-Banking prüfen und die Einzüge nicht erneut einreichen, bevor das geklärt ist.") + " " + reason
        showCollectionSheet = true
        changed()
    }
    /// cancelSync for a collection run: its sheet comes back with a notice.
    function cancelRun() {
        failRun(qsTr("Einzug abgebrochen – die TAN wurde nicht bestätigt. Bereits freigegebene Dateien bitte unter „Geplant“ prüfen, bevor Sie erneut einreichen."))
    }
    /// endBankDialogsForLock: no sheet stays open, no PIN stays in memory.
    function endForLock() {
        debitRun = null
        showCollectionSheet = false
        draft = null
        collectionFiles = []
    }

    property Connections vaultWatch: Connections {
        target: AppModel
        function onVaultGenerationChanged() {
            dd.mandates = []; dd.selectedID = null; dd.accountID = null; dd.openReturns = []; dd.bookings = []
            dd.creditorID = ""; dd.suggestedCreditorID = ""; dd.error = ""; dd.note = ""
            dd.endForLock()
        }
    }

    // MARK: `--demo-sheet` (AppModel.swift › presentDemoSheet)
    /// true when `name` is one of the „Lastschriften“ sheets (then it is opened here).
    function presentDemoSheet(name) {
        switch (name) {
        case "mandate": case "collection": case "collection-files": case "mandate-select":
            AppModel.sidebarSelection = "directDebits"
            reload()
            if (name === "mandate") {
                newMandate()
                draft = Object.assign({}, draft || newDraft(null), { name: "Mia Beispiel", iban: "DE89 3704 0044 0532 0130 00",
                                                                reference: "M-2026-001", amountText: "12,50", purpose: "Mitgliedsbeitrag" })
            } else if (name === "mandate-select") {
                // the mandate with the returned collection, selected for the inspector
                const m = mandates.find(x => x.reference === "M-2025-014")
                selectedID = m ? m.id : null
            } else {
                openCollection()
                // `collection-files`: the step after "Dateien erzeugen", with the submit area
                if (name === "collection-files") buildCollection(collectionDue)
            }
            return true
        }
        return false
    }
}
