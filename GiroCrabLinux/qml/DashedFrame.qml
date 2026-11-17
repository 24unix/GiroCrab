import QtQuick
import QtQuick.Shapes

// `RoundedRectangle(…).strokeBorder(…, style: StrokeStyle(dash: […]))`: a dashed, rounded
// frame drawn inside the item's bounds (inspector edit mode, partial tag chips).
Shape {
    id: frame
    property real radius: 12
    property color strokeColor: Theme.border
    property real lineWidth: 1.5
    /// Dash and gap in points (as in SwiftUI; ShapePath counts in line widths).
    property var dash: [5, 4]
    readonly property real inset: lineWidth / 2
    readonly property real r: Math.max(0, Math.min(radius, width / 2, height / 2) - inset)
    ShapePath {
        strokeColor: frame.strokeColor; strokeWidth: frame.lineWidth; fillColor: "transparent"
        strokeStyle: ShapePath.DashLine
        dashPattern: frame.dash.map(x => x / frame.lineWidth)
        startX: frame.inset + frame.r; startY: frame.inset
        PathLine { x: frame.width - frame.inset - frame.r; y: frame.inset }
        PathArc { x: frame.width - frame.inset; y: frame.inset + frame.r; radiusX: frame.r; radiusY: frame.r }
        PathLine { x: frame.width - frame.inset; y: frame.height - frame.inset - frame.r }
        PathArc { x: frame.width - frame.inset - frame.r; y: frame.height - frame.inset; radiusX: frame.r; radiusY: frame.r }
        PathLine { x: frame.inset + frame.r; y: frame.height - frame.inset }
        PathArc { x: frame.inset; y: frame.height - frame.inset - frame.r; radiusX: frame.r; radiusY: frame.r }
        PathLine { x: frame.inset; y: frame.inset + frame.r }
        PathArc { x: frame.inset + frame.r; y: frame.inset; radiusX: frame.r; radiusY: frame.r }
    }
}
