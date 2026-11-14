import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// .confirmationDialog(title, …) { Button(role: .destructive); Button("Abbrechen", role: .cancel) } message: { … }
// HIG: "Abbrechen" stays the default; the destructive action is never triggered by Return.
Sheet {
    id: dlg
    property string heading
    property string message
    property string actionTitle
    /// role: .destructive (red); false = a plain action such as "Archivieren"
    property bool destructive: true
    signal confirmed()
    sheetWidth: 400
    ColumnLayout {
        width: dlg.availableWidth
        spacing: 12
        Text { text: dlg.heading; font.pixelSize: Theme.body + 2; font.weight: Font.Bold; color: Theme.text; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        Text { text: dlg.message; font.pixelSize: Theme.body; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Button { text: qsTr("Abbrechen"); onClicked: dlg.close(); focus: true }
            Button {
                text: AppModel.menuText(dlg.actionTitle)   // may carry names with "&"
                palette.buttonText: dlg.destructive ? Theme.negative : Theme.text
                onClicked: { dlg.close(); dlg.confirmed() }
            }
        }
    }
}
