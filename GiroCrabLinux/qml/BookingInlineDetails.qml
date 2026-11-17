import QtQuick
import QtQuick.Layouts

// BookingInlineDetails.swift (#542): the labelled fields of an expanded booking row
// („Kompakt“: the active booking, „Großzügig“: every booking). Uses only the already loaded
// booking: selecting a row never fetches bank data. Equal-width columns keep the labels
// aligned across rows; fewer columns at narrow widths let every value wrap.
GridLayout {
    id: grid
    property var booking: null
    readonly property var fields: booking ? BookingDetails.fields(booking) : []
    readonly property real minimumColumnWidth: 240 * Theme.textScale
    columns: Math.max(1, Math.floor((width + columnSpacing) / (minimumColumnWidth + columnSpacing)))
    readonly property real columnWidth: Math.max(0, (width - (columns - 1) * columnSpacing) / columns)
    columnSpacing: 20 * Theme.textScale
    rowSpacing: 4 * Theme.textScale

    function escaped(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }

    Repeater {
        model: grid.fields
        Text {
            required property var modelData
            Layout.preferredWidth: grid.columnWidth
            Layout.maximumWidth: grid.columnWidth
            Layout.alignment: Qt.AlignTop
            textFormat: Text.StyledText
            text: "<b>" + grid.escaped(modelData.title) + "</b>: " + grid.escaped(modelData.value).replace(/\n/g, "<br>")
            wrapMode: Text.Wrap
            font.pixelSize: Theme.callout + 1
            color: Theme.secondary
            Sensitive { when: modelData.redaction !== ""; labels: modelData.redaction === "labels" }
        }
    }
}
