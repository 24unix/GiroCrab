import QtQuick
import QtQuick.Pdf

// PDFPreview (PDFKit, autoScales + singlePageContinuous) → QtPdf.
PdfMultiPageView {
    id: view
    property alias source: pdfDoc.source
    document: PdfDocument {
        id: pdfDoc
        onStatusChanged: if (pdfDoc.status === PdfDocument.Ready) Qt.callLater(() => view.scaleToWidth(view.width, view.height))
    }
    onWidthChanged: if (pdfDoc.status === PdfDocument.Ready) scaleToWidth(width, height)
}
