import QtQuick
import QtQuick.Controls

// ComboBox whose popup entries show their text literally (AppMenuItem): the stock
// delegate reads "&" as a mnemonic, so "Wohnen & Energie" became "Wohnen _Energie".
ComboBox {
    id: control
    delegate: AppMenuItem {
        required property var model
        required property int index
        width: ListView.view ? ListView.view.width : implicitWidth
        text: control.textRole ? model[control.textRole] : model.modelData
        highlighted: control.highlightedIndex === index
        hoverEnabled: control.hoverEnabled
    }
}
