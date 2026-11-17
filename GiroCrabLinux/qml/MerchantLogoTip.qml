import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// MerchantLogoTip.swift › MerchantLogoTipView: instead of asking at first start, online
// merchant logos are offered once, in context, at the top of the booking stream (TipView
// look: symbol, title, message, close button, the actions below a divider). Shown while
// `MerchantLogos.tipEligible`; an action or the close button answers it for good.
Rectangle {
    id: tip
    visible: MerchantLogos.tipEligible
    implicitHeight: visible ? col.implicitHeight + 24 : 0
    radius: 12
    color: Theme.card
    border.color: Theme.border; border.width: 1

    ColumnLayout {
        id: col
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.margins: 12
        spacing: 10
        RowLayout {
            spacing: 12
            SFIcon { symbol: "photo.on.rectangle"; size: 28; color: Theme.accent; Layout.alignment: Qt.AlignTop }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: qsTr("Händler-Logos anzeigen?")
                       font.pixelSize: Theme.body; font.weight: Font.DemiBold; color: Theme.text }
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap
                       text: qsTr("GiroCrab kann Logos von DuckDuckGo laden. Übertragen wird nur die Händler-Domain (z. B. lidl.de) – keine Beträge, keine Kontodaten.")
                       font.pixelSize: Theme.callout + 1; color: Theme.secondary }
            }
            // TipView's close button: dismissed for good (TipKit `.tipClosed`)
            IconButton {
                symbol: "xmark"; symbolSize: 12
                Layout.alignment: Qt.AlignTop
                ToolTip.text: qsTr("Schließen")
                onClicked: MerchantLogos.tipDone = true
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
        TipAction {
            text: qsTr("Mit DuckDuckGo laden")
            onClicked: { MerchantLogos.setProvider("duckduckgo"); MerchantLogos.tipDone = true }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
        // opens the settings; the tip stays until a provider is chosen there
        TipAction { text: qsTr("Einstellungen …"); onClicked: AppModel.openSettings("general") }
    }

    component TipAction: Text {
        signal clicked()
        Layout.fillWidth: true
        font.pixelSize: Theme.body; color: Theme.accent
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
    }
}
