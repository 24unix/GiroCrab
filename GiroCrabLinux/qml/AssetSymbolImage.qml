import QtQuick
import org.kde.kirigami as Kirigami

// TangibleAssetsUI.swift › AssetSymbolImage: an asset icon – the nearest Breeze icon for the
// SF Symbol, or an own drawing (gem, necklace; Breeze has no diamond either, so
// "diamond.fill" is the gem outline without facets).
Item {
    id: img
    property string symbol
    /// Point size, like the font size of an SF Symbol.
    property real size: 16
    property color color: Theme.accent
    readonly property bool drawn: symbol === AssetSymbols.gem || symbol === AssetSymbols.necklace || symbol === "diamond.fill" || symbol === "diamond"
    implicitWidth: drawn ? size * 1.15 : size
    implicitHeight: drawn ? size * 1.15 * (symbol === AssetSymbols.necklace ? 1 : 0.86) : size

    Kirigami.Icon {
        visible: !img.drawn
        anchors.fill: parent
        source: AssetSymbols.breeze[img.symbol] || SF.icon(img.symbol)
        fallback: "package"
        isMask: true
        color: img.color
    }
    Canvas {
        id: canvas
        visible: img.drawn
        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const w = width, h = height
            const pt = (x, y) => [x * w, y * h]
            const c = img.color
            ctx.lineCap = "round"; ctx.lineJoin = "round"
            if (img.symbol === AssetSymbols.necklace) {
                // a pearl chain hanging in a U with a drop pendant
                const bead = Math.max(2, img.size * 0.17)
                ctx.strokeStyle = c; ctx.lineWidth = bead
                ctx.setLineDash([0.01, 1.55])   // in line widths (QPen)
                ctx.beginPath()
                ctx.moveTo(...pt(0.1, 0.08))
                ctx.bezierCurveTo(...pt(0.1, 0.45), ...pt(0.3, 0.6), ...pt(0.5, 0.6))
                ctx.bezierCurveTo(...pt(0.7, 0.6), ...pt(0.9, 0.45), ...pt(0.9, 0.08))
                ctx.stroke()
                ctx.setLineDash([])
                ctx.fillStyle = c
                ctx.beginPath()
                ctx.moveTo(...pt(0.5, 0.62)); ctx.lineTo(...pt(0.63, 0.78)); ctx.lineTo(...pt(0.5, 0.97)); ctx.lineTo(...pt(0.37, 0.78))
                ctx.closePath(); ctx.fill()
                return
            }
            // a brilliant-cut stone: table on top, girdle, pavilion down to the culet
            ctx.beginPath()
            ctx.moveTo(...pt(0.27, 0.06)); ctx.lineTo(...pt(0.73, 0.06)); ctx.lineTo(...pt(0.97, 0.36))
            ctx.lineTo(...pt(0.5, 0.96)); ctx.lineTo(...pt(0.03, 0.36)); ctx.closePath()
            const gem = img.symbol === AssetSymbols.gem
            ctx.fillStyle = gem ? Qt.alpha(c, 0.3) : c
            ctx.fill()
            ctx.strokeStyle = c; ctx.lineWidth = Math.max(1.2, img.size * 0.11)
            ctx.stroke()
            if (!gem) return
            ctx.lineWidth = Math.max(1, img.size * 0.075)
            ctx.beginPath()
            ctx.moveTo(...pt(0.03, 0.36)); ctx.lineTo(...pt(0.97, 0.36))
            ctx.moveTo(...pt(0.27, 0.06)); ctx.lineTo(...pt(0.34, 0.36)); ctx.lineTo(...pt(0.5, 0.06))
            ctx.lineTo(...pt(0.66, 0.36)); ctx.lineTo(...pt(0.73, 0.06))
            ctx.moveTo(...pt(0.34, 0.36)); ctx.lineTo(...pt(0.5, 0.96)); ctx.lineTo(...pt(0.66, 0.36))
            ctx.stroke()
        }
    }
    onSymbolChanged: canvas.requestPaint()
    onColorChanged: canvas.requestPaint()
}
