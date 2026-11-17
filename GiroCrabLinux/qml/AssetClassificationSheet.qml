import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// AssetClassificationUI.swift › AssetClassificationSheet: own asset class and instrument of a
// position („Automatisch“ resets only that axis). Several open positions are worked through
// one after the other („Speichern & weiter“). Driven by `AssetClassification.request`.
Sheet {
    id: sheet
    readonly property var request: AssetClassification.request
    readonly property var entries: request ? request.entries : []
    property int index: 0
    readonly property var entry: entries.length ? entries[Math.min(index, entries.length - 1)] : null
    readonly property var current: entry ? entry.classification : null
    readonly property bool hasNext: index + 1 < entries.length
    /// "" = Automatisch
    property string asset: ""
    property string instrument: ""
    property bool saved: false
    property string error: ""
    // an explicit "unclassified" from an older state reads as automatic: both mean "not assigned"
    readonly property string initialAsset: current && current.asset_class_source === "User" && current.asset_class !== "unclassified" ? current.asset_class : ""
    readonly property string initialInstrument: current && current.instrument_source === "User" && current.instrument !== "unclassified" ? current.instrument : ""
    readonly property var assetOptions: [{ key: "", title: qsTr("Automatisch") }].concat(AssetClassification.assignableClasses)
    readonly property var instrumentOptions: [{ key: "", title: qsTr("Automatisch") }].concat(AssetClassification.assignableInstruments)

    visible: request !== null
    sheetWidth: 560
    padding: 20
    onAboutToShow: { index = 0; saved = false; load() }
    onClosed: AssetClassification.request = null

    /// „Aktien · Importiert“; without a source there is nothing to add to „Nicht klassifiziert“.
    function stateText(value, source) { return source === "Unknown" ? value : value + " · " + AssetClassification.sourceTitle(source) }
    function load() { asset = initialAsset; instrument = initialInstrument; error = "" }
    function save(advance) {
        const c = current
        if (!c || !c.security_key || !AppModel.isUnlocked) return
        const assetChanged = asset !== initialAsset, instrumentChanged = instrument !== initialInstrument
        try {
            if (assetChanged) AppModel.core("set_asset_class_override", { security_key: c.security_key, value: asset === "" ? null : asset })
            if (instrumentChanged) AppModel.core("set_instrument_override", { security_key: c.security_key, value: instrument === "" ? null : instrument })
        } catch (e) {
            error = AppModel.parseCoreError(e.message).message
            return
        }
        // only the classification changed: the views that show it reload on this counter
        if (assetChanged || instrumentChanged) AssetClassification.version++
        saved = saved || assetChanged || instrumentChanged
        if (advance && hasNext) { index++; load() } else close()
    }

    ColumnLayout {
        width: sheet.availableWidth
        spacing: 14

        RowLayout {
            Layout.fillWidth: true
            Text {
                Layout.fillWidth: true
                text: sheet.entry ? sheet.entry.name : ""
                font.pixelSize: Theme.subheadline + 2; font.weight: Font.DemiBold; color: Theme.text; elide: Text.ElideRight
                Accessible.role: Accessible.Heading
                Sensitive { labels: !AssetClassification.isTangible(sheet.current) }
            }
            Text {
                visible: sheet.entries.length > 1
                text: qsTr("Position %1 von %2").arg(sheet.index + 1).arg(sheet.entries.length)
                font.pixelSize: Theme.caption; color: Theme.secondary
            }
        }

        FormSection {
            FormRow {
                label: qsTr("Anlageklasse")
                AppComboBox {
                    implicitWidth: 260
                    model: sheet.assetOptions.map(o => o.title)
                    currentIndex: Math.max(0, sheet.assetOptions.findIndex(o => o.key === sheet.asset))
                    onActivated: i => sheet.asset = sheet.assetOptions[i].key
                }
            }
            FormRow {
                label: qsTr("Instrument")
                AppComboBox {
                    implicitWidth: 260
                    model: sheet.instrumentOptions.map(o => o.title)
                    currentIndex: Math.max(0, sheet.instrumentOptions.findIndex(o => o.key === sheet.instrument))
                    onActivated: i => sheet.instrument = sheet.instrumentOptions[i].key
                }
            }
            FormRow {
                label: qsTr("Aktuelle Anlageklasse")
                value: sheet.current ? sheet.stateText(AssetClassification.classTitle(sheet.current.asset_class), sheet.current.asset_class_source) : ""
            }
            FormRow {
                label: qsTr("Aktuelles Instrument")
                value: sheet.current ? sheet.stateText(AssetClassification.instrumentTitle(sheet.current.instrument), sheet.current.instrument_source) : ""
            }
        }

        Text {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: AssetClassification.isTangible(sheet.current)
                  ? qsTr("Die eigene Zuordnung gilt für diesen Sachwert. Automatisch setzt nur das jeweilige Merkmal zurück.")
                  : qsTr("Eigene Zuordnungen gelten für dieses Wertpapier in allen Depots dieses Tresors. Automatisch setzt nur das jeweilige Merkmal zurück.")
            font.pixelSize: Theme.caption; color: Theme.secondary
        }
        Text {
            visible: sheet.error !== ""
            Layout.fillWidth: true; wrapMode: Text.Wrap
            text: sheet.error; font.pixelSize: Theme.caption; color: Theme.negative
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Button { text: sheet.saved ? qsTr("Fertig") : qsTr("Abbrechen"); onClicked: sheet.close() }
            Item { Layout.fillWidth: true }
            Button { visible: sheet.hasNext; text: qsTr("Speichern"); enabled: AppModel.isUnlocked; onClicked: sheet.save(false) }
            Button {
                text: sheet.hasNext ? qsTr("Speichern & weiter") : qsTr("Speichern")
                highlighted: true; enabled: AppModel.isUnlocked
                onClicked: sheet.save(true)
            }
        }
    }
    // .keyboardShortcut(.defaultAction)
    Shortcut { enabled: sheet.visible; sequences: ["Return", "Enter"]; onActivated: sheet.save(true) }
}
