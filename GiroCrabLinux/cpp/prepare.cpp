// Settings that must be in place before QGuiApplication exists: QtWebEngine
// (bank consent pages, portal logins) shares the OpenGL context with Qt Quick.
#include <QtCore/QCoreApplication>
#include <QtQml/qqmldebug.h>
#include <QtQuick/QQuickWindow>
#include <QtQuick/QSGRendererInterface>

extern "C" void girocrab_prepare_qt()
{
    QCoreApplication::setAttribute(Qt::AA_ShareOpenGLContexts);
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    // GIROCRAB_QML_PROFILE=1: allow Qt's QML profiler / debugger to attach
    // (`qmlprofiler -o trace.qtd -- girocrab`). Off by default: a debug server
    // must never be reachable in normal use.
    if (qEnvironmentVariableIsSet("GIROCRAB_QML_PROFILE"))
        QQmlDebuggingEnabler::enableDebugging(true);
}

#include <QtGui/QGuiApplication>
#include <QtGui/QImage>
#include <QtQuick/QQuickWindow>

// Screenshot.swift: the whole window, sheets and popups included (they live
// in the overlay layer, which Item::grabToImage does not see).
extern "C" bool girocrab_grab_window(const char *path)
{
    for (QWindow *w : QGuiApplication::topLevelWindows()) {
        if (auto *q = qobject_cast<QQuickWindow *>(w); q && q->isVisible())
            return q->grabWindow().save(QString::fromUtf8(path));
    }
    return false;
}

#include <QtWidgets/QApplication>
#include <QtGui/QIcon>
#include <QtGui/QStyleHints>

// A QApplication (not only QGuiApplication): the print dialog (QPrintDialog,
// printing.cpp) is a widget. argc/argv must outlive the application.
static int s_argc = 0;
extern "C" void girocrab_create_app(int argc, char **argv, const char *version)
{
    s_argc = argc;
    new QApplication(s_argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("GiroCrab"));
    QCoreApplication::setOrganizationName(QStringLiteral("GiroCrab"));
    QCoreApplication::setOrganizationDomain(QStringLiteral("girocrab.de"));
    QCoreApplication::setApplicationVersion(QString::fromUtf8(version));
    // Wayland: ties the window to de.girocrab.GiroCrab.desktop (icon, task bar entry)
    QGuiApplication::setDesktopFileName(QStringLiteral("de.girocrab.GiroCrab"));
    QGuiApplication::setWindowIcon(QIcon::fromTheme(QStringLiteral("de.girocrab.GiroCrab")));
    // LaunchOptions.swift `--dark` / `--light`: force the appearance (README screenshots).
    const QStringList args = QCoreApplication::arguments();
    // Qt Quick Controls get their palette from Theme.forcedPalette (the KDE colour
    // scheme does not follow this request).
    // QStyleHints::setColorScheme exists since Qt 6.8; before that Theme.qml alone forces it.
#if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
    if (args.contains(QStringLiteral("--dark")))
        QGuiApplication::styleHints()->setColorScheme(Qt::ColorScheme::Dark);
    else if (args.contains(QStringLiteral("--light")))
        QGuiApplication::styleHints()->setColorScheme(Qt::ColorScheme::Light);
#else
    Q_UNUSED(args);
#endif
}

extern "C" int girocrab_exec_app()
{
    return QApplication::exec();
}

// Called after the QML engine is gone: run the pending deleteLater()s while
// every plugin (Kirigami & co.) is still loaded, then delete the application.
// Left to the exit handlers, those deletions crash in libKirigamiPlatform.
extern "C" void girocrab_destroy_app()
{
    QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
    delete QCoreApplication::instance();
}

// Settings / Abruf-Protokoll / Hilfe are separate top-level windows:
// `--screenshot` with `--demo-settings` & co. grabs the one with this title.
extern "C" bool girocrab_grab_window_titled(const char *path, const char *title)
{
    const QString wanted = QString::fromUtf8(title);
    for (QWindow *w : QGuiApplication::topLevelWindows()) {
        if (auto *q = qobject_cast<QQuickWindow *>(w); q && q->isVisible() && q->title() == wanted)
            return q->grabWindow().save(QString::fromUtf8(path));
    }
    return false;
}

#include <QtCore/QMimeData>
#include <QtCore/QTimer>
#include <QtGui/QClipboard>

// VaultKeyManager.copyToPasteboard: the vault key leaves the clipboard after
// 60 s unless something else was copied meanwhile. Only plain text plus
// `x-kde-passwordManagerHint: secret`, so Klipper & co. keep no history of it
// (the counterpart of the concealed/transient pasteboard types on macOS).
extern "C" void girocrab_copy_secret(const char *text)
{
    QClipboard *cb = QGuiApplication::clipboard();
    const QString s = QString::fromUtf8(text);
    auto *data = new QMimeData;
    data->setText(s);
    data->setData(QStringLiteral("x-kde-passwordManagerHint"), QByteArrayLiteral("secret"));
    cb->setMimeData(data);
    QTimer::singleShot(60000, cb, [s]() {
        QClipboard *c = QGuiApplication::clipboard();
        if (c->text() == s)
            c->clear();
    });
}
