import QtQuick
import QtQuick.Shapes

// Loading spinner (ProgressView). The rotation is a RotationAnimator, which runs on the
// scene-graph render thread: it keeps turning while the GUI thread is busy loading a
// large vault, so the window never looks frozen.
Item {
    id: spinner
    property real size: 32
    property real lineWidth: Math.max(2.5, size / 10)
    property color color: Theme.accent
    property bool running: visible
    implicitWidth: size; implicitHeight: size

    Shape {
        id: arc
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {   // faint full ring
            strokeColor: Theme.withAlpha(spinner.color, 0.18); strokeWidth: spinner.lineWidth
            fillColor: "transparent"; capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: spinner.size / 2; centerY: spinner.size / 2
                radiusX: (spinner.size - spinner.lineWidth) / 2; radiusY: radiusX
                startAngle: 0; sweepAngle: 360
            }
        }
        ShapePath {   // the moving part
            strokeColor: spinner.color; strokeWidth: spinner.lineWidth
            fillColor: "transparent"; capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: spinner.size / 2; centerY: spinner.size / 2
                radiusX: (spinner.size - spinner.lineWidth) / 2; radiusY: radiusX
                startAngle: -90; sweepAngle: 100
            }
        }
        RotationAnimator on rotation {
            from: 0; to: 360; duration: 900
            loops: Animation.Infinite
            running: spinner.running
        }
    }
}
