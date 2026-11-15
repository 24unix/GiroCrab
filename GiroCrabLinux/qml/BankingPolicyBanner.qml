import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// BankingPolicyUI.swift › BankingPolicyBanner: red banner while banks are blocked.
Item {
    id: banner
    readonly property var gate: AppModel.bankingPolicy.gate
    visible: gate !== null && gate !== undefined
    implicitHeight: visible ? box.implicitHeight + 16 : 0
    Rectangle {
        id: box
        anchors.horizontalCenter: parent.horizontalCenter
        y: 8
        width: Math.min(parent.width - 40, 720)
        implicitHeight: row.implicitHeight + 24
        radius: 12
        color: Qt.rgba(1, 0, 0, 0.08)
        border.color: Qt.rgba(1, 0, 0, 0.35)
        RowLayout {
            id: row
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 12
            spacing: 10
            SFIcon { symbol: "exclamationmark.shield.fill"; size: 18; color: "red"; Layout.alignment: Qt.AlignTop }
            ColumnLayout {
                spacing: 8; Layout.fillWidth: true
                Text { text: banner.gate ? (AppModel.bankingPolicy.title || AppModel.bankingGateTitle(banner.gate)) : ""; font.pixelSize: Theme.body + 1; font.weight: Font.DemiBold; color: Theme.text }
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout + 1; color: Theme.secondary
                       text: AppModel.bankingPolicy.detail || "" }
                RowLayout {
                    spacing: 8
                    Button { visible: banner.gate && banner.gate.reason === "checkUnavailable"; text: qsTr("Erneut prüfen"); highlighted: true
                             enabled: !AppModel.bankingPolicyChecking; onClicked: AppModel.withFreshBankingPolicy(null, true) }
                    BusyIndicator { visible: AppModel.bankingPolicyChecking; running: visible; implicitWidth: 18; implicitHeight: 18 }
                    Button { visible: banner.gate && banner.gate.reason !== "checkUnavailable" && banner.gate.update_available; text: qsTr("Jetzt aktualisieren"); highlighted: true
                             onClicked: Qt.openUrlExternally("https://github.com/GiroCrab/GiroCrab/releases/latest") }
                    Button { visible: banner.gate && !!banner.gate.advisory; text: qsTr("Details"); onClicked: Qt.openUrlExternally(banner.gate.advisory) }
                }
            }
        }
    }
}
