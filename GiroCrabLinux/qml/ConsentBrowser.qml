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
        let a, r
        try { a = new URL(u); r = new URL(redirect.trim()) } catch (e) { return false }
        if (a.hostname.toLowerCase() !== r.hostname.toLowerCase()) return false
        if (a.protocol !== "http:" && a.protocol !== "https:") return false
        const want = r.pathname || "/", have = a.pathname || "/"
        if (have !== want && have !== want + "/") return false
        return a.searchParams.has("code") || a.searchParams.has("error")
    }
    function finish(u) { if (done) return; done = true; log("redirect caught, back to GiroCrab", u); view.stop(); popupView.stop(); popup.visible = false; finished(u) }
    /// `--debug-consent`: every page, new window and load error of the consent flow on stderr –
    /// scheme, host and path only (no query: it carries codes and states).
    readonly property bool debug: AppModel.launchArgs.indexOf("--debug-consent") >= 0
    function log(what, u) {
        if (!debug) return
        let shown = String(u)
        // parameter names only, e.g. "(?code,state)" – never their values
        const q = shown.indexOf("?")
        const names = q < 0 ? "" : shown.slice(q + 1).split("&").map(p => p.split("=")[0]).join(",")
        shown = (q < 0 ? shown : shown.slice(0, q)) + (names ? " (?" + names + ")" : "")
        console.warn("consent:", what, shown)
    }

    WebEngineView {
        id: view
        anchors.fill: parent
        anchors.margins: 1
        profile: WebEngineProfile {
            offTheRecord: true
            // Plain Chrome user agent, like WebLoginSheet: banks (e.g. Revolut) end the
            // authorisation with an error when they see the "QtWebEngine/…" token
            Component.onCompleted: httpUserAgent = httpUserAgent.replace(/ QtWebEngine\/\S+/, "")
        }
        // the host sets `url` after creating this item (Loader.onLoaded): follow it
        Component.onCompleted: if (browser.url) url = browser.url
        Connections { target: browser; function onUrlChanged() { if (browser.url) view.url = browser.url } }
        // Links and server redirects: catch the redirect URL before it loads.
        onNavigationRequested: request => browser.navigation("main", request)
        // Fallback: the redirect failed to load (localhost isn't served).
        onLoadingChanged: info => browser.loading("main", info)
        // A new window (target=_blank, window.open): a real second view on top, so the page
        // that opened it stays alive – OAuth pages (Revolut) wait there for the approval.
        // The Mac loads it into the same view instead (GiroCrab/GiroCrab#289).
        onNewWindowRequested: request => {
            browser.log("new window", request.requestedUrl)
            popup.visible = true
            request.openIn(popupView)
        }
        onRenderProcessTerminated: (status, code) => browser.log("render process ended " + status + "/" + code, "")
    }
    function navigation(where, request) {
        const u = request.url.toString()
        log(where + " navigate", u)
        if (redirect && matches(u)) { request.reject(); finish(u) }
    }
    function loading(where, info) {
        const u = info.url.toString()
        if (info.status === WebEngineView.LoadFailedStatus) log(where + " load failed: " + info.errorString, u)
        else if (info.status === WebEngineView.LoadSucceededStatus) log(where + " loaded", u)
        if (info.status === WebEngineView.LoadFailedStatus && matches(u)) finish(u)
    }
    // the second window of the bank page; closes itself (window.close()) or with the button
    Rectangle {
        id: popup
        visible: false
        anchors.fill: parent
        anchors.margins: 24
        radius: 8
        color: Theme.card
        border.color: Theme.border
        z: 10
        WebEngineView {
            id: popupView
            anchors.fill: parent
            anchors.margins: 1
            anchors.topMargin: 30
            profile: view.profile   // same cookies and storage as the page that opened it
            onNavigationRequested: request => browser.navigation("popup", request)
            onLoadingChanged: info => browser.loading("popup", info)
            onNewWindowRequested: request => { browser.log("popup new window", request.requestedUrl); popupView.url = request.requestedUrl }
            onWindowCloseRequested: { browser.log("popup closed by page", ""); popup.visible = false }
        }
        IconButton {
            anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 4
            symbol: "xmark"; symbolSize: 12
            Accessible.name: qsTr("Schließen")
            onClicked: { popupView.stop(); popup.visible = false }
        }
    }
}
