import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Onboarding.swift › DemoHintBanner: login `demo`, PIN `12345`, TAN `123456`.
Rectangle {
    id: banner
    property bool credentials: true
    property string buttonTitle: ""
    signal fill()
    implicitHeight: col.implicitHeight + 20
    radius: 10
    color: Theme.withAlpha(Theme.accent, 0.12)
    ColumnLayout {
        id: col
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 10
        spacing: 6
        RowLayout {
            spacing: 6
            SFIcon { symbol: "play.circle.fill"; size: 15; color: Theme.accent }
            Text {
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                text: banner.credentials ? qsTr("Test- & Demo-Zugang (ohne echtes Bankkonto): Kennung demo · PIN 12345")
                                         : qsTr("Demo-Modus: PIN 12345 · TAN 123456")
                font.pixelSize: Theme.callout + 1; font.weight: Font.DemiBold; color: Theme.text
            }
        }
        Button {
            text: banner.buttonTitle || (banner.credentials ? qsTr("Demo-Zugangsdaten ausfüllen") : qsTr("Demo-Werte einfügen"))
            onClicked: banner.fill()
        }
    }
}
