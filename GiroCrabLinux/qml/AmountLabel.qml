import QtQuick

// BookingListView.swift › AmountLabel: inflows in a green capsule.
Rectangle {
    property real cents: 0
    readonly property bool inflow: cents > 0
    implicitWidth: label.implicitWidth + (inflow ? 16 : 0)
    implicitHeight: label.implicitHeight + (inflow ? 6 : 0)
    radius: height / 2
    color: inflow ? Theme.inflowBadge : "transparent"
    Text {
        id: label
        anchors.centerIn: parent
        text: parent.inflow ? Fmt.signed(parent.cents) : Fmt.money(parent.cents)
        font.pixelSize: Theme.body
        font.weight: parent.inflow ? Font.DemiBold : Font.Medium
        font.features: { "tnum": 1 }
        color: parent.inflow ? Theme.inflow : Theme.outflow
    }
}
