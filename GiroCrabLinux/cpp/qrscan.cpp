// PaymentParser.swift › image(from:isPDF:): one page of a dropped invoice as an 8-bit grey
// image for the GiroCode (EPC QR) search in src/qr_scan.rs. Photos (PNG, JPEG, … – every
// format Qt reads) are read as they are; a PDF page goes through Qt's PDF image plugin
// (QtPdf, qt6-image-formats-plugin-pdf), rendered like the Mac app at 3× its size in points
// on white. Without that plugin a PDF simply has no page here. Runs on Core.callAsync's
// worker thread: QImageReader, QImage and QPainter on a QImage need no GUI thread.
#include <QtCore/QBuffer>
#include <QtCore/QByteArray>
#include <QtGui/QColor>
#include <QtGui/QImage>
#include <QtGui/QImageReader>
#include <QtGui/QPainter>

#include <algorithm>
#include <cstddef>

using GiroCrabGraySink = void (*)(void *ctx, const unsigned char *pixels, int width, int height,
                                  int stride);

// Hands page `index` of `data` to `sink` (rows of `stride` bytes, 0 = black, 255 = white).
// Returns the number of pages (1 for a plain image), or -1 when Qt cannot read the data or
// that page.
extern "C" int girocrab_scan_page(const unsigned char *data, size_t len, int index,
                                  double pdfScale, int maxSide, void *ctx, GiroCrabGraySink sink)
{
    QByteArray bytes = QByteArray::fromRawData(reinterpret_cast<const char *>(data),
                                               static_cast<qsizetype>(len));
    QBuffer buffer(&bytes);
    if (!buffer.open(QIODevice::ReadOnly))
        return -1;
    QImageReader reader(&buffer);
    reader.setDecideFormatFromContent(true);
    reader.setAutoTransform(true);
    if (!reader.canRead())
        return -1;
    const int count = std::max(reader.imageCount(), 1);
    if (index >= count || (index > 0 && !reader.jumpToImage(index)))
        return -1;
    const bool isPdf = reader.format() == "pdf";
    QSize size = reader.size();
    if (size.isValid()) {
        QSize target = isPdf ? size * pdfScale : size;
        if (std::max(target.width(), target.height()) > maxSide)
            target.scale(maxSide, maxSide, Qt::KeepAspectRatio);
        if (target != size)
            reader.setScaledSize(target);
    }
    reader.setBackgroundColor(Qt::white);
    QImage image = reader.read();
    if (image.isNull())
        return -1;
    if (image.hasAlphaChannel()) {
        // transparent pixels count as paper (white), not as black ink
        QImage flat(image.size(), QImage::Format_RGB32);
        flat.fill(Qt::white);
        QPainter painter(&flat);
        painter.drawImage(0, 0, image);
        painter.end();
        image = flat;
    }
    const QImage grey = image.convertToFormat(QImage::Format_Grayscale8);
    if (grey.isNull())
        return -1;
    sink(ctx, grey.constBits(), grey.width(), grey.height(),
         static_cast<int>(grey.bytesPerLine()));
    return count;
}
