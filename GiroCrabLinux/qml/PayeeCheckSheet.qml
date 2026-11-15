import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// PayeeCheckSheet.swift: result of the recipient name check (Verification of
// Payee) before a transfer: the user decides whether to send it anyway.
Sheet {
    id: sheet
    readonly property var pending: AppModel.payeeCheck
    readonly property var c: pending ? pending.check : null
    readonly property string matchResult: c ? c.result : ""
    visible: pending !== null
    sheetWidth: 480
    closePolicy: Popup.NoAutoClose

    readonly property var symbols: ({ Match: "checkmark.seal.fill", CloseMatch: "exclamationmark.triangle.fill",
                                      NoMatch: "xmark.octagon.fill", NotPossible: "questionmark.circle.fill" })
    readonly property var tints: ({ Match: Theme.inflow, CloseMatch: Theme.warning, NoMatch: Theme.negative, NotPossible: Theme.secondary })
    readonly property var titles: ({ Match: qsTr("Name stimmt überein"), CloseMatch: qsTr("Name stimmt nur teilweise überein"),
                                     NoMatch: qsTr("Name stimmt nicht überein"), NotPossible: qsTr("Name konnte nicht geprüft werden") })
    function explanation() {
        switch (matchResult) {
        case "Match": return qsTr("Die Bank verlangt trotzdem eine ausdrückliche Bestätigung, bevor sie die Freigabe anfordert.")
        case "CloseMatch": return qsTr("Der eingegebene Name weicht vom Namen des Kontoinhabers ab. Übernehmen Sie den Namen, wenn das der richtige Empfänger ist.")
        case "NoMatch": return qsTr("Das Konto gehört nicht zum eingegebenen Namen. Wenn Sie trotzdem senden, kann das Geld beim falschen Empfänger landen und lässt sich womöglich nicht zurückholen.")
        case "NotPossible": return qsTr("Die Empfängerbank konnte den Namen nicht prüfen%1. Senden Sie nur, wenn Sie sich bei IBAN und Empfänger sicher sind.")
                                   .arg(c && c.reason ? " (" + c.reason + ")" : "")
        }
        return ""
    }

    ColumnLayout {
        width: sheet.availableWidth
        spacing: 16
        RowLayout {
            spacing: 12
            SFIcon { symbol: sheet.symbols[sheet.matchResult] || ""; size: 34; color: sheet.tints[sheet.matchResult] || Theme.secondary }
            ColumnLayout { spacing: 2; Layout.fillWidth: true
                Text { text: sheet.titles[sheet.matchResult] || ""; font.pixelSize: Theme.title3 + 2; font.weight: Font.Bold; color: Theme.text }
                Text { text: qsTr("Empfängerüberprüfung · %1").arg(sheet.pending ? sheet.pending.connection.display_name : "")
                       font.pixelSize: Theme.caption; color: Theme.secondary } }
        }
        Card {
            Layout.fillWidth: true
            padding: 14
            ColumnLayout {
                width: parent.width
                spacing: 8
                Row_ { key: qsTr("Eingegeben"); value: sheet.c ? sheet.c.entered_name : "" }
                Row_ { visible: sheet.c !== null && !!sheet.c.bank_name; key: qsTr("Kontoinhaber"); value: sheet.c && sheet.c.bank_name ? sheet.c.bank_name : "" }
                Row_ { key: qsTr("IBAN"); value: sheet.c ? Fmt.iban(sheet.c.iban) : "" }
            }
        }
        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: sheet.explanation(); color: Theme.text; font.pixelSize: Theme.body }
        RowLayout {
            visible: sheet.c !== null && !!sheet.c.notice
            Layout.fillWidth: true; spacing: 6
            SFIcon { symbol: "building.columns"; size: 14; Layout.alignment: Qt.AlignTop }
            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: sheet.c && sheet.c.notice ? sheet.c.notice : ""
                   color: Theme.secondary; font.pixelSize: Theme.callout + 1 }
        }
        // HIG: Cancel on the left, the safe default on the far right; sending
        // despite a mismatch is destructive and never the default.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Button { text: qsTr("Abbrechen"); onClicked: AppModel.cancelPayee(false) }
            Item { Layout.fillWidth: true }
            BusyIndicator { visible: sheet.pending !== null && sheet.pending.busy; running: visible; implicitWidth: 18; implicitHeight: 18 }
            Button { visible: sheet.matchResult === "Match"; text: qsTr("Weiter zur Freigabe"); highlighted: true
                     enabled: !(sheet.pending && sheet.pending.busy); onClicked: AppModel.confirmPayee() }
            Button { visible: sheet.matchResult !== "Match"; text: qsTr("Trotzdem senden"); palette.buttonText: Theme.negative
                     enabled: !(sheet.pending && sheet.pending.busy); onClicked: AppModel.confirmPayee() }
            Button { visible: sheet.matchResult === "CloseMatch" && sheet.c !== null && !!sheet.c.bank_name
                     text: qsTr("Namen übernehmen"); highlighted: true
                     enabled: !(sheet.pending && sheet.pending.busy); onClicked: AppModel.cancelPayee(true) }
        }
    }
    Shortcut { sequence: "Escape"; enabled: sheet.visible; onActivated: AppModel.cancelPayee(false) }
    Shortcut {
        sequences: ["Return", "Enter"]
        enabled: sheet.visible && !(sheet.pending && sheet.pending.busy)
        onActivated: {
            if (sheet.matchResult === "Match") AppModel.confirmPayee()
            else if (sheet.matchResult === "CloseMatch" && sheet.c.bank_name) AppModel.cancelPayee(true)
        }
    }

    component Row_: RowLayout {
        property string key
        property string value
        Layout.fillWidth: true
        Text { Layout.preferredWidth: 110; Layout.alignment: Qt.AlignTop; text: parent.key; color: Theme.secondary; font.pixelSize: Theme.body }
        TextEdit { Layout.fillWidth: true; readOnly: true; selectByMouse: true; wrapMode: Text.WordWrap; text: parent.value; color: Theme.text; font.pixelSize: Theme.body }
    }
}
