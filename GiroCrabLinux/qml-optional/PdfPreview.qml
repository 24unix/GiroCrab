import QtQuick
import QtQuick.Pdf

// PDFPreview (PDFKit, autoScales + singlePageContinuous) → QtPdf.
PdfMultiPageView {
    id: view
    property alias source: pdfDoc.source
    document: PdfDocument {
        id: pdfDoc
        onStatusChanged: if (pdfDoc.status === PdfDocument.Ready) Qt.callLater(view.fit)
    }
    onWidthChanged: if (pdfDoc.status === PdfDocument.Ready) Qt.callLater(fit)

    // autoScales: the first page fills the width (minus the scroll bar). The view lays its
    // page column out only on size changes, not on a new renderScale, so it is asked again –
    // without that the page sits off-centre in a column as wide as at the old scale.
    function fit() {
        if (pdfDoc.status !== PdfDocument.Ready || width <= 0) return
        scaleToWidth(Math.max(1, width - 16), height)
        for (let i = 0; i < children.length; ++i)
            if (typeof children[i].forceLayout === "function") children[i].forceLayout()
    }
}
