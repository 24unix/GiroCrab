import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtCore

// VaultBackupUI.swift › VaultBackupSection: Einstellungen › Sicherheit › „Sicherung“ – save
// the own vault with a password, or replace it with such a backup. Linux: the password
// comes first, then the file dialog writes the backup straight to the chosen file
// (the Mac builds it in memory for `.fileExporter`).
SettingsFormSection {
    id: section
    title: qsTr("Sicherung")
    /// The password of „Tresor sichern …“ until the save dialog is answered.
    property string pendingPassword: ""
    property string restorePath: ""

    RowLayout {
        spacing: 8
        IconButton {
            symbol: "externaldrive.badge.plus"; text: qsTr("Tresor sichern …"); tint: Theme.accent
            enabled: !BackupModel.busy
            onClicked: { passwordSheet.restoring = false; passwordSheet.open() }
        }
        IconButton {
            symbol: "clock.arrow.circlepath"; text: qsTr("Tresor wiederherstellen …"); tint: Theme.accent
            enabled: !BackupModel.busy
            onClicked: openDialog.open()
        }
        BusyIndicator { visible: BackupModel.busy; running: visible; implicitWidth: 18; implicitHeight: 18 }
    }
    Text {
        Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout + 1; color: Theme.secondary
        text: qsTr("Die Sicherung enthält alle Konten, Buchungen, Kategorien, Regeln und Einstellungen des Tresors, verschlüsselt mit einem Passwort Ihrer Wahl. Sie lässt sich auf jedem Gerät wiederherstellen, auch ohne diesen Schlüsselbund – aber nicht ohne das Passwort.")
    }

    BackupPasswordSheet {
        id: passwordSheet
        confirm: p => {
            if (passwordSheet.restoring) {
                BackupModel.restoreBackup(section.restorePath, p, (ok, err) => { if (!ok) AppModel.toast = err })
            } else {
                section.pendingPassword = p
                saveDialog.selectedFile = saveDialog.currentFolder + "/" + BackupModel.fileName()
                saveDialog.open()
            }
        }
    }
    FileDialog {
        id: saveDialog
        title: qsTr("Tresor sichern")
        acceptLabel: qsTr("Sichern")
        fileMode: FileDialog.SaveFile
        defaultSuffix: "girocrab-backup"
        nameFilters: [qsTr("GiroCrab-Sicherung (*.girocrab-backup)")]
        currentFolder: StandardPaths.writableLocation(StandardPaths.DocumentsLocation)
        onAccepted: {
            const p = section.pendingPassword
            section.pendingPassword = ""
            BackupModel.writeBackup(AppModel.localPath(selectedFile), p)
        }
        onRejected: section.pendingPassword = ""
    }
    FileDialog {
        id: openDialog
        title: qsTr("Tresor wiederherstellen")
        fileMode: FileDialog.OpenFile
        nameFilters: [qsTr("GiroCrab-Sicherung (*.girocrab-backup)"), qsTr("Alle Dateien (*)")]
        currentFolder: StandardPaths.writableLocation(StandardPaths.DocumentsLocation)
        onAccepted: {
            section.restorePath = AppModel.localPath(selectedFile)
            passwordSheet.restoring = true
            passwordSheet.open()
        }
    }
}
