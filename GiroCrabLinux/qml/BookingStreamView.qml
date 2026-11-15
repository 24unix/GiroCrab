import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes

// BookingListView.swift › BookingStreamView: header card on top (macOS),
// then a scrolling stream of statistics cards and day cards with booking rows.
Rectangle {
    id: stream
    color: Theme.canvas
    readonly property bool isOverview: AppModel.sidebarSelection === "all"
    readonly property bool isDepot: AppModel.selectedAccount !== null
        && (AppModel.selectedAccount.kind === "Brokerage" || AppModel.selectedAccount.name.toLowerCase().indexOf("depot") >= 0)
    /// @AppStorage("showAccountAnalytics")
    readonly property bool showAnalytics: AppModel.uiDefaults.showAccountAnalytics
    /// No accounts in the personal vault: the welcome card replaces header and placeholder.
    readonly property bool emptyVault: !AppModel.demoActive && AppModel.allAccounts.length === 0

    focus: true
    Keys.onDownPressed: AppModel.moveSelection(1)
    Keys.onUpPressed: AppModel.moveSelection(-1)
    Keys.onPressed: e => {
        if (AppModel.screenshotMode || AppModel.selectedBooking === null) return
        const b = AppModel.selectedBooking
        // Strg+C copies the selected booking (Bearbeiten › Kopieren)
        if (e.matches(StandardKey.Copy)) { AppModel.copyToClipboard(AppModel.clipboardLine(b)); e.accepted = true; return }
        if (e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
        // C: categorise, R: rule for this merchant
        if (e.key === Qt.Key_C) { AppModel.showCategorizer = true; e.accepted = true }
        else if (e.key === Qt.Key_R) { AppModel.openRuleEditor(b); e.accepted = true }
        // Return: edit the note in the inspector
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { AppModel.editNote(b); e.accepted = true }
        // Space: Quick Look of the first document (only; "Geprüft" is Strg+Umschalt+U)
        else if (e.key === Qt.Key_Space) e.accepted = AppModel.quickLookFirstDocument(b)
    }
    Connections {
        target: AppModel
        // Esc in the note field hands the keyboard back to the list
        function onFocusList() { stream.forceActiveFocus() }
    }

    // .dropDestination(for: URL.self) { model.dropAnywhere(urls) }
    DropArea {
        anchors.fill: parent
        onDropped: d => { if (d.hasUrls) AppModel.dropAnywhere(d.urls) }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        BankingPolicyBanner { Layout.fillWidth: true }

        // header(isOverview:emptyVault:scope:)
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: false // a nested layout fills by default (all children hidden: empty vault)
            Layout.leftMargin: 20; Layout.rightMargin: 20; Layout.topMargin: 18; Layout.bottomMargin: 10
            spacing: 14
            DemoBanner { visible: AppModel.demoActive && !AppModel.screenshotMode; Layout.fillWidth: true }
            StreamHeaderCard { visible: !stream.emptyVault; Layout.fillWidth: true }
            RowLayout {
                visible: !stream.emptyVault && AppModel.showStatistics && !stream.isOverview && !stream.isDepot && AppModel.scope !== "Investments" && AppModel.allAccounts.length > 0
                Rectangle {
                    implicitWidth: an.implicitWidth + 20; implicitHeight: an.implicitHeight + 8; radius: height / 2
                    color: stream.showAnalytics ? Theme.withAlpha(Theme.accent, 0.18) : Theme.withAlpha(Theme.secondary, 0.12)
                    RowLayout { id: an; anchors.centerIn: parent; spacing: 4
                        SFIcon { symbol: "chart.bar.xaxis"; size: 11; color: Theme.text }
                        Text { text: qsTr("Analysen"); font.pixelSize: Theme.caption; font.weight: Font.Medium; color: Theme.text } }
                    MouseArea { id: analyticsArea; anchors.fill: parent; hoverEnabled: true; onClicked: AppModel.uiDefaults.showAccountAnalytics = !stream.showAnalytics }
                    ToolTip.visible: analyticsArea.containsMouse; ToolTip.delay: 600
                    ToolTip.text: qsTr("Cashflow und Budgets für dieses Konto ein-/ausblenden")
                }
                Item { Layout.fillWidth: true }
            }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: AppModel.streamModel
            reuseItems: true
            cacheBuffer: 800
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: AppScrollBar { id: vbar }
            bottomMargin: 18
            // The statistics cards above the stream grow after the first load:
            // stay at the top unless the user has scrolled away.
            property bool pinnedTop: true
            onMovingChanged: { if (!moving) pinnedTop = atYBeginning; else scrollDate.show() }

            // Linux addition (not in the Mac app): while the list is scrolled by hand, a bubble
            // next to the scroll bar handle shows the day of the topmost visible booking.
            // mouse wheel / touchpad (not always reported as `moving`), flicking, dragging the handle;
            // programmatic jumps (selection, paging) happen without the pointer over the list
            HoverHandler { id: listHover }
            readonly property bool userScrolling: moving || vbar.pressed || listHover.hovered

            header: ColumnLayout {
                width: list.width
                onImplicitHeightChanged: if (list.pinnedTop) Qt.callLater(list.positionViewAtBeginning)
                spacing: 14
                Item { implicitHeight: 4 }
                EmptyVaultCard {
                    visible: stream.emptyVault
                    Layout.fillWidth: true; Layout.leftMargin: 20; Layout.rightMargin: 20
                }
                // Built only in "Sparpläne & Perks" (it is hidden everywhere else).
                Loader {
                    active: AppModel.scope === "Investments" && AppModel.dashboard !== null
                    visible: active
                    Layout.fillWidth: true; Layout.leftMargin: 20; Layout.rightMargin: 20
                    sourceComponent: Component { InvestmentDashboardView {} }
                }
                CashflowCard {
                    visible: AppModel.showStatistics && AppModel.allAccounts.length > 0 && (stream.isOverview || stream.showAnalytics) && AppModel.scope !== "Investments"
                    Layout.fillWidth: true; Layout.leftMargin: 20; Layout.rightMargin: 20
                }
                BudgetProgressCard {
                    visible: AppModel.showStatistics && AppModel.allAccounts.length > 0 && (stream.isOverview || stream.showAnalytics) && AppModel.scope !== "Investments"
                    Layout.fillWidth: true; Layout.leftMargin: 20; Layout.rightMargin: 20
                }
                // ContentUnavailableView "Keine Buchungen im Depot", in the middle of the visible area
                ColumnLayout {
                    visible: AppModel.dayGroups.length === 0 && stream.isDepot && AppModel.searchText === ""
                    Layout.alignment: Qt.AlignHCenter // the column is only as wide as its texts
                    Layout.topMargin: Math.max(40, (list.height - implicitHeight) / 2 - 20)
                    spacing: 6
                    SFIcon { Layout.alignment: Qt.AlignHCenter; symbol: "chart.line.uptrend.xyaxis"; size: 32 }
                    Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Keine Buchungen im Depot"); font.pixelSize: Theme.title2; font.weight: Font.Bold; color: Theme.text }
                    Text { Layout.alignment: Qt.AlignHCenter; Layout.maximumWidth: Math.min(460, list.width - 40); horizontalAlignment: Text.AlignHCenter
                           wrapMode: Text.WordWrap; color: Theme.secondary; font.pixelSize: Theme.body
                           text: qsTr("Ein Depot zeigt seine Positionen oben. Käufe, Verkäufe und Sparpläne stehen als Buchungen im Verrechnungskonto.") }
                }
                ColumnLayout {
                    visible: AppModel.dayGroups.length === 0 && !(stream.isDepot && AppModel.searchText === "") && !stream.emptyVault
                    Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 40
                    spacing: 6
                    SFIcon { Layout.alignment: Qt.AlignHCenter; symbol: AppModel.searchText ? "magnifyingglass" : "tray"; size: 32 }
                    Text { Layout.alignment: Qt.AlignHCenter; text: AppModel.searchText ? qsTr("Keine Treffer") : qsTr("Keine Buchungen"); font.pixelSize: Theme.title2; font.weight: Font.Bold; color: Theme.text }
                    Text { Layout.alignment: Qt.AlignHCenter; color: Theme.secondary; font.pixelSize: Theme.body
                           text: AppModel.searchText ? qsTr("Nichts passt zu „%1“.").arg(AppModel.searchText) : qsTr("Konto abrufen oder anderen Zeitraum wählen.") }
                }
            }

            // LoadMoreBookingsFooter. Below the info it reserves the estimated height of the
            // bookings not loaded yet, so the total length (and the scroll bar handle) stays put
            // while pages arrive. Whenever that space comes into view, the bookings up to the
            // visible position are loaded (also when the handle is dragged to the bottom).
            property real estItemHeight: 48   // measured after each page, see measureItems()
            readonly property real placeholderHeight: {
                const n = AppModel.bookings.length
                if (!AppModel.hasMoreBookings || n === 0) return 0
                return AppModel.remainingBookingCount * (AppModel.streamModel.count / n) * estItemHeight
            }
            function measureItems() {
                const h = list.contentHeight - (list.headerItem ? list.headerItem.height : 0)
                          - (list.footerItem ? list.footerItem.height : 0)
                const n = AppModel.streamModel.count
                if (n > 50 && h > 0) list.estItemHeight = h / n
            }
            function loadVisible() {
                const f = list.footerItem
                if (!AppModel.hasMoreBookings || AppModel.isLoadingMoreBookings || !f || !f.visible) return
                const missing = list.contentY + list.height - f.y   // px of the footer in view (+ below)
                if (missing < -400) return
                const perBooking = (AppModel.streamModel.count / Math.max(1, AppModel.bookings.length)) * list.estItemHeight
                AppModel.loadMoreBookings(Math.min(3000, Math.max(AppModel.defaultListLimit,
                                                                  Math.ceil(missing / perBooking) + 100)))
            }
            onContentYChanged: { Qt.callLater(loadVisible); if (userScrolling) scrollDate.show() }
            onHeightChanged: Qt.callLater(loadVisible)
            Connections {
                target: AppModel
                function onIsLoadingMoreBookingsChanged() {
                    if (!AppModel.isLoadingMoreBookings) { list.measureItems(); Qt.callLater(list.loadVisible) }
                }
            }
            footer: Item {
                width: list.width
                visible: AppModel.hasMoreBookings
                height: visible ? info.implicitHeight + 28 + list.placeholderHeight : 0
                onVisibleChanged: if (visible) Qt.callLater(list.loadVisible)
                ColumnLayout {
                    id: info
                    width: parent.width
                    spacing: 8
                    Item { implicitHeight: 14 }
                    Text {
                        Layout.alignment: Qt.AlignHCenter; Layout.maximumWidth: list.width - 40
                        horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                        text: qsTr("%1 von %2 Buchungen geladen – ältere Buchungen sind noch nicht sichtbar.")
                              .arg(AppModel.bookings.length).arg(AppModel.bookings.length + AppModel.remainingBookingCount)
                        font.pixelSize: Theme.caption; color: Theme.secondary
                    }
                    BusyIndicator { Layout.alignment: Qt.AlignHCenter; implicitWidth: 18; implicitHeight: 18; opacity: AppModel.isLoadingMoreBookings ? 1 : 0; running: AppModel.isLoadingMoreBookings }
                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter; spacing: 10
                        Button { text: qsTr("Weitere Buchungen laden"); enabled: !AppModel.isLoadingMoreBookings; onClicked: AppModel.loadMoreBookings() }
                        Button { text: qsTr("Alle Buchungen laden"); onClicked: AppModel.loadAllBookings() }
                    }
                }
                // in the reserved space: a spinner in the middle of the visible part
                BusyIndicator {
                    readonly property real infoHeight: info.implicitHeight + 28
                    readonly property real viewMid: list.contentY + list.height / 2 - parent.y
                    visible: AppModel.isLoadingMoreBookings && viewMid > infoHeight + 40
                    running: visible
                    width: 28; height: 28
                    x: (parent.width - width) / 2
                    y: Math.min(parent.height - height, Math.max(infoHeight, viewMid - height / 2))
                }
            }

            delegate: Item {
                id: item
                required property int index
                readonly property var modelData: AppModel.streamItems[index] ?? ({ type: "none" })
                width: list.width
                height: modelData.type === "header" ? 14 + dayHeader.height : row.height

                DayHeader {
                    id: dayHeader
                    visible: item.modelData.type === "header"
                    day: item.modelData.type === "header" ? item.modelData.day : null
                    x: 20; y: 14; width: item.width - 40
                }
                DayCardRow {
                    id: row
                    visible: item.modelData.type === "row"
                    booking: item.modelData.type === "row" ? item.modelData.booking : null
                    isLast: !!item.modelData.isLast
                    x: 20; width: item.width - 40
                }
            }

            Rectangle {
                id: scrollDate
                /// Day of the topmost visible booking ("" over the cards above the list).
                property string label: ""
                function show() {
                    const i = list.indexAt(40, list.contentY + 1)
                    const item = i >= 0 ? AppModel.streamItems[i] : null
                    const day = !item ? "" : item.type === "header" ? item.day.date : item.type === "row" ? item.booking.booking_date : ""
                    const d = Fmt.date(day)
                    label = d ? d.toLocaleDateString(Fmt.locale, Fmt.pattern("d. MMMM yyyy")) : estimate()
                    hideTimer.restart()
                }
                /// In the reserved space of bookings not loaded yet: month and year estimated from
                /// the pace of the loaded ones ("ca. März 2021"), "" elsewhere.
                function estimate() {
                    const f = list.footerItem, b = AppModel.bookings
                    if (!f || !f.visible || b.length < 2 || list.placeholderHeight <= 0) return ""
                    const start = f.y + f.height - list.placeholderHeight
                    const y = list.contentY + 1
                    if (y < start) return ""
                    const perBooking = (AppModel.streamModel.count / b.length) * list.estItemHeight
                    const below = Math.min(AppModel.remainingBookingCount, (y - start) / perBooking)
                    const first = Fmt.date(b[0].booking_date), last = Fmt.date(b[b.length - 1].booking_date)
                    if (!first || !last) return ""
                    const est = new Date(last.getTime() + (last.getTime() - first.getTime()) * below / b.length)
                    return qsTr("ca. %1").arg(est.toLocaleDateString(Fmt.locale, "MMMM yyyy"))
                }
                visible: opacity > 0
                opacity: label !== "" && (list.moving || vbar.pressed || hideTimer.running) ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 150 } }
                z: 10
                parent: list
                radius: height / 2
                color: Theme.withAlpha(Theme.text, 0.82)
                implicitWidth: dateText.implicitWidth + 24
                implicitHeight: dateText.implicitHeight + 10
                x: list.width - width - 18
                // next to the middle of the scroll bar handle
                y: Math.max(4, Math.min(list.height - height - 4,
                                        (vbar.position + vbar.size / 2) * list.height - height / 2))
                Text {
                    id: dateText
                    anchors.centerIn: parent
                    text: scrollDate.label
                    font.pixelSize: Theme.callout; font.weight: Font.DemiBold; font.features: { "tnum": 1 }
                    color: Theme.canvas
                }
                Timer { id: hideTimer; interval: 700 }
            }

            function revealSelection() {
                const i = AppModel.streamItems.findIndex(x => x.type === "row" && x.booking.id === AppModel.selectedBookingID)
                if (i >= 0) list.positionViewAtIndex(i, ListView.Contain)
            }
            Connections {
                target: AppModel
                function onSidebarSelectionChanged() { list.pinnedTop = true; list.positionViewAtBeginning() }
                function onPeriodChanged() { list.pinnedTop = true; list.positionViewAtBeginning() }
                function onScopeChanged() { list.pinnedTop = true; list.positionViewAtBeginning() }
                // SelectionScroller: keep the selected booking visible.
                function onSelectedBookingIDChanged() {
                    if (AppModel.scrollOnSelect) Qt.callLater(list.revealSelection)
                }
                // click in the balance chart: that day's card to the top, its first booking selected
                function onScrollToDay(day) {
                    const i = AppModel.streamItems.findIndex(x => x.type === "header" && x.day.date === day)
                    if (i < 0) return
                    list.pinnedTop = false
                    list.positionViewAtIndex(i, ListView.Beginning)
                    const first = AppModel.streamItems[i + 1]
                    if (first && first.type === "row") AppModel.selectBooking(first.booking.id, false, false)
                }
            }
        }
    }

    // DayCardSegment: one card per day, split into header + rows.
    component DayHeader: Rectangle {
        property var day
        height: 40
        color: Theme.card
        radius: 12
        border.color: Theme.border
        Rectangle { anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right; height: parent.height / 2; color: Theme.card
                    Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.border }
                    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.border } }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16
            Text { text: day ? Fmt.dayHeader(day.date) : ""; font.pixelSize: Theme.subheadline + 1; font.weight: Font.DemiBold; color: Theme.text; Layout.fillWidth: true }
            Text { text: day ? Fmt.signed(day.sum) : ""; font.pixelSize: Theme.subheadline + 1; font.features: { "tnum": 1 }; color: day && day.sum > 0 ? Theme.inflow : Theme.secondary }
        }
    }

    component DayCardRow: Item {
        id: dc
        property var booking
        property bool isLast
        readonly property bool selected: booking !== null && !!AppModel.selectedBookingIDs[booking.id]
        height: 54 + (isLast ? 0 : 0)

        // background: rounded only at the bottom of the day's last row
        Rectangle {
            anchors.fill: parent
            color: Theme.card
            radius: dc.isLast ? 12 : 0
            border.color: Theme.border
            Rectangle { visible: dc.isLast; anchors.top: parent.top; width: parent.width; height: 12; color: Theme.card
                        Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.border }
                        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.border } }
            Rectangle { visible: !dc.isLast; anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
                        anchors.topMargin: 0; anchors.bottomMargin: 0; anchors.leftMargin: 1; anchors.rightMargin: 1; color: Theme.card }
        }
        // not booked yet ("vorgemerkt"): light diagonal hatching under the row, as on the Mac
        Canvas {
            id: pendingHatch
            visible: dc.booking !== null && !!dc.booking.is_pending
            anchors.fill: parent; anchors.margins: 1
            anchors.bottomMargin: dc.isLast ? 4 : 0
            readonly property color lineColor: Theme.withAlpha(Theme.secondary, 0.14)
            onLineColorChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onVisibleChanged: if (visible) requestPaint()
            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                // the day's last row is rounded at the bottom: keep the lines inside
                const r = dc.isLast ? 10 : 0
                ctx.beginPath()
                ctx.moveTo(0, 0)
                ctx.lineTo(width, 0)
                ctx.lineTo(width, height - r)
                ctx.arcTo(width, height, width - r, height, r)
                ctx.lineTo(r, height)
                ctx.arcTo(0, height, 0, height - r, r)
                ctx.closePath()
                ctx.clip()
                ctx.strokeStyle = lineColor
                ctx.lineWidth = 1
                ctx.beginPath()
                for (let x = -height; x < width; x += 7) {
                    ctx.moveTo(x, height)
                    ctx.lineTo(x + height, 0)
                }
                ctx.stroke()
            }
        }
        Rectangle {
            anchors.fill: parent; anchors.margins: 1
            anchors.bottomMargin: dc.isLast ? 4 : 0
            radius: dc.isLast ? 10 : 0
            color: dc.selected ? Theme.selection : "transparent"
        }
        BookingRow { anchors.fill: parent; booking: dc.booking }
        DropArea {
            id: rowDrop
            anchors.fill: parent
            onDropped: d => { if (d.hasUrls) { AppModel.selectedBookingID = dc.booking.id; AppModel.attach(d.urls, dc.booking) } }
        }
        Rectangle { anchors.fill: parent; visible: rowDrop.containsDrag; color: "transparent"; border.color: Theme.accent; border.width: 2; radius: 6 }
        Rectangle { visible: !dc.isLast; x: 64; width: parent.width - 65; height: 1; anchors.bottom: parent.bottom; color: Theme.withAlpha(Theme.border, 0.7) }
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: m => {
                stream.forceActiveFocus()
                // the context menu acts on its own row and leaves the selection alone
                if (m.button === Qt.RightButton) { stream.openRowMenu(dc.booking, dc, m.x, m.y); return }
                AppModel.selectBooking(dc.booking.id, m.modifiers & Qt.ControlModifier, m.modifiers & Qt.ShiftModifier)
            }
            onDoubleClicked: m => { if (m.button === Qt.LeftButton) AppModel.editNote(dc.booking) }
        }
    }

    // One context menu for the whole list (BookingListView.swift .contextMenu): built once,
    // shown for the row that was right-clicked. A menu per row was rebuilt with every list
    // reload and made switching accounts slow with many bookings.
    property var menuBooking: null
    function openRowMenu(booking, item, x, y) {
        menuBooking = booking
        rowMenu.popup(item, x, y)
    }
    AppMenu {
        id: rowMenu
        // CategorizeMenuButton
        AppMenuItem {
            readonly property bool many: AppModel.isMultiSelection && stream.menuBooking !== null && !!AppModel.selectedBookingIDs[stream.menuBooking.id]
            text: many ? qsTr("%1 Buchungen kategorisieren …").arg(Object.keys(AppModel.selectedBookingIDs).length) : qsTr("Kategorisieren …")
            icon.name: SF.icon("tag")
            onTriggered: {
                if (!AppModel.selectedBookingIDs[stream.menuBooking.id]) AppModel.selectedBookingID = stream.menuBooking.id
                AppModel.showCategorizer = true
            }
        }
        AppMenuItem { text: qsTr("Regel für diesen Händler erstellen …"); icon.name: SF.icon("wand.and.stars"); onTriggered: AppModel.openRuleEditor(stream.menuBooking) }
        AppMenuItem { text: qsTr("Notiz bearbeiten …"); icon.name: SF.icon("note.text"); onTriggered: AppModel.editNote(stream.menuBooking) }
        AppMenuItem { text: qsTr("Umsatz aufteilen (Splitbuchung) …"); icon.name: SF.icon("arrow.triangle.branch"); onTriggered: AppModel.splitBooking = stream.menuBooking }
        // LoanAssignMenu(hidesWhenUnavailable: true): left out for loan bookings
        Instantiator {
            model: stream.menuBooking !== null && stream.menuBooking.account_kind !== "Loan" ? 1 : 0
            delegate: LoanAssignMenu { booking: stream.menuBooking }
            onObjectAdded: (index, menu) => {
                let at = 0
                for (let i = 0; i < rowMenu.count; ++i)
                    if (rowMenu.itemAt(i) && rowMenu.itemAt(i).text === qsTr("Umsatz aufteilen (Splitbuchung) …")) at = i + 1
                rowMenu.insertMenu(at, menu)
            }
            onObjectRemoved: (index, menu) => rowMenu.removeMenu(menu)
        }
        AppMenuSeparator {}
        AppMenuItem {
            readonly property string who: stream.menuBooking ? (stream.menuBooking.counterparty || stream.menuBooking.merchant_name) : ""
            text: qsTr("Nach „%1“ suchen").arg(who); icon.name: SF.icon("magnifyingglass"); enabled: who !== ""
            onTriggered: AppModel.searchText = who
        }
        AppMenuItem { text: qsTr("Neue Überweisung aus Buchung …"); icon.name: SF.icon("paperplane"); enabled: AppModel.canTransfer
                   onTriggered: AppModel.openTransferFrom(stream.menuBooking) }
        AppMenuItem { text: qsTr("Umsatz kopieren"); icon.name: SF.icon("doc.on.doc")
                   onTriggered: AppModel.copyToClipboard(AppModel.clipboardLine(stream.menuBooking)) }
        AppMenuSeparator {}
        AppMenuItem { text: stream.menuBooking && stream.menuBooking.checked ? qsTr("Als neu markieren") : qsTr("Als geprüft markieren"); icon.name: SF.icon("checkmark.circle")
                   onTriggered: AppModel.setChecked(!stream.menuBooking.checked, stream.menuBooking) }
    }

    // BookingListView.swift › BookingRow
    component BookingRow: Item {
        id: br
        property var booking
        RowLayout {
            visible: br.booking !== null
            anchors.fill: parent
            anchors.leftMargin: 14; anchors.rightMargin: 14; anchors.topMargin: 5; anchors.bottomMargin: 5
            spacing: 12
            MerchantSignet {
                merchant: br.booking ? br.booking.merchant : null
                categorySymbol: br.booking ? br.booking.category_symbol : ""
                showNewDot: br.booking ? !br.booking.checked : false
                opacity: br.booking && br.booking.is_pending ? 0.7 : 1
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                RowLayout {
                    spacing: 5
                    Layout.fillWidth: true
                    Text {
                        text: br.booking ? (br.booking.merchant.name || br.booking.booking_text) : ""
                        font.pixelSize: Theme.body + 1; font.weight: Font.DemiBold; color: Theme.text
                        elide: Text.ElideRight; Layout.fillWidth: true; Layout.maximumWidth: implicitWidth
                    }
                    SFIcon { visible: br.booking && br.booking.document_count > 0; symbol: "doc.text.fill"; size: 11; color: Theme.withAlpha(Theme.accent, 0.8) }
                    SFIcon { visible: br.booking !== null && AppModel.recurringSeries(br.booking) !== null; symbol: "repeat"; size: 11 }
                    Item { Layout.fillWidth: true; Layout.preferredWidth: 0 }
                }
                RowLayout {
                    spacing: 6
                    Layout.fillWidth: true
                    clip: true
                    AccountChip {
                        visible: AppModel.showsAccountMarkers && br.booking !== null
                        label: br.booking ? AppModel.accountShortLabel(br.booking.account_id) : ""
                        tint: br.booking ? AppModel.accountColor(br.booking.account_id) : Theme.tertiary
                        symbol: br.booking ? AppModel.accountSymbol(br.booking.account_id) : ""
                    }
                    BookingCategoryLabel { booking: br.booking }
                    Text {
                        visible: br.booking && br.booking.payment_method !== ""
                        text: br.booking ? "· " + br.booking.payment_method : ""
                        font.pixelSize: Theme.callout + 1; color: Theme.secondary; elide: Text.ElideRight; Layout.fillWidth: true
                    }
                    Item { Layout.fillWidth: true }
                }
            }
            SFIcon { visible: br.booking && br.booking.checked; symbol: "checkmark"; size: 11; color: Theme.tertiary }
            SFIcon { visible: br.booking && br.booking.is_pending; symbol: "clock"; size: 11; color: Theme.tertiary }
            AmountLabel { cents: br.booking ? br.booking.amount_cents : 0 }
        }
    }

    component AccountChip: Rectangle {
        property string label
        property color tint
        property string symbol
        implicitWidth: ac.implicitWidth + 12; implicitHeight: ac.implicitHeight + 3
        radius: height / 2
        color: Theme.withAlpha(tint, 0.12)
        RowLayout { id: ac; anchors.centerIn: parent; spacing: 4
            SFIcon { symbol: parent.parent.symbol; size: 11; color: parent.parent.tint }
            Text { text: parent.parent.label; font.pixelSize: Theme.subheadline + 1; font.weight: Font.Medium; color: parent.parent.tint } }
    }

    component BookingCategoryLabel: RowLayout {
        property var booking
        readonly property bool none: !booking || booking.category_name === ""
        readonly property color tint: none ? Theme.warning : Theme.readable(booking.category_color_hex)
        spacing: 3
        SFIcon { symbol: none ? "questionmark.folder" : (booking.category_symbol || "tag.fill"); size: 11; color: parent.tint }
        Text { text: none ? qsTr("Ohne Kategorie") : booking.category_name; font.pixelSize: Theme.callout + 1; font.weight: Font.Medium; color: parent.tint; elide: Text.ElideRight }
    }

    // Onboarding.swift › EmptyVaultCard: the personal vault has no accounts yet.
    component EmptyVaultCard: Card {
        ColumnLayout {
            width: parent.width; spacing: 14
            RowLayout {
                spacing: 12
                Image { source: "qrc:/qt/qml/GiroCrab/assets/app-icon.png"; sourceSize.width: 56; sourceSize.height: 56 }
                Text { text: qsTr("Willkommen bei GiroCrab"); font.pixelSize: Theme.title3 + 2; font.weight: Font.DemiBold; color: Theme.text }
            }
            Text { text: qsTr("Ihr Tresor ist eingerichtet, enthält aber noch keine Konten. So geht es weiter:")
                   font.pixelSize: Theme.callout + 1; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            Repeater {
                model: [qsTr("Bank wählen und Anmeldenamen eingeben"),
                        qsTr("Fehlende Angaben ergänzen (z. B. FinTS-Produkt-ID, API-Schlüssel) – das Formular öffnet sich automatisch"),
                        qsTr("PIN eingeben und in der Banking-App freigeben")]
                RowLayout {
                    required property string modelData
                    required property int index
                    Layout.fillWidth: true; spacing: 10
                    Rectangle {
                        Layout.alignment: Qt.AlignTop
                        implicitWidth: 20; implicitHeight: 20; radius: 10; color: Theme.selection
                        Text { anchors.centerIn: parent; text: index + 1; font.pixelSize: Theme.caption; font.weight: Font.Bold; color: Theme.accent }
                    }
                    Text { text: modelData; font.pixelSize: Theme.callout + 1; color: Theme.text; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                }
            }
            Button { text: qsTr("Bank suchen und hinzufügen …"); icon.name: SF.icon("magnifyingglass"); highlighted: true
                     Layout.fillWidth: true; implicitHeight: 34; onClicked: AppModel.showAddBank = true }
            Button { text: qsTr("Vorhandene Daten importieren …"); icon.name: SF.icon("square.and.arrow.down.on.square"); highlighted: true
                     Layout.fillWidth: true; implicitHeight: 34; onClicked: AppModel.openMoneyMoneyImport() }
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
            RowLayout {
                Layout.fillWidth: true; spacing: 8
                Text { text: qsTr("Erst einmal ansehen?"); font.pixelSize: Theme.caption; color: Theme.secondary }
                Button { flat: true; text: qsTr("Demo-Daten && Demo-Banken laden (Kennung: demo / PIN: 12345)"); font.pixelSize: Theme.caption
                         palette.buttonText: Theme.accent; onClicked: AppModel.showDemo() }
                Item { Layout.fillWidth: true }
            }
        }
    }

    // Onboarding.swift › DemoBanner
    component DemoBanner: Rectangle {
        implicitHeight: db.implicitHeight + 24
        radius: 12
        color: Theme.selection
        border.color: Theme.withAlpha(Theme.accent, 0.18)
        RowLayout {
            id: db
            anchors.fill: parent; anchors.margins: 12
            spacing: 12
            SFIcon { symbol: "theatermasks.fill"; size: 18; color: Theme.accent; Layout.alignment: Qt.AlignTop }
            ColumnLayout {
                spacing: 2
                Layout.fillWidth: true
                Text { text: qsTr("Demo-Daten"); font.pixelSize: Theme.subheadline + 1; font.weight: Font.DemiBold; color: Theme.text }
                Text {
                    text: AppModel.hasOwnVault
                        ? qsTr("Ihr eigener Tresor ist noch leer. Hier sehen Sie erfundene Buchungen aller 7 Banken.")
                        : qsTr("Erfundene Buchungen aller 7 Banken – keine echte Bank verbunden. Sobald echte Daten da sind, schützt Face ID bzw. Ihr Gerätecode den Tresor automatisch; hier können Sie den Sperrbildschirm testen.")
                    font.pixelSize: Theme.caption; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true
                }
            }
            Button { text: AppModel.hasOwnVault || AppModel.vaultMayHoldRealData() ? qsTr("Zurück zum eigenen Tresor") : qsTr("Eigenes Konto anlegen")
                     Layout.alignment: Qt.AlignTop; onClicked: AppModel.showOwnVault() }
            Button { visible: !AppModel.hasOwnVault && !AppModel.vaultMayHoldRealData(); text: qsTr("Sperrbildschirm testen")
                     Layout.alignment: Qt.AlignTop; onClicked: AppModel.previewLock() }
        }
    }
}
