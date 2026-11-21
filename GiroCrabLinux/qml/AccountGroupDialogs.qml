import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// AccountGroupsUI.swift › AccountGroupDialogs (`AppModel.groupDialog`): the text alert for
// "Neue Gruppe" / "Gruppe umbenennen" / "Konto umbenennen" and the confirmations
// "Gruppe … löschen?" / "Mit … zusammenführen?". Below: the account and bank-login
// confirmations of SidebarView.swift › SidebarDialog (`AppModel.sidebarDialog`).
Item {
    id: root
    readonly property string kind: AppModel.groupDialog ? AppModel.groupDialog.kind : ""
    readonly property bool needsText: ["create", "rename", "renameAccount", "editOwner", "renameUncategorized"].indexOf(kind) >= 0

    /// GroupDialog.title
    function titleOf(d) {
        switch (d.kind) {
        case "create": return d.parent ? qsTr("Neue Untergruppe in „%1“").arg(d.parent.name) : qsTr("Neue Gruppe")
        case "rename": return qsTr("Gruppe umbenennen")
        case "renameAccount": return qsTr("Konto umbenennen")
        case "editOwner": return qsTr("Kontoinhaber")
        case "renameUncategorized": return qsTr("Bezeichnung ändern")
        case "delete": return qsTr("Gruppe „%1“ löschen?").arg(d.group.name)
        case "merge": return qsTr("Mit „%1“ zusammenführen?").arg(d.into.name)
        }
        return ""
    }
    /// Dismissing clears the dialog unless an action already switched to another one.
    function dismissed(d) { if (AppModel.groupDialog === d) AppModel.groupDialog = null }

    Sheet {
        id: textAlert
        reportCapturable: false   // an alert on the Mac (ReportDialogs.qml)
        property var current: null
        visible: root.needsText
        sheetWidth: 360
        parent: Overlay.overlay
        z: 10
        onAboutToShow: {
            current = AppModel.groupDialog
            field.text = current.kind === "rename" ? current.group.name : current.kind === "renameAccount" ? current.account.name
                       : current.kind === "editOwner" ? (current.account.owner || "") : ""
            field.selectAll(); field.forceActiveFocus()
        }
        onClosed: root.dismissed(current)
        function submit() {
            const d = current
            const name = field.text.trim()
            // "Kontoinhaber …" (#280): empty text clears the owner
            if (d.kind === "editOwner") { close(); AppModel.setAccountOwner(d.account.id, name); return }
            // „Ohne Kategorie“ (#597): empty text restores the default
            if (d.kind === "renameUncategorized") { close(); SidebarModel.setUncategorizedName(name); return }
            if (name === "") return
            close()
            switch (d.kind) {
            case "create": AppModel.createUserGroup(name, d.movingAccount, d.parent ? d.parent.uuid : null); break
            case "rename": {
                // after the alert has closed
                const next = AppModel.renameUserGroup(d.group, name)
                if (next) Qt.callLater(() => AppModel.groupDialog = next)
                break
            }
            case "renameAccount": AppModel.renameAccount(d.account.id, name); break
            }
        }
        ColumnLayout {
            width: textAlert.availableWidth
            spacing: 12
            Text { text: textAlert.current ? root.titleOf(textAlert.current) : ""; font.pixelSize: Theme.body + 1; font.weight: Font.Bold; color: Theme.text
                   horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            Text {
                readonly property var moving: textAlert.current && textAlert.current.kind === "create" && textAlert.current.movingAccount !== null
                                              ? AppModel.account(textAlert.current.movingAccount) : null
                visible: moving !== null
                text: moving ? qsTr("„%1“ wird in die neue Gruppe verschoben.").arg(moving.name) : ""
                font.pixelSize: Theme.callout; color: Theme.secondary; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; Layout.fillWidth: true
            }
            TextField { id: field; Layout.fillWidth: true; onAccepted: textAlert.submit()
                        placeholderText: textAlert.current && textAlert.current.kind === "editOwner" ? qsTr("Name des Kontoinhabers") : qsTr("Name, z. B. „Privat“ oder „Geschäft“") }
            RowLayout {
                Layout.fillWidth: true
                Button { text: qsTr("Abbrechen"); Layout.fillWidth: true; onClicked: textAlert.close() }
                Button {
                    readonly property string k: textAlert.current ? textAlert.current.kind : ""
                    text: k === "editOwner" ? qsTr("Sichern") : k === "renameUncategorized" ? qsTr("Umbenennen") : k !== "create" ? qsTr("Umbenennen") : qsTr("Anlegen")
                    highlighted: true; Layout.fillWidth: true; enabled: k === "editOwner" || k === "renameUncategorized" || field.text.trim() !== ""; onClicked: textAlert.submit()
                }
            }
        }
    }

    ConfirmDialog {
        id: confirm
        property var current: null
        visible: root.kind === "delete" || root.kind === "merge"
        parent: Overlay.overlay
        z: 10
        onAboutToShow: current = AppModel.groupDialog
        onClosed: root.dismissed(current)
        heading: current ? root.titleOf(current) : ""
        message: !current ? "" : current.kind === "delete" ? AppModel.deleteMessage(current.group)
                 : current.kind !== "merge" ? "" : qsTr("Die Konten aus „%1“ kommen nach „%2“. „%1“ wird entfernt.").arg(current.from.name).arg(current.into.name)
        actionTitle: current && current.kind === "merge" ? qsTr("Zusammenführen") : qsTr("Löschen")
        destructive: current !== null && current.kind === "delete"
        onConfirmed: {
            const d = current
            if (d.kind === "delete") AppModel.deleteUserGroup(d.group)
            else AppModel.mergeUserGroups(d.from, d.into)
        }
    }

    // SidebarView.swift › SidebarDialog: archive / delete an account, remove a bank login
    ConfirmDialog {
        id: sidebarConfirm
        property var current: null
        visible: AppModel.sidebarDialog !== null
        parent: Overlay.overlay
        z: 10
        onAboutToShow: current = AppModel.sidebarDialog
        onClosed: if (AppModel.sidebarDialog === current) AppModel.sidebarDialog = null
        // one form for every delete / archive dialog (#669): the name in the title, „Löschen“ as action
        heading: !current ? "" : current.kind === "archiveAccount" ? qsTr("Konto „%1“ archivieren?").arg(current.account.name)
                 : current.kind === "deleteAccount" ? qsTr("Konto „%1“ löschen?").arg(current.account.name) : qsTr("Bankzugang entfernen?")
        message: !current ? ""
            : current.kind === "archiveAccount"
              ? qsTr("Das Konto wird nicht mehr abgerufen, von Regeln nicht mehr verändert und zählt nicht mehr zur Gesamtsumme. Buchungen, Kategorien, Belege und die Gruppe bleiben erhalten. Es lässt sich jederzeit reaktivieren.")
            : current.kind === "deleteAccount"
              ? qsTr("Das Konto wird samt %1 Buchungen, Belegen und Depotpositionen unwiderruflich gelöscht – auch aus Auswertungen und Kategoriesummen. Ist es das letzte Konto seines Bankzugangs, wird auch der Bankzugang mit den gespeicherten Zugangsdaten entfernt.").arg(current.account.transaction_count)
              : qsTr("Alle Konten dieses Bankzugangs werden samt Buchungen, Belegen und gespeicherten Zugangsdaten aus dem Tresor gelöscht. Das lässt sich nicht widerrufen.")
        actionTitle: !current ? "" : current.kind === "archiveAccount" ? qsTr("Archivieren")
                     : current.kind === "deleteAccount" ? qsTr("Löschen") : qsTr("Entfernen")
        destructive: current !== null && current.kind !== "archiveAccount"
        onConfirmed: {
            const d = current
            if (d.kind === "archiveAccount") AppModel.setAccountArchived(d.account, true)
            else if (d.kind === "deleteAccount") AppModel.deleteAccount(d.account.id)
            else AppModel.removeConnection(d.id)
        }
    }
}
