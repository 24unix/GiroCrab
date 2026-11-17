pragma Singleton
import QtQuick

// VaultBackupUI.swift › VaultBackup + AppModel+Backup.swift: „Tresor sichern …“ /
// „Tresor wiederherstellen …“ (Einstellungen › Sicherheit, and „Vorhandene Daten importieren“
// › Datenbank › GiroCrab). Always the own vault (core `write_backup` / `restore_backup` in
// src/dispatch.rs), also while the demo is shown.
QtObject {
    id: backup
    /// VaultBackup.minPasswordLength
    readonly property int minPasswordLength: 8
    /// A backup is being written or restored (one at a time).
    property bool busy: false

    /// VaultBackup.acceptable: long enough and typed the same twice.
    function acceptable(password, repeated) {
        return password.length >= minPasswordLength && password === repeated
    }
    /// VaultBackup.suggestedPassword: "kawxe7-hupdyq-bomtiz" from the kernel's CSPRNG
    /// (QML has none; src/dispatch.rs › suggested_backup_password).
    function suggestedPassword() { return AppModel.run(() => AppModel.core("suggested_backup_password")) || "" }
    /// VaultBackup.fileName: "GiroCrab-Sicherung 2026-11-15.girocrab-backup".
    function fileName(date) {
        const d = date || new Date()
        const pad = n => (n < 10 ? "0" : "") + n
        return "GiroCrab-Sicherung " + d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) + ".girocrab-backup"
    }

    /// AppModel.makeBackup + the file exporter: Linux writes straight to the chosen path
    /// (off the GUI thread). `done(ok)`.
    function writeBackup(path, password, done) {
        if (busy) { if (done) done(false, qsTr("Eine Sicherung läuft gerade. Bitte warten Sie, bis sie fertig ist.")); return }
        busy = true
        AppModel.coreAsync("write_backup", { dest_path: path, password: password }, () => {
            busy = false
            AppModel.toast = qsTr("Sicherung gespeichert")
            if (done) done(true)
        }, err => {
            busy = false
            AppModel.toast = AppModel.parseCoreError(err).message
            if (done) done(false)
        })
    }

    /// AppModel.restoreBackup: replaces the own vault's contents with the backup and shows
    /// it. `done(ok, error)`; on failure nothing changed and `error` says why (the Mac shows
    /// it as a toast, the import assistant below its form).
    function restoreBackup(path, password, done) {
        if (busy) { if (done) done(false, qsTr("Eine Sicherung läuft gerade. Bitte warten Sie, bis sie fertig ist.")); return }
        if (!AppModel.hasOwnVault) {
            const msg = qsTr("Bitte zuerst Ihren eigenen Tresor öffnen, dann die Sicherung wiederherstellen.")
            if (done) done(false, msg)
            return
        }
        busy = true
        AppModel.coreAsync("restore_backup", { backup_path: path, password: password }, () => {
            busy = false
            // also from the demo an empty vault shows on a new device. The Mac then calls
            // syncNow() (iCloud merge); Linux has no folder sync yet, so nothing follows.
            if (AppModel.hasOwnVault) AppModel.useVault(false)
            AppModel.toast = qsTr("Tresor aus der Sicherung wiederhergestellt")
            if (done) done(true, "")
        }, err => {
            busy = false
            if (done) done(false, AppModel.parseCoreError(err).message)
        })
    }
}
