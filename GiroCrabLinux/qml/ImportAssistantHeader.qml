import QtQuick
import QtQuick.Layouts

// MoneyMoneyImportSheet.swift › ImportAssistantHeader: symbol, step title and
// subtitle. No "Schritt n von m" – each step is named by its title.
RowLayout {
    id: h
    property string title
    property string subtitle
    property string symbol: "square.and.arrow.down.on.square"
    property color tint: Theme.accent
    Layout.fillWidth: true
    spacing: 12
    SFIcon { symbol: h.symbol; size: 26; color: h.tint; Layout.alignment: Qt.AlignTop }
    ColumnLayout {
        spacing: 3
        Layout.fillWidth: true
        Text { text: h.title; font.pixelSize: Theme.title3 + 2; font.weight: Font.DemiBold; color: Theme.text }
        Text {
            visible: h.subtitle !== ""
            text: h.subtitle
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            font.pixelSize: Theme.callout + 1; color: Theme.secondary
        }
    }
}
