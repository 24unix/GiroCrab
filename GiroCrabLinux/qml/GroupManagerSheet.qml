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
    sheetWidth: 680
    padding: 0
    /// uuid of the selected group; "" = "Ohne Gruppe", null = none
    property var selection: null
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
        height: Math.min(560, sheet.maxBodyHeight)
        spacing: 0
        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.margins: 20
            spacing: 20
            // the group list with add/remove square buttons beneath it (HIG: Buttons › Square buttons)
            ColumnLayout {
                Layout.preferredWidth: 240; Layout.maximumWidth: 240; Layout.fillHeight: true
                spacing: 8
                ListBox {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    ListView {
                        id: groupList
                        Layout.fillWidth: true; Layout.fillHeight: true
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        // fixed at the end, like in the sidebar: where "−" puts accounts
                        model: AppModel.namedUserGroups.concat(AppModel.hasUserGroups ? [AppModel.ungroupedForSettings] : [])
                        ScrollBar.vertical: AppScrollBar {}
                        delegate: GroupListRow {
                            required property var modelData
                            required property int index
                            group: modelData
                            width: ListView.view.width
                            selected: (modelData.is_ungrouped ? "" : modelData.uuid) === sheet.selection
                            onClicked: { detail.commitName(); sheet.selection = modelData.is_ungrouped ? "" : modelData.uuid }
                            // .onMove: drag a group to a new place (not "Ohne Gruppe", it stays last)
                            draggable: !modelData.is_ungrouped
                            onMoved: to => {
                                const list = AppModel.namedUserGroups.map(g => g.uuid)
                                const [u] = list.splice(index, 1)
                                list.splice(Math.min(to, list.length), 0, u)
                                AppModel.reorderUserGroups(list)
                            }
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
                        ? qsTr("Reihenfolge per Ziehen ändern, Untergruppen über „Übergeordnete Gruppe“. Konten ohne Gruppe erscheinen unter „Ohne Gruppe“.")
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
        RowLayout { id: bar; Layout.leftMargin: 2; spacing: 0; Layout.preferredHeight: 24 }
    }
    /// GroupListRow: symbol, name, account count, "not in total".
    component GroupListRow: ReorderRow {
        id: glr
        property var group
        property bool selected: false
        signal clicked()
        implicitHeight: 40
        color: selected ? Theme.withAlpha(Theme.accent, 0.18) : "transparent"
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 10 + glr.group.depth * 14; anchors.rightMargin: 10
            spacing: 10
            SFIcon { symbol: glr.group.sf_symbol; size: 16; color: Theme.accent; Layout.preferredWidth: 22 }
            ColumnLayout {
                spacing: 1; Layout.fillWidth: true
                Text { text: glr.group.name; font.pixelSize: Theme.body; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                Text { text: AppModel.accountCountText(glr.group.accounts.length); font.pixelSize: Theme.caption; color: Theme.secondary }
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
                footer: ed.ungrouped ? qsTr("Konten ohne Gruppe stehen in der Seitenleiste unter „Ohne Gruppe“.") : qsTr("Ein Konto gehört zu höchstens einer Gruppe.")
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
        readonly property var accounts: group ? group.accounts : []
        readonly property var selectedAccount: accounts.find(a => a.id === selectedID) || null
        readonly property var addable: group ? AppModel.addableAccounts(group.uuid) : []
        implicitHeight: 200
        color: Theme.card
        /// Adds the account and selects it, so "−" undoes a mis-click at once.
        function add(a) { AppModel.moveAccount(a.id, group.uuid, null); selectedID = a.id }
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
                onMoved: to => {
                    const ids = gal.accounts.map(a => a.id)
                    const [id] = ids.splice(index, 1)
                    ids.splice(Math.min(to, ids.length), 0, id)
                    AppModel.reorderAccounts(gal.group.uuid, ids)
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
                            readonly property string ident: AppModel.accountIdentity(arow.modelData)
                            readonly property string detail: ident === arow.modelData.bank_name ? ident : [arow.modelData.bank_name, ident].filter(x => x).join(" · ")
                            text: arow.modelData.archived_unix !== null ? qsTr("Archiviert · %1").arg(detail) : detail
                            font.pixelSize: Theme.caption2; color: Theme.secondary; elide: Text.ElideRight; Layout.fillWidth: true
                        }
                    }
                }
                TapHandler { onTapped: gal.selectedID = arow.modelData.id }
            }
            Text {
                anchors.centerIn: parent
                visible: gal.accounts.length === 0
                text: gal.group && gal.group.is_ungrouped ? qsTr("Alle Konten sind in Gruppen.") : qsTr("Noch keine Konten – mit + hinzufügen")
                font.pixelSize: Theme.caption; color: Theme.secondary
            }
        }
        // the same square buttons as beneath the group list
        SquareButtons {
            IconButton {
                id: addButton
                symbol: "plus"; symbolSize: 12; implicitWidth: 26; implicitHeight: 22
                enabled: gal.addable.length > 0
                ToolTip.text: qsTr("Konto hinzufügen"); Accessible.name: qsTr("Konto hinzufügen")
                onClicked: addMenu.popup(addButton, 0, addButton.height)
            }
            Rectangle { width: 1; height: 16; color: Theme.border }
            IconButton {
                symbol: "minus"; symbolSize: 12; implicitWidth: 26; implicitHeight: 22
                // accounts in "Ohne Gruppe" are already out of every group
                enabled: gal.selectedAccount !== null && gal.group !== null && !gal.group.is_ungrouped
                ToolTip.text: qsTr("Aus Gruppe entfernen"); Accessible.name: qsTr("Aus Gruppe entfernen")
                onClicked: AppModel.moveAccount(gal.selectedAccount.id, null, null)
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
