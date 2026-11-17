// „Im Dateimanager anzeigen“ (DocumentsUI.swift › „Im Finder anzeigen“, #622): the
// counterpart of NSWorkspace.activateFileViewerSelecting. Asks the desktop's file manager
// (Dolphin, Nautilus, Nemo, Thunar, …) over the session bus to open the folder with the
// file selected: org.freedesktop.FileManager1.ShowItems. False when no file manager
// answers; the caller then opens the folder itself.
#include <QtCore/QStringList>
#include <QtCore/QUrl>
#include <QtDBus/QDBusConnection>
#include <QtDBus/QDBusMessage>

extern "C" bool girocrab_show_in_file_manager(const char *path)
{
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected())
        return false;
    QDBusMessage call = QDBusMessage::createMethodCall(
        QStringLiteral("org.freedesktop.FileManager1"),
        QStringLiteral("/org/freedesktop/FileManager1"),
        QStringLiteral("org.freedesktop.FileManager1"),
        QStringLiteral("ShowItems"));
    call << QStringList { QUrl::fromLocalFile(QString::fromUtf8(path)).toString() } << QString();
    // a short wait: the bus may have to start the file manager first
    const QDBusMessage reply = bus.call(call, QDBus::Block, 3000);
    return reply.type() == QDBusMessage::ReplyMessage;
}
