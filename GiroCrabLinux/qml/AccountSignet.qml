import QtQuick

// MerchantSignet.swift › AccountSignet
Rectangle {
    property var account
    property int size: 22
    property color tintColor: account && account.kind === "Loan" ? Theme.loan : Theme.secondary
    property bool onSelection: false
    readonly property color tint: onSelection ? Theme.text : tintColor
    width: size; height: size
    radius: size * 0.28
    color: Theme.withAlpha(tint, 0.12)
    SFIcon { anchors.centerIn: parent; symbol: account ? account.sf_symbol : ""; size: parent.size * 0.6; color: parent.tint }
}
