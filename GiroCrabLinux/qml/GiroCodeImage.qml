import QtQuick

// GiroCode.image(for:): the core's QR modules (quiet zone included) on white,
// drawn without interpolation; a placeholder symbol without payload.
Item {
    id: root
    property string payload: ""
    readonly property var matrix: {
        if (payload === "") return null
        return AppModel.coreOrNull("girocode_matrix", { payload: payload })
    }
    implicitWidth: 200; implicitHeight: 200
    Accessible.name: qsTr("GiroCode")

    SFIcon { visible: root.matrix === null; anchors.fill: parent; symbol: "qrcode"; size: Math.min(root.width, root.height); color: Theme.tertiary }
    Canvas {
        id: canvas
        visible: root.matrix !== null
        anchors.fill: parent
        antialiasing: false
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const m = root.matrix
            if (!m) return
            const n = m.width
            const side = Math.min(width, height)
            const scale = Math.max(1, Math.floor(side / n))
            const off = Math.floor((side - scale * n) / 2)
            ctx.fillStyle = "white"
            ctx.fillRect(0, 0, side, side)
            ctx.fillStyle = "black"
            for (let y = 0; y < n; y++)
                for (let x = 0; x < n; x++)
                    if (m.modules[y * n + x]) ctx.fillRect(off + x * scale, off + y * scale, scale, scale)
        }
    }
    onMatrixChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
}
