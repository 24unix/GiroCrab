import QtQuick
import QtQuick.Controls

// Thin divider between menu groups in GiroCrab's colours (AppMenu).
MenuSeparator {
    topPadding: 4; bottomPadding: 4; leftPadding: 6; rightPadding: 6
    contentItem: Rectangle { implicitWidth: 120; implicitHeight: 1; color: Theme.border }
}
