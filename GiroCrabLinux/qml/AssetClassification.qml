pragma Singleton
import QtQuick

// AssetClassificationUI.swift (#351): titles of asset classes, instruments and sources,
// the open edit request (ClassificationEditRequest) and the change counter
// (AppModel.assetClassificationVersion) the views that show a classification reload on.
// A classification is the core's AssetClassification as JSON:
// { security_key, asset_class: "equity"…, asset_class_source: "User"…, instrument: "etf"…, instrument_source }.
QtObject {
    id: ac
    /// AppModel.assetClassificationVersion: only the classification changed.
    property int version: 0
    /// ClassificationEditRequest: { entries: [{ name, classification }] }, or null.
    property var request: null

    /// AssetClass.choices (fixed order: stable colours and card order).
    readonly property var assetClasses: [
        { key: "equity", title: qsTr("Aktien") }, { key: "bond", title: qsTr("Anleihen") },
        { key: "real_estate", title: qsTr("Immobilien") }, { key: "commodity", title: qsTr("Rohstoffe & Edelmetalle") },
        { key: "crypto", title: qsTr("Krypto") }, { key: "cash", title: qsTr("Liquidität & Geldmarkt") },
        { key: "multi_asset", title: qsTr("Mischanlagen / Multi-Asset") }, { key: "other", title: qsTr("Sonstiges") },
        { key: "unclassified", title: qsTr("Nicht klassifiziert") }]
    /// InstrumentKind.choices
    readonly property var instruments: [
        { key: "single", title: qsTr("Einzeltitel") }, { key: "etf", title: "ETF" }, { key: "fund", title: qsTr("Fonds") },
        { key: "etc_etn", title: "ETC/ETN" }, { key: "derivative", title: qsTr("Derivat / strukturiertes Produkt") },
        { key: "direct", title: qsTr("Direktbesitz") }, { key: "other", title: qsTr("Sonstiges") },
        { key: "unclassified", title: qsTr("Nicht klassifiziert") }]
    /// What a user can pick: „Automatisch“ already stands for „no own choice“.
    readonly property var assignableClasses: assetClasses.filter(c => c.key !== "unclassified")
    readonly property var assignableInstruments: instruments.filter(c => c.key !== "unclassified")

    function classIndex(key) { return Math.max(0, assetClasses.findIndex(c => c.key === key)) }
    function instrumentIndex(key) { return Math.max(0, instruments.findIndex(c => c.key === key)) }
    function classTitle(key) { return assetClasses[classIndex(key)].title }
    function instrumentTitle(key) { return instruments[instrumentIndex(key)].title }
    /// ClassificationSource.title
    function sourceTitle(source) {
        switch (source) {
        case "User": return qsTr("Eigene Zuordnung")
        case "Import": return qsTr("Importiert")
        case "Rule": return qsTr("Automatisch ermittelt")
        default: return qsTr("Nicht klassifiziert")
        }
    }

    // MARK: AssetClassification helpers
    /// Sachwerte carry their own identity; „Direktbesitz“ is true for each of them and says nothing.
    function isTangible(c) { return !!c && !!c.security_key && c.security_key.startsWith("asset:") }
    /// null when the instrument adds nothing.
    function instrumentTitleOf(c) {
        return c.instrument === "unclassified" || (isTangible(c) && c.instrument === "direct") ? null : instrumentTitle(c.instrument)
    }
    /// „Aktien · ETF“
    function compactTitle(c) { return [classTitle(c.asset_class), instrumentTitleOf(c)].filter(x => x).join(" · ") }
    function sourceDescription(c) {
        return qsTr("Anlageklasse") + ": " + sourceTitle(c.asset_class_source) + " · "
            + qsTr("Instrument") + ": " + sourceTitle(c.instrument_source)
    }
    /// WealthAssetSelection.isDirectProperty
    function isDirectProperty(asset) {
        return asset.classification.asset_class === "real_estate" && asset.classification.instrument === "direct"
    }

    // MARK: ClassificationEditRequest
    /// One position to classify.
    function edit(name, classification) { editAll([{ name: name, classification: classification }]) }
    /// Several, worked through one after the other. Positions without a stable key cannot be
    /// stored; the same security in two depots is one entry.
    function editAll(entries) {
        const kept = storable(entries)
        if (kept.length) request = { entries: kept }
    }
    function storable(entries) {
        const seen = {}
        return entries.filter(e => {
            const k = e.classification.security_key
            if (!k || seen[k]) return false
            seen[k] = true
            return true
        })
    }
}
