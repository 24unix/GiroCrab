import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtCore

// SyncLog.swift › SyncLogView: "Abruf-Protokoll" window (Fenster › Abruf-Protokoll, GitHub #238):
// when a fetch ran, for which connection, how it ended and with which error text. Searchable,
// filterable by connection and errors, exportable as CSV. Rows older than seven days and
// anything beyond 10 MB are dropped by the core; no logins, PINs or TANs are kept.
ApplicationWindow {
    id: win
    // `--dark` / `--light`: the controls follow the forced appearance (Theme.forcedPalette)
    Binding on palette { when: Theme.forced !== ""; value: Theme.forcedPalette }
    title: qsTr("Abruf-Protokoll")
    width: 900; height: 520
    minimumWidth: 680; minimumHeight: 320
    color: Theme.canvas
    visible: AppModel.showSyncLog
    onClosing: AppModel.showSyncLog = false
    onVisibleChanged: if (visible) { reload(); requestActivate(); raise() }

    property var entries: []
    property string search: ""
    property bool onlyErrors: false
    property var connectionID: null
    /// Sort column ("time" | "connection") and direction.
    property string sortKey: "time"
    property bool ascending: false
    property var selection: ({})
    readonly property bool filtered: search !== "" || onlyErrors || connectionID !== null
    readonly property var sorted: {
        const out = entries.slice()
        const k = sortKey === "time" ? (e => e.timestamp_ms) : (e => e.connection_name.toLowerCase())
        out.sort((a, b) => { const x = k(a), y = k(b); return (x < y ? -1 : x > y ? 1 : 0) * (ascending ? 1 : -1) })
        return out
    }
    readonly property int timeWidth: 170
    readonly property int connectionWidth: 160
    readonly property int outcomeWidth: 130

    Shortcut { sequences: [StandardKey.Close]; onActivated: win.close() }
    Connections { target: AppModel; function onSyncLogVersionChanged() { if (win.visible) win.reload() } }
    Timer { id: searchTimer; interval: 200; onTriggered: win.reload() }
    onOnlyErrorsChanged: reload()
    onConnectionIDChanged: reload()

    function reload() {
        if (!AppModel.isUnlocked) { entries = []; return }
        const filter = { connection_id: connectionID, only_errors: onlyErrors, search: search === "" ? null : search, limit: 0 }
        AppModel.coreAsync("list_sync_log", { filter: filter }, loaded => {
            entries = loaded
            const s = {}
            for (const e of loaded) if (selection[e.id]) s[e.id] = true
            selection = s
        }, () => {})
    }
    function message(e) {
        if (e.message !== "") return e.message
        if (e.outcome === "Ok") return e.imported === 0 ? qsTr("Keine neuen Buchungen") : qsTr("%1 neue Buchungen").arg(e.imported)
        return ""
    }
    function copySelection() {
        AppModel.copyToClipboard(sorted.filter(e => selection[e.id]).map(message).join("\n"))
    }
    function select(id, toggle) {
        const s = toggle ? Object.assign({}, selection) : {}
        if (toggle && s[id]) delete s[id]; else s[id] = true
        selection = s
    }
    function sortBy(key) { if (sortKey === key) ascending = !ascending; else { sortKey = key; ascending = key !== "time" } }

    FileDialog {
        id: exportDialog
        title: qsTr("Exportieren …")
        fileMode: FileDialog.SaveFile
        defaultSuffix: "csv"
        nameFilters: [qsTr("CSV-Datei (*.csv)")]
        currentFolder: StandardPaths.writableLocation(StandardPaths.DocumentsLocation)
        selectedFile: currentFolder + "/GiroCrab-Abrufprotokoll.csv"
        onAccepted: AppModel.run(() => AppModel.core("write_text_file", {
            path: AppModel.localPath(selectedFile), text: AppModel.syncLogCSV(win.sorted) }))
    }
    ConfirmDialog {
        id: confirmClear
        heading: qsTr("Protokoll leeren?")
        message: qsTr("Alle Einträge des Abruf-Protokolls werden gelöscht. Das lässt sich nicht widerrufen.")
        actionTitle: qsTr("Protokoll leeren")
        onConfirmed: AppModel.coreAsync("clear_sync_log", {}, () => win.reload())
    }
    AppMenu {
        id: rowMenu
        AppMenuItem { text: qsTr("Meldung kopieren"); enabled: Object.keys(win.selection).length > 0; onTriggered: win.copySelection() }
    }

    header: ToolBar {
        background: Rectangle { color: Theme.canvas; Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border } }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10; anchors.rightMargin: 10
            spacing: 8
            AppComboBox {
                id: connectionPicker
                implicitWidth: 200
                model: [{ id: null, name: qsTr("Alle Konten") }].concat(AppModel.connections.map(c => ({ id: c.id, name: c.display_name })))
                textRole: "name"
                onActivated: i => win.connectionID = model[i].id
            }
            IconButton {
                symbol: "exclamationmark.triangle"; text: qsTr("Nur Fehler")
                checkable: true; checked: win.onlyErrors; onToggled: win.onlyErrors = checked
                ToolTip.text: qsTr("Nur fehlgeschlagene Abrufe zeigen")
            }
            Item { Layout.fillWidth: true }
            IconButton { symbol: "square.and.arrow.up"; text: qsTr("Exportieren …"); enabled: win.entries.length > 0
                         ToolTip.text: qsTr("Angezeigte Einträge als CSV exportieren"); onClicked: exportDialog.open() }
            IconButton { symbol: "trash"; text: qsTr("Protokoll leeren …"); enabled: win.entries.length > 0 || win.filtered
                         ToolTip.text: qsTr("Alle Einträge löschen"); onClicked: confirmClear.open() }
            TextField {
                Layout.preferredWidth: 220
                placeholderText: qsTr("Protokoll durchsuchen")
                leftPadding: 28
                SFIcon { symbol: "magnifyingglass"; size: 14; anchors.verticalCenter: parent.verticalCenter; x: 8 }
                onTextEdited: { win.search = text; searchTimer.restart() }
                Keys.onEscapePressed: { text = ""; win.search = ""; win.reload() }
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        // table header
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 26
            color: Theme.card
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                spacing: 10
                HeaderCell { text: qsTr("Zeit"); key: "time"; Layout.preferredWidth: win.timeWidth }
                HeaderCell { text: qsTr("Konto"); key: "connection"; Layout.preferredWidth: win.connectionWidth }
                HeaderCell { text: qsTr("Ergebnis"); Layout.preferredWidth: win.outcomeWidth }
                HeaderCell { text: qsTr("Meldung"); Layout.fillWidth: true }
            }
        }
        ListView {
            id: table
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: win.sorted
            ScrollBar.vertical: AppScrollBar {}
            delegate: Rectangle {
                id: rowItem
                required property var modelData
                required property int index
                readonly property bool selected: !!win.selection[modelData.id]
                width: table.width
                implicitHeight: Math.max(26, msg.implicitHeight + 10)
                color: selected ? Theme.selection : index % 2 ? Theme.withAlpha(Theme.secondary, 0.05) : "transparent"
                readonly property var outcomeColor: modelData.outcome === "Ok" ? Theme.inflow : modelData.outcome === "Error" ? Theme.negative : Theme.secondary
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                    spacing: 10
                    Text { Layout.preferredWidth: win.timeWidth; font.pixelSize: Theme.body; font.features: { "tnum": 1 }; color: Theme.text
                           text: new Date(rowItem.modelData.timestamp_ms).toLocaleString(Fmt.locale, Fmt.pattern("d. MMM yyyy, HH:mm:ss")) }
                    Text { Layout.preferredWidth: win.connectionWidth; font.pixelSize: Theme.body; color: Theme.text; elide: Text.ElideRight
                           text: rowItem.modelData.connection_name === "" ? "–" : rowItem.modelData.connection_name }
                    RowLayout { Layout.preferredWidth: win.outcomeWidth; Layout.fillWidth: false; spacing: 5
                        SFIcon { symbol: rowItem.modelData.outcome === "Ok" ? "checkmark.circle.fill" : rowItem.modelData.outcome === "Error" ? "exclamationmark.triangle.fill" : "minus.circle.fill"
                                 size: 13; color: rowItem.outcomeColor }
                        Text { text: AppModel.syncLogOutcomeTitles[rowItem.modelData.outcome]; font.pixelSize: Theme.body; color: rowItem.outcomeColor } }
                    Text { id: msg; Layout.fillWidth: true; font.pixelSize: Theme.body; color: Theme.text; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight
                           text: win.message(rowItem.modelData) }
                }
                TapHandler { acceptedModifiers: Qt.NoModifier; onTapped: win.select(rowItem.modelData.id, false) }
                TapHandler { acceptedModifiers: Qt.ControlModifier; onTapped: win.select(rowItem.modelData.id, true) }
                TapHandler { acceptedButtons: Qt.RightButton
                             onTapped: { if (!rowItem.selected) win.select(rowItem.modelData.id, false); rowMenu.popup() } }
            }
            // ContentUnavailableView
            ColumnLayout {
                anchors.centerIn: parent
                visible: win.entries.length === 0
                width: Math.min(parent.width - 40, 420)
                spacing: 8
                SFIcon { Layout.alignment: Qt.AlignHCenter; symbol: win.filtered ? "magnifyingglass" : "list.bullet.clipboard"; size: 36; color: Theme.tertiary }
                Text { Layout.alignment: Qt.AlignHCenter; text: win.filtered ? qsTr("Keine Ergebnisse") : qsTr("Noch keine Abrufe"); font.pixelSize: Theme.title3; font.weight: Font.DemiBold; color: Theme.text }
                Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: Theme.body; color: Theme.secondary
                       text: win.filtered ? qsTr("Prüfen Sie die Schreibweise oder versuchen Sie eine neue Suche.") : qsTr("Hier erscheinen Abrufe der letzten sieben Tage – mit Ergebnis und Fehlertext.") }
            }
        }
    }

    component HeaderCell: Item {
        id: hc
        property string text
        property string key: ""
        implicitHeight: 24
        RowLayout {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            Text { text: hc.text; font.pixelSize: Theme.callout; font.weight: Font.Medium; color: Theme.secondary }
            Text { visible: hc.key !== "" && win.sortKey === hc.key; text: win.ascending ? "▲" : "▼"; font.pixelSize: 8; color: Theme.secondary }
        }
        MouseArea { anchors.fill: parent; enabled: hc.key !== ""; onClicked: win.sortBy(hc.key) }
    }
}
