pragma Singleton
import QtQuick

// AppModel+Planned.swift: state of „Geplant“ (GitHub #240) – everything already ordered at
// the bank but not booked yet, across accounts. Only real orders, never guesses from the
// booking history. The list (PlannedPaymentsView.qml) and its inspector
// (PlannedInspector.qml) read it; standing order actions go through Payments.qml.
QtObject {
    id: pl

    // AppModel.swift › plannedPayments, plannedMonths, plannedTotals, plannedAccountFilter,
    // plannedHorizon, selectedPlannedID
    property var payments: []
    /// `payments` grouped by month, computed once per reload: [{ id: "YYYY-MM", items, sumCents }].
    property var months: []
    property var totals: ({ count: 0, outgoing_cents: 0, incoming_cents: 0 })
    /// null = all accounts.
    property var accountFilter: null
    /// PlannedHorizon: "days30" | "days90" | "year1" | "all".
    property string horizon: "days90"
    property var selectedID: null
    /// The view is on screen: changes reload only then (`.task(id:)`).
    property bool active: false

    readonly property var horizons: ["days30", "days90", "year1", "all"]
    /// PlannedHorizon.title
    function horizonTitle(h) {
        switch (h) {
        case "days30": return qsTr("30 Tage")
        case "days90": return qsTr("3 Monate")
        case "year1": return qsTr("12 Monate")
        }
        return qsTr("Alles")
    }
    /// PlannedHorizon.endISO: last day (`YYYY-MM-DD`) or null for no limit.
    function endISO(h) {
        const days = ({ days30: 30, days90: 90, year1: 365 })[h]
        if (days === undefined) return null
        const d = new Date()
        d.setDate(d.getDate() + days)
        return Fmt.iso(d)
    }

    readonly property var selected: {
        const id = selectedID
        return id === null ? null : (payments.find(p => p.id === id) || null)
    }

    function setAccountFilter(id) { if (accountFilter !== id) { accountFilter = id; reload() } }
    function setHorizon(h) { if (horizon !== h) { horizon = h; reload() } }

    /// reloadPlanned: list, sums and the stored standing orders off the GUI thread; an answer
    /// of a swapped vault or of an older filter state is dropped (AppModel.loadOffMain).
    function reload() {
        if (!AppModel.isUnlocked) return
        AppModel.loadOffMain("planned", () => {
            const accounts = pl.accountFilter === null ? [] : [pl.accountFilter]
            const to = endISO(pl.horizon)
            const range = { from: null, to: to, account_ids: accounts }
            return [["list_planned_payments", range], ["planned_payment_totals", range],
                    ["list_standing_orders", { account_ids: [] }]]
        }, r => {
            Payments.standingOrders = r[2]
            payments = r[0]
            months = group(r[0])
            totals = r[1]
            if (selectedID !== null && !r[0].some(p => p.id === selectedID)) selectedID = null
        }, () => {})
    }

    /// PlannedMonth.group: payments already sorted by date in one pass; a payment out of
    /// order only starts another card, nothing gets lost.
    function group(list) {
        const out = []
        let key = "", items = []
        const flush = () => { if (items.length) out.push({ id: key, items: items, sumCents: items.reduce((s, p) => s + p.amount_cents, 0) }) }
        for (const p of list) {
            const k = p.date.slice(0, 7)
            if (k !== key) { flush(); items = []; key = k }
            items.push(p)
        }
        flush()
        return out
    }

    /// movePlannedSelection: ↑/↓ – the neighbour of the selected payment (the first one when
    /// nothing is selected); stops at both ends like the booking list.
    function moveSelection(delta) {
        if (!payments.length) return
        const idx = selectedID === null ? -1 : payments.findIndex(p => p.id === selectedID)
        selectedID = payments[Math.max(0, Math.min(payments.length - 1, idx + delta))].id
    }

    // PlannedPayment.kindSymbol / kindText / rhythmText
    function kindSymbol(p) {
        return p.kind === "StandingOrder" ? "repeat" : p.kind === "DirectDebit" ? "arrow.down.circle" : "calendar.badge.clock"
    }
    /// "Terminüberweisung", "Lastschrift" or "Dauerauftrag · monatlich".
    function kindText(p) {
        if (p.kind === "DirectDebit") return qsTr("Lastschrift")
        if (p.kind !== "StandingOrder") return qsTr("Terminüberweisung")
        return qsTr("Dauerauftrag") + " · " + rhythmText(p)
    }
    function rhythmText(p) {
        const n = p.rhythm_interval
        if (p.rhythm_unit === "W") return n <= 1 ? qsTr("wöchentlich") : qsTr("alle %1 Wochen").arg(n)
        if (n <= 1) return qsTr("monatlich")
        switch (n) {
        case 3: return qsTr("vierteljährlich")
        case 6: return qsTr("halbjährlich")
        case 12: return qsTr("jährlich")
        }
        return qsTr("alle %1 Monate").arg(n)
    }

    // `.task(id: ReloadKey(… version: plannedVersion))`: a payment reached the bank, a standing
    // order changed – reload while the page is shown; the sidebar counter follows in any case.
    property Connections paymentsWatch: Connections {
        target: Payments
        function onPlannedVersionChanged() {
            if (pl.active) pl.reload()
            SidebarModel.refreshCounts()
        }
    }
    // Linux: after a sync (accounts reloaded) the orders the bank reported show at once.
    property Connections accountsWatch: Connections {
        target: AppModel
        function onGroupsChanged() { if (pl.active) pl.reload() }
        // another vault in front: nothing of the old one stays
        function onVaultGenerationChanged() {
            pl.payments = []; pl.months = []; pl.selectedID = null; pl.accountFilter = null
            pl.totals = { count: 0, outgoing_cents: 0, incoming_cents: 0 }
        }
    }
}
