import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// MoneyMoneyImportSheet.swift › ImportFileRow: the chosen file or folder (icon
// and name) or "Keine Auswahl"; the button opens the file dialog.
FormRow {
    id: row
    /// Full path (tooltip) and the name shown.
    property string path
    property string name
    property bool loading: false
    property bool isFolder: false
    signal choose()
    BusyIndicator { visible: row.loading; running: row.loading; implicitWidth: 18; implicitHeight: 18 }
    Text { visible: row.name === ""; text: qsTr("Keine Auswahl"); color: Theme.tertiary; font.pixelSize: Theme.body }
    RowLayout {
        visible: row.name !== ""
        spacing: 5
        SFIcon { symbol: row.isFolder ? "folder" : "doc"; size: 16 }
        Text {
            text: row.name; color: Theme.text; font.pixelSize: Theme.body
            elide: Text.ElideMiddle; Layout.maximumWidth: 300
            HoverHandler { id: hover }
            ToolTip.visible: hover.hovered && row.path !== ""; ToolTip.text: row.path; ToolTip.delay: 600
        }
    }
    Button { text: row.name === "" ? qsTr("Auswählen …") : qsTr("Ändern …"); onClicked: row.choose() }
}
