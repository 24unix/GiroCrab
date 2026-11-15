import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// AccountGroupsUI.swift › GroupManagerSheet + AccountGroupsSettings (macOS): "Gruppen bearbeiten …".
// The group list with +/− beneath it, the selected group's details beside it.
// Changes apply immediately – "Fertig" only closes the sheet.
Sheet {
    id: sheet
    visible: AppModel.showGroupManager
    onClosed: { detail.commitName(); AppModel.showGroupManager = false }
    sheetWidth: 740
    padding: 0
    /// uuid of the selected group; "" = "Ohne Gruppe", null = none
    property var selection: null
    /// Filters groups and their accounts (name, Kontoinhaber, IBAN / number).
    property string search: ""
    readonly property bool isSearching: search.trim() !== ""
    function hits(accounts) { return accounts.filter(a => AppModel.matchesSidebarSearch(a, search)) }
    /// Groups whose name or accounts match the search (order unchanged).
    readonly property var listedGroups: !isSearching ? AppModel.namedUserGroups
        : AppModel.namedUserGroups.filter(g => AppModel.sidebarTextMatches(g.name, search) || hits(g.accounts).length > 0)
    readonly property bool showsUngrouped: AppModel.hasUserGroups && (!isSearching || hits(AppModel.ungroupedForSettings.accounts).length > 0)
    /// An account dragged out of the detail list: the group row under the pointer takes it.
    property var draggedAccount: null
    property point dragScenePos: Qt.point(0, 0)
    /// uuid of the group row under a dragged account ("" = "Ohne Gruppe", null = none)
    readonly property var dropTarget: {
        if (draggedAccount === null) return null
        const p = groupList.mapFromItem(null, dragScenePos.x, dragScenePos.y)
        if (p.x < 0 || p.x > groupList.width || p.y < 0 || p.y > groupList.height) return null
        const i = groupList.indexAt(p.x, p.y + groupList.contentY)
        const g = i >= 0 ? groupList.model[i] : null
        return g ? (g.is_ungrouped ? "" : g.uuid) : null
    }
    /// Drop an account onto a group row / "Ohne Gruppe".
    function dropAccount(account) {
        const target = dropTarget
        draggedAccount = null
        if (target === null) return false
        AppModel.moveAccount(account.id, target === "" ? null : target, null)
        return true
    }
    readonly property var selectedGroup: selection ? (AppModel.namedUserGroups.find(g => g.uuid === selection) || null) : null
    property var knownUUIDs: []
    onAboutToShow: {
        knownUUIDs = AppModel.namedUserGroups.map(g => g.uuid)
        if (selection === null || (selection !== "" && !selectedGroup))
            selection = AppModel.namedUserGroups.length ? AppModel.namedUserGroups[0].uuid : null
    }
    // select a group just created here; leave a deleted one
    Connections {
        target: AppModel
        function onUserGroupsChanged() {
            if (!sheet.visible) return
            const now = AppModel.namedUserGroups.map(g => g.uuid)
            const added = now.find(u => sheet.knownUUIDs.indexOf(u) < 0)
            if (added) sheet.selection = added
            else if (sheet.selection && now.indexOf(sheet.selection) < 0) sheet.selection = now.length ? now[0] : null
            sheet.knownUUIDs = now
        }
    }

    ColumnLayout {
        width: sheet.availableWidth
        height: Math.min(620, sheet.maxBodyHeight)
        spacing: 0
        Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: 20; Layout.rightMargin: 20; Layout.topMargin: 20
            implicitHeight: searchRow.implicitHeight + 12
            radius: 6
            color: Theme.withAlpha(Theme.tertiary, 0.12)
            Accessible.name: qsTr("Gruppen und Konten suchen")
            RowLayout {
                id: searchRow
                anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                spacing: 6
                SFIcon { symbol: "magnifyingglass"; size: Theme.caption; color: Theme.tertiary }
                TextField {
                    Layout.fillWidth: true
                    padding: 0; leftPadding: 0; rightPadding: 0
                    background: null
                    placeholderText: qsTr("Gruppe, Konto, Kontoinhaber, IBAN …")
                    font.pixelSize: Theme.body
                    color: Theme.text
                    text: sheet.search
                    onTextEdited: sheet.search = text
                }
                IconButton {
                    visible: sheet.search !== ""
                    symbol: "xmark.circle.fill"; symbolSize: Theme.body; tint: Theme.tertiary
                    implicitWidth: 18; implicitHeight: 18
                    Accessible.name: qsTr("Suche löschen")
                    onClicked: sheet.search = ""
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.margins: 20; Layout.topMargin: 12
            spacing: 20
            // the group list with add/remove square buttons beneath it (HIG: Buttons › Square buttons)
            ColumnLayout {
                Layout.preferredWidth: 260; Layout.maximumWidth: 260; Layout.fillHeight: true
                spacing: 8
                ListBox {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    ListView {
                        id: groupList
                        Layout.fillWidth: true; Layout.fillHeight: true
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        // fixed at the end, like in the sidebar: where "−" puts accounts
                        model: sheet.listedGroups.concat(sheet.showsUngrouped ? [AppModel.ungroupedForSettings] : [])
                        ScrollBar.vertical: AppScrollBar {}
                        delegate: GroupListRow {
                            required property var modelData
                            required property int index
                            group: modelData
                            width: ListView.view.width
                            hitCount: sheet.isSearching ? sheet.hits(modelData.accounts).length : -1
                            dropHighlight: sheet.dropTarget !== null && sheet.dropTarget === (modelData.is_ungrouped ? "" : modelData.uuid)
                            selected: (modelData.is_ungrouped ? "" : modelData.uuid) === sheet.selection
                            onClicked: { detail.commitName(); sheet.selection = modelData.is_ungrouped ? "" : modelData.uuid }
                            // .onMove: drag a group to a new place (not "Ohne Gruppe", it stays last)
                            draggable: !modelData.is_ungrouped && !sheet.isSearching
                            onMoved: to => {
                                const list = AppModel.namedUserGroups.map(g => g.uuid)
                                const [u] = list.splice(index, 1)
                                list.splice(Math.min(to, list.length), 0, u)
                                AppModel.reorderUserGroups(list)
                            }
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: sheet.isSearching && groupList.count === 0
                            text: qsTr("Keine Treffer")
                            font.pixelSize: Theme.caption; color: Theme.secondary
                        }
                    }
                    SquareButtons {
                        IconButton { symbol: "plus"; symbolSize: 12; implicitWidth: 26; implicitHeight: 22
                                     ToolTip.text: qsTr("Neue Gruppe …"); Accessible.name: qsTr("Neue Gruppe")
                                     onClicked: AppModel.groupDialog = { kind: "create", movingAccount: null, parent: null } }
                        Rectangle { width: 1; height: 16; color: Theme.border }
                        IconButton { symbol: "minus"; symbolSize: 12; implicitWidth: 26; implicitHeight: 22
                                     enabled: sheet.selectedGroup !== null
                                     ToolTip.text: qsTr("Gruppe löschen …"); Accessible.name: qsTr("Gruppe löschen")
                                     onClicked: AppModel.groupDialog = { kind: "delete", group: sheet.selectedGroup } }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: AppModel.hasUserGroups
                        ? qsTr("Konten per Ziehen auf eine Gruppe legen, Reihenfolge per Ziehen ändern. Suche nach Name, Kontoinhaber oder IBAN.")
                        : qsTr("Mit Gruppen trennen Sie z. B. private und geschäftliche Konten oder die Konten von Familienmitgliedern.")
                    font.pixelSize: Theme.caption; color: Theme.secondary; wrapMode: Text.WordWrap
                }
            }
            // details: "Ohne Gruppe", the selected group, or ContentUnavailableView
            Item {
                Layout.fillWidth: true; Layout.fillHeight: true
                GroupDetailEditor {
                    id: detail
                    anchors.fill: parent
                    onEditSymbol: button => {
                        const p = button.mapToItem(null, button.width + 8, 0)
                        popover.x = Math.min(p.x, (Overlay.overlay ? Overlay.overlay.width : 1000) - popover.width - 8)
                        popover.y = Math.max(8, Math.min(p.y - 40, (Overlay.overlay ? Overlay.overlay.height : 800) - 560))
                        AppModel.iconColorTarget = { type: "group", uuid: group.uuid, host: "manager" }
                    }
                    visible: sheet.selectedGroup !== null || sheet.selection === ""
                    group: sheet.selection === "" ? AppModel.ungroupedForSettings : sheet.selectedGroup
                }
                ColumnLayout {
                    visible: !detail.visible
                    anchors.centerIn: parent
                    width: parent.width
                    spacing: 6
                    SFIcon { Layout.alignment: Qt.AlignHCenter; symbol: "folder"; size: 32; color: Theme.tertiary }
                    Text { Layout.alignment: Qt.AlignHCenter; text: AppModel.hasUserGroups ? qsTr("Keine Gruppe ausgewählt") : qsTr("Noch keine Gruppen")
                           font.pixelSize: Theme.body + 3; font.weight: Font.Bold; color: Theme.secondary }
                    Text { Layout.alignment: Qt.AlignHCenter; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                           text: AppModel.hasUserGroups ? qsTr("Wählen Sie links eine Gruppe aus.") : qsTr("Mit + legen Sie die erste Gruppe an.")
                           font.pixelSize: Theme.body; color: Theme.secondary }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
        RowLayout {
            Layout.fillWidth: true; Layout.margins: 12
            Item { Layout.fillWidth: true }
            Button { text: qsTr("Fertig"); highlighted: true; onClicked: sheet.close() }
        }
    }

    // the drag image of an account: its name in a capsule, following the pointer
    Rectangle {
        readonly property point pos: sheet.contentItem.mapFromItem(null, sheet.dragScenePos.x, sheet.dragScenePos.y)
        parent: sheet.contentItem
        visible: sheet.draggedAccount !== null
        z: 30
        x: pos.x - 12; y: pos.y - height / 2
        width: ghostText.implicitWidth + 20; height: 24; radius: 12
        color: Theme.card; border.color: Theme.border; opacity: 0.92
        Text { id: ghostText; anchors.centerIn: parent; text: sheet.draggedAccount ? sheet.draggedAccount.name : ""; font.pixelSize: Theme.body; color: Theme.text }
    }

    // "Symbol & Farbe" of the selected group, next to its button
    IconColorPopover { id: popover; host: "manager"; parent: Overlay.overlay; z: 20 }

    /// A list row that can be dragged up or down (List `.onMove`): `moved(to)` with the new index.
    component ReorderRow: Rectangle {
        id: rr
        property bool draggable: true
        signal moved(int to)
        property real homeY: 0
        z: drag.active ? 10 : 0
        DragHandler {
            id: drag
            enabled: rr.draggable
            xAxis.enabled: false
            dragThreshold: 6
            onActiveChanged: {
                if (active) { rr.homeY = rr.y; return }
                const to = Math.max(0, Math.round(rr.y / rr.height))
                const from = Math.round(rr.homeY / rr.height)
                rr.y = rr.homeY
                if (to !== from) rr.moved(to)
            }
        }
    }
    /// A bordered list with the square buttons beneath it.
    component ListBox: Rectangle {
        default property alias content: box.data
        color: Theme.card
        radius: 6
        border.color: Theme.border
        clip: true
        ColumnLayout { id: box; anchors.fill: parent; anchors.margins: 1; spacing: 0 }
    }
    component SquareButtons: ColumnLayout {
        default property alias buttons: bar.data
        Layout.fillWidth: true
        spacing: 0
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
        RowLayout { id: bar; Layout.fillWidth: true; Layout.leftMargin: 2; spacing: 0; Layout.preferredHeight: 24 }
    }
    /// GroupListRow: symbol, name, account count, "not in total".
    component GroupListRow: ReorderRow {
        id: glr
        property var group
        property bool selected: false
        /// While searching: how many accounts in this group match (-1 = hide).
        property int hitCount: -1
        /// A dragged account would land here.
        property bool dropHighlight: false
        signal clicked()
        implicitHeight: 40
        color: dropHighlight ? Theme.withAlpha(Theme.accent, 0.32) : selected ? Theme.withAlpha(Theme.accent, 0.18) : "transparent"
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 10 + glr.group.depth * 14; anchors.rightMargin: 10
            spacing: 10
            SFIcon { symbol: glr.group.sf_symbol; size: 16; color: Theme.accent; Layout.preferredWidth: 22 }
            ColumnLayout {
                spacing: 1; Layout.fillWidth: true
                Text { text: glr.group.name; font.pixelSize: Theme.body; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                Text { text: glr.hitCount < 0 ? AppModel.accountCountText(glr.group.accounts.length)
                           : glr.hitCount === 0 ? qsTr("Kein Treffer") : glr.hitCount === 1 ? qsTr("1 Treffer") : qsTr("%1 Treffer").arg(glr.hitCount)
                       font.pixelSize: Theme.caption; color: Theme.secondary }
            }
            SFIcon { visible: !glr.group.in_total; symbol: "eye.slash"; size: 13; color: Theme.tertiary
                     HoverHandler { id: eh }
                     ToolTip.visible: eh.hovered; ToolTip.delay: 600; ToolTip.text: qsTr("Nicht in der Gesamtsumme") }
        }
        TapHandler { onTapped: glr.clicked() }
    }

    /// GroupDetailEditor / UngroupedDetail: name, symbol & colour, parent, total switch, accounts.
    component GroupDetailEditor: Flickable {
        id: ed
        property var group: null
        readonly property bool ungrouped: group !== null && group.is_ungrouped
        signal editSymbol(Item button)
        contentHeight: form.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: AppScrollBar {}
        onGroupChanged: if (group && !ungrouped && !nameField.activeFocus) nameField.text = group.name
        /// Saves the edited name, if the group still exists; a name clash asks to merge.
        function commitName() {
            const g = group ? AppModel.userGroupByUUID(group.uuid) : null
            const n = nameField.text.trim()
            if (!g || g.is_ungrouped || n === "" || n === g.name) return
            const merge = AppModel.renameUserGroup(g, n)
            if (merge) { nameField.text = g.name; AppModel.groupDialog = merge }
        }
        ColumnLayout {
            id: form
            width: ed.width - 12
            spacing: 14
            SettingsFormSection {
                visible: !ed.ungrouped
                TextField { id: nameField; Layout.fillWidth: true; placeholderText: qsTr("Name")
                            onAccepted: ed.commitName(); onActiveFocusChanged: if (!activeFocus) ed.commitName() }
            }
            SettingsFormSection {
                visible: !ed.ungrouped
                SettingsFormRow {
                    label: qsTr("Symbol & Farbe")
                    // the same "Symbol & Farbe" popover as the sidebar's group menu
                    Rectangle {
                        id: symbolButton
                        implicitWidth: 28; implicitHeight: 24; radius: 6
                        color: Theme.withAlpha(Theme.accent, 0.12)
                        Accessible.role: Accessible.Button
                        Accessible.name: qsTr("Symbol & Farbe …")
                        SFIcon { anchors.centerIn: parent; size: 16; symbol: ed.group ? ed.group.sf_symbol : ""
                                 color: !ed.group || ed.group.color_hex === "" ? Theme.accent : Theme.readable(ed.group.color_hex) }
                        TapHandler { onTapped: ed.editSymbol(symbolButton) }
                    }
                }
            }
            SettingsFormSection {
                visible: !ed.ungrouped
                footer: qsTr("Summe, Buchungsliste und Saldoverlauf einer Gruppe enthalten auch ihre Untergruppen.")
                SettingsFormRow {
                    label: qsTr("Übergeordnete Gruppe")
                    AppComboBox {
                        id: parentPicker
                        readonly property var options: ed.group && !ed.ungrouped
                            ? [{ uuid: "", text: qsTr("Keine (oberste Ebene)") }].concat(AppModel.parentCandidates(ed.group).map(c => ({ uuid: c.uuid, text: AppModel.indentedName(c) })))
                            : []
                        Layout.preferredWidth: 170
                        model: options
                        textRole: "text"
                        currentIndex: ed.group ? Math.max(0, options.findIndex(o => o.uuid === (ed.group.parent_uuid || ""))) : 0
                        onActivated: i => AppModel.setUserGroupParent(ed.group, options[i].uuid === "" ? null : options[i].uuid)
                    }
                }
            }
            SettingsFormSection {
                visible: !ed.ungrouped
                footer: ed.group && ed.group.include_in_total && !ed.group.in_total
                    ? qsTr("Diese Gruppe liegt in einer Gruppe, die nicht zur Gesamtsumme zählt – ihre Konten zählen deshalb ebenfalls nicht.")
                    : qsTr("Ausgeschaltet zählen die Konten dieser Gruppe und ihrer Untergruppen nicht zu „Verfügbar“ und zum Saldoverlauf der Übersicht – z. B. für Geschäfts- oder Kinderkonten.")
                SettingsFormRow {
                    label: qsTr("In Gesamtsumme einbeziehen")
                    Switch { checked: ed.group ? ed.group.include_in_total : false
                             onToggled: AppModel.updateUserGroup(ed.group, { includeInTotal: checked }) }
                }
            }
            SettingsFormSection {
                title: qsTr("Konten")
                footer: ed.ungrouped ? qsTr("Konten ohne Gruppe stehen in der Seitenleiste unter „Ohne Gruppe“. Konten per Ziehen auf eine Gruppe links legen.")
                                     : qsTr("Ein Konto gehört zu höchstens einer Gruppe. Konten per Ziehen auf eine andere Gruppe links legen.")
                GroupAccountsList { Layout.fillWidth: true; group: ed.group }
            }
        }
    }

    /// GroupAccountsList (#229): the group's own accounts, "+" (a menu of all others),
    /// "−" (back to "Ohne Gruppe").
    component GroupAccountsList: ListBox {
        id: gal
        property var group: null
        property var selectedID: null
        readonly property var allAccounts: group ? group.accounts : []
        readonly property var accounts: sheet.isSearching ? sheet.hits(allAccounts) : allAccounts
        readonly property var selectedAccount: allAccounts.find(a => a.id === selectedID) || null
        readonly property var addable: group ? AppModel.addableAccounts(group.uuid) : []
        /// While searching: the matching accounts of every other group, flat.
        readonly property var addableHits: sheet.isSearching ? sheet.hits([].concat(...addable.map(s => s.accounts))) : []
        readonly property bool nothingToAdd: sheet.isSearching ? addableHits.length === 0 : addable.length === 0
        implicitHeight: 220
        color: Theme.card
        /// Adds the account and selects it, so "−" undoes a mis-click at once.
        function add(a) { AppModel.moveAccount(a.id, group.is_ungrouped ? null : group.uuid, null); selectedID = a.id }
        /// Bank and IBAN/number, marked when archived; while searching led by the owner it matched.
        function rowDetail(a) {
            const ident = AppModel.accountIdentity(a)
            const detail = ident === a.bank_name ? ident : [a.bank_name, ident].filter(x => x).join(" · ")
            const base = a.archived_unix !== null ? qsTr("Archiviert · %1").arg(detail) : detail
            const q = sheet.search.trim().toLowerCase(), owner = (a.owner || "").toLowerCase()
            if (sheet.isSearching && owner !== "" && (owner.includes(q) || q.split(/\s+/).every(t => owner.includes(t))))
                return [a.owner, base].filter(x => x).join(" · ")
            return base
        }
        ListView {
            id: accountList
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: gal.accounts
            ScrollBar.vertical: AppScrollBar {}
            onCountChanged: { const i = gal.accounts.findIndex(a => a.id === gal.selectedID); if (i >= 0) positionViewAtIndex(i, ListView.Contain) }
            delegate: ReorderRow {
                id: arow
                required property var modelData
                required property int index
                width: ListView.view.width; height: 38
                // one drag for both: onto a group row on the left (moves it there) or to
                // another place in this list (.onMove, not while searching)
                draggable: false
                DragHandler {
                    id: toGroup
                    target: null
                    dragThreshold: 6
                    onActiveChanged: {
                        if (active) { sheet.draggedAccount = arow.modelData; return }
                        if (sheet.draggedAccount === null) return
                        if (sheet.dropAccount(arow.modelData) || sheet.isSearching) return
                        const p = accountList.mapFromItem(null, sheet.dragScenePos.x, sheet.dragScenePos.y)
                        if (p.x < 0 || p.x > accountList.width || p.y < 0 || p.y > accountList.height) return
                        let to = accountList.indexAt(10, p.y + accountList.contentY)
                        if (to < 0) to = gal.accounts.length - 1
                        if (to === arow.index) return
                        const ids = gal.accounts.map(a => a.id)
                        const [id] = ids.splice(arow.index, 1)
                        ids.splice(Math.min(to, ids.length), 0, id)
                        AppModel.reorderAccounts(gal.group.uuid, ids)
                    }
                    onCentroidChanged: if (active) sheet.dragScenePos = centroid.scenePosition
                }
                color: gal.selectedID === modelData.id ? Theme.withAlpha(Theme.accent, 0.18) : "transparent"
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 9
                    AccountSignet { account: arow.modelData; size: 22; tintColor: AppModel.accountColor(arow.modelData.id) }
                    ColumnLayout {
                        spacing: 1; Layout.fillWidth: true
                        Text { text: arow.modelData.name; font.pixelSize: Theme.body; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                        // bank and IBAN/number, marked when archived
                        Text {
                            text: gal.rowDetail(arow.modelData)
                            font.pixelSize: Theme.caption2; color: Theme.secondary; elide: Text.ElideRight; Layout.fillWidth: true
                        }
                    }
                }
                TapHandler { onTapped: gal.selectedID = arow.modelData.id }
            }
            Text {
                anchors.centerIn: parent
                visible: gal.accounts.length === 0
                width: parent.width - 24
                horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                text: sheet.isSearching ? qsTr("Keine Treffer in dieser Gruppe")
                    : gal.group && gal.group.is_ungrouped ? qsTr("Alle Konten sind in Gruppen.") : qsTr("Noch keine Konten – mit + hinzufügen oder hierher ziehen")
                font.pixelSize: Theme.caption; color: Theme.secondary
            }
        }
        // the same square buttons as beneath the group list
        SquareButtons {
            IconButton {
                id: addButton
                symbol: "plus"; symbolSize: 12; implicitWidth: 26; implicitHeight: 22
                enabled: !gal.nothingToAdd
                ToolTip.text: sheet.isSearching ? qsTr("Passendes Konto hinzufügen") : qsTr("Konto hinzufügen"); Accessible.name: qsTr("Konto hinzufügen")
                onClicked: (sheet.isSearching ? hitsMenu : addMenu).popup(addButton, 0, addButton.height)
            }
            Rectangle { width: 1; height: 16; color: Theme.border }
            IconButton {
                symbol: "minus"; symbolSize: 12; implicitWidth: 26; implicitHeight: 22
                // accounts in "Ohne Gruppe" are already out of every group
                enabled: gal.selectedAccount !== null && gal.group !== null && !gal.group.is_ungrouped
                ToolTip.text: qsTr("Aus Gruppe entfernen"); Accessible.name: qsTr("Aus Gruppe entfernen")
                onClicked: AppModel.moveAccount(gal.selectedAccount.id, null, null)
            }
            Item { Layout.fillWidth: true }
            Text { visible: sheet.isSearching; text: qsTr("Auf Gruppe links ziehen"); font.pixelSize: Theme.caption2; color: Theme.tertiary
                   Layout.rightMargin: 8 }
        }
        // while searching: the matching accounts, flat
        AppMenu {
            id: hitsMenu
            Instantiator {
                model: gal.addableHits
                delegate: AppMenuItem {
                    required property var modelData
                    text: AppModel.menuText(modelData.name + " — " + AppModel.accountDetail(modelData))
                    onTriggered: gal.add(modelData)
                }
                onObjectAdded: (index, object) => hitsMenu.insertItem(index, object)
                onObjectRemoved: (index, object) => hitsMenu.removeItem(object)
            }
        }
        // "Ohne Gruppe" first and inline (the likeliest candidates), then one submenu per group
        AppMenu {
            id: addMenu
            readonly property var ungrouped: gal.addable.find(s => s.id === "") || null
            readonly property var others: gal.addable.filter(s => s.id !== "")
            AppMenuItem { visible: addMenu.ungrouped !== null; height: visible ? implicitHeight : 0; enabled: false
                       text: addMenu.ungrouped ? addMenu.ungrouped.title : "" }
            Instantiator {
                model: addMenu.ungrouped ? addMenu.ungrouped.accounts : []
                delegate: AppMenuItem {
                    required property var modelData
                    text: AppModel.menuText(modelData.name + " — " + AppModel.accountDetail(modelData))
                    onTriggered: gal.add(modelData)
                }
                onObjectAdded: (index, object) => addMenu.insertItem(index + 1, object)
                onObjectRemoved: (index, object) => addMenu.removeItem(object)
            }
            AppMenuSeparator { visible: addMenu.ungrouped !== null && addMenu.others.length > 0; height: visible ? implicitHeight : 0 }
            Instantiator {
                model: addMenu.others
                delegate: AppMenu {
                    id: sub
                    required property var modelData
                    title: AppModel.menuText(modelData.title)
                    Instantiator {
                        model: sub.modelData.accounts
                        delegate: AppMenuItem {
                            required property var modelData
                            text: AppModel.menuText(modelData.name + " — " + AppModel.accountDetail(modelData))
                            onTriggered: gal.add(modelData)
                        }
                        onObjectAdded: (index, object) => sub.insertItem(index, object)
                        onObjectRemoved: (index, object) => sub.removeItem(object)
                    }
                }
                onObjectAdded: (index, object) => addMenu.addMenu(object)
                onObjectRemoved: (index, object) => addMenu.removeMenu(object)
            }
        }
    }
}
