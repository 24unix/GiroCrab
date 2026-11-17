pragma Singleton
import QtQuick
import QtCore

// InspectorLayout.swift (#448): order and visibility of the inspector cards (right-hand column),
// stored per device like UserDefaults (`inspectorLayout` in GiroCrab.conf). Layout only, no
// vault data. A layout is { order: [section id], hidden: { id: true } }: every section exactly
// once, the visible ones first, then the hidden ones.
QtObject {
    id: layouts

    /// InspectorSection: the case order is the standard layout. The merchant history, whose
    /// stats load later and grow the card, comes after the category and document cards (#492).
    readonly property var sections: [
        { id: "receipt", title: qsTr("Buchung"), symbol: "doc.text" },
        { id: "note", title: qsTr("Notiz"), symbol: "note.text" },
        { id: "tags", title: qsTr("Tags"), symbol: "number" },
        { id: "salary", title: qsTr("Gehalt / Rente"), symbol: "briefcase" },
        { id: "recurring", title: qsTr("Wiederkehrend"), symbol: "repeat" },
        { id: "categories", title: qsTr("Kategorie"), symbol: "tag" },
        { id: "documents", title: qsTr("Belege & Abrechnungen"), symbol: "paperclip" },
        { id: "merchantHistory", title: qsTr("Händler-Historie"), symbol: "clock.arrow.circlepath" },
        { id: "rawData", title: qsTr("SEPA & Bank-Rohdaten"), symbol: "doc.plaintext" }]
    readonly property var allIDs: sections.map(s => s.id)
    function section(id) { return sections.find(s => s.id === id) || null }

    property Settings store: Settings { property string inspectorLayout: "" }

    /// Standard layouts of earlier versions, as „Zurücksetzen“ stored them: read as the current standard.
    readonly property var formerStandardValues: [
        "receipt,note,salary,recurring,categories,documents,merchantHistory,rawData"]   // v0.7.5 (#448)

    /// The stored layout (unknown names skipped, missing ones appended).
    readonly property var current: parse(store.inspectorLayout)
    /// The visible and the hidden sections in order. Replaced only when they really change:
    /// a new array rebuilds every card of the inspector (and would drop a note being typed).
    property var shown: []
    property var hiddenSections: []
    onCurrentChanged: syncLists()
    Component.onCompleted: syncLists()
    function syncLists() {
        const s = current.order.filter(id => !current.hidden[id]), h = current.order.filter(id => current.hidden[id])
        if (s.join() !== shown.join()) shown = s
        if (h.join() !== hiddenSections.join()) hiddenSections = h
    }
    readonly property bool isStandard: isStandardLayout(current)

    /// InspectorLayout.init(order:hidden:): duplicates dropped, sections added in a later
    /// version (or lost in a broken value) at the end, then visible before hidden.
    function make(order, hidden) {
        const seen = {}
        let cleaned = order.filter(id => allIDs.indexOf(id) >= 0 && !seen[id] && (seen[id] = true))
        cleaned = cleaned.concat(allIDs.filter(id => !seen[id]))
        const h = {}
        for (const id of Object.keys(hidden)) if (allIDs.indexOf(id) >= 0) h[id] = true
        return { order: cleaned.filter(id => !h[id]).concat(cleaned.filter(id => h[id])), hidden: h }
    }
    readonly property var standard: make(allIDs, {})
    function isStandardLayout(l) { return storageValue(l) === storageValue(standard) }
    /// `"receipt,note,-salary"`: the order, hidden sections prefixed with `-`.
    function storageValue(l) { return l.order.map(id => l.hidden[id] ? "-" + id : id).join(",") }
    function parse(value) {
        if (!value || formerStandardValues.indexOf(value) >= 0) return standard
        const order = [], hidden = {}
        for (const token of value.split(",")) {
            const isHidden = token.startsWith("-")
            const id = isHidden ? token.slice(1) : token
            if (allIDs.indexOf(id) < 0) continue
            order.push(id)
            if (isHidden) hidden[id] = true
        }
        return make(order, hidden)
    }
    /// Stores `l`: empty for the standard layout, so a card added in a later version takes its
    /// standard place (#228) instead of landing at the bottom.
    function save(l) { store.inspectorLayout = isStandardLayout(l) ? "" : storageValue(l) }

    /// Puts `id` at `index` of the visible list (0 = top); shows it if it was hidden.
    function move(id, index) {
        const l = current
        const list = shown.filter(x => x !== id)
        list.splice(Math.min(Math.max(index, 0), list.length), 0, id)
        const hidden = Object.assign({}, l.hidden)
        delete hidden[id]
        save(make(list.concat(l.order.filter(x => hidden[x])), hidden))
    }
    /// Drop of `id` into `gap` of the visible list as drawn while dragging, i.e. still containing
    /// `id` itself (gap 0 = above the first card, shown.length = below the last).
    function insert(id, gap) {
        const at = shown.indexOf(id)
        move(id, at >= 0 && at < gap ? gap - 1 : gap)
    }
    /// Hides `id`; it becomes the last of the hidden ones.
    function hide(id) {
        const l = current
        if (l.hidden[id]) return
        const hidden = Object.assign({}, l.hidden)
        hidden[id] = true
        save(make(shown.filter(x => x !== id).concat(hiddenSections, [id]), hidden))
    }
    /// Shows a hidden `id` again at the bottom of the visible list.
    function show(id) { if (current.hidden[id]) move(id, shown.length) }
    function reset() { save(standard) }
}
