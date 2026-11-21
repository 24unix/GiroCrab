pragma Singleton
import QtQuick

// Category suggestions from the booking history (#664), kept apart from AppModel.qml:
// - AppModel.swift › categorySuggestion / listSuggestions,
// - AppModel+Loading.swift › loadCategorySuggestion (stage 1–3: same IBAN, same merchant,
//   similar booking text), loadListSuggestions, refreshSelectedBookingHistory,
// - BookingDetailView.swift › CategorySuggestionBox.ruleDraft / reason.
// The core decides which bookings get one (only uncategorised ones with a clear history) and
// keeps the history until the data changes; the first call after a change scans it, so both
// loads run off the GUI thread (`loadOffMain`: latest wins, answers of another vault dropped)
// after the same short delay as the merchant history. Nothing is stored: a suggestion counts
// in no sum and no budget until it is taken over.
QtObject {
    id: cs

    /// Suggestion for the selected booking ({ booking_id, category_id, basis, support, considered }), or null.
    property var selected: null
    /// The same for the uncategorised rows of the list, by booking id.
    property var list: ({})

    /// The category of a suggestion, or null when it is gone (deleted meanwhile).
    function category(s) { return s ? AppModel.categoryByID(s.category_id) : null }
    /// The suggestion for this booking in the list (row hint, row menu), or null.
    function forBooking(b) {
        if (!b || b.category_id !== null) return null
        return list[b.id] || null
    }
    /// The inspector's suggestion for this booking, or null.
    function forSelected(b) {
        return b && selected && selected.booking_id === b.id && b.category_id === null ? selected : null
    }

    // MARK: selected booking (AppModel+Loading.swift › loadCategorySuggestion)
    property Timer selectedTimer: Timer { interval: 80; onTriggered: cs.loadSelectedNow() }
    /// `keepShown`: after a data change the shown suggestion of the same booking stays until
    /// the fresh one arrives (no flicker).
    function loadSelected(keepShown) {
        // Not `selectedBooking`: inside onSelectedBookingIDChanged that binding may be stale.
        const b = AppModel.bookingByID(AppModel.selectedBookingID)
        // a categorised booking needs no call (and loses a shown suggestion at once)
        if (!b || b.category_id !== null || !AppModel.isUnlocked) {
            selectedTimer.stop(); AppModel.cancelLoad("suggestion")
            selected = null
            return
        }
        if (!(keepShown && selected && selected.booking_id === b.id)) selected = null
        if (AppModel.demoActive) loadSelectedNow()
        else selectedTimer.restart()
    }
    function loadSelectedNow() {
        AppModel.loadOffMain("suggestion", () => {
            const b = AppModel.bookingByID(AppModel.selectedBookingID)
            if (!b || b.category_id !== null) return null
            return { calls: [["suggest_categories", { booking_ids: [b.id] }]], ctx: b.id }
        }, (r, id) => {
            if (AppModel.selectedBookingID !== id) return
            selected = r[0].length ? r[0][0] : null
        }, () => { selected = null })   // a failed call leaves no stale suggestion
    }

    // MARK: list rows (AppModel+Loading.swift › loadListSuggestions)
    property Timer listTimer: Timer { interval: 80; onTriggered: cs.loadListNow() }
    /// After each change of `bookings` (reload, paging, an edit): the shown suggestions stay
    /// until the new set arrives.
    function loadList() {
        if (!AppModel.isUnlocked || !AppModel.bookings.some(b => b.category_id === null)) {
            listTimer.stop(); AppModel.cancelLoad("listSuggestions")
            if (Object.keys(list).length) list = ({})
            return
        }
        if (AppModel.demoActive) loadListNow()
        else listTimer.restart()
    }
    function loadListNow() {
        AppModel.loadOffMain("listSuggestions", () => {
            const ids = AppModel.bookings.filter(b => b.category_id === null).map(b => b.id)
            return ids.length ? [["suggest_categories", { booking_ids: ids }]] : null
        }, r => {
            const map = {}
            for (const s of r[0]) if (map[s.booking_id] === undefined) map[s.booking_id] = s
            list = map
        }, () => { list = ({}) })
    }

    function clear() {
        selectedTimer.stop(); listTimer.stop()
        AppModel.cancelLoad("suggestion"); AppModel.cancelLoad("listSuggestions")
        selected = null; list = ({})
    }

    property Connections watch: Connections {
        target: AppModel
        function onSelectedBookingIDChanged() { cs.loadSelected(false) }
        // every reload (edit, sync, import) and paging hands in a new list: the selected
        // booking's suggestion again too (refreshSelectedBookingHistory)
        function onBookingsChanged() { cs.loadList(); cs.loadSelected(true) }
        function onVaultReplaced() { cs.clear() }
    }
    // the singleton is created on first use: a list loaded before that gets its suggestions now
    Component.onCompleted: { loadList(); loadSelected(false) }

    // MARK: texts and actions (BookingDetailView.swift › CategorySuggestionBox)
    /// At least two bookings back a suggestion, so the plural always fits. The core weighs
    /// the votes, so a split count says why it still decided.
    function reason(s) {
        const n = s.support, of = s.considered
        if (n === of) {
            if (s.basis === "Iban") return qsTr("Wie alle %1 Buchungen an diese IBAN").arg(n)
            if (s.basis === "Merchant") return qsTr("Wie alle %1 Buchungen bei diesem Händler").arg(n)
            return qsTr("Wie alle %1 Buchungen mit ähnlichem Text").arg(n)
        }
        if (s.basis === "Iban") return qsTr("Wie %1 von %2 Buchungen an diese IBAN; zeitnahe zählen mehr, Regel-Buchungen weniger").arg(n).arg(of)
        if (s.basis === "Merchant") return qsTr("Wie %1 von %2 Buchungen bei diesem Händler; zeitnahe zählen mehr, Regel-Buchungen weniger").arg(n).arg(of)
        return qsTr("Wie %1 von %2 Buchungen mit ähnlichem Text; ähnlichere und zeitnahe zählen mehr").arg(n).arg(of)
    }
    /// „Als Regel …“: the usual draft with the suggested category, matching the IBAN when
    /// that is what told this payee apart from a namesake (AppModel+Editing.swift ›
    /// openRuleEditor(draft:)).
    function openRule(booking, s) {
        AppModel.reloadRulesNow()   // the draft's priority comes after the last rule
        const rule = AppModel.newRuleDraft(booking)
        rule.category_id = s.category_id
        const iban = (booking.counterparty_iban || "").replace(/\s/g, "")
        if (s.basis === "Iban" && iban !== "") {
            rule.field = "CounterpartyIban"
            rule.pattern = iban
        }
        AppModel.ruleDraft = rule
        AppModel.showRuleEditor = true
    }
}
