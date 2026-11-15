import QtQuick
import QtQuick.Controls

// ComboBox whose popup entries show their text literally (AppMenuItem): the stock
// delegate reads "&" as a mnemonic, so "Wohnen & Energie" became "Wohnen _Energie".
// Entries `{ header: true, … }` are section titles that cannot be chosen.
ComboBox {
    id: control
    delegate: AppMenuItem {
        required property var model
        required property var modelData
        required property int index
        /// `{ header: true, title }`: a section title (Picker › Section), not choosable
        readonly property bool isHeader: !!(modelData && modelData.header)
        width: ListView.view ? ListView.view.width : implicitWidth
        text: control.textRole ? model[control.textRole] : model.modelData
        enabled: !isHeader
        font.pixelSize: isHeader ? Theme.caption : Theme.body
        font.weight: isHeader ? Font.DemiBold : Font.Normal
        highlighted: control.highlightedIndex === index && !isHeader
        hoverEnabled: control.hoverEnabled
    }
}
