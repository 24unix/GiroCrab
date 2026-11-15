import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// AccountGroupsUI.swift › IconColorPopover: colour palette and symbol grid in one popover.
// Target: a category (`AppModel.iconColorCategoryID`) or an account / user group
// (`AppModel.iconColorTarget`). A click applies immediately; a category always has a
// colour, so only accounts ("Standardfarbe") and groups ("Keine Farbe") can clear it.
Popup {
    id: pop
    readonly property var category: host === "sidebar" ? AppModel.categoryByID(AppModel.iconColorCategoryID) : null
    /// Which instance shows an account/group target: "sidebar" or "manager" (`iconColorTarget.host`).
    property string host: "sidebar"
    readonly property var target: AppModel.iconColorTarget && (AppModel.iconColorTarget.host || "sidebar") === host ? AppModel.iconColorTarget : null
    readonly property var account: target && target.type === "account" ? AppModel.account(target.id) : null
    readonly property var group: target && target.type === "group" ? AppModel.userGroupByUUID(target.uuid) : null
    readonly property var item: account || group || category
    readonly property string colorHex: item ? item.color_hex.toUpperCase() : ""
    readonly property color tint: account ? AppModel.accountColor(account.id) : colorHex === "" ? Theme.accent : Theme.readable(colorHex)
    visible: (host === "sidebar" && AppModel.iconColorCategoryID !== null) || target !== null
    onClosed: { if (host === "sidebar") AppModel.iconColorCategoryID = null; if (target !== null) AppModel.iconColorTarget = null }
    padding: 14
    width: 360
    background: Rectangle { color: Theme.card; radius: 10; border.color: Theme.border }

    function setColor(hex) {
        const h = hex === "" ? null : hex
        if (account) AppModel.setAccountColor(account.id, h)
        else if (group) AppModel.setUserGroupColor(group, h)
        else if (category && h) AppModel.setCategoryColor(category.id, h)
    }
    function setSymbol(s) {
        if (account) AppModel.setAccountSymbol(account.id, s)
        else if (group) AppModel.updateUserGroup(group, { symbol: s })
        else if (category) AppModel.setCategorySymbol(category.id, s)
    }

    ColumnLayout {
        width: pop.availableWidth
        spacing: 10
        Text { text: qsTr("Farbe"); font.pixelSize: Theme.body; font.weight: Font.Bold; color: Theme.text }
        ColorSwatches {
            Layout.fillWidth: true
            Layout.maximumWidth: 7 * 30
            selection: pop.colorHex
            noneTip: pop.account ? qsTr("Standardfarbe") : pop.group ? qsTr("Keine Farbe") : ""
            onChosen: hex => pop.setColor(hex)
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
        RowLayout {
            Layout.fillWidth: true
            Text { text: qsTr("Symbol"); font.pixelSize: Theme.body; font.weight: Font.Bold; color: Theme.text; Layout.fillWidth: true }
            // an account's symbol can go back to the one of its kind
            IconButton {
                visible: pop.account !== null
                symbol: "arrow.uturn.backward"; symbolSize: 12; text: qsTr("Standardsymbol"); font.pixelSize: Theme.caption
                implicitHeight: 22
                ToolTip.text: qsTr("Symbol der Kontoart verwenden")
                onClicked: AppModel.resetAccountSymbol(pop.account.id)
            }
        }
        // a click applies the symbol and the popover stays open
        // The symbol catalogue (hundreds of icons) is built only while the popover is open.
        Loader {
            Layout.fillWidth: true
            Layout.leftMargin: -14; Layout.rightMargin: -14
            Layout.preferredHeight: 420
            active: pop.visible
            sourceComponent: SymbolPicker {
                selection: pop.item ? pop.item.sf_symbol : ""
                tint: pop.tint
                onPicked: s => pop.setSymbol(s)
            }
        }
    }
}
