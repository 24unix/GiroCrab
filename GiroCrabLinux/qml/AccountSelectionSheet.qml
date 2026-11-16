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
        // "Später" leaves the login pending: don't ask again for it in this session (the Mac
        // re-checks right away and would show the same choice again)
        const c = AppModel.accountSelectionConnection
        if (c) { const p = Object.assign({}, AppModel.postponedAccountSelection); p[c.id] = true; AppModel.postponedAccountSelection = p }
        AppModel.accountSelectionConnection = null
        AppModel.checkPendingAccountSelection()
    }
    AccountSelectionPanel {
        width: sheet.availableWidth
        connection: sheet.connection
        onDone: sheet.finish()
    }
}
