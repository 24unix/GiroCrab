import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// BalanceHeaderView.swift › StreamHeaderCard: title, balance, chart, KPI tiles, filter row.
Card {
    id: card
    readonly property var account: AppModel.selectedAccount
    readonly property bool isDepot: account !== null && (account.kind === "Brokerage" || account.name.toLowerCase().indexOf("depot") >= 0)
    /// AccountCopyMenu.bankDetails: name, IBAN and bank as a block for an e-mail.
    function bankDetails(bic) {
        const a = account
        const bank = bic ? (a.bank_name ? "BIC: " + bic + " (" + a.bank_name + ")" : "BIC: " + bic) : (a.bank_name ? "Bank: " + a.bank_name : "")
        return [a.owner ? "Name: " + a.owner : "", "IBAN: " + Fmt.iban(a.iban), bank].filter(s => s).join("\n")
    }
    readonly property int openFixed: AppModel.recurringMonth ? AppModel.recurringMonth.items.filter(i => !i.booked && i.amount_cents < 0).length : 0

    ColumnLayout {
        width: parent.width
        spacing: 9
        RowLayout {
            Layout.fillWidth: true
            ColumnLayout {
                spacing: 3
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                Text { text: AppModel.title; font.pixelSize: Theme.title2 + 3; font.weight: Font.DemiBold; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                Text {
                    text: card.account ? [card.account.bank_name, Fmt.iban(card.account.iban)].filter(s => s).join(" · ") : AppModel.lastSyncText
                    font.pixelSize: Theme.caption; color: Theme.secondary
                }
                // AccountCopyMenu on the title
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    enabled: card.account !== null
                    onTapped: { accountCopyMenu.bic = AppModel.run(() => AppModel.core("bic_for_iban", { iban: card.account.iban })) || ""; accountCopyMenu.popup() }
                }
                AppMenu {
                    id: accountCopyMenu
                    property string bic: ""
                    AppMenuSeparator { contentItem: Text { text: qsTr("In Zwischenablage kopieren"); font.pixelSize: Theme.caption; color: Theme.secondary; leftPadding: 8 } }
                    AppMenuItem { text: qsTr("Bankverbindung"); visible: card.account !== null && card.account.iban !== ""; height: visible ? implicitHeight : 0
                               onTriggered: AppModel.copyToClipboard(card.bankDetails(accountCopyMenu.bic)) }
                    AppMenuItem { text: qsTr("IBAN"); visible: card.account !== null && card.account.iban !== ""; height: visible ? implicitHeight : 0
                               onTriggered: AppModel.copyToClipboard(card.account.iban) }
                    AppMenuItem { text: qsTr("BIC"); visible: accountCopyMenu.bic !== ""; height: visible ? implicitHeight : 0
                               onTriggered: AppModel.copyToClipboard(accountCopyMenu.bic) }
                    AppMenuItem { text: qsTr("Kontostand"); onTriggered: AppModel.copyToClipboard(Fmt.clipboard(card.account.balance_cents)) }
                }
            }
            ColumnLayout {
                visible: AppModel.headerBalance !== null
                spacing: 2
                Layout.alignment: Qt.AlignTop
                // "<Label> kopieren" on the balance
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onTapped: balanceCopyMenu.popup()
                }
                AppMenu {
                    id: balanceCopyMenu
                    AppMenuItem { text: AppModel.headerBalance ? qsTr("%1 kopieren").arg(AppModel.headerBalance.label) : ""; icon.name: SF.icon("doc.on.doc")
                               onTriggered: AppModel.copyToClipboard(Fmt.clipboard(AppModel.headerBalance.cents)) }
                }
                Text {
                    Layout.alignment: Qt.AlignRight
                    text: AppModel.headerBalance ? Fmt.money(AppModel.headerBalance.cents) : ""
                    font.pixelSize: Theme.largeTitle + 4; font.weight: Font.DemiBold; font.features: { "tnum": 1 }
                    color: card.account && card.account.kind === "Loan" ? Theme.loan : Theme.text
                }
                Text { Layout.alignment: Qt.AlignRight; text: AppModel.headerBalance ? AppModel.headerBalance.label : ""; font.pixelSize: Theme.caption; color: Theme.secondary }
            }
        }

        LoanProgressCard {
            visible: card.account !== null && card.account.kind === "Loan"
            Layout.fillWidth: true
            account: card.account
            compact: true
        }
        HoldingsCard {
            visible: card.isDepot
            Layout.fillWidth: true
            account: card.isDepot ? card.account : null
        }

        BalanceChart {
            visible: !card.isDepot && AppModel.showStatistics && AppModel.scope !== "Investments"
            Layout.fillWidth: true
            Layout.preferredHeight: 72
            points: AppModel.history
            onSelectDay: day => AppModel.jumpToDay(day)
        }

        RowLayout {
            visible: !card.isDepot
            Layout.fillWidth: true
            spacing: 10
            KPI { Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: 1
                  title: qsTr("Konsumausgaben"); subtitle: AppModel.periodSubtitle; value: Fmt.money(-AppModel.consumptionThisMonth); tint: Theme.outflow }
            KPI { Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: 1
                  title: qsTr("Investiert"); subtitle: qsTr("Sparpläne & Perks"); value: Fmt.money(AppModel.investedThisMonth); tint: Theme.invest }
            KPI { Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: 1
                  title: qsTr("Einnahmen"); subtitle: AppModel.periodSubtitle; value: Fmt.money(AppModel.incomeThisMonth); tint: Theme.inflow }
            KPI { Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: 1
                  title: qsTr("Fixkosten offen"); subtitle: qsTr("Diesen Monat · %1 offen").arg(card.openFixed)
                  value: Fmt.money(-(AppModel.recurringMonth ? AppModel.recurringMonth.open_expense_cents : 0)); tint: Theme.outflow
                  disclosure: true
                  onClicked: AppModel.showRecurringSheet = true
                  ToolTip.visible: fixedHover.hovered; ToolTip.delay: 600; ToolTip.text: qsTr("Wiederkehrende Buchungen anzeigen")
                  HoverHandler { id: fixedHover } }
        }

        // filterRow
        RowLayout {
            visible: !card.isDepot
            Layout.fillWidth: true
            spacing: 12
            MenuLabel {
                symbol: "calendar"; text: AppModel.periodTitle
                onClicked: periodMenu.popup()
                AppMenu {
                    id: periodMenu
                    Instantiator {
                        model: AppModel.periods
                        AppMenuItem { required property var modelData; text: modelData.title; checkable: true
                                   checked: AppModel.period === modelData.id; onTriggered: AppModel.period = modelData.id }
                        onObjectAdded: (index, object) => periodMenu.insertItem(index, object)
                        onObjectRemoved: (index, object) => periodMenu.removeItem(object)
                    }
                    AppMenuSeparator {}
                    // The checkmark shows while the custom range is active (PlanningUI.swift › CustomPeriodForm).
                    AppMenuItem {
                        text: AppModel.period === "custom" ? qsTr("Benutzerdefiniert: %1 …").arg(AppModel.periodTitle) : qsTr("Benutzerdefiniert …")
                        checkable: true; checked: AppModel.period === "custom"
                        onTriggered: { checked = Qt.binding(() => AppModel.period === "custom"); AppModel.showCustomPeriod = true }
                    }
                }
            }
            MenuLabel {
                symbol: AppModel.statusFilter === "all" && AppModel.directionFilter === "All" ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill"
                text: AppModel.filterTitle
                onClicked: filterMenu.popup()
                AppMenu {
                    id: filterMenu
                    AppMenuSeparator { contentItem: Text { text: qsTr("Status"); font.pixelSize: Theme.caption; color: Theme.secondary; leftPadding: 8 } }
                    Repeater {
                        model: AppModel.statusFilters
                        AppMenuItem { required property var modelData; text: modelData.title; checkable: true
                                   checked: AppModel.statusFilter === modelData.id; onTriggered: AppModel.statusFilter = modelData.id }
                    }
                    AppMenuSeparator { contentItem: Text { text: qsTr("Buchungsart"); font.pixelSize: Theme.caption; color: Theme.secondary; leftPadding: 8 } }
                    Repeater {
                        model: AppModel.directions
                        AppMenuItem { required property var modelData; text: modelData.title; checkable: true
                                   checked: AppModel.directionFilter === modelData.id; onTriggered: AppModel.directionFilter = modelData.id }
                    }
                }
            }
            MenuLabel { visible: card.account !== null; symbol: "doc.text"; text: qsTr("Dokumente"); chevron: false
                        onClicked: AppModel.openAccountDocuments(card.account) }
            Item { Layout.fillWidth: true }
            Text { text: qsTr("%1 Buchungen").arg(AppModel.bookingCountLabel); font.pixelSize: Theme.caption; color: Theme.secondary }
        }
        // depotRow
        RowLayout {
            visible: card.isDepot
            Layout.fillWidth: true
            IconButton { text: qsTr("Dokumente"); symbol: "doc.text"; symbolSize: 12; font.pixelSize: Theme.caption
                         onClicked: AppModel.openAccountDocuments(card.account) }
            Item { Layout.fillWidth: true }
            Text { text: qsTr("Depot: Positionen statt Buchungen"); font.pixelSize: Theme.caption; color: Theme.secondary }
        }
    }

    component MenuLabel: Item {
        id: ml
        property string symbol
        property string text
        property bool chevron: true
        signal clicked()
        implicitWidth: r.implicitWidth; implicitHeight: 22
        RowLayout {
            id: r
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5
            SFIcon { symbol: ml.symbol; size: 14; color: Theme.text }
            Text { text: ml.text; font.pixelSize: Theme.body; color: Theme.text }
            SFIcon { visible: ml.chevron; symbol: "chevron.down"; size: 9; color: Theme.text }
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: ml.clicked() }
    }
}
