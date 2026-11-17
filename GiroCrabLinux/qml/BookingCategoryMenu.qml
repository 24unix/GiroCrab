import QtQuick
import QtQuick.Controls

// BookingCategoryMenu.swift › CategoryAssignMenu (#366): „Kategorie“ of the row menu – the
// category tree to pick from (a category with sub-categories opens them, a leaf is assigned,
// as in the inspector's grid), the search sheet and removal. Acts on the multiple selection
// when the row is part of it. The tree items are built when the menu opens after the
// categories changed (a menu per row would be rebuilt with every list reload).
AppMenu {
    id: root
    property var booking: null
    readonly property var targets: BookingDetails.categorizeTargets(booking)
    /// Category ids of the targets (null = none), each once.
    readonly property var assigned: {
        const seen = {}, out = []
        for (const b of targets) { const k = String(b.category_id); if (!seen[k]) { seen[k] = true; out.push(b.category_id) } }
        return out
    }
    /// Ticked: the one category all targets share.
    readonly property var current: assigned.length === 1 ? assigned[0] : null
    title: qsTr("Kategorie")
    icon.name: SF.icon("tag")

    /// Picking the checked category again changes nothing (it would turn a rule's category manual).
    function pick(id) {
        if (id === current) return
        AppModel.setCategoryFor(targets, id)
    }

    property Component itemComponent: Component { AppMenuItem { property var categoryID: null } }
    property Component menuComponent: Component { AppMenu {} }
    property bool dirty: true
    property var built: []
    /// Every created entry (items get no QObject parent: a menu is no Item), destroyed on rebuild.
    property var created: []
    Connections { target: AppModel; function onCategoryTreeChanged() { root.dirty = true } }
    onAboutToShow: if (dirty) rebuild()

    function rebuild() {
        for (const o of built) { if (o.menu) removeMenu(o.obj); else removeItem(o.obj) }
        for (const o of created) o.destroy()
        built = []
        created = []
        fill(root, AppModel.categoryTree, true)
        dirty = false
    }
    // CategoryMenuItems: nested menus for categories with sub-categories, ticks on leaves
    function fill(menu, nodes, top) {
        nodes.forEach((n, i) => {
            const c = n.category
            if (n.children) {
                const sub = menuComponent.createObject(menu, { title: AppModel.menuText(c.name) })
                created.push(sub)
                sub.icon.name = SF.icon(c.sf_symbol)
                fill(sub, n.children, false)
                if (top) { menu.insertMenu(i, sub); built.push({ menu: true, obj: sub }) } else menu.addMenu(sub)
            } else {
                const item = itemComponent.createObject(null, { text: AppModel.menuText(c.name), checkable: true, categoryID: c.id })
                created.push(item)
                item.icon.name = SF.icon(c.sf_symbol)
                item.checked = Qt.binding(() => root.current === item.categoryID)
                item.triggered.connect(() => {
                    item.checked = Qt.binding(() => root.current === item.categoryID)   // the click flipped it
                    root.pick(item.categoryID)
                })
                if (top) { menu.insertItem(i, item); built.push({ menu: false, obj: item }) } else menu.addItem(item)
            }
        })
    }

    AppMenuSeparator {}
    AppMenuItem {
        text: root.targets.length > 1 ? qsTr("%1 Buchungen kategorisieren …").arg(root.targets.length) : qsTr("Kategorisieren …")
        icon.name: SF.icon("magnifyingglass")
        onTriggered: {
            if (!AppModel.selectedBookingIDs[root.booking.id]) AppModel.selectedBookingID = root.booking.id
            AppModel.showCategorizer = true
        }
    }
    AppMenuItem {
        text: qsTr("Kategorie entfernen")
        icon.name: SF.icon("tag.slash")
        enabled: !(root.assigned.length === 1 && root.assigned[0] === null)
        onTriggered: AppModel.setCategoryFor(root.targets, null)
    }
}
