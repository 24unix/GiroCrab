import QtQuick

// MerchantSignet.swift › SymbolTile
Rectangle {
    property string symbol
    property color tint: Theme.secondary
    property int size: 22
    width: size; height: size
    radius: size * 0.28
    color: Theme.withAlpha(tint, 0.12)
    SFIcon { anchors.centerIn: parent; symbol: parent.symbol; size: parent.size * 0.6; color: parent.tint }
}
