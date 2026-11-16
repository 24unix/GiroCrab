import QtQuick

// TangibleAssetsUI.swift › AssetSymbolTile: the 36 pt tile of a position row, also the
// editor's icon button.
Rectangle {
    property string symbol
    property real size: 36
    implicitWidth: size; implicitHeight: size
    radius: size * 0.28
    color: Theme.withAlpha(Theme.accent, 0.12)
    AssetSymbolImage { anchors.centerIn: parent; symbol: parent.symbol; size: parent.size * 0.42 }
}
