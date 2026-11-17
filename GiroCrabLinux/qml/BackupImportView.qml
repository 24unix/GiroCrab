import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import QtCore

// BackupImportView.swift: „Vorhandene Daten importieren“ › Datenbank › GiroCrab restores
// a backup from „Tresor sichern …“, like Einstellungen › Sicherheit › „Tresor
// wiederherstellen …“. Unlike the other sources it replaces the vault.
ColumnLayout {
    id: v
    /// The MoneyMoneyImportSheet: close(), source, importRunning.
    property var host
    spacing: 16
    property string filePath: ""
    property bool restoring: false
    property string error: ""
    /// The vault already holds accounts that the backup would replace.
    readonly property bool replacesAccounts: AppModel.hasOwnVault && !AppModel.isDemo && AppModel.allAccounts.length > 0

    onRestoringChanged: if (host) host.importRunning = restoring
    function reset() { filePath = ""; password.text = ""; restoring = false; error = "" }
    function forget() { password.text = "" }
    function restore() {
        if (filePath === "" || restoring) return
        restoring = true; error = ""
        BackupModel.restoreBackup(filePath, password.text, (ok, err) => {
            restoring = false
            if (ok) { password.text = ""; v.host.close() } else error = err
        })
    }

    ImportAssistantHeader {
        title: qsTr("Vorhandene Daten importieren")
        subtitle: qsTr("Wählen Sie, woher die Daten kommen. Die Originaldaten bleiben unverändert.")
    }
    ColumnLayout {
        Layout.fillWidth: true
        Layout.preferredHeight: 470
        spacing: 18
        ImportSourceSection {
            source: v.host ? v.host.source : "backup"
            enabled: !v.restoring
            onChosen: s => v.host.source = s
        }
        FormSection {
            title: qsTr("Datei")
            // Linux: no iCloud Sync, so the Mac's second sentence is left out
            footer: qsTr("Ersetzt alle Daten dieses Tresors durch die Sicherung.")
            ImportFileRow {
                label: qsTr("Sicherung")
                path: v.filePath
                name: v.filePath.split("/").pop()
                onChoose: picker.open()
            }
            FormRow {
                label: qsTr("Passwort")
                TextField {
                    id: password
                    Layout.preferredWidth: 280
                    echoMode: TextInput.Password
                    onAccepted: footerRow.next()
                }
            }
        }
        Item { Layout.fillHeight: true }
    }
    RowLayout {
        visible: v.error !== ""
        Layout.fillWidth: true
        spacing: 6
        SFIcon { symbol: "exclamationmark.triangle"; size: 14; color: Theme.warning; Layout.alignment: Qt.AlignTop }
        Text { text: v.error; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout + 1; color: Theme.warning }
    }
    AssistantFooter {
        id: footerRow
        cancelDisabled: v.restoring
        nextTitle: qsTr("Wiederherstellen")
        nextDisabled: v.filePath === "" || password.text === "" || v.restoring
        busy: v.restoring
        onCancel: { v.forget(); v.host.close() }
        onNext: { if (nextDisabled) return; if (v.replacesAccounts) confirmReplace.open(); else v.restore() }
    }

    FileDialog {
        id: picker
        title: qsTr("Sicherung")
        fileMode: FileDialog.OpenFile
        nameFilters: [qsTr("GiroCrab-Sicherung (*.girocrab-backup)"), qsTr("Alle Dateien (*)")]
        currentFolder: StandardPaths.writableLocation(StandardPaths.DocumentsLocation)
        onAccepted: { v.filePath = AppModel.localPath(selectedFile); v.error = "" }
    }
    ConfirmDialog {
        id: confirmReplace
        heading: qsTr("Tresor ersetzen?")
        message: qsTr("Ihr Tresor enthält bereits Konten. Sie werden durch den Inhalt der Sicherung ersetzt.")
        actionTitle: qsTr("Ersetzen")
        onConfirmed: v.restore()
    }
}
