import QtQuick

// SidebarView.swift › NewCountBadge: small bubble with the number of new bookings,
// next to an account's name. Hidden at 0, "999+" above 999.
Rectangle {
    id: badge
    property int count: 0
    property bool onSelection: false
    readonly property string label: count <= 0 ? "" : count > 999 ? "999+" : String(count)
    visible: label !== ""
    implicitWidth: t.implicitWidth + 10
    implicitHeight: t.implicitHeight + 2
    radius: height / 2
    color: Theme.withAlpha(Theme.accent, onSelection ? 0.35 : 0.18)
    border.width: 1
    border.color: onSelection ? Theme.text : Theme.accent
    Accessible.name: qsTr("%1 neue Buchungen").arg(count)
    Text {
        id: t
        anchors.centerIn: parent
        text: badge.label
        font.pixelSize: Theme.caption2; font.weight: Font.DemiBold; font.features: { "tnum": 1 }
        color: badge.onSelection ? Theme.text : Theme.accent
    }
}
