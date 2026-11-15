import QtQuick
import QtQuick.Controls

// AccountSelectionView.swift › AccountSelectionSheet (#346): shown after a fetch when an
// account was found that another login already delivers (AppModel.accountSelectionConnection).
Sheet {
    id: sheet
    sheetWidth: 520
    padding: 0
    readonly property var connection: AppModel.accountSelectionConnection
    visible: connection !== null
    // Esc = "Später"
    onClosed: if (AppModel.accountSelectionConnection !== null) finish()
    function finish() {
        AppModel.accountSelectionConnection = null
        AppModel.checkPendingAccountSelection()
    }
    AccountSelectionPanel {
        width: sheet.availableWidth
        connection: sheet.connection
        onDone: sheet.finish()
    }
}
