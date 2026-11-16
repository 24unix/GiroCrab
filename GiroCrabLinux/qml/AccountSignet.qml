import QtQuick

// MerchantSignet.swift › AccountSignet
Rectangle {
    property var account
    property int size: 22
    property color tintColor: account && account.kind === "Loan" ? Theme.loan : Theme.secondary
    property bool onSelection: false
    readonly property color tint: onSelection ? Theme.text : tintColor
    /// Drawn size: grows with the text size like on the Mac (#343).
    readonly property int px: Theme.scaled(size)
    width: px; height: px
    radius: px * 0.28
    color: Theme.withAlpha(tint, 0.12)
    SFIcon { anchors.centerIn: parent; symbol: account ? account.sf_symbol : ""; size: parent.px * 0.6; color: parent.tint }
}
