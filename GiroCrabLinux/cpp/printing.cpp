// PrintSheet.swift › HTMLPrinter: the booking report is laid out by a browser engine
// from the Mac app's own markup, stylesheet and paginator (WebPrinter.qml, QtWebEngine)
// and arrives here as a PDF. This file shows the system print dialog, which also offers
// "In Datei drucken (PDF)", and sends the pages to the printer.
#include <QtCore/QFile>
#include <QtCore/QString>
#include <QtGui/QGuiApplication>
#include <QtGui/QImage>
#include <QtGui/QImageReader>
#include <QtGui/QPageSize>
#include <QtGui/QPainter>
#include <QtGui/QWindow>
#include <QtGui/QPaintEngine>
#include <QtPrintSupport/QPrintPreviewDialog>
#include <QtPrintSupport/QPrinter>

/// Qt's PDF image plugin (package qt6-image-formats-plugin-pdf) renders PDF pages.
extern "C" bool girocrab_print_pdf_supported()
{
    return QImageReader::supportedImageFormats().contains("pdf");
}

/// PrintSheet.swift › NSPrintOperation of the WebKit report: prints the PDF that
/// WebPrinter.qml rendered from the Mac markup. Like the Mac print panel it starts with a
/// preview (pages, page count, zoom); "Drucken" there opens the system print dialog.
/// "In Datei drucken" copies the PDF as it is (vector); a printer gets every page
/// rendered at its resolution (at most 600 dpi, the preview at 150 dpi).
/// Returns 1 = printed / written, 0 = cancelled, -1 = failed.
extern "C" int girocrab_print_pdf(const char *path, const char *job_name)
{
    const QString file = QString::fromUtf8(path);
    QImageReader reader(file, "pdf");
    const int pages = reader.imageCount();
    if (pages <= 0)
        return -1;

    QPrinter printer(QPrinter::HighResolution);
    printer.setDocName(QString::fromUtf8(job_name));
    printer.setPageSize(QPageSize(QPageSize::A4));
    printer.setFullPage(true); // the PDF pages carry their own margins
    printer.setFromTo(1, pages);

    bool failed = false, printed = false;
    QString copyTo; // "In Datei drucken": the PDF itself, not a re-rendered copy
    auto paint = [&](QPrinter *target) {
        if (target->outputFormat() == QPrinter::PdfFormat && !target->outputFileName().isEmpty()) {
            copyTo = target->outputFileName();
            return;
        }
        int from = 1, to = pages;
        if (target->printRange() == QPrinter::PageRange && target->fromPage() > 0) {
            from = qBound(1, target->fromPage(), pages);
            to = qBound(from, target->toPage() > 0 ? target->toPage() : pages, pages);
        }
        QPainter p;
        if (!p.begin(target)) {
            failed = true;
            return;
        }
        const bool preview = p.paintEngine() && p.paintEngine()->type() == QPaintEngine::Picture;
        const double dpi = preview ? 150 : qMin(target->resolution(), 600);
        const QRectF paper = target->paperRect(QPrinter::DevicePixel);
        for (int i = from; i <= to; ++i) {
            if (i > from)
                target->newPage();
            if (!reader.jumpToImage(i - 1)) {
                failed = true;
                break;
            }
            const QSize points = reader.size(); // page size in PDF points (1/72 inch)
            if (points.isValid())
                reader.setScaledSize(QSize(qRound(points.width() * dpi / 72), qRound(points.height() * dpi / 72)));
            const QImage page = reader.read();
            if (page.isNull()) {
                failed = true;
                break;
            }
            p.drawImage(paper, page);
        }
        if (!p.end())
            failed = true;
        else if (!preview)
            printed = true;
    };

    QPrintPreviewDialog dialog(&printer);
    dialog.setWindowTitle(QStringLiteral("Druckvorschau"));
    dialog.resize(900, 1000);
    dialog.winId();
    if (QWindow *owner = QGuiApplication::focusWindow(); owner && dialog.windowHandle())
        dialog.windowHandle()->setTransientParent(owner);
    QObject::connect(&dialog, &QPrintPreviewDialog::paintRequested, &dialog, paint);
    const bool accepted = dialog.exec() == QDialog::Accepted;
    if (!copyTo.isEmpty()) {
        QFile::remove(copyTo);
        return QFile::copy(file, copyTo) ? 1 : -1;
    }
    if (failed)
        return -1;
    return accepted && printed ? 1 : 0;
}
