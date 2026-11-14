import QtQuick
import QtWebEngine

// ConsentBrowser.swift: the bank's consent page inside GiroCrab. Nothing is
// stored (off-the-record profile) and nothing is read from the pages; the view
// only waits for the jump to the redirect URL, stops it, and hands the address on.
Rectangle {
    id: browser
    property string url
    property string redirect
    property bool done: false
    signal finished(string result)
    radius: 8
    border.color: Theme.border
    clip: true

    /// ConsentRedirect.matches: same host and path, http/https, with `code` or `error`.
    function matches(u) {
        const a = new URL(u), r = new URL(redirect.trim())
        if (a.hostname.toLowerCase() !== r.hostname.toLowerCase()) return false
        if (a.protocol !== "http:" && a.protocol !== "https:") return false
        const want = r.pathname || "/", have = a.pathname || "/"
        if (have !== want && have !== want + "/") return false
        return a.searchParams.has("code") || a.searchParams.has("error")
    }
    function finish(u) { if (done) return; done = true; view.stop(); finished(u) }

    WebEngineView {
        id: view
        anchors.fill: parent
        anchors.margins: 1
        profile: WebEngineProfile { offTheRecord: true }
        Component.onCompleted: url = browser.url
        // Links and server redirects: catch the redirect URL before it loads.
        onNavigationRequested: request => {
            const u = request.url.toString()
            if (browser.redirect && browser.matches(u)) { request.reject(); browser.finish(u) }
        }
        // Fallback: the redirect failed to load (localhost isn't served).
        onLoadingChanged: info => {
            if (info.status === WebEngineView.LoadFailedStatus && browser.matches(info.url.toString())) browser.finish(info.url.toString())
        }
        // target=_blank: stay in this view.
        onNewWindowRequested: request => { view.url = request.requestedUrl }
    }
}
