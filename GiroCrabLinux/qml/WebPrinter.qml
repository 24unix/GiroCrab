import QtQuick
import QtWebEngine

// PrintSheet.swift › HTMLPrinter: WebKit lays out the report on the Mac. Here
// QtWebEngine does it with the same markup, stylesheet and paginator
// (PrintReport.qml) and writes a PDF, which cpp/printing.cpp sends to the
// print dialog. Main.qml loads this file only while printing, so the app
// still starts without QtWebEngine.
WebEngineView {
    id: view
    property string targetPath: ""
    /// Rendering is done: `ok` = the PDF is at `targetPath`.
    signal finished(bool ok)

    // one A4 page at 96 dpi; never shown
    width: 794; height: 1123
    visible: false
    // nothing to remember, nothing to fetch: the report is a string with local images
    profile: WebEngineProfile { offTheRecord: true }
    settings.localContentCanAccessRemoteUrls: false
    settings.pluginsEnabled: false

    function render(html, path) {
        targetPath = path
        loadHtml(html, "qrc:/qt/qml/GiroCrab/")
    }

    onLoadingChanged: info => {
        if (info.status === WebEngineView.LoadSucceededStatus)
            printToPdf(targetPath, WebEngineView.A4, WebEngineView.Portrait)
        else if (info.status === WebEngineView.LoadFailedStatus)
            finished(false)
    }
    onPdfPrintingFinished: (filePath, success) => finished(success)
}
