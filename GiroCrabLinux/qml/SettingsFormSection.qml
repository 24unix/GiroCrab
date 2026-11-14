import QtQuick

// Form { Section("…") { … } footer: { … } }.formStyle(.grouped) in the Settings window:
// FormSection with the Settings style (bold header in the text colour, card-coloured box).
FormSection {
    headerFont.pixelSize: Theme.body
    headerColor: Theme.text
    headerInset: 4
    footerTrailingInset: 4
    boxColor: Theme.card
    boxRadius: 9
    inset: 12
    rowSpacing: 10
    spacing: 6
}
