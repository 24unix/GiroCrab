#include "webcookies.h"

#include <QtCore/QDateTime>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QUrl>
#include <QtGui/QGuiApplication>
#include <QtGui/QWindow>

#include <cstdlib>
#include <cstring>
#include <dlfcn.h>

namespace {

// Non-virtual member functions called through their exported symbols: the
// object pointer is the first argument (Itanium C++ ABI, x86_64 / aarch64).
using CookieStoreFn = QObject *(*)(const QObject *);
using LoadAllFn = void (*)(QObject *);
using DeleteFn = void (*)(QObject *, const QNetworkCookie &, const QUrl &);
using SetFn = void (*)(QObject *, const QNetworkCookie &, const QUrl &);

void *symbol(const char *library, const char *name)
{
    // RTLD_NOLOAD: only a library the QML module QtWebEngine has loaded already.
    void *handle = dlopen(library, RTLD_LAZY | RTLD_NOLOAD);
    return handle ? dlsym(handle, name) : nullptr;
}

bool sameCookie(const QNetworkCookie &a, const QNetworkCookie &b)
{
    return a.name() == b.name() && a.domain() == b.domain() && a.path() == b.path();
}

QObject *findProfile()
{
    for (QWindow *w : QGuiApplication::allWindows()) {
        if (auto *p = w->findChild<QObject *>(QStringLiteral("girocrabWebProfile"));
            p && p->inherits("QQuickWebEngineProfile"))
            return p;
    }
    return nullptr;
}

} // namespace

WebCookieTracker &WebCookieTracker::instance()
{
    static WebCookieTracker tracker;
    return tracker;
}

bool WebCookieTracker::attach()
{
    QObject *profile = findProfile();
    if (!profile)
        return false;
    auto cookieStore = reinterpret_cast<CookieStoreFn>(
        symbol("libQt6WebEngineQuick.so.6", "_ZNK22QQuickWebEngineProfile11cookieStoreEv"));
    if (!cookieStore)
        return false;
    QObject *store = cookieStore(profile);
    if (!store)
        return false;
    if (store == m_store)
        return true;
    if (m_store)
        m_store->disconnect(this);
    m_store = store;
    m_cookies.clear();
    connect(store, SIGNAL(cookieAdded(QNetworkCookie)), this, SLOT(onAdded(QNetworkCookie)));
    connect(store, SIGNAL(cookieRemoved(QNetworkCookie)), this, SLOT(onRemoved(QNetworkCookie)));
    if (auto loadAll = reinterpret_cast<LoadAllFn>(
            symbol("libQt6WebEngineCore.so.6", "_ZN21QWebEngineCookieStore14loadAllCookiesEv")))
        loadAll(store);
    return true;
}

void WebCookieTracker::remove(const QNetworkCookie &cookie)
{
    if (!m_store)
        return;
    auto deleteCookie = reinterpret_cast<DeleteFn>(symbol(
        "libQt6WebEngineCore.so.6", "_ZN21QWebEngineCookieStore12deleteCookieERK14QNetworkCookieRK4QUrl"));
    if (deleteCookie)
        deleteCookie(m_store, cookie, QUrl());
    onRemoved(cookie);
}

void WebCookieTracker::set(const QNetworkCookie &cookie, const QUrl &origin,
                           void (*setCookie)(QObject *, const QNetworkCookie &, const QUrl &))
{
    if (!m_store)
        return;
    setCookie(m_store, cookie, origin);
    // known at once (the store reports it asynchronously)
    onAdded(cookie);
}

void WebCookieTracker::onAdded(const QNetworkCookie &cookie)
{
    onRemoved(cookie);
    m_cookies.append(cookie);
}

void WebCookieTracker::onRemoved(const QNetworkCookie &cookie)
{
    m_cookies.removeIf([&](const QNetworkCookie &c) { return sameCookie(c, cookie); });
}

extern "C" bool girocrab_web_attach()
{
    return WebCookieTracker::instance().attach();
}

namespace {
QString sameSiteName(QNetworkCookie::SameSite s)
{
    switch (s) {
    case QNetworkCookie::SameSite::None: return QStringLiteral("None");
    case QNetworkCookie::SameSite::Lax: return QStringLiteral("Lax");
    case QNetworkCookie::SameSite::Strict: return QStringLiteral("Strict");
    default: return QStringLiteral("Default");
    }
}
} // namespace

/// `[{domain, name, value, path, expiry (Unix s or null), secure, http_only, same_site}]`
/// of the profile's cookies; free with girocrab_web_free.
extern "C" char *girocrab_web_cookies_json()
{
    QJsonArray list;
    for (const QNetworkCookie &c : WebCookieTracker::instance().cookies()) {
        list.append(QJsonObject{
            {QStringLiteral("domain"), c.domain()},
            {QStringLiteral("name"), QString::fromUtf8(c.name())},
            {QStringLiteral("value"), QString::fromUtf8(c.value())},
            {QStringLiteral("path"), c.path()},
            {QStringLiteral("expiry"), c.isSessionCookie() ? QJsonValue() : QJsonValue(c.expirationDate().toSecsSinceEpoch())},
            {QStringLiteral("secure"), c.isSecure()},
            {QStringLiteral("http_only"), c.isHttpOnly()},
            {QStringLiteral("same_site"), sameSiteName(c.sameSitePolicy())},
        });
    }
    return strdup(QJsonDocument(list).toJson(QJsonDocument::Compact).constData());
}

/// Puts one cookie (JSON as above) into the browser profile: the session restored
/// from the vault. The origin is https://<domain><path>, so secure cookies are accepted.
extern "C" bool girocrab_web_set_cookie(const char *json)
{
    auto &tracker = WebCookieTracker::instance();
    if (!tracker.attach())
        return false;
    const QJsonObject o = QJsonDocument::fromJson(QByteArray(json)).object();
    QNetworkCookie c(o.value(QStringLiteral("name")).toString().toUtf8(),
                     o.value(QStringLiteral("value")).toString().toUtf8());
    const QString domain = o.value(QStringLiteral("domain")).toString();
    QString path = o.value(QStringLiteral("path")).toString();
    if (path.isEmpty())
        path = QStringLiteral("/");
    c.setDomain(domain);
    c.setPath(path);
    if (o.value(QStringLiteral("expiry")).isDouble())
        c.setExpirationDate(QDateTime::fromSecsSinceEpoch(qint64(o.value(QStringLiteral("expiry")).toDouble())));
    c.setSecure(o.value(QStringLiteral("secure")).toBool());
    c.setHttpOnly(o.value(QStringLiteral("http_only")).toBool());
    const QString ss = o.value(QStringLiteral("same_site")).toString();
    c.setSameSitePolicy(ss == QLatin1String("None") ? QNetworkCookie::SameSite::None
                        : ss == QLatin1String("Lax") ? QNetworkCookie::SameSite::Lax
                        : ss == QLatin1String("Strict") ? QNetworkCookie::SameSite::Strict
                                                         : QNetworkCookie::SameSite::Default);
    const QString host = domain.startsWith(QLatin1Char('.')) ? domain.mid(1) : domain;
    const QUrl origin(QStringLiteral("https://") + host + path);
    if (c.name().isEmpty() || host.isEmpty() || !origin.isValid())
        return false;
    auto setCookie = reinterpret_cast<SetFn>(symbol(
        "libQt6WebEngineCore.so.6", "_ZN21QWebEngineCookieStore9setCookieERK14QNetworkCookieRK4QUrl"));
    if (!setCookie)
        return false;
    tracker.set(c, origin, setCookie);
    return true;
}

extern "C" void girocrab_web_free(char *s)
{
    if (s) {
        // session cookies: do not leave them in freed memory
        std::memset(s, 0, std::strlen(s));
        std::free(s);
    }
}

extern "C" void girocrab_web_delete_cookie(const char *domain, const char *name, const char *path)
{
    auto &tracker = WebCookieTracker::instance();
    const QString d = QString::fromUtf8(domain), p = QString::fromUtf8(path);
    const QByteArray n(name);
    const QList<QNetworkCookie> all = tracker.cookies();
    for (const QNetworkCookie &c : all) {
        if (c.domain() == d && c.name() == n && c.path() == p)
            tracker.remove(c);
    }
}
