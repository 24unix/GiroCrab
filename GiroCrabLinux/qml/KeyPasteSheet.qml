import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// SettingsView.swift › KeyPasteSheet: paste the vault key (Base64 or Hex). Linux: rekeys the
// open vault to it, or – while the vault is locked because the key is missing from the
// keyring – checks it against the vault file and stores it in the Secret Service.
Sheet {
    id: sheet
    sheetWidth: 440
    property string error: ""
    property bool busy: false
    readonly property bool valid: {
        const t = field.text.trim()
        return /^[0-9a-fA-F]{64}$/.test(t) || (/^[A-Za-z0-9+/]{43}=$/.test(t))
    }
    onAboutToShow: { field.text = ""; error = ""; busy = false; field.forceActiveFocus() }
    onClosed: field.text = ""
    function apply() {
        if (!valid || busy) return
        busy = true
        AppModel.importVaultKey(field.text, () => { busy = false; sheet.close() },
                                err => { busy = false; error = err })
    }
    ColumnLayout {
        width: sheet.availableWidth
        spacing: 12
        Text { text: qsTr("Tresor-Schlüssel einfügen"); font.pixelSize: Theme.body + 2; font.weight: Font.Bold; color: Theme.text }
        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout + 1; color: Theme.secondary
               text: qsTr("Fügen Sie den gesicherten Schlüssel ein (Einstellungen › Sicherheit › „Tresor-Schlüssel anzeigen …“ auf dem anderen Rechner). Er wird im Schlüsselbund gespeichert, nie neben der Tresordatei.") }
        TextField { id: field; Layout.fillWidth: true; echoMode: TextInput.Password; placeholderText: qsTr("Schlüssel (Base64 oder Hex)"); onAccepted: sheet.apply() }
        Text { visible: sheet.error !== ""; text: sheet.error; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.negative }
        RowLayout {
            Layout.fillWidth: true
            Button { text: qsTr("Abbrechen"); onClicked: sheet.close() }
            Item { Layout.fillWidth: true }
            BusyIndicator { visible: sheet.busy; running: sheet.busy; implicitWidth: 20; implicitHeight: 20 }
            Button { text: qsTr("Übernehmen"); highlighted: true; enabled: sheet.valid && !sheet.busy; onClicked: sheet.apply() }
        }
    }
}
