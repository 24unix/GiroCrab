import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// RuleTagsUI.swift › RuleTagsField (#580): the tags a rule adds to every booking it matches –
// chips with ✕, a menu of the other tags and „Neuer Tag …“. A rule only ever adds tags, never
// removes one. Tag names stay marked `Sensitive {}` (TagChip) like everywhere else.
RowLayout {
    id: field
    /// The rule's `tag_ids`; a change is reported through `picked(ids)` (RuleForm owns the draft).
    property var tagIds: []
    signal picked(var ids)

    readonly property var chosen: TagsModel.tags.filter(t => tagIds.indexOf(t.id) >= 0)
    readonly property var available: TagsModel.tags.filter(t => tagIds.indexOf(t.id) < 0)

    spacing: 12
    // LabeledContent { … } label: { Text("Tags") }
    Text { text: qsTr("Tags"); font.pixelSize: Theme.body; color: Theme.text; Layout.alignment: Qt.AlignTop; Layout.topMargin: 4 }
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 6
        Flow {
            visible: field.chosen.length > 0
            Layout.fillWidth: true
            layoutDirection: Qt.RightToLeft   // VStack(alignment: .trailing)
            spacing: 4
            Repeater {
                model: field.chosen
                TagChip {
                    required property var modelData
                    name: modelData.name
                    colorHex: modelData.color_hex
                    removable: true
                    maxWidth: 220
                    onRemoved: field.picked(field.tagIds.filter(id => id !== modelData.id))
                }
            }
        }
        // Menu { … } label: { Label("Tag hinzufügen", systemImage: "plus") }, borderless
        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            ToolButton {
                id: addButton
                text: qsTr("Tag hinzufügen")
                icon.name: SF.icon("plus")
                font.pixelSize: Theme.body
                onClicked: addMenu.popup(addButton, 0, addButton.height)
                ToolTip.visible: hovered && !addMenu.visible
                ToolTip.delay: 600
                ToolTip.text: qsTr("Diese Tags bekommt jede passende Buchung")
            }
        }
    }

    AppMenu {
        id: addMenu
        Instantiator {
            model: field.available
            delegate: AppMenuItem {
                required property var modelData
                text: AppModel.menuText(modelData.name)
                onTriggered: field.picked(field.tagIds.concat([modelData.id]))
            }
            onObjectAdded: (index, item) => addMenu.insertItem(index, item)
            onObjectRemoved: (index, item) => addMenu.removeItem(item)
        }
        AppMenuSeparator { visible: field.available.length > 0; height: visible ? implicitHeight : 0 }
        AppMenuItem { text: qsTr("Neuer Tag …"); onTriggered: { newName.text = ""; creator.open() } }
    }

    // .alert("Neuer Tag") { TextField("Name"); Button("Anlegen"); Button("Abbrechen", role: .cancel) }
    Sheet {
        id: creator
        parent: Overlay.overlay
        sheetWidth: 320
        onOpened: newName.forceActiveFocus()
        function create() {
            const t = TagsModel.tagNamed(newName.text)
            if (t && field.tagIds.indexOf(t.id) < 0) field.picked(field.tagIds.concat([t.id]))
            newName.text = ""
            creator.close()
        }
        ColumnLayout {
            width: creator.availableWidth
            spacing: 12
            Text { text: qsTr("Neuer Tag"); font.pixelSize: Theme.body + 2; font.weight: Font.Bold; color: Theme.text }
            TextField {
                id: newName
                Layout.fillWidth: true
                placeholderText: qsTr("Name")
                maximumLength: TagsModel.maxTagNameLength
                onAccepted: creator.create()
                Sensitive {}
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                Button { text: qsTr("Abbrechen"); onClicked: { newName.text = ""; creator.close() } }
                Button { text: qsTr("Anlegen"); highlighted: true; onClicked: creator.create() }
            }
        }
    }
}
