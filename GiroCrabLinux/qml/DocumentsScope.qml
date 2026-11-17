pragma Singleton
import QtQuick

// AppModelTypes.swift › DocumentsScope (#526): „Belege & PostBox“ shows all documents, only
// the user's own receipts or only the bank's documents – independent of the booking link.
// `current` is `AppModel.documentsScope` of the Mac (kept here so AppModel.qml stays small).
QtObject {
    /// "all" | "receipts" | "postbox"
    property string current: "all"

    readonly property var options: [
        { id: "all", title: qsTr("Alle Dokumente") },
        { id: "receipts", title: qsTr("Belege") },
        { id: "postbox", title: qsTr("PostBox") }
    ]
    readonly property string heading: current === "all" ? qsTr("Belege & PostBox") : options.find(o => o.id === current).title
    readonly property string description: {
        switch (current) {
        case "receipts": return qsTr("Selbst hinzugefügte Rechnungen, Kassenbons und Fotos. PDF oder Foto hierher ziehen: GiroCrab sucht den passenden Umsatz.")
        case "postbox": return qsTr("Von der Bank bereitgestellte Kontoauszüge, Wertpapierabrechnungen und Mitteilungen. Sie gehören zum Konto und können einem Umsatz zugeordnet sein.")
        default: return qsTr("Eigene Belege und Bankdokumente – verschlüsselt im Tresor. Die Auswahl eines Kontos grenzt die Sammlung ein.")
        }
    }

    /// DocumentInfo.isBankDocument: connectors and statement imports store a source key,
    /// user uploads leave it empty (old demo vaults used synthetic "demo-doc-" keys).
    function isBankDocument(d) { return !!d.source_url && !d.source_url.startsWith("demo-doc-") }
    /// DocumentInfo.originTitle
    function originTitle(d) { return isBankDocument(d) ? qsTr("PostBox") : qsTr("Beleg") }
    /// DocumentsScope.includes
    function includes(d) {
        return current === "all" || (current === "postbox") === isBankDocument(d)
    }
}
