import QtQuick
import QtQuick.Layouts

// TagsUI.swift › TagsCard (content) and MultiSelectionTags: „Tags“ with the chips and the entry
// field. One booking: ✕ removes a tag. Several bookings (the multiple-selection card): dashed
// chips are carried by only some of them (click: give it to all), ✕ removes a tag from all.
ColumnLayout {
    id: section
    property var bookings: []
    readonly property bool multiple: bookings.length > 1
    readonly property var ids: bookings.map(b => b.id)
    readonly property var usage: TagsModel.usage(bookings)
    spacing: 8

    function claimFocus() {
        const id = TagsModel.pendingTagFocus
        if (id === null || !bookings.some(b => b.id === id)) return
        TagsModel.pendingTagFocus = null
        Qt.callLater(field.focusField)
    }
    Component.onCompleted: claimFocus()
    onBookingsChanged: claimFocus()
    Connections { target: TagsModel; function onPendingTagFocusChanged() { section.claimFocus() } }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6
        SFIcon { symbol: "number"; size: 14; color: Theme.text }
        Text { text: qsTr("Tags"); font.pixelSize: Theme.subheadline + 2; font.weight: Font.DemiBold; color: Theme.text }
        Item { Layout.fillWidth: true }
        // TagsCard: the tag sheet (rename, merge, delete); also Konten › Tags verwalten …
        // (not in MultiSelectionTags)
        Text {
            visible: !section.multiple
            text: qsTr("Verwalten …")
            font.pixelSize: Theme.caption; color: Theme.accent
            font.underline: manageMouse.containsMouse
            Accessible.role: Accessible.Button
            Accessible.name: text
            Accessible.onPressAction: TagManager.open()
            MouseArea { id: manageMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: TagManager.open() }
        }
    }
    Flow {
        id: chips
        visible: section.usage.length > 0
        Layout.fillWidth: true
        spacing: 6
        Repeater {
            model: section.usage
            TagChip {
                required property var modelData
                name: modelData.tag.name
                colorHex: modelData.tag.color_hex
                maxWidth: chips.width
                partial: !modelData.all
                removable: true
                tappable: section.multiple && !modelData.all
                toolTip: !section.multiple ? "" : modelData.all ? qsTr("Bei allen ausgewählten Buchungen")
                                                                : qsTr("Nur bei einigen – klicken, um ihn allen zu geben")
                onTapped: TagsModel.addTag(modelData.tag.id, section.ids)
                onRemoved: TagsModel.removeTag(modelData.tag.id, section.ids)
            }
        }
    }
    TagEntryField {
        id: field
        Layout.fillWidth: true
        multiple: section.multiple
        carried: {
            const out = {}
            for (const u of section.usage) if (u.all) out[u.tag.id] = true
            return out
        }
        onAdd: name => TagsModel.addTagNamed(name, section.bookings)
    }
}
