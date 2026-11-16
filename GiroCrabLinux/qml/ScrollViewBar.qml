import QtQuick
import QtQuick.Controls

// AppScrollBar for a ScrollView (`ScrollBar.vertical: ScrollViewBar {}`): replacing the
// style's bar also drops its placement, so it puts itself at the right edge here.
AppScrollBar {
    x: parent ? (parent.mirrored ? 0 : parent.width - width) : 0
    y: parent ? parent.topPadding : 0
    height: parent ? parent.availableHeight : 0
    z: 1   // above the ScrollView's content, which is created after the bar
}
