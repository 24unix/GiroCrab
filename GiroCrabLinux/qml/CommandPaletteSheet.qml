import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// CommandPalette.swift › CommandPaletteView: Strg+K – views, actions, accounts, categories, merchants.
Sheet {
    id: sheet
    visible: AppModel.showCommandPalette
    sheetWidth: 560
    padding: 0
    onAboutToShow: { query.text = ""; index = 0; query.forceActiveFocus() }
    onClosed: AppModel.showCommandPalette = false
    property int index: 0

    /// Item: { title, subtitle, symbol, action }
    readonly property var items: {
        const m = AppModel
        const out = []
        const action = qsTr("Aktion"), view = qsTr("Ansicht")
        const add = (title, subtitle, symbol, fn) => out.push({ title: title, subtitle: subtitle, symbol: symbol, action: fn })
        for (const s of m.scopes) add(s.title, view, "rectangle.split.3x1", () => m.scope = s.id)
        if (m.canTransfer) add(qsTr("Überweisung senden"), action + " · " + Fmt.keys("Strg+N"), "paperplane", () => m.openTransfer())
        if (!m.bankingBlocksAll) add(qsTr("Alle Konten abrufen"), action + " · " + Fmt.keys("Strg+R"), "arrow.triangle.2.circlepath", () => m.requestSyncAll())
        add(qsTr("Regeln bearbeiten"), action, "wand.and.stars", () => m.openRuleEditor(null))
        add(qsTr("Umsätze exportieren"), action, "square.and.arrow.up", () => m.openBookingExport(false))
        add(qsTr("Buchungen drucken"), action + " · " + Fmt.keys("Strg+P"), "printer", () => m.showPrintSheet = true)
        add(qsTr("Wiederkehrende Buchungen"), action, "repeat", () => m.showRecurringSheet = true)
        add(qsTr("Zeitraum: Seit letztem Gehalt"), view, "banknote", () => m.choosePeriod("sinceSalary"))
        add(qsTr("Zeitraum: 12 Monate"), view, "calendar", () => m.choosePeriod("months12"))
        const previousYear = m.previousYearPeriod()
        add(qsTr("Zeitraum: %1").arg(m.periodTitleOf(previousYear)), view, "calendar", () => m.choosePeriod(previousYear))
        add(qsTr("Zeitraum: Benutzerdefiniert …"), view, "calendar.badge.clock", () => m.showCustomPeriod = true)
        const b = m.selectedBooking
        if (b) {
            add(qsTr("„%1“ kategorisieren").arg(b.merchant_name), action + " · C", "tag", () => m.showCategorizer = true)
            add(qsTr("Regel für „%1“ erstellen").arg(b.merchant_name), action + " · R", "wand.and.stars", () => m.openRuleEditor(b))
        }
        add(qsTr("Historie & Kategorien importieren"), action, "square.and.arrow.down.on.square", () => m.openMoneyMoneyImport())
        add(qsTr("Regeln jetzt anwenden"), action, "play", () => m.applyAllRules())
        add(qsTr("Einstellungen"), action + " · " + Fmt.keys("Strg+,"), "gearshape", () => m.openSettings())
        add(qsTr("Alle Konten"), qsTr("Konten"), "square.grid.2x2", () => m.sidebarSelection = "all")
        add(qsTr("Neue Umsätze"), qsTr("Konten"), "tray.full", () => m.sidebarSelection = "newBookings")
        add(qsTr("Neue Kontogruppe"), action + " · " + Fmt.keys("Strg+Umschalt+N"), "folder.badge.plus", () => m.groupDialog = { kind: "create", movingAccount: null, parent: null })
        add(qsTr("Kontogruppen bearbeiten"), action, "slider.horizontal.3", () => m.openGroupManager())
        add(qsTr("Neue Hauptkategorie"), action, "plus.square", () => m.newCategoryRequest = { parent: null })
        add(qsTr("Neues Darlehen"), action, "car", () => m.openLoanEditor("create"))
        add(qsTr("Neues Sachwerte-Konto"), action, "diamond", () => m.createTangibleAccount())
        if (m.sidebarSelection.startsWith("account:")) {
            const accId = parseInt(m.sidebarSelection.slice(8))
            if (m.isTangible(accId)) add(qsTr("Sachwert hinzufügen"), action, "plus", () => m.openAssetEditor(accId))
            const loan = m.manualLoan(accId)
            if (loan) add(qsTr("Stand von „%1“ neu setzen").arg(loan.setup.name), action, "calendar.badge.clock", () => m.openLoanEditor("anchor", accId))
        }
        if (m.accountView !== "byGroup") add(qsTr("Konten nach Gruppe anzeigen"), view, "folder", () => m.setAccountView("byGroup"))
        if (m.accountView !== "byBank") add(qsTr("Konten nach Bank anzeigen"), view, "building.columns", () => m.setAccountView("byBank"))
        if (m.accountView !== "byKind") add(qsTr("Konten nach Kontoart anzeigen"), view, "square.stack.3d.up", () => m.setAccountView("byKind"))
        for (const b of m.bankGroups)
            add(b.name, qsTr("Bank · %1").arg(m.accountCountText(b.accounts.length)), b.sf_symbol, () => {
                m.setAccountView("byBank"); m.sidebarSelection = "bank:" + b.id })
        for (const g of m.namedUserGroups)
            add(g.name, qsTr("Gruppe · %1").arg(m.accountCountText(g.accounts.length)), g.sf_symbol, () => {
                m.setAccountView("byGroup"); m.sidebarSelection = "userGroup:" + g.uuid })
        const sel = m.selectedAccount
        if (sel) for (const g of m.namedUserGroups) if (g.uuid !== sel.user_group_uuid)
            add(qsTr("„%1“ nach „%2“ verschieben").arg(sel.name).arg(g.name), action, "folder", () => m.moveAccount(sel.id, g.uuid, null))
        for (const a of m.allAccounts) add(a.name, qsTr("Konto · %1").arg(a.bank_name), a.sf_symbol, () => m.sidebarSelection = "account:" + a.id)
        for (const c of m.categories) add(c.name, qsTr("Kategorie · %1").arg(c.path), c.sf_symbol, () => m.sidebarSelection = "category:" + c.id)
        const seen = {}
        let n = 0
        for (const x of m.bookings) {
            const key = x.merchant ? x.merchant.key : x.merchant_name
            if (seen[key] || n >= 300) continue
            seen[key] = true; n++
            const name = x.merchant_name
            add(name, qsTr("Händler suchen"), "magnifyingglass", () => m.searchText = name)
        }
        const q = query.text.trim().toLowerCase()
        if (q === "") return out.slice(0, 14)
        return out.filter(i => i.title.toLowerCase().indexOf(q) >= 0 || i.subtitle.toLowerCase().indexOf(q) >= 0).slice(0, 14)
    }

    /// Closes the palette, then runs the action (one sheet at a time).
    function run() {
        if (index < 0 || index >= items.length) return
        const action = items[index].action
        close()
        Qt.callLater(action)
    }

    ColumnLayout {
        width: sheet.availableWidth
        spacing: 0
        RowLayout {
            Layout.fillWidth: true; Layout.margins: 14
            spacing: 10
            SFIcon { symbol: "command"; size: 16; color: Theme.secondary }
            TextField {
                id: query
                Layout.fillWidth: true
                placeholderText: qsTr("Befehl, Konto, Kategorie oder Händler …")
                font.pixelSize: Theme.body + 5
                background: null
                onTextChanged: sheet.index = 0
                onAccepted: sheet.run()
                Keys.onDownPressed: { sheet.index = Math.min(sheet.index + 1, Math.max(sheet.items.length - 1, 0)); results.positionViewAtIndex(sheet.index, ListView.Contain) }
                Keys.onUpPressed: { sheet.index = Math.max(sheet.index - 1, 0); results.positionViewAtIndex(sheet.index, ListView.Contain) }
                Keys.onEscapePressed: sheet.close()
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
        ListView {
            id: results
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(380, sheet.maxBodyHeight - 60)
            Layout.margins: 8
            clip: true
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds
            model: sheet.items
            ScrollBar.vertical: AppScrollBar {}
            // A real button: screen readers and the keyboard can run it.
            delegate: ItemDelegate {
                id: row
                required property var modelData
                required property int index
                readonly property bool current: index === sheet.index
                width: ListView.view.width
                leftPadding: 12; rightPadding: 12; topPadding: 7; bottomPadding: 7
                Accessible.name: modelData.title
                Accessible.selected: current
                background: Rectangle { radius: 7; color: row.current ? Theme.withAlpha(Theme.secondary, Theme.dark ? 0.28 : 0.16) : "transparent" }
                contentItem: RowLayout {
                    spacing: 10
                    SFIcon { symbol: row.modelData.symbol; size: 16; color: row.current ? Theme.accent : Theme.secondary; Layout.preferredWidth: 20 }
                    Text { text: row.modelData.title; font.pixelSize: Theme.body; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                    Text { text: row.modelData.subtitle; font.pixelSize: Theme.caption; color: Theme.secondary; elide: Text.ElideRight; Layout.maximumWidth: 220 }
                }
                onClicked: { sheet.index = index; sheet.run() }
            }
        }
    }
}
