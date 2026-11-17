import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// AccountSelectionView.swift › AccountSelectionList (#346): which accounts of one login
// are fetched. Accounts that are already reachable through another login are held back
// until the user decides; skipped accounts stay listed so the choice can be changed later.
ColumnLayout {
    id: list
    property var connection: null
    property bool showsSaveButton: true
    property string saveTitle: qsTr("Auswahl speichern")
    /// After a successful save (the sheet closes itself).
    signal saved()

    property var choices: []
    /// account_ref → true ("Abrufen" on)
    property var enabledRefs: ({})
    property bool loaded: false
    property string error: ""

    Layout.fillWidth: true
    spacing: 10

    function load() {
        loaded = false
        error = ""
        if (!connection) return
        const id = connection.id
        AppModel.coreAsync("connection_account_choices", { connection_id: id }, rows => {
            if (!list.connection || list.connection.id !== id) return
            list.choices = rows
            // held-back accounts start as "Abrufen" off: the user has to opt in
            const on = {}
            for (const c of rows) if (c.enabled) on[c.account_ref] = true
            list.enabledRefs = on
            list.loaded = true
        }, () => { list.loaded = true })
    }
    onConnectionChanged: load()
    Component.onCompleted: load()

    function setEnabled(ref, on) {
        const x = Object.assign({}, enabledRefs)
        if (on) x[ref] = true
        else delete x[ref]
        enabledRefs = x
    }
    function detail(c) { return [c.number, c.owner].filter(s => s !== "").join(" · ") }
    function save() {
        const id = connection.id
        AppModel.coreAsync("set_connection_account_choices", { connection_id: id, enabled_refs: Object.keys(enabledRefs) }, () => {
            AppModel.reloadAll()
            list.saved()
        }, err => { list.error = AppModel.parseCoreError(err).message })
    }

    Spinner { visible: !list.loaded; size: 20; Layout.alignment: Qt.AlignHCenter }
    Text {
        visible: list.loaded && list.choices.length === 0
        text: qsTr("Noch keine Konten abgerufen.")
        font.pixelSize: Theme.body; color: Theme.secondary
    }
    Repeater {
        model: list.loaded ? list.choices : []
        delegate: RowLayout {
            id: row
            required property var modelData
            Layout.fillWidth: true
            spacing: 10
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text { text: row.modelData.name; font.pixelSize: Theme.body; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                Text { visible: text !== ""; text: list.detail(row.modelData); font.pixelSize: Theme.caption; color: Theme.secondary
                       elide: Text.ElideRight; Layout.fillWidth: true }
                RowLayout {
                    visible: row.modelData.pending
                    Layout.fillWidth: true
                    spacing: 4
                    SFIcon { symbol: "exclamationmark.triangle"; size: 11; color: Theme.warning; Layout.alignment: Qt.AlignTop }
                    Text { text: qsTr("Bereits über „%1“ eingebunden").arg(row.modelData.existing_connection)
                           font.pixelSize: Theme.caption; color: Theme.warning; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                }
            }
            Switch {
                checked: !!list.enabledRefs[row.modelData.account_ref]
                onToggled: list.setEnabled(row.modelData.account_ref, checked)
            }
        }
    }
    Text {
        visible: list.loaded && list.choices.length > 0
        Layout.fillWidth: true; wrapMode: Text.WordWrap
        text: qsTr("Abrufen: Konto, Umsätze und Dokumente werden über diesen Zugang importiert. Überspringen: nichts davon; das Konto wird archiviert (abgeblendet, nicht in der Summe) und behält seine gespeicherten Daten.")
        font.pixelSize: Theme.caption; color: Theme.secondary
    }
    Text {
        visible: list.error !== ""
        Layout.fillWidth: true; wrapMode: Text.WordWrap
        text: list.error
        font.pixelSize: Theme.caption; color: Theme.negative
    }
    Button {
        visible: list.loaded && list.choices.length > 0 && list.showsSaveButton
        text: list.saveTitle
        highlighted: true
        onClicked: list.save()
    }
}
