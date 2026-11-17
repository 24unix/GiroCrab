import QtQuick
import QtQuick.Controls

// TagsUI.swift › TagsMenu (#228): „Tags“ submenu of a booking row (and of the multiple selection
// it belongs to): a tick per tag (ticked = every booking carries it), „Neuer Tag …“ focuses the
// inspector field.
AppMenu {
    id: tagsMenu
    property var booking: null
    readonly property var targets: TagsModel.targets(booking)
    title: targets.length > 1 ? qsTr("Tags (%1 Buchungen)").arg(targets.length) : qsTr("Tags")
    icon.name: SF.icon("number")

    Instantiator {
        model: TagsModel.tags
        delegate: AppMenuItem {
            id: tagItem
            required property var modelData
            readonly property bool all: tagsMenu.targets.length > 0 && tagsMenu.targets.every(b => (b.tags || []).some(t => t.id === modelData.id))
            text: AppModel.menuText(modelData.name)
            checkable: true
            checked: all
            onTriggered: {
                checked = Qt.binding(() => tagItem.all)   // the click flipped `checked` itself
                TagsModel.toggleTag(modelData.id, tagsMenu.targets)
            }
        }
        onObjectAdded: (index, item) => tagsMenu.insertItem(index, item)
        onObjectRemoved: (index, item) => tagsMenu.removeItem(item)
    }
    AppMenuSeparator { visible: TagsModel.tags.length > 0; height: visible ? implicitHeight : 0 }
    AppMenuItem { text: qsTr("Neuer Tag …"); onTriggered: TagsModel.editTags(tagsMenu.booking) }
}
