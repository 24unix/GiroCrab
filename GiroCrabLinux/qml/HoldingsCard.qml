import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// BalanceHeaderView.swift › HoldingsCard: positions of a depot account.
ColumnLayout {
    id: hc
    property var account
    property var holdings: []
    spacing: 6
    function reload() { holdings = account ? AppModel.holdings(account.id) : [] }
    onAccountChanged: reload()
    Connections { target: AppModel; function onGroupsChanged() { hc.reload() } }

    /// HoldingsCard.calculatedGain: cost = quantity × purchase price.
    function gain(h) {
        if (!(h.quantity > 0) || h.purchase_price_cents <= 0 || h.value_cents < 0) return null
        const cost = Math.round(h.quantity * h.purchase_price_cents)
        if (!(cost >= 1)) return null
        const g = h.value_cents - cost
        return { cents: g, percent: g / cost * 100 }
    }
    function qty(q) { return Number(q).toLocaleString(Qt.locale(), "f", 4).replace(/[.,]?0+$/, "") }
    function line(h) {
        const id = h.isin || h.wkn
        return [h.name, id, qty(h.quantity) + " × " + Fmt.money(h.current_price_cents), Fmt.money(h.value_cents)].filter(x => x).join(" · ")
    }

    Text { visible: hc.holdings.length > 0; text: qsTr("Positionen"); font.pixelSize: Theme.caption; font.weight: Font.DemiBold; color: Theme.secondary }
    Repeater {
        model: hc.holdings
        RowLayout {
            required property var modelData
            readonly property var g: hc.gain(modelData)
            Layout.fillWidth: true
            ColumnLayout { spacing: 1; Layout.fillWidth: true
                Text { text: modelData.name || modelData.isin || modelData.wkn; font.pixelSize: Theme.callout + 1; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                Text { text: hc.qty(modelData.quantity) + " × " + Fmt.money(modelData.current_price_cents) + " · " + (modelData.isin || modelData.wkn)
                       font.pixelSize: Theme.caption2; color: Theme.secondary; elide: Text.ElideRight; Layout.fillWidth: true } }
            ColumnLayout { spacing: 1
                Text { Layout.alignment: Qt.AlignRight; text: Fmt.money(modelData.value_cents); font.pixelSize: Theme.callout + 1; font.features: { "tnum": 1 }; color: Theme.text }
                Text { visible: parent.parent.g !== null; Layout.alignment: Qt.AlignRight; font.pixelSize: Theme.caption2; font.features: { "tnum": 1 }
                       readonly property var g: parent.parent.g
                       text: g ? qsTr("GuV (berechnet): %1 (%2 %)").arg(Fmt.money(g.cents)).arg(Number(g.percent).toLocaleString(Qt.locale(), "f", 2)) : ""
                       color: g && g.cents < 0 ? "red" : "green" } }
            TapHandler { acceptedButtons: Qt.RightButton; onTapped: menu.popup() }
            AppMenu { id: menu
                AppMenuItem { text: qsTr("Position kopieren"); onTriggered: AppModel.copyToClipboard(hc.line(modelData)) }
                AppMenuItem { text: qsTr("Alle Positionen kopieren"); onTriggered: AppModel.copyToClipboard(hc.holdings.map(hc.line).join("\n")) } }
        }
    }
}
