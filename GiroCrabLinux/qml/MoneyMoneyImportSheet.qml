import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// MoneyMoneyImportSheet.swift: "Aus MoneyMoney importieren …" either reads
// MoneyMoney's own database (recommended, everything in one go) or a
// per-account CSV/XML export. Both are assistants with the same frame (title,
// steps, Zurück / Fortfahren), so switching the source doesn't change the sheet.
Sheet {
    id: sheet
    sheetWidth: 860
    padding: 20
    property string source: "database"     // database | export
    /// An import is running in the view below (no Esc, no closing).
    property bool importRunning: false
    closePolicy: importRunning ? Popup.NoAutoClose : Popup.CloseOnEscape

    onAboutToShow: {
        source = "database"
        if (AppModel.demoImportPreview !== null) source = "export"
        if (AppModel.demoDbPreview !== null) source = "database"
        importRunning = false
        dbView.reset()
        exportView.reset()
    }
    onClosed: dbView.forget()

    StackLayout {
        width: sheet.availableWidth
        currentIndex: sheet.source === "database" ? 0 : 1
        MoneyMoneyDatabaseImportView { id: dbView; host: sheet }
        MoneyMoneyExportImportView { id: exportView; host: sheet }
    }
}
