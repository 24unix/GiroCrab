pragma Singleton
import QtQuick

// AppModel+Tags.swift › „Tag management window (#228, part 2b)“ and AppModelTypes.swift ›
// TagDraft / TagRenameIntent: the state behind Konten › Tags verwalten … (TagManagerSheet.qml).
// Names, colours and order changed in the sheet are a draft, stored when the sheet closes
// (`applyDraft`), so the sidebar and the booking rows behind it stay as they were until then.
// Creating, merging and deleting act at once. The Mac registers no undo for any of these
// (deleteTags: „no undo: the core never revives a deleted tag“).
QtObject {
    id: mgr

    /// AppModel.showTagManager: Konten › Tags verwalten … (Strg+Umschalt+T) and the tag card's „Verwalten …“.
    property bool shown: false
    /// AppModel.tagDraft: { renames: {id: name}, colors: {id: hex}, order: [id] | null }.
    property var draft: ({ renames: {}, colors: {}, order: null })
    readonly property bool draftEmpty: Object.keys(draft.renames).length === 0 && Object.keys(draft.colors).length === 0 && draft.order === null

    /// The tags as the sheet shows them: with the names and colours changed there.
    readonly property var current: drafted(TagsModel.tags, draft)
    /// The tags in the sheet's order: the pending arrangement, tags new since then after it.
    readonly property var ordered: {
        const tags = current
        if (draft.order === null) return tags
        const byID = {}
        for (const t of tags) byID[t.id] = t
        return tagOrder(draft.order, tags).map(id => byID[id]).filter(t => t !== undefined)
    }
    /// AppModel.unusedTags: tags without bookings („Ungenutzte entfernen“).
    readonly property var unusedTags: TagsModel.tags.filter(t => t.booking_count === 0)

    function open() { if (AppModel.isUnlocked) shown = true }

    // MARK: the draft (reassigned as a whole, so bindings follow)
    function setRename(id, name) { const r = Object.assign({}, draft.renames); r[id] = name; draft = Object.assign({}, draft, { renames: r }) }
    function setColor(id, hex) { const c = Object.assign({}, draft.colors); c[id] = hex; draft = Object.assign({}, draft, { colors: c }) }
    function setOrder(ids) { draft = Object.assign({}, draft, { order: ids }) }
    function clearDraft() { draft = { renames: {}, colors: {}, order: null } }

    /// AppModel.tagsDrafted: the tags with the sheet's unsaved names and colours.
    function drafted(tags, d) {
        if (Object.keys(d.renames).length === 0 && Object.keys(d.colors).length === 0) return tags
        return tags.map(t => {
            const name = d.renames[t.id], hex = d.colors[t.id]
            if (name === undefined && hex === undefined) return t
            const c = Object.assign({}, t)
            if (name !== undefined) c.name = name
            if (hex !== undefined) c.color_hex = hex
            return c
        })
    }
    /// AppModel.tagOrder: `pending` without the tags gone since, the tags new since then after it.
    function tagOrder(pending, tags) {
        const live = {}, listed = {}
        for (const t of tags) live[t.id] = true
        for (const id of pending) listed[id] = true
        return pending.filter(id => live[id]).concat(tags.map(t => t.id).filter(id => !listed[id]))
    }
    /// localizedStandardCompare: case-insensitive, numbers by value.
    function compareNames(a, b) { return a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" }) }
    /// „Sortieren › Nach Name“.
    function idsByName(tags) { return tags.slice().sort((a, b) => compareNames(a.name, b.name)).map(t => t.id) }
    /// „Sortieren › Meiste / Wenigste Buchungen zuerst“; equal counts by name.
    function idsByBookings(tags, mostFirst) {
        return tags.slice().sort((a, b) => {
            if (a.booking_count !== b.booking_count) return mostFirst ? b.booking_count - a.booking_count : a.booking_count - b.booking_count
            return compareNames(a.name, b.name)
        }).map(t => t.id)
    }

    // MARK: checks of the name sheet
    /// AppModel.tagEntryIntent against `tags` (nothing carried): { kind: "none" | "create" | "add" | "similar" | "tooLong", name, existing }.
    function entryIntent(text, tags) {
        const name = TagsModel.cleanTagName(text)
        if (name === "") return { kind: "none" }
        if ([...name].length > TagsModel.maxTagNameLength) return { kind: "tooLong" }
        const key = TagsModel.tagKey(name)
        const known = tags.find(t => TagsModel.tagKey(t.name) === key)
        if (known) return { kind: "add", id: known.id, existing: known.name }
        const loose = TagsModel.lookAlikeKey(name)
        const alike = loose !== "" ? tags.find(t => TagsModel.lookAlikeKey(t.name) === loose) : null
        if (alike) return { kind: "similar", name: name, existing: alike.name }
        return { kind: "create", name: name }
    }
    /// AppModel.tagRenameIntent: { kind: "empty" | "unchanged" | "rename" | "taken" | "similar" | "tooLong", name, existing }.
    function renameIntent(text, tags, id) {
        const name = TagsModel.cleanTagName(text)
        if (name === "") return { kind: "empty" }
        if ([...name].length > TagsModel.maxTagNameLength) return { kind: "tooLong" }
        const cur = tags.find(t => t.id === id)
        if (cur && cur.name === name) return { kind: "unchanged" }
        const key = TagsModel.tagKey(name)
        const other = tags.find(t => t.id !== id && TagsModel.tagKey(t.name) === key)
        if (other) return { kind: "taken", existing: other.name }
        const loose = TagsModel.lookAlikeKey(name)
        if (cur && TagsModel.tagKey(cur.name) !== key && loose !== "") {
            const alike = tags.find(t => t.id !== id && TagsModel.lookAlikeKey(t.name) === loose)
            if (alike) return { kind: "similar", name: name, existing: alike.name }
        }
        return { kind: "rename", name: name }
    }

    // MARK: changes
    /// AppModel.createTag(named:): a new tag; null when the name is empty or taken (the sheet says so first).
    function createTag(name) {
        const kind = entryIntent(name, TagsModel.tags).kind
        if (kind !== "create" && kind !== "similar") return null
        return TagsModel.tagNamed(name)
    }
    /// TagManagerView.create: right away (it only adds). A name that is free only because a
    /// tag here gets another one needs those names stored first.
    function createFromSheet(name) {
        if (createTag(name) === null && Object.keys(draft.renames).length > 0) {
            applyRenames(draft.renames)
            draft = Object.assign({}, draft, { renames: {} })
            createTag(name)
        }
    }

    /// AppModel.applyTagDraft: stores the sheet's draft (on closing it) and clears it.
    function applyDraft() {
        const d = draft
        clearDraft()
        if ((Object.keys(d.renames).length === 0 && Object.keys(d.colors).length === 0 && d.order === null) || !AppModel.isUnlocked) return
        if (Object.keys(d.renames).length > 0) applyRenames(d.renames)
        const live = {}
        for (const t of TagsModel.tags) live[t.id] = t.color_hex
        const colors = Object.keys(d.colors).filter(id => live[id] !== undefined && live[id] !== d.colors[id])
        if (colors.length > 0) {
            AppModel.run(() => { for (const id of colors) AppModel.core("set_tag_color", { id: Number(id), color_hex: d.colors[id] }) })
            afterTagEdit()
        }
        if (d.order !== null) applyOrder(d.order)
    }

    /// AppModel.applyTagRenames: the core refuses a name another tag still has, so a rename
    /// waits until its name is free; names that only swap places go through a temporary name.
    /// A name held by a tag outside the sheet's changes (synced in meanwhile) is reported.
    function applyRenames(renames) {
        if (!AppModel.isUnlocked) return false
        const names = {}
        for (const t of TagsModel.tags) names[t.id] = t.name
        const pending = {}
        for (const id of Object.keys(renames)) {
            const clean = TagsModel.cleanTagName(renames[id])
            if (names[id] !== undefined && names[id] !== clean && clean !== "") pending[id] = clean
        }
        let ok = true
        function rename(id, name) {
            try {
                AppModel.core("rename_tag", { id: Number(id), name: name })
                names[id] = name
            } catch (e) {
                AppModel.errorMessage = e.message
                ok = false
            }
        }
        function blockers(id) {
            const key = TagsModel.tagKey(pending[id] || "")
            return Object.keys(names).filter(k => k !== id && TagsModel.tagKey(names[k]) === key)
        }
        while (Object.keys(pending).length > 0) {
            const ids = Object.keys(pending).sort((a, b) => Number(a) - Number(b))
            const free = ids.find(id => blockers(id).length === 0)
            const swap = free === undefined ? ids.find(id => blockers(id).every(b => pending[b] !== undefined)) : undefined
            if (free !== undefined) {
                rename(free, pending[free])
                delete pending[free]
            } else if (swap !== undefined) {
                // a swap: park the tag that blocks this one under a free name
                const parked = blockers(swap)[0]
                rename(parked, "~" + parked + "-" + Math.random().toString(16).slice(2, 10).toUpperCase())
                if (!ok) delete pending[parked]
            } else {
                rename(ids[0], pending[ids[0]])   // refused by the core: reports the clash
                delete pending[ids[0]]
            }
        }
        afterTagEdit()
        return ok
    }

    /// AppModel.applyTagOrder / reorderTags: the order the sheet arranged (on closing it).
    function applyOrder(ids) {
        const order = tagOrder(ids, TagsModel.tags)
        if (!AppModel.isUnlocked || order.join(",") === TagsModel.tags.map(t => t.id).join(",")) return
        AppModel.run(() => AppModel.core("reorder_tags", { ids: order }))
        afterTagEdit()
    }

    /// AppModel.deleteTags: they drop off every booking (asked for beforehand, no undo).
    function deleteTags(ids) {
        if (!AppModel.isUnlocked || ids.length === 0) return
        AppModel.run(() => { for (const id of ids) AppModel.core("delete_tag", { id: id }) })
        afterTagEdit()
    }

    /// AppModel.mergeTags: every booking of `sources` carries `target` afterwards; the sources are gone.
    function mergeTags(sources, target) {
        if (!AppModel.isUnlocked) return
        AppModel.run(() => { for (const s of sources) if (s !== target) AppModel.core("merge_tag_into", { source: s, target: target }) })
        afterTagEdit()
    }

    function removeUnusedTags() { deleteTags(unusedTags.map(t => t.id)) }

    /// Names, colours and order show in the rows and the inspector: reload them.
    function afterTagEdit() {
        TagsModel.reload()
        AppModel.reloadBookings()
        const s = AppModel.stickyBooking
        if (s !== null) AppModel.stickyBooking = AppModel.freshBooking(s) || s
    }

    /// releaseVaultState: another vault (demo / own, lock, reset) closes the sheet; its draft
    /// belongs to the old vault (a lock stores it first, AppModel.lock).
    property Connections vaultWatch: Connections {
        target: AppModel
        function onVaultReplaced() { mgr.clearDraft(); mgr.shown = false }
    }
}
