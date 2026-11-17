import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// RuleAccountPicker.swift: which accounts a rule is restricted to (#562) – removable chips
// plus a menu to add one. An empty list means all accounts.
ColumnLayout {
    id: picker
    property var accountIds: []
    signal picked(var ids)
    spacing: 8

    /// RuleAccountSelection.adding / removing: added once, kept in the order they were added.
    function adding(id) { return accountIds.indexOf(id) >= 0 ? accountIds : accountIds.concat([id]) }
    function removing(id) { return accountIds.filter(x => x !== id) }
    function label(a) { return a.bank_name + " – " + a.name }
    /// the add menu: section titles (disabled) and the accounts not chosen yet, like the sidebar (#412)
    readonly property var menuEntries: {
        const out = []
        for (const s of AppModel.accountMenuSections) {
            const rest = s.accounts.filter(a => picker.accountIds.indexOf(a.id) < 0)
            if (!rest.length) continue
            out.push({ header: true, title: s.title })
            for (const a of rest) out.push({ header: false, id: a.id, title: label(a) })
        }
        return out
    }

    RowLayout {
        Layout.fillWidth: true
        Text { text: qsTr("Konten"); font.pixelSize: Theme.body; color: Theme.text; Layout.fillWidth: true }
        IconButton {
            id: addButton
            symbol: "plus.circle"; text: qsTr("Konto hinzufügen")
            enabled: picker.menuEntries.length > 0
            onClicked: addMenu.popup(addButton, 0, addButton.height)
        }
    }
    Text {
        visible: picker.accountIds.length === 0
        text: qsTr("Alle Konten"); font.pixelSize: Theme.callout; color: Theme.secondary
    }
    // ChipFlowLayout: left to right, wrapping to the next line
    Flow {
        visible: picker.accountIds.length > 0
        Layout.fillWidth: true
        spacing: 6
        Repeater {
            model: picker.accountIds
            Rectangle {
                id: chip
                required property var modelData
                readonly property var account: AppModel.accountsByID[modelData] || null
                implicitWidth: chipRow.implicitWidth + 16; implicitHeight: chipRow.implicitHeight + 6
                width: Math.min(implicitWidth, picker.width)
                radius: height / 2
                color: Theme.withAlpha(Theme.accent, 0.15)
                RowLayout {
                    id: chipRow
                    anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 8; anchors.rightMargin: 8
                    spacing: 4
                    Text { text: chip.account ? picker.label(chip.account) : "?"; font.pixelSize: Theme.caption; color: Theme.text
                           elide: Text.ElideRight; Layout.fillWidth: true; Layout.maximumWidth: Math.ceil(implicitWidth)
                           Sensitive {} }
                    IconButton {
                        symbol: "xmark.circle.fill"; symbolSize: Theme.caption + 2
                        implicitWidth: 14; implicitHeight: 14
                        Accessible.name: qsTr("Konto entfernen")
                        ToolTip.text: qsTr("Konto entfernen")
                        onClicked: picker.picked(picker.removing(chip.modelData))
                    }
                }
            }
        }
    }

    AppMenu {
        id: addMenu
        Instantiator {
            model: picker.menuEntries
            delegate: AppMenuItem {
                required property var modelData
                text: AppModel.menuText(modelData.title)
                enabled: !modelData.header
                font.weight: modelData.header ? Font.DemiBold : Font.Normal
                onTriggered: picker.picked(picker.adding(modelData.id))
            }
            onObjectAdded: (index, object) => addMenu.insertItem(index, object)
            onObjectRemoved: (index, object) => addMenu.removeItem(object)
        }
    }
}
