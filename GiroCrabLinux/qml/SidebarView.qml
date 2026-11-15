import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt.labs.qmlmodels

// SidebarView.swift: column 1 – collapsible account sections with subtotals, then categories.
Rectangle {
    id: sidebar
    color: Theme.sidebar

    /// The List of the Swift view, flattened into typed rows.
    readonly property var rows: {
        const m = AppModel
        const out = []
        out.push({ type: "nav", key: "all", symbol: "square.grid.2x2", title: qsTr("Übersicht"), badge: m.newCount })
        out.push({ type: "nav", key: "documents", symbol: "doc.on.doc", title: qsTr("Belege & PostBox"), badge: 0 })
        if (m.allAccounts.length) out.push({ type: "accountsHeader" })
        const shown = a => m.showArchivedAccounts || a.archived_unix === null
        if (m.accountView === "byGroup") {
            for (const g of m.userGroups) {
                if (!m.isUserGroupVisible(g)) continue
                const open = !m.collapsedUserGroups[g.uuid]
                out.push({ type: "userGroup", group: g, open: open })
                if (!open) continue
                if (!g.accounts.length && !g.is_ungrouped && m.userGroupSubtree(g.uuid).length === 1)
                    out.push({ type: "hint", depth: g.depth, text: qsTr("Konten hierher ziehen"), group: g })
                g.accounts.forEach((a, i) => { if (shown(a)) out.push({ type: "account", account: a, indent: g.depth * 14 + 14, group: g, row: i }) })
            }
        } else {
            for (const g of m.groups) {
                const open = !m.collapsedGroups[g.id]
                out.push({ type: "kindGroup", group: g, open: open })
                if (open) for (const a of g.accounts) if (shown(a)) out.push({ type: "account", account: a, indent: 0 })
            }
        }
        const pending = m.connections.filter(c => !m.allAccounts.some(a => a.connection_id === c.id))
        if (pending.length) {
            out.push({ type: "section", title: qsTr("Neue Bankzugänge") })
            for (const c of pending) out.push({ type: "connection", connection: c })
        }
        out.push({ type: "categoriesHeader" })
        out.push({ type: "nav", key: "uncategorized", symbol: "questionmark.folder", title: qsTr("Ohne Kategorie"),
                   badge: m.uncategorizedCount, tint: Theme.warning, regular: true })
        function walk(nodes, depth) {
            for (const n of nodes) {
                const open = !!m.expandedCategories[n.category.id]
                out.push({ type: "category", category: n.category, depth: depth, hasChildren: !!n.children, open: open })
                if (n.children && open) walk(n.children, depth + 1)
            }
        }
        walk(m.categoryTree, 0)
        return out
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            topMargin: 10
            bottomMargin: 10
            model: sidebar.rows
            boundsBehavior: Flickable.StopAtBounds
            // Mouse drags move accounts and groups (like the Mac sidebar); the wheel scrolls.
            interactive: false
            WheelHandler {
                onWheel: e => {
                    const max = Math.max(0, list.contentHeight - list.height + list.topMargin + list.bottomMargin)
                    list.contentY = Math.max(-list.topMargin, Math.min(max - list.topMargin, list.contentY - e.angleDelta.y / 120 * 48))
                }
            }
            ScrollBar.vertical: AppScrollBar {}
            delegate: DelegateChooser {
                role: "type"
                DelegateChoice { roleValue: "nav"; delegate: SidebarRow {
                    id: navRow
                    required property var modelData
                    selectionKey: modelData.key
                    TapHandler { enabled: navRow.modelData.key === "all"; acceptedButtons: Qt.RightButton; onTapped: overviewMenu.popup() }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                        SFIcon { symbol: modelData.symbol; size: 16; color: modelData.tint || Theme.secondary; Layout.preferredWidth: 20 }
                        Text { text: modelData.title; font.pixelSize: Theme.body; font.weight: modelData.regular ? Font.Normal : Font.Medium; color: Theme.text; Layout.fillWidth: true; elide: Text.ElideRight }
                        Badge { count: modelData.badge }
                    }
                } }
                DelegateChoice { roleValue: "accountsHeader"; delegate: AccountsSectionHeader {} }
                DelegateChoice { roleValue: "userGroup"; delegate: SidebarRow {
                    id: groupRow
                    required property var modelData
                    readonly property var g: modelData.group
                    selectionKey: "userGroup:" + g.uuid
                    topGap: g.depth === 0 ? 10 : 4
                    TapHandler { acceptedButtons: Qt.RightButton; onTapped: sidebar.openGroupMenu(groupRow.g, groupRow) }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 6 + g.depth * 14; anchors.rightMargin: 10; spacing: 5
                        Disclosure { open: modelData.open; onToggled: AppModel.toggleCollapsedUserGroup(g.uuid)
                                     accessibleName: open ? qsTr("Gruppe einklappen") : qsTr("Gruppe ausklappen") }
                        SFIcon { symbol: g.sf_symbol; size: 16; Layout.preferredWidth: 20
                                 color: selected || !g.color_hex ? Theme.secondary : Theme.readable(g.color_hex) }
                        Text { text: g.name; font.pixelSize: Theme.body; font.weight: Font.DemiBold; color: Theme.secondary; elide: Text.ElideRight; Layout.fillWidth: true }
                        SFIcon { visible: !g.in_total; symbol: "eye.slash"; size: 11
                                 Accessible.name: qsTr("Nicht in der Gesamtsumme")
                                 HoverHandler { id: eyeHover }
                                 ToolTip.visible: eyeHover.hovered; ToolTip.delay: 600; ToolTip.text: qsTr("Nicht in der Gesamtsumme") }
                        Text { text: Fmt.money(g.balance_cents); font.pixelSize: Theme.callout; font.weight: Font.DemiBold; font.features: { "tnum": 1 }
                               opacity: g.in_total ? 1 : 0.6
                               color: selected ? Theme.text : (g.balance_cents < 0 ? Theme.negative : Theme.secondary) }
                    }
                    // an account goes to the top of this group; a group above it
                    // (upper half) or into it as a subgroup (lower half)
                    DropSlot {
                        key: "g:" + g.uuid
                        freeLeading: 12 + g.depth * 14
                        payload: g.is_ungrouped ? null : { type: "group", uuid: g.uuid, label: g.name }
                        edgeFor: (half, p) => {
                            if (p.type !== "group") return "below"
                            const into = half === "below" && !g.is_ungrouped
                            return AppModel.canDropGroup(p.uuid, g, into) ? (into ? "into" : "above") : null
                        }
                        onPerform: (p, edge) => {
                            if (p.type === "account") AppModel.moveAccount(p.id, g.uuid, 0)
                            else AppModel.dropUserGroup(p.uuid, g, edge !== "into")
                        }
                    }
                } }
                DelegateChoice { roleValue: "kindGroup"; delegate: SidebarRow {
                    required property var modelData
                    readonly property var g: modelData.group
                    readonly property bool isLoanGroup: g.accounts.length > 0 && g.accounts.every(a => a.kind === "Loan")
                    selectionKey: "group:" + g.id
                    topGap: 10
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 10; spacing: 5
                        Disclosure { open: modelData.open; onToggled: AppModel.toggleCollapsedGroup(g.id)
                                     accessibleName: open ? qsTr("„%1“ einklappen").arg(g.name) : qsTr("„%1“ ausklappen").arg(g.name) }
                        SFIcon { symbol: g.sf_symbol; size: 16; Layout.preferredWidth: 20 }
                        Text { text: g.name; font.pixelSize: Theme.body; font.weight: Font.DemiBold; color: Theme.secondary; elide: Text.ElideRight; Layout.fillWidth: true }
                        Text { text: Fmt.money(g.balance_cents); font.pixelSize: Theme.callout; font.weight: Font.DemiBold; font.features: { "tnum": 1 }
                               color: selected ? Theme.text : (g.balance_cents < 0 && isLoanGroup ? Theme.loan : (g.balance_cents < 0 ? Theme.negative : Theme.secondary)) }
                    }
                } }
                DelegateChoice { roleValue: "hint"; delegate: Item {
                    required property var modelData
                    width: ListView.view.width; height: 20
                    Text { x: 33 + modelData.depth * 14; anchors.verticalCenter: parent.verticalCenter; text: modelData.text; font.pixelSize: Theme.caption; color: Theme.tertiary }
                    // an account goes here; a group into the group (header lights up)
                    DropSlot {
                        key: "e:" + modelData.group.uuid
                        intoKey: "g:" + modelData.group.uuid
                        inset: 33 + modelData.depth * 14
                        edgeFor: (half, p) => p.type === "group" ? (AppModel.canDropGroup(p.uuid, modelData.group, true) ? "into" : null) : "above"
                        onPerform: (p, edge) => {
                            if (p.type === "account") AppModel.moveAccount(p.id, modelData.group.uuid, 0)
                            else AppModel.dropUserGroup(p.uuid, modelData.group, false)
                        }
                    }
                } }
                DelegateChoice { roleValue: "account"; delegate: AccountRow {
                    id: accountRow
                    onContextMenuRequested: sidebar.openAccountMenu(accountRow.account, accountRow)
                } }
                DelegateChoice { roleValue: "section"; delegate: Item {
                    required property var modelData
                    width: ListView.view.width; height: 30
                    Text { x: 10; anchors.bottom: parent.bottom; anchors.bottomMargin: 4; text: modelData.title; font.pixelSize: Theme.caption; font.weight: Font.DemiBold; color: Theme.secondary }
                } }
                DelegateChoice { roleValue: "connection"; delegate: Item {
                    id: connectionRow
                    required property var modelData
                    width: ListView.view.width; height: 40
                    TapHandler { acceptedButtons: Qt.RightButton; onTapped: sidebar.openConnectionMenu(connectionRow.modelData.connection) }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 9
                        SymbolTile { symbol: modelData.connection.sf_symbol; size: 24 }
                        ColumnLayout { spacing: 1; Layout.fillWidth: true
                            Text { text: modelData.connection.display_name; font.pixelSize: Theme.body; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                            Text { readonly property bool setup: AppModel.missingSettings(modelData.connection).length > 0
                                   text: setup ? qsTr("Einrichtung fehlt") : qsTr("Noch nicht abgerufen"); font.pixelSize: Theme.caption2; color: setup ? Theme.warning : Theme.secondary }
                        }
                        // .disabled(bankingGate != nil).help(gate.message); the wrapper sees the hover of the disabled button
                        Item {
                            readonly property var gate: { void AppModel.bankingPolicy; return AppModel.bankingGate(modelData.connection) }
                            implicitWidth: pendingSync.implicitWidth; implicitHeight: pendingSync.implicitHeight
                            HoverHandler { id: pendingHover }
                            Button { id: pendingSync; anchors.fill: parent
                                     text: AppModel.missingSettings(modelData.connection).length ? qsTr("Einrichten") : qsTr("Abrufen")
                                     enabled: parent.gate === null
                                     ToolTip.text: parent.gate ? parent.gate.message : ""
                                     ToolTip.visible: pendingHover.hovered && ToolTip.text !== ""
                                     onClicked: AppModel.requestSync(modelData.connection) }
                        }
                    }
                } }
                DelegateChoice { roleValue: "categoriesHeader"; delegate: Item {
                    width: ListView.view.width; height: 34
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6; anchors.topMargin: 12
                        Text { text: qsTr("Kategorien"); font.pixelSize: Theme.caption; font.weight: Font.DemiBold; color: Theme.secondary; Layout.fillWidth: true }
                        IconButton { symbol: "plus"; symbolSize: 12; implicitWidth: 24; implicitHeight: 20
                                     ToolTip.text: qsTr("Neue Hauptkategorie …"); ToolTip.visible: hovered; enabled: AppModel.isUnlocked
                                     Accessible.name: qsTr("Neue Hauptkategorie")
                                     onClicked: AppModel.newCategoryRequest = { parent: null } }
                    }
                } }
                DelegateChoice { roleValue: "category"; delegate: SidebarRow {
                    id: catRow
                    required property var modelData
                    readonly property var c: modelData.category
                    selectionKey: "category:" + c.id
                    TapHandler { acceptedButtons: Qt.RightButton; onTapped: sidebar.openCategoryMenu(catRow.c, catRow) }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 2 + modelData.depth * 14; anchors.rightMargin: 10; spacing: 6
                        Disclosure { visible: modelData.hasChildren; open: modelData.open; onToggled: AppModel.toggleExpandedCategory(c.id) }
                        Item { visible: !modelData.hasChildren; implicitWidth: 12 }
                        SFIcon { symbol: c.sf_symbol; size: 15; color: Theme.withAlpha(Theme.readable(c.color_hex), 0.85); Layout.preferredWidth: 20 }
                        Text { text: c.name; font.pixelSize: Theme.body; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                        Text { visible: c.total_cents !== 0; text: Fmt.money(c.total_cents); font.pixelSize: Theme.caption; font.features: { "tnum": 1 }; color: Theme.secondary }
                    }
                } }
            }
        }

        // safeAreaInset(edge: .bottom): lock state + "Bank hinzufügen"
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 34
            color: Theme.withAlpha(Theme.card, 0.6)
            Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.border }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 8; spacing: 6
                // Marketing screenshots (`--screenshot`) look like a real vault: no demo banner.
                readonly property bool demo: AppModel.isDemo && !AppModel.screenshotMode
                SFIcon { symbol: parent.demo ? "theatermasks" : "lock.fill"; size: 12 }
                Text {
                    text: parent.demo ? qsTr("Demo-Daten – keine echte Bank verbunden")
                                      : qsTr("Verschlüsselt · %1").arg(AppModel.lastSyncText)
                    font.pixelSize: Theme.caption; color: Theme.secondary; elide: Text.ElideRight; Layout.fillWidth: true
                }
                IconButton { visible: parent.demo; text: AppModel.hasOwnVault ? qsTr("Eigener Tresor") : qsTr("Tresor öffnen"); symbol: ""; font.pixelSize: Theme.caption
                             onClicked: AppModel.showOwnVault() }
                IconButton { symbol: "plus"; symbolSize: 12; implicitWidth: 24; implicitHeight: 20; onClicked: AppModel.showAddBank = true
                             ToolTip.text: qsTr("Bank hinzufügen …"); ToolTip.visible: hovered; enabled: AppModel.isUnlocked }
            }
        }
    }

    // The drag image: the row title in a capsule, following the pointer.
    Rectangle {
        id: ghost
        readonly property point pos: sidebar.mapFromItem(null, AppModel.dragScenePos.x, AppModel.dragScenePos.y)
        visible: AppModel.dragPayload !== null
        x: pos.x - 12; y: pos.y - height / 2
        width: ghostText.implicitWidth + 20; height: 24; radius: 12
        color: Theme.card; border.color: Theme.border; opacity: 0.92
        Text { id: ghostText; anchors.centerIn: parent; text: AppModel.dragLabel; font.pixelSize: Theme.body; color: Theme.text }
        Drag.active: AppModel.dragPayload !== null
        Drag.keys: ["girocrab-sidebar"]
        Drag.hotSpot.x: 12; Drag.hotSpot.y: height / 2
        Drag.dragType: Drag.Internal
        Connections {
            target: AppModel
            function onDragEnded() { ghost.Drag.drop(); AppModel.dragPayload = null; AppModel.dropLine = null }
        }
    }
    // categoryMenu(_:) – same order as the menus of accounts and groups: rename,
    // look, place – then what only categories have – then delete
    property var menuCategory: null
    property var moveTargets: []
    function openCategoryMenu(c, row) {
        menuCategory = c
        moveTargets = AppModel.categoryMoveTargets(c.id)
        iconPopover.y = Math.max(8, Math.min(sidebar.height - 520, row.mapToItem(sidebar, 0, 0).y))
        categoryMenu.popup()
    }
    AppMenu {
        id: categoryMenu
        AppMenuItem { text: qsTr("Umbenennen …"); icon.name: SF.icon("pencil"); onTriggered: AppModel.renameCategoryTarget = sidebar.menuCategory }
        AppMenuItem { text: qsTr("Symbol && Farbe …"); icon.name: SF.icon("paintpalette"); onTriggered: AppModel.iconColorCategoryID = sidebar.menuCategory.id }
        AppMenu {
            id: moveMenu
            title: qsTr("Verschieben nach")
            icon.name: SF.icon("arrow.turn.down.right")
            AppMenuItem {
                text: qsTr("Oberste Ebene"); icon.name: SF.icon("arrow.up.to.line")
                checkable: true; checked: sidebar.menuCategory !== null && sidebar.menuCategory.parent_id === null
                onTriggered: AppModel.moveCategory(sidebar.menuCategory.id, null)
            }
            AppMenuSeparator {}
            Instantiator {
                model: sidebar.moveTargets
                delegate: AppMenuItem {
                    required property var modelData
                    text: AppModel.menuText("\u2003".repeat(modelData.depth) + modelData.name)
                    icon.name: SF.icon(modelData.sf_symbol)
                    checkable: true
                    checked: sidebar.menuCategory !== null && sidebar.menuCategory.parent_id === modelData.id
                    onTriggered: AppModel.moveCategory(sidebar.menuCategory.id, modelData.id)
                }
                onObjectAdded: (index, object) => moveMenu.insertItem(index + 2, object)
                onObjectRemoved: (index, object) => moveMenu.removeItem(object)
            }
        }
        AppMenuSeparator {}
        AppMenuItem { text: qsTr("Neue Unterkategorie …"); icon.name: SF.icon("plus"); onTriggered: AppModel.newCategoryRequest = { parent: sidebar.menuCategory.id } }
        AppMenuItem { text: qsTr("Monatsbudget festlegen …"); icon.name: SF.icon("gauge.with.dots.needle.67percent"); onTriggered: AppModel.budgetCategoryID = sidebar.menuCategory.id }
        AppMenuSeparator {}
        AppMenuItem { text: qsTr("Kategorie löschen …"); icon.name: SF.icon("trash"); onTriggered: AppModel.deleteCategoryTarget = sidebar.menuCategory }
    }
    // MARK: account & group menus (SidebarView.swift › accountMenu, AccountGroupsUI.swift › UserGroupMenu)
    property var menuAccount: null
    property var menuGroup: null
    property var menuConnection: null
    property string menuBIC: ""
    /// The "Symbol & Farbe" popover sits next to the row the menu was opened on.
    function placePopover(row) { iconPopover.y = Math.max(8, Math.min(sidebar.height - 520, row.mapToItem(sidebar, 0, 0).y)) }
    function openAccountMenu(a, row, x, y) {
        menuAccount = a
        menuBIC = AppModel.bicForIban(a.iban) || ""
        placePopover(row)
        if (x === undefined) accountMenu.popup(); else accountMenu.popup(row, x, y)
    }
    function openGroupMenu(g, row, x, y) {
        menuGroup = g
        placePopover(row)
        const menu = g.is_ungrouped ? ungroupedMenu : groupMenu
        if (x === undefined) menu.popup(); else menu.popup(row, x, y)
    }
    function openConnectionMenu(c) { menuConnection = c; connectionMenu.popup() }
    readonly property var menuConnectionOfAccount: menuAccount && menuAccount.archived_unix === null && menuAccount.connection_id !== null
        ? (AppModel.connections.find(c => c.id === menuAccount.connection_id) || null) : null

    // "Übersicht"
    AppMenu {
        id: overviewMenu
        AppMenuItem { text: qsTr("Alle als gelesen markieren"); icon.name: SF.icon("checkmark.circle"); enabled: AppModel.newCount > 0
                   onTriggered: AppModel.markAllChecked() }
    }
    // pending bank logins ("Neue Bankzugänge")
    AppMenu {
        id: connectionMenu
        AppMenuItem { text: qsTr("Bankzugang entfernen …"); icon.name: SF.icon("trash")
                   onTriggered: AppModel.sidebarDialog = { kind: "removeConnection", id: sidebar.menuConnection.id } }
    }
    // same order as a group's menu: rename, look, place – then what only
    // accounts have – then archive / delete
    AppMenu {
        id: accountMenu
        readonly property var a: sidebar.menuAccount
        readonly property bool archived: a !== null && a.archived_unix !== null
        AppMenuItem { text: qsTr("Umbenennen …"); icon.name: SF.icon("pencil"); onTriggered: AppModel.groupDialog = { kind: "renameAccount", account: accountMenu.a } }
        AppMenuItem { text: qsTr("Symbol && Farbe …"); icon.name: SF.icon("paintpalette"); onTriggered: AppModel.iconColorTarget = { type: "account", id: accountMenu.a.id } }
        // AccountGroupMenu: named like the group menu's entry, so both menus read the same
        AppMenu {
            id: accountMoveMenu
            title: qsTr("Verschieben nach")
            icon.name: SF.icon("arrow.turn.down.right")
            Instantiator {
                model: AppModel.namedUserGroups
                delegate: AppMenuItem {
                    required property var modelData
                    text: AppModel.menuText(AppModel.indentedName(modelData))
                    icon.name: SF.icon(modelData.sf_symbol)
                    checkable: true
                    checked: accountMenu.a !== null && accountMenu.a.user_group_uuid === modelData.uuid
                    onTriggered: AppModel.moveAccount(accountMenu.a.id, modelData.uuid, null)
                }
                onObjectAdded: (index, object) => accountMoveMenu.insertItem(index, object)
                onObjectRemoved: (index, object) => accountMoveMenu.removeItem(object)
            }
            AppMenuItem { text: qsTr("Ohne Gruppe"); icon.name: SF.icon("tray"); checkable: true
                       checked: accountMenu.a !== null && !accountMenu.a.user_group_uuid
                       onTriggered: AppModel.moveAccount(accountMenu.a.id, null, null) }
            AppMenuSeparator {}
            AppMenuItem { text: qsTr("Neue Gruppe …"); icon.name: SF.icon("folder.badge.plus")
                       onTriggered: AppModel.groupDialog = { kind: "create", movingAccount: accountMenu.a.id, parent: null } }
        }
        AppMenuSeparator {}
        AppMenuItem { text: qsTr("Alle als gelesen markieren"); icon.name: SF.icon("checkmark.circle"); onTriggered: AppModel.markAllChecked([accountMenu.a.id]) }
        // ManualLoanAccountMenu + OpeningBalanceMenuItem (ManualLoansUI.swift, OpeningBalanceUI.swift)
        AppMenuItem { readonly property bool shown: AppModel.isEditableManualLoan(accountMenu.a)
                   visible: shown; height: shown ? implicitHeight : 0
                   text: qsTr("Darlehen bearbeiten …"); icon.name: SF.icon("pencil")
                   onTriggered: AppModel.openLoanEditor("edit", accountMenu.a.id) }
        AppMenuItem { readonly property bool shown: AppModel.isEditableManualLoan(accountMenu.a)
                   visible: shown; height: shown ? implicitHeight : 0
                   text: qsTr("Stand neu setzen …"); icon.name: SF.icon("calendar.badge.clock")
                   onTriggered: AppModel.openLoanEditor("anchor", accountMenu.a.id) }
        AppMenuSeparator { visible: AppModel.isEditableManualLoan(accountMenu.a); height: visible ? implicitHeight : 0 }
        AppMenuItem { readonly property bool shown: AppModel.canSetOpeningBalance(accountMenu.a)
                   visible: shown; height: shown ? implicitHeight : 0
                   text: qsTr("Startsaldo …"); icon.name: SF.icon("clock.arrow.circlepath")
                   onTriggered: AppModel.openOpeningBalance(accountMenu.a) }
        AppMenuItem {
            readonly property var conn: sidebar.menuConnectionOfAccount
            visible: conn !== null; height: visible ? implicitHeight : 0
            text: conn ? qsTr("%1 abrufen").arg(AppModel.menuText(conn.display_name)) : ""
            icon.name: SF.icon("arrow.triangle.2.circlepath")
            enabled: conn !== null && AppModel.bankingGate(conn) === null
            onTriggered: AppModel.requestSync(conn)
        }
        // AccountCopyMenu (BalanceHeaderView.swift)
        AppMenu {
            id: copyMenu
            title: qsTr("In Zwischenablage kopieren")
            icon.name: SF.icon("doc.on.clipboard")
            AppMenuItem { visible: accountMenu.a !== null && accountMenu.a.iban !== ""; height: visible ? implicitHeight : 0
                       text: qsTr("Bankverbindung"); onTriggered: AppModel.copyToClipboard(AppModel.accountBankDetails(accountMenu.a, sidebar.menuBIC)) }
            AppMenuItem { visible: accountMenu.a !== null && accountMenu.a.iban !== ""; height: visible ? implicitHeight : 0
                       text: qsTr("IBAN"); onTriggered: AppModel.copyToClipboard(accountMenu.a.iban) }
            AppMenuItem { visible: sidebar.menuBIC !== ""; height: visible ? implicitHeight : 0
                       text: qsTr("BIC"); onTriggered: AppModel.copyToClipboard(sidebar.menuBIC) }
            AppMenuItem { text: qsTr("Kontostand"); onTriggered: AppModel.copyToClipboard(Fmt.clipboard(accountMenu.a.balance_cents)) }
        }
        AppMenuItem { text: qsTr("Belege anzeigen"); icon.name: SF.icon("doc.text.magnifyingglass")
                   onTriggered: { AppModel.documentsAccountFilter = accountMenu.a.id; AppModel.sidebarSelection = "documents" } }
        AppMenuSeparator {}
        AppMenuItem { visible: accountMenu.archived; height: visible ? implicitHeight : 0
                   text: qsTr("Reaktivieren"); icon.name: SF.icon("arrow.uturn.backward"); onTriggered: AppModel.setAccountArchived(accountMenu.a, false) }
        // only archived accounts can be deleted (GiroCrab/GiroCrab#43)
        AppMenuItem { visible: accountMenu.archived; height: visible ? implicitHeight : 0
                   text: qsTr("Konto löschen …"); icon.name: SF.icon("trash"); onTriggered: AppModel.sidebarDialog = { kind: "deleteAccount", account: accountMenu.a } }
        AppMenuItem { visible: !accountMenu.archived; height: visible ? implicitHeight : 0
                   text: qsTr("Konto archivieren …"); icon.name: SF.icon("archivebox"); onTriggered: AppModel.sidebarDialog = { kind: "archiveAccount", account: accountMenu.a } }
    }
    // UserGroupMenu: same order as an account's menu: rename, look, place – then
    // what only groups have – then delete
    AppMenu {
        id: groupMenu
        readonly property var g: sidebar.menuGroup
        AppMenuItem { text: qsTr("Umbenennen …"); icon.name: SF.icon("pencil"); onTriggered: AppModel.groupDialog = { kind: "rename", group: groupMenu.g } }
        AppMenuItem { text: qsTr("Symbol && Farbe …"); icon.name: SF.icon("paintpalette"); onTriggered: AppModel.iconColorTarget = { type: "group", uuid: groupMenu.g.uuid } }
        AppMenuItem { text: qsTr("Alle als gelesen markieren"); icon.name: SF.icon("checkmark.circle")
                   onTriggered: AppModel.markAllChecked(AppModel.userGroupAccountIDs(groupMenu.g.uuid)) }
        AppMenu {
            id: groupMoveMenu
            title: qsTr("Verschieben nach")
            icon.name: SF.icon("arrow.turn.down.right")
            AppMenuItem {
                text: qsTr("Oberste Ebene"); icon.name: SF.icon("arrow.up.to.line")
                checkable: true; checked: groupMenu.g !== null && !groupMenu.g.parent_uuid
                onTriggered: AppModel.setUserGroupParent(groupMenu.g, null)
            }
            AppMenuSeparator {}
            Instantiator {
                model: groupMenu.g ? AppModel.parentCandidates(groupMenu.g) : []
                delegate: AppMenuItem {
                    required property var modelData
                    text: AppModel.menuText(AppModel.indentedName(modelData))
                    icon.name: SF.icon(modelData.sf_symbol)
                    checkable: true
                    checked: groupMenu.g !== null && groupMenu.g.parent_uuid === modelData.uuid
                    onTriggered: AppModel.setUserGroupParent(groupMenu.g, modelData.uuid)
                }
                onObjectAdded: (index, object) => groupMoveMenu.insertItem(index + 2, object)
                onObjectRemoved: (index, object) => groupMoveMenu.removeItem(object)
            }
        }
        AppMenuSeparator {}
        GroupFetchItem { group: groupMenu.g }
        AppMenuItem { text: qsTr("In Gesamtsumme einbeziehen"); checkable: true
                   checked: groupMenu.g !== null && groupMenu.g.include_in_total
                   onTriggered: AppModel.updateUserGroup(groupMenu.g, { includeInTotal: !groupMenu.g.include_in_total }) }
        AppMenuItem { text: qsTr("Neue Untergruppe …"); icon.name: SF.icon("folder.badge.plus")
                   onTriggered: AppModel.groupDialog = { kind: "create", movingAccount: null, parent: groupMenu.g } }
        AppMenuSeparator {}
        AppMenuItem { text: qsTr("Gruppe löschen …"); icon.name: SF.icon("trash"); onTriggered: AppModel.groupDialog = { kind: "delete", group: groupMenu.g } }
    }
    // "Ohne Gruppe": only the fetch button
    AppMenu {
        id: ungroupedMenu
        GroupFetchItem { group: sidebar.menuGroup }
    }
    /// Fetches every login behind the group's accounts, like "Alle abrufen".
    component GroupFetchItem: AppMenuItem {
        property var group: null
        text: qsTr("Konten abrufen"); icon.name: SF.icon("arrow.triangle.2.circlepath")
        enabled: group !== null && AppModel.syncingConnectionID === null
                 && AppModel.groupSyncConnections(group).some(c => AppModel.bankingGate(c) === null)
        onTriggered: AppModel.requestSyncGroup(group)
    }
    // the "Symbol & Farbe" popover, anchored next to the category row
    IconColorPopover {
        id: iconPopover
        x: sidebar.width - 12
        y: 80
    }

    component Disclosure: Item {
        property bool open: true
        property string accessibleName
        signal toggled()
        implicitWidth: 12; implicitHeight: 18
        Accessible.role: Accessible.Button
        Accessible.name: accessibleName
        Accessible.onPressAction: toggled()
        SFIcon { anchors.centerIn: parent; symbol: "chevron.right"; size: 10; rotation: parent.open ? 90 : 0
                 Behavior on rotation { NumberAnimation { duration: 150 } } }
        MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: parent.toggled() }
    }
    component Badge: Rectangle {
        property int count: 0
        visible: count > 0
        implicitWidth: Math.max(20, t.implicitWidth + 10); implicitHeight: 16
        radius: 8
        color: Theme.withAlpha(Theme.secondary, 0.15)
        Text { id: t; anchors.centerIn: parent; text: parent.count; font.pixelSize: Theme.caption; color: Theme.secondary }
    }
}
