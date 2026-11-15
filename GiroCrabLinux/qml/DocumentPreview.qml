import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// DocumentsUI.swift › DocumentPreview: PDF (QtPdf instead of PDFKit) or image.
// The PDF view lives in PdfPreview.qml and is loaded on demand, so the app still
// runs (with an "Öffnen" fallback) when qml6-module-qtquick-pdf is missing.
Rectangle {
    id: preview
    property var doc: null
    readonly property string fileURL: doc ? AppModel.documentFileURL(doc) : ""
    readonly property bool isPdf: doc !== null && doc.mime_type === "application/pdf"
    color: Theme.canvas
    clip: true   // the PDF view scrolls inside, it must not paint past the preview
    Image {
        id: image
        visible: preview.doc !== null && !preview.isPdf
        anchors.fill: parent; anchors.margins: 8
        source: visible ? preview.fileURL : ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true
    }
    Loader {
        id: pdf
        anchors.fill: parent
        active: preview.isPdf
        source: "PdfPreview.qml"
        onLoaded: item.source = Qt.binding(() => preview.fileURL)
    }
    ColumnLayout {
        anchors.centerIn: parent
        // no document, QtPdf missing, or an image Qt cannot decode (AppModel.image(from:) == nil)
        visible: preview.doc === null || (preview.isPdf && pdf.status === Loader.Error)
                 || (!preview.isPdf && image.status === Image.Error)
        spacing: 8
        SFIcon { Layout.alignment: Qt.AlignHCenter; symbol: "doc"; size: 32 }
        Text { Layout.alignment: Qt.AlignHCenter; text: qsTr("Keine Vorschau"); font.pixelSize: Theme.title3; font.weight: Font.DemiBold; color: Theme.text }
        Button { visible: preview.doc !== null; Layout.alignment: Qt.AlignHCenter; text: qsTr("Im Standardprogramm öffnen"); onClicked: AppModel.quickLook(preview.doc) }
    }
}
