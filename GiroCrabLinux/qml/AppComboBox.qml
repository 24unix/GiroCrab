import QtQuick
import QtQuick.Controls

// ComboBox whose popup entries show their text literally (AppMenuItem): the stock
// delegate reads "&" as a mnemonic, so "Wohnen & Energie" became "Wohnen _Energie".
// Entries `{ header: true, … }` are section titles that cannot be chosen, `{ separator: true }`
// a divider (Picker › Divider).
ComboBox {
    id: control
    delegate: AppMenuItem {
        required property var model
        required property var modelData
        required property int index
        /// `{ header: true, title }`: a section title (Picker › Section), not choosable
        readonly property bool isHeader: !!(modelData && modelData.header)
        readonly property bool isSeparator: !!(modelData && modelData.separator)
        width: ListView.view ? ListView.view.width : implicitWidth
        implicitHeight: isSeparator ? 9 : Math.max(28, implicitContentHeight + topPadding + bottomPadding)
        text: isSeparator ? "" : (control.textRole ? model[control.textRole] : model.modelData)
        enabled: !isHeader && !isSeparator
        Rectangle { visible: parent.isSeparator; anchors.centerIn: parent; width: parent.width - 12; height: 1; color: Theme.border }
        font.pixelSize: isHeader ? Theme.caption : Theme.body
        font.weight: isHeader ? Font.DemiBold : Font.Normal
        highlighted: control.highlightedIndex === index && !isHeader
        hoverEnabled: control.hoverEnabled
    }
}
