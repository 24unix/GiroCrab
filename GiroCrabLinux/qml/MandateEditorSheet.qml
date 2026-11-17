import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// MandateEditorSheet.swift: a new or changed mandate (GitHub #143). The sheet edits its own
// copy of DirectDebits.draft (`@State draft`) and hands it over on „Sichern“.
Sheet {
    id: sheet
    property var d: null
    visible: DirectDebits.draft !== null
    // Mac: 460 – the date field (day, month, year) is wider here
    sheetWidth: 560
    padding: 0
    function load() { if (DirectDebits.draft) d = Object.assign({}, DirectDebits.draft, { signed: new Date(DirectDebits.draft.signed) }) }
    onAboutToShow: load()
    // a draft handed over while the sheet is open (`--demo-sheet mandate`)
    Connections { target: DirectDebits; function onDraftChanged() { if (sheet.visible) sheet.load() } }
    onClosed: if (DirectDebits.draft !== null) DirectDebits.draft = null
    function set(patch) { d = Object.assign({}, d, patch) }
    readonly property var schemes: ["Core", "Cor1", "B2b"]
    function save() { DirectDebits.saveDraft(d) }

    ColumnLayout {
        width: sheet.availableWidth
        spacing: 0
        ScrollView {
            id: scroll
            ScrollBar.vertical: ScrollViewBar {}
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(form.implicitHeight + 40, sheet.maxBodyHeight - footer.implicitHeight - 60)
            contentWidth: availableWidth
            clip: true
            ColumnLayout {
                id: form
                x: 20; y: 20; width: scroll.availableWidth - 40
                spacing: 18
                FormSection {
                    title: qsTr("Zahlungspflichtiger")
                    Field { placeholder: qsTr("Name"); key: "name" }
                    Field { placeholder: qsTr("IBAN"); key: "iban"; mono: true }
                    Field { placeholder: qsTr("BIC (optional)"); key: "bic"; mono: true }
                }
                FormSection {
                    title: qsTr("Mandat")
                    Field { placeholder: qsTr("Mandatsreferenz"); key: "reference" }
                    FormRow {
                        label: qsTr("Unterschrieben am")
                        DateField {
                            date: sheet.d ? sheet.d.signed : new Date()
                            maximum: new Date()
                            onPicked: dt => sheet.set({ signed: dt })
                        }
                    }
                    FormRow {
                        label: qsTr("Art")
                        AppComboBox {
                            Layout.preferredWidth: 200
                            model: sheet.schemes.map(s => DirectDebits.schemeTitle(s))
                            currentIndex: sheet.d ? sheet.schemes.indexOf(sheet.d.scheme) : 0
                            onActivated: i => sheet.set({ scheme: sheet.schemes[i] })
                        }
                    }
                    FormRow {
                        label: qsTr("Einmaliges Mandat")
                        Switch { checked: !!sheet.d && sheet.d.oneOff; onToggled: sheet.set({ oneOff: checked }) }
                    }
                    FormRow {
                        label: qsTr("Aktiv")
                        Switch { checked: !!sheet.d && sheet.d.active; onToggled: sheet.set({ active: checked }) }
                    }
                }
                FormSection {
                    title: qsTr("Vorgaben für den Einzug")
                    Field { placeholder: qsTr("Betrag (optional)"); key: "amountText"; mono: true }
                    Field { placeholder: qsTr("Verwendungszweck (optional)"); key: "purpose" }
                    Field { placeholder: qsTr("Notiz (optional)"); key: "note" }
                }
            }
        }
        RowLayout {
            visible: DirectDebits.error !== ""
            Layout.fillWidth: true
            Layout.leftMargin: 20; Layout.rightMargin: 20; Layout.bottomMargin: 8
            spacing: 6
            SFIcon { symbol: "exclamationmark.triangle.fill"; size: 14; color: Theme.negative; Layout.alignment: Qt.AlignTop }
            TextEdit { Layout.fillWidth: true; readOnly: true; selectByMouse: true; wrapMode: Text.WordWrap
                       text: DirectDebits.error; color: Theme.negative; font.pixelSize: Theme.callout }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
        RowLayout {
            id: footer
            Layout.fillWidth: true
            Layout.margins: 14
            spacing: 8
            Item { Layout.fillWidth: true }
            Button { text: qsTr("Abbrechen"); onClicked: DirectDebits.draft = null }
            Button { text: qsTr("Sichern"); highlighted: true; onClicked: sheet.save() }
        }
    }
    // .keyboardShortcut(.defaultAction) / (.cancelAction)
    Shortcut { sequences: ["Return", "Enter"]; enabled: sheet.visible; onActivated: sheet.save() }

    /// TextField("…", text: $draft.…) in a grouped form: the title as the row's label.
    component Field: FormRow {
        id: f
        property string placeholder
        property string key
        property bool mono: false
        label: placeholder
        TextField {
            Layout.preferredWidth: 240; horizontalAlignment: TextInput.AlignRight
            font.features: f.mono ? { "tnum": 1 } : {}
            text: sheet.d ? sheet.d[f.key] : ""
            onTextEdited: sheet.set({ [f.key]: text })
            Accessible.name: f.placeholder
            Sensitive {}
        }
    }
}
