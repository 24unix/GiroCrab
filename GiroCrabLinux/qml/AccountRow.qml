import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// SidebarView.swift › AccountRow
SidebarRow {
    id: row
    required property var modelData
    readonly property var account: modelData.account
    readonly property bool archived: account.archived_unix !== null
    /// SidebarView.swift › accountRow(syncing:): its bank login is being fetched
    readonly property bool syncing: AppModel.syncingConnectionID !== null && AppModel.syncingConnectionID === account.connection_id
    /// right click: SidebarView opens accountMenu(_:)
    signal contextMenuRequested()
    readonly property var repaid: account.kind === "Loan" && account.initial_balance_cents > 0
        ? Math.max(0, Math.min(1, 1 - (-account.balance_cents) / account.initial_balance_cents)) : null
    /// First letters of the owner's first two words (owner capsule after the name).
    readonly property string ownerInitials: (account.owner || "").split(/\s+/).filter(w => w).slice(0, 2).map(w => w[0]).join("").toUpperCase()
    /// While searching, prefer Kontoinhaber or IBAN so the hit is obvious.
    readonly property string searchAwareSubtitle: {
        if (!AppModel.isSidebarAccountSearching) return account.bank_name
        const q = AppModel.sidebarAccountSearch.trim()
        const compact = q.replace(/\s/g, "").toLowerCase()
        const terms = q.split(/\s+/).filter(t => t)
        if (account.owner && terms.length && terms.every(t => account.owner.toLowerCase().includes(t.toLowerCase())))
            return account.owner
        if (compact.length >= 3 && AppModel.compactAccountIds(account).some(x => x.includes(compact)))
            return account.iban ? Fmt.iban(account.iban) : account.account_number
        return account.bank_name
    }
    readonly property bool ibanSubtitle: AppModel.isSidebarAccountSearching && account.iban !== "" && searchAwareSubtitle === Fmt.iban(account.iban)
    selectionKey: "account:" + account.id
    rowHeight: 40
    opacity: archived ? 0.55 : 1
    TapHandler { acceptedButtons: Qt.RightButton; onTapped: row.contextMenuRequested() }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 10 + row.modelData.indent; anchors.rightMargin: 10
        spacing: 9
        AccountSignet { account: row.account; size: 24; tintColor: AppModel.accountColor(row.account.id); onSelection: row.selected }
        ColumnLayout {
            spacing: 1
            Layout.fillWidth: true
            RowLayout {
                spacing: 4
                Layout.fillWidth: true
                Text { text: row.account.name; font.pixelSize: Theme.body; color: Theme.text; elide: Text.ElideRight; Layout.maximumWidth: Math.ceil(implicitWidth); Layout.fillWidth: true; Sensitive {} }
                Rectangle {
                    visible: row.ownerInitials !== ""
                    implicitWidth: initials.implicitWidth + 8; implicitHeight: initials.implicitHeight
                    radius: height / 2
                    color: Theme.withAlpha(Theme.secondary, 0.15)
                    Text { id: initials; anchors.centerIn: parent; text: row.ownerInitials
                           font.pixelSize: Theme.caption2; font.weight: Font.DemiBold; color: Theme.secondary }
                    Sensitive {}
                }
                SFIcon { visible: row.account.access_revoked; symbol: "lock.slash"; size: 10; color: "orange"
                         HoverHandler { id: revokedHover }
                         ToolTip.visible: revokedHover.hovered; ToolTip.delay: 600
                         ToolTip.text: qsTr("Zugriff entzogen: Die Bank liefert dieses Konto nicht mehr. Buchungen bleiben erhalten.") }
                // a count bubble, not just a dot: how many are new
                NewCountBadge { count: row.account.new_count; onSelection: row.selected }
                Item { Layout.fillWidth: true; Layout.preferredWidth: 0 }
            }
            ProgressBar {
                visible: row.repaid !== null
                from: 0; to: 1; value: row.repaid || 0
                Layout.maximumWidth: 110; Layout.fillWidth: true; implicitHeight: 4
                background: Rectangle { radius: 2; color: Theme.withAlpha(Theme.loan, 0.2) }
                contentItem: Item { Rectangle { width: parent.width * (row.repaid || 0); height: parent.height; radius: 2; color: Theme.withAlpha(Theme.loan, 0.7) } }
            }
            Text {
                visible: row.repaid === null
                text: row.archived ? qsTr("Archiviert %1").arg(new Date(row.account.archived_unix * 1000).toLocaleDateString(Fmt.locale, Fmt.pattern("dd.MM.yy"))) : row.searchAwareSubtitle
                font.pixelSize: Theme.caption2; font.family: row.ibanSubtitle ? "monospace" : Qt.application.font.family
                color: Theme.secondary; elide: Text.ElideRight; Layout.fillWidth: true
                Sensitive { when: !row.archived && row.searchAwareSubtitle !== row.account.bank_name }   // owner / IBAN hits
            }
        }
        BusyIndicator { visible: row.syncing; running: row.syncing; implicitWidth: 16; implicitHeight: 16; padding: 0 }
        ColumnLayout {
            spacing: 1
            Text {
                Layout.alignment: Qt.AlignRight
                text: Fmt.money(row.account.balance_cents, row.account.currency)
                font.pixelSize: Theme.callout; font.features: { "tnum": 1 }
                color: row.selected ? Theme.text : (row.account.kind === "Loan" ? Theme.loan : (row.account.balance_cents < 0 ? Theme.negative : Theme.text))
                Sensitive {}
            }
            Text { visible: row.repaid !== null; Layout.alignment: Qt.AlignRight
                   text: qsTr("%1 getilgt").arg(Fmt.percent(row.repaid || 0)); font.pixelSize: Theme.caption2; color: Theme.secondary; Sensitive {} }
        }
    }

    // accounts are dragged in the "Nach Gruppe" view only
    DropSlot {
        readonly property var g: row.modelData.group || null
        key: "a:" + row.account.id
        intoKey: g ? "g:" + g.uuid : key
        payload: g ? { type: "account", id: row.account.id, label: row.account.name } : null
        enabled: g !== null
        edgeFor: (half, p) => {
            if (p.type === "group") return AppModel.canDropGroup(p.uuid, g, true) ? "into" : null
            return half
        }
        onPerform: (p, edge) => {
            if (p.type === "account") {
                const from = g.accounts.findIndex(a => a.id === p.id)
                AppModel.moveAccount(p.id, g.uuid, AppModel.insertionIndex(row.modelData.row, edge === "below", from))
            } else {
                AppModel.dropUserGroup(p.uuid, g, edge !== "into")
            }
        }
    }
}
