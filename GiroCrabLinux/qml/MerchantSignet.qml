import QtQuick
import QtQuick.Shapes

// MerchantSignet.swift › MerchantSignet: person initials, brand SVG (simple-icons),
// category symbol for unknown merchants, else the brand monogram.
Item {
    id: root
    property var merchant
    property string categorySymbol: ""
    property int size: 36
    property bool showNewDot: false
    width: size; height: size

    readonly property bool person: merchant && merchant.is_person
    readonly property bool hasSvg: merchant && merchant.svg_path !== ""
    readonly property bool useCategory: merchant && !merchant.known && categorySymbol !== "" && !hasSvg && !person
    readonly property color brand: merchant && merchant.color_hex ? merchant.color_hex : Theme.tertiary

    Rectangle {
        anchors.fill: parent
        radius: root.person ? width / 2 : root.size * 0.28
        color: root.person ? Theme.personFill
             : root.useCategory ? Theme.neutralTile
             : Theme.withAlpha(root.brand, root.hasSvg ? 0.09 : 0.10)
        border.width: root.person ? 0 : 1
        border.color: Theme.withAlpha(root.brand, 0.16)
    }
    Text {
        visible: root.person || (!root.hasSvg && !root.useCategory)
        anchors.centerIn: parent
        text: root.merchant ? root.merchant.monogram : ""
        font.pixelSize: root.size * (root.person ? 0.36 : (text.length > 2 ? 0.30 : 0.40))
        font.weight: root.person ? Font.DemiBold : Font.Bold
        color: root.person ? Theme.personText : Theme.readable(root.merchant ? root.merchant.color_hex : "")
    }
    SFIcon {
        visible: root.useCategory
        anchors.centerIn: parent
        symbol: root.categorySymbol
        size: root.size * 0.5
        color: Theme.secondary
    }
    Shape {
        visible: root.hasSvg && !root.person
        anchors.fill: parent
        anchors.margins: root.size * 0.2
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: Theme.readable(root.merchant ? root.merchant.color_hex : "")
            strokeWidth: -1
            fillRule: ShapePath.WindingFill // FillStyle(eoFill: false)
            scale: Qt.size((root.size * 0.6) / 24, (root.size * 0.6) / 24)
            PathSvg { path: root.hasSvg ? root.merchant.svg_path : "" }
        }
    }
    Rectangle {
        visible: root.showNewDot
        width: 8; height: 8; radius: 4
        color: Theme.accent
        border.color: Theme.card; border.width: 1.5
        x: parent.width - 6; y: -2
    }
}
