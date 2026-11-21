pragma Singleton
import QtQuick

// OfflineAccountsUI.swift › OfflineStore + `extension AppModel` (GitHub #679, #81): cash and other
// accounts without a bank connection. The user types the bookings; the balance is the starting
// balance plus the bookings (the core keeps it: `offline.rs`). Everything else (categories, rules,
// totals, charts) treats these accounts like any other. The sheets: OfflineAccountSheets.qml.
QtObject {
    id: store

    /// OfflineStore.accountIDs: which accounts take manual bookings. Re-read with the accounts
    /// (`rebuildAccountIndex` › reloadOfflineAccounts; a small indexed query).
    readonly property var ids: {
        if (!AppModel.isUnlocked || !AppModel.groups.length) return []
        try { return AppModel.core("list_offline_account_ids") } catch (e) { return [] }
    }
    /// "Neue Buchung …" / "Buchung bearbeiten …": { accountId, booking (null = new) } or null.
    property var bookingRequest: null
    /// "Neues Offline-Konto …".
    property bool showNewAccount: false
    /// "Saldo korrigieren …": { accountId } or null.
    property var correctionRequest: null
    /// Waiting for the answer of "Buchung löschen …".
    property var deleting: null

    function isOffline(accountId) { return ids.indexOf(accountId) >= 0 }

    /// Offline accounts that take new bookings (not archived), in sidebar order.
    readonly property var offlineAccounts: AppModel.allAccounts.filter(a => store.isOffline(a.id) && a.archived_unix === null)

    /// The selected sidebar account, if it takes manual bookings.
    readonly property var selectedOfflineAccount: {
        const a = AppModel.selectedAccount
        return a && isOffline(a.id) && a.archived_unix === null ? a : null
    }

    readonly property bool canAddManualBooking: AppModel.isUnlocked && offlineAccounts.length > 0

    /// Whether `booking` can be edited or deleted by hand.
    function isManuallyEditable(b) {
        if (!b || !isOffline(b.account_id)) return false
        const a = AppModel.accountsByID[b.account_id]
        return !!a && a.archived_unix === null
    }

    /// "Neue Buchung …": in the selected offline account, else the first one.
    function openManualBooking(accountId) {
        const target = accountId !== undefined && accountId !== null ? accountId
            : selectedOfflineAccount ? selectedOfflineAccount.id
            : offlineAccounts.length ? offlineAccounts[0].id : null
        if (target === null) return
        bookingRequest = { accountId: target, booking: null }
    }

    function editManualBooking(b) {
        if (!isManuallyEditable(b)) return
        bookingRequest = { accountId: b.account_id, booking: b }
    }

    function openBalanceCorrection(accountId) { correctionRequest = { accountId: accountId } }

    /// Everything a changed booking or balance shows up in.
    function reloadAfterManualChange() {
        AppModel.reloadAccounts(); AppModel.reloadBookings(); AppModel.reloadHistory(); AppModel.reloadCategories()
        // a manual booking can start or end a recurring payment and changes the planning (#1514)
        AppModel.refreshRecurring(); AppModel.reloadPlanning()
    }

    /// Creates (`bookingId` null) or changes a booking; returns its id. Throws on a core error.
    function saveManualBooking(accountId, bookingId, setup) {
        const id = AppModel.core("save_manual_booking", { account_id: accountId, booking_id: bookingId, setup: setup })
        reloadAfterManualChange()
        return id
    }

    function deleteManualBooking(b) {
        if (AppModel.run(() => { AppModel.core("delete_manual_booking", { booking_id: b.id }); return true }) === undefined) return
        if (AppModel.selectedBookingID === b.id) AppModel.selectedBookingID = null
        AppModel.toast = qsTr("Buchung gelöscht")
        reloadAfterManualChange()
    }

    /// AppModel.runInOwnVault (#487): the action runs in the own vault, not the demo. Coming from
    /// the demo the own vault comes to the front; without one it is unlocked first.
    property var pendingOwnVaultAction: null
    function runInOwnVault(action) {
        if (!AppModel.demoActive) { action(); return }
        if (AppModel.hasOwnVault) { AppModel.useVault(false); action(); return }
        pendingOwnVaultAction = action
        AppModel.vaultState = "locked"
        AppModel.unlock()
    }
    property Connections ownVaultWatch: Connections {
        target: AppModel
        function onVaultStateChanged() {
            const f = store.pendingOwnVaultAction
            if (f === null || AppModel.vaultState !== "open") return
            store.pendingOwnVaultAction = null
            // cancelled before any own vault exists: back in the demo, the action is dropped
            if (!AppModel.hasOwnVault) return
            if (AppModel.demoActive) AppModel.useVault(false)
            f()
        }
    }
    function openNewAccount() { runInOwnVault(() => { store.showNewAccount = true }) }

    /// "Neues Offline-Konto …": always cash, with its account note (#980).
    function createOfflineAccount(name, note, openingCents) {
        runInOwnVault(() => {
            const id = AppModel.run(() => AppModel.core("create_offline_account", { name: name, kind: "Cash", currency: "", opening_cents: openingCents }))
            if (id === undefined) return
            // the note is a field of the account (#980): set before the one reload
            if (note.trim() !== "") AppModel.run(() => { AppModel.core("set_account_note", { account_id: id, note: note.trim() }); return true })
            AppModel.reloadAccounts(() => { AppModel.sidebarSelection = "account:" + id })
        })
    }

    /// One-time copy of `b` into `account` with the amount reversed and no category.
    function mirror(b, account) {
        if (AppModel.run(() => AppModel.core("mirror_booking_to_offline_account", { booking_id: b.id, account_id: account.id })) === undefined) return
        AppModel.toast = qsTr("Buchung in „%1“ gespiegelt").arg(account.name)
        reloadAfterManualChange()
    }

    function correctBalance(accountId, targetCents) {
        const r = AppModel.run(() => AppModel.core("correct_offline_balance", { account_id: accountId, target_cents: targetCents }))
        if (r === undefined) return
        if (r === null) { AppModel.toast = qsTr("Der Saldo stimmt bereits."); return }
        AppModel.toast = qsTr("Korrekturbuchung angelegt")
        reloadAfterManualChange()
    }
}
