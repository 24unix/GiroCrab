import QtQuick

// MerchantSignet.swift › SymbolTile
Rectangle {
    property string symbol
    property color tint: Theme.secondary
    property int size: 22
    /// Drawn size: grows with the text size like on the Mac (#343).
    readonly property int px: Theme.scaled(size)
    width: px; height: px
    radius: px * 0.28
    color: Theme.withAlpha(tint, 0.12)
    SFIcon { anchors.centerIn: parent; symbol: parent.symbol; size: parent.px * 0.6; color: parent.tint }
}
