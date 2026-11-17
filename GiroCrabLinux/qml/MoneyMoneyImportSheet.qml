import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// MoneyMoneyImportSheet.swift: "Vorhandene Daten importieren" restores a GiroCrab backup
// (replaces the vault), reads MoneyMoney's own database (recommended, everything in one
// go) or a per-account CSV/XML export. All are assistants with the same frame (title,
// steps, Zurück / Fortfahren), so switching the source doesn't change the sheet.
Sheet {
    id: sheet
    sheetWidth: 860
    padding: 20
    property string source: "export"       // backup | database | export
    /// An import is running in the view below (no Esc, no closing).
    property bool importRunning: false
    closePolicy: importRunning ? Popup.NoAutoClose : Popup.CloseOnEscape

    /// MoneyMoneyImportSheet.defaultSource: a new device (empty vault) most likely brings
    /// a backup; otherwise the sources that add data (the database like on the Mac – Linux
    /// imports a database copied from there).
    function defaultSource() {
        const empty = !AppModel.hasOwnVault || AppModel.isDemo || AppModel.allAccounts.length === 0
        return empty ? "backup" : "database"
    }

    onAboutToShow: {
        source = defaultSource()
        if (AppModel.demoImportPreview !== null) source = "export"
        if (AppModel.demoDbPreview !== null) source = "database"
        importRunning = false
        backupView.reset()
        dbView.reset()
        exportView.reset()
    }
    onClosed: { dbView.forget(); backupView.forget() }

    StackLayout {
        width: sheet.availableWidth
        currentIndex: ["backup", "database", "export"].indexOf(sheet.source)
        BackupImportView { id: backupView; host: sheet }
        MoneyMoneyDatabaseImportView { id: dbView; host: sheet }
        MoneyMoneyExportImportView { id: exportView; host: sheet }
    }
}
