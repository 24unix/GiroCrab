import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A TextField in a grouped Form (.formStyle(.grouped)) on macOS: no bezel, the text
// right-aligned up to the row's trailing edge (`.multilineTextAlignment(.trailing)`).
// Used in rows of a FormSection with `separators`; the row's line marks the field.
TextField {
    Layout.fillWidth: true
    horizontalAlignment: TextInput.AlignRight
    leftPadding: 0; rightPadding: 0; topPadding: 4; bottomPadding: 4
    font.pixelSize: Theme.body
    color: Theme.text
    placeholderTextColor: Theme.tertiary
    selectByMouse: true
    background: Item {}
}
