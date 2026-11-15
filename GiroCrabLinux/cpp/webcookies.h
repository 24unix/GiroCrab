// Cookie store of the web-login browser profile (WebLoginSheet.qml).
//
// ConnectionsUI.swift › WebLoginSheet reads the `tr_session` cookie from
// WKWebsiteDataStore; on Linux the cookies live in the QtWebEngine profile.
// QtWebEngine stays optional at runtime: nothing here links against it. The
// two non-invokable calls it needs (`QQuickWebEngineProfile::cookieStore()`,
// `QWebEngineCookieStore::loadAllCookies()` / `deleteCookie()`) are looked up
// in the already loaded libraries, the signals are connected by name.
#pragma once

#include <QtCore/QList>
#include <QtCore/QObject>
#include <QtCore/QPointer>
#include <QtCore/QUrl>
#include <QtNetwork/QNetworkCookie>

class WebCookieTracker : public QObject
{
    Q_OBJECT
public:
    static WebCookieTracker &instance();
    /// Finds the profile (objectName `girocrabWebProfile`) and follows its cookie store.
    bool attach();
    /// Cookies seen in the store (memory only, the profile is off the record).
    const QList<QNetworkCookie> &cookies() const { return m_cookies; }
    /// Deletes one cookie from the browser profile.
    void remove(const QNetworkCookie &cookie);
    /// Puts a cookie into the browser profile (`setCookie` is passed in, see webcookies.cpp).
    void set(const QNetworkCookie &cookie, const QUrl &origin,
             void (*setCookie)(QObject *, const QNetworkCookie &, const QUrl &));

public Q_SLOTS:
    void onAdded(const QNetworkCookie &cookie);
    void onRemoved(const QNetworkCookie &cookie);

private:
    QPointer<QObject> m_store;
    QList<QNetworkCookie> m_cookies;
};
