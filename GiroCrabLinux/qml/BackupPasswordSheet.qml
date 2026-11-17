import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// VaultBackupUI.swift › BackupPasswordSheet: asks for the backup password – twice when
// saving (with „Passwort vorschlagen“), once with a warning when restoring.
// Linux: no AutoFill from a password manager; the suggestion is copied with
// `copySecret` (cleared from the clipboard after 60 s, no clipboard history).
Sheet {
    id: sheet
    sheetWidth: 400
    property bool restoring: false
    /// Called with the password on „Sichern“ / „Wiederherstellen“.
    property var confirm: null
    /// Shown while both fields still hold the suggested password.
    property string suggestion: ""
    property bool copied: false
    readonly property bool ready: restoring ? password.text !== "" : BackupModel.acceptable(password.text, repeated.text)

    onAboutToShow: { password.text = ""; repeated.text = ""; suggestion = ""; copied = false; password.forceActiveFocus() }
    onClosed: { password.text = ""; repeated.text = ""; suggestion = "" }
    function accept() {
        if (!ready) return
        const p = password.text
        sheet.close()
        if (confirm) confirm(p)
    }
    /// „Passwort vorschlagen“: into both fields, shown in clear text below.
    function suggest() {
        const p = BackupModel.suggestedPassword()
        if (p === "") return
        password.text = p; repeated.text = p; suggestion = p; copied = false
    }
    Timer { id: copiedReset; interval: 60000; onTriggered: sheet.copied = false }

    ColumnLayout {
        width: sheet.availableWidth
        spacing: 14
        Text { text: sheet.restoring ? qsTr("Tresor wiederherstellen") : qsTr("Tresor sichern")
               font.pixelSize: Theme.body + 2; font.weight: Font.Bold; color: Theme.text }
        TextField {
            id: password
            Layout.fillWidth: true
            echoMode: TextInput.Password
            placeholderText: qsTr("Passwort")
            onAccepted: sheet.restoring ? sheet.accept() : repeated.forceActiveFocus()
            // typed over the suggestion: it no longer applies
            onTextChanged: if (text !== sheet.suggestion) sheet.suggestion = ""
        }
        Text {
            visible: sheet.restoring
            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout + 1; color: Theme.secondary
            // Linux: no iCloud Sync, so the Mac's second sentence is left out
            text: qsTr("Ersetzt alle Daten dieses Tresors durch die Sicherung.")
        }
        TextField {
            id: repeated
            visible: !sheet.restoring
            Layout.fillWidth: true
            echoMode: TextInput.Password
            placeholderText: qsTr("Passwort wiederholen")
            onAccepted: sheet.accept()
        }
        IconButton {
            visible: !sheet.restoring
            symbol: "key"; text: qsTr("Passwort vorschlagen"); tint: Theme.accent
            onClicked: sheet.suggest()
        }
        RowLayout {
            visible: !sheet.restoring && sheet.suggestion !== ""
            Layout.fillWidth: true
            Text { text: sheet.suggestion; font.family: "monospace"; font.pixelSize: Theme.body + 1; color: Theme.text
                   Layout.fillWidth: true; elide: Text.ElideRight
                   Sensitive {} }   // a password in clear text
            IconButton {
                symbol: sheet.copied ? "checkmark" : "doc.on.doc"
                text: sheet.copied ? qsTr("Kopiert") : qsTr("Kopieren"); tint: Theme.accent
                onClicked: { AppModel.copySecret(sheet.suggestion); sheet.copied = true; copiedReset.restart() }
            }
        }
        Text {
            visible: !sheet.restoring && sheet.suggestion !== ""
            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout + 1; color: Theme.secondary
            text: qsTr("Sichern Sie das Passwort jetzt in Ihrem Passwortmanager. Die Zwischenablage wird nach 60 Sekunden geleert.")
        }
        Text {
            visible: !sheet.restoring
            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout + 1; color: Theme.secondary
            text: qsTr("Mindestens %1 Zeichen. Ohne dieses Passwort lässt sich die Sicherung nicht öffnen – auch nicht von GiroCrab.").arg(BackupModel.minPasswordLength)
        }
        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Button { text: qsTr("Abbrechen"); onClicked: sheet.close() }
            Button {
                text: sheet.restoring ? qsTr("Wiederherstellen") : qsTr("Sichern")
                highlighted: true
                enabled: sheet.ready
                onClicked: sheet.accept()
            }
        }
    }
}
