import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtCore

// PortalUI.swift › PortalWebSheet (American Express, Amazon Visa): the user signs in to
// the card portal; the portal's own JSON responses (captured by the traffic hook) or the
// visible booking table are handed to the core (`import_portal_capture`). Recognised
// bookings are counted live; the import starts by itself once the count is stable.
WebLoginFlow {
    id: flow
    title: connection ? qsTr("%1 – Direkt-Login").arg(connection.display_name) : ""
    captureTraffic: true
    badgeText: qsTr("Erkannte Umsätze: %1").arg(recognized)
    badgeSymbol: recognized > 0 ? "checkmark.circle.fill" : "circle.dashed"
    badgeColor: recognized > 0 ? Theme.inflow : Theme.secondary
    busy: importing
    info: {
        if (browser.blockedHost !== "")
            return qsTr("Unsichere Seite blockiert (%1) – nur HTTPS-Seiten werden geöffnet.").arg(browser.blockedHost)
        if (browser.onLoginPage) return qsTr("Melden Sie sich wie gewohnt an (Benutzername, Passwort, 2FA) und öffnen Sie die Umsatzübersicht.")
        if (importedCount > 0 && olderOffered)
            return qsTr("%1 Umsätze übernommen. Für ältere Umsätze im Portal „Umsätze anzeigen“ wählen und den SMS-Code bestätigen – die Übernahme läuft danach automatisch weiter.").arg(importedCount)
        if (importedCount > 0) return qsTr("%1 Umsätze übernommen – weitere werden geladen …").arg(importedCount)
        if (recognized === 0) return qsTr("Angemeldet – öffnen Sie die Umsatzübersicht, damit das Portal die Buchungen lädt.")
        return qsTr("%1 Umsätze erkannt – Übernahme startet automatisch, sobald die Seite fertig geladen ist.").arg(recognized)
    }

    readonly property string kind: connection ? connection.connector : ""
    property var bodies: []
    property var seenPaths: []
    property int recognized: 0
    property real lastChange: Date.now()
    property int lastSeenCount: 0
    /// Bookings stored so far while the sheet stays open for older history.
    property int importedCount: 0
    /// The portal offers older history ("Umsätze anzeigen" + SMS code).
    property bool olderOffered: false
    /// The booking list was opened after sign-in (only once, so the user may browse freely).
    property bool openedTransactions: false
    /// Labels logged once at the end of the list (to adapt to portal changes).
    property bool loggedLabels: false
    property bool importing: false
    property bool ticking: false
    property bool finished: false

    /// The older history (SMS code) is offered once per connection; later syncs close on their own.
    Settings { id: portalDefaults; category: "portal" }
    readonly property string historyOfferedKey: connection ? "historyOffered." + connection.id : ""

    /// URL paths that may carry bookings/balances; other JSON (config, i18n, tracking)
    /// is only kept as a path.
    readonly property var relevantURLWords: ["transaction", "activity", "balance", "account", "statement", "card", "umsa", "booking",
                                             "posting", "movement", "movimiento", "operation", "history", "contract", "product", "position"]
    /// Customer profile / login endpoints: never handed to the parser.
    readonly property var privateURLWords: ["customer", "profile", "personal", "authentication", "authorize", "login", "kyc"]

    function captured(body, url) {
        seenPaths.push(maskedPath(url))
        if (seenPaths.length > 200) seenPaths.splice(0, seenPaths.length - 200)
        const lower = url.toLowerCase()
        if (!relevantURLWords.some(w => lower.indexOf(w) >= 0) || privateURLWords.some(w => lower.indexOf(w) >= 0)) return
        bodies.push(body)
        // room for a long history paged in with "mehr anzeigen" (≈20 bookings per page)
        if (bodies.length > 300) bodies.splice(0, bodies.length - 300)
    }
    /// Host + path without query, digits masked – no ids or card numbers.
    function maskedPath(url) {
        const u = browser.urlParts(url)
        const s = u ? u.hostname + u.pathname : url.slice(0, 120)
        return s.replace(/[0-9]/g, "9")
    }

    readonly property string domRowsScript: `(function(){ var rows = [];
  document.querySelectorAll('tr,[role=\"row\"]').forEach(function(r) { var cells = [];
    r.querySelectorAll('td,th,[role=\"cell\"],[role=\"gridcell\"]').forEach(function(c) {
      var t = (c.innerText || '').trim().replace(/\\s+/g, ' '); if (t) cells.push(t); });
    if (cells.length >= 2) rows.push(cells); });
  return JSON.stringify(rows); })()`
    function domRows(done) {
        if (!browser.onPortal) { done("[]"); return }
        browser.evaluate(domRowsScript, browser.mainWorld, r => done(typeof r === "string" ? r : "[]"))
    }

    /// Paging buttons of the Amazon Visa (Open Bank) transaction list: "mehr anzeigen"
    /// loads the next page (clicked when `clickMore`), "Umsätze anzeigen" unlocks history
    /// older than ~3 months behind an SMS code (left to the user).
    function pagerScript(clickMore) {
        return `(function(){
  var vis = function(e){ var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  var label = function(b){ return (b.innerText || b.getAttribute('aria-label') || '').trim().replace(/\\s+/g, ' '); };
  var buttons = Array.prototype.filter.call(document.querySelectorAll('button,a,[role=button]'),
    function(b){ var t = label(b); return vis(b) && !b.disabled && t && t.length <= 40; });
  var more = buttons.find(function(b){ return /^(mehr|weitere) (anzeigen|laden)$/i.test(label(b)); });
  var older = buttons.find(function(b){ return /umsätze anzeigen|ältere umsätze|alle umsätze/i.test(label(b)); });
  if (more && ${clickMore ? "true" : "false"}) more.click();
  var labels = buttons.map(function(b){ return label(b).replace(/[0-9]/g, '9'); })
    .filter(function(t, i, a){ return a.indexOf(t) === i; }).slice(0, 25);
  return JSON.stringify({more: !!more, older: !!older, labels: labels});
})()`
    }
    function pager(clickMore, done) {
        browser.evaluate(pagerScript(clickMore), browser.mainWorld, r => {
            let p = { more: false, older: false, labels: [] }
            try { p = Object.assign(p, JSON.parse(r)) } catch (e) {}
            done(p)
        })
    }

    // Count recognised bookings live; auto-import only when >= 1 booking is recognised,
    // the user is past login/2FA and the count has been stable for 4 s.
    Timer {
        interval: 1500
        repeat: true
        running: !flow.finished
        onTriggered: flow.tick()
    }
    function tick() {
        if (ticking || importing || finished) return
        ticking = true
        browser.drainCaptures(() => {
            const away = browser.onLoginPage || !browser.onPortal
            // the sheet may have moved on to another login meanwhile (this flow is gone then)
            const preview = rows => AppModel.previewPortalCapture(connection, bodies, rows, n => { if (flow && typeof flow.afterPreview === "function") flow.afterPreview(n, away) })
            if (away) preview("[]")
            else domRows(preview)
        })
    }
    function afterPreview(n, away) {
        if (finished) return
        if (n !== lastSeenCount || n !== recognized) { lastSeenCount = n; lastChange = Date.now() }
        recognized = n
        const list = AppModel.portalTransactionsURL(kind)
        const here = browser.urlParts(browser.currentURL)
        if (!openedTransactions && !browser.onLoginPage && !browser.loading && list && here && here.hostname === new URL(list).hostname) {
            openedTransactions = true
            if (here.pathname !== new URL(list).pathname) browser.load(list)
        }
        // Amazon Visa lists ~20 bookings per page: keep paging until the end.
        if (kind === "AmazonVisa" && !away) pager(!browser.loading, p => afterPager(n, away, p))
        else afterPager(n, away, { more: false, older: false, labels: [] })
    }
    function afterPager(n, away, p) {
        if (kind === "AmazonVisa" && !away) {
            olderOffered = p.older
            if (p.more) lastChange = Date.now()
            if (!p.more && n > 0 && !loggedLabels) {
                loggedLabels = true
                console.info("portal pager: older=" + p.older + " buttons=" + p.labels.join(" | "))
            }
        }
        if (n > importedCount && !away && !p.more && Date.now() - lastChange > 4000) {
            // First sync with older history on offer: store what is there, but keep the
            // sheet open so the user can unlock the rest (SMS code).
            const keepOpen = p.older && importedCount === 0 && !portalDefaults.value(historyOfferedKey, false)
            attempt(!keepOpen, ok => {
                if (ok && keepOpen) importedCount = n
                ticking = false
            })
            return
        }
        ticking = false
    }

    function attempt(closing, done) {
        importing = true
        domRows(rows => {
            const ok = AppModel.importPortalCapture(connection, bodies, rows)
            importing = false
            if (ok && closing) close(true)
            if (done) done(ok)
        })
    }

    function close(success) {
        if (finished) return
        finished = true
        if (importedCount > 0) portalDefaults.setValue(historyOfferedKey, true)
        // Nothing taken over: in a batch this login counts as skipped.
        if (success || importedCount > 0) AppModel.closeWebLogin()
        else AppModel.cancelWebLogin()
    }
    function cancel() { close(false) }

    FileDialog {
        id: statementDialog
        title: qsTr("CSV- oder PDF-Kontoauszug importieren …")
        nameFilters: [qsTr("Kontoauszüge (*.csv *.txt *.pdf)"), qsTr("Alle Dateien (*)")]
        currentFolder: StandardPaths.writableLocation(StandardPaths.DownloadLocation)
        onAccepted: { AppModel.importStatement(flow.connection, selectedFile); flow.close(true) }
    }

    Button { text: flow.importedCount > 0 ? qsTr("Fertig") : qsTr("Abbrechen"); onClicked: flow.close(false) }
    IconButton { symbol: "doc.badge.plus"; text: qsTr("CSV- oder PDF-Kontoauszug importieren …"); tint: Theme.accent; onClicked: statementDialog.open() }
    Item { Layout.fillWidth: true }
    Button {
        text: qsTr("Umsätze übernehmen (%1 erkannt)").arg(flow.recognized)
        highlighted: true
        enabled: !flow.importing && flow.recognized > 0
        onClicked: flow.attempt(true)
    }
}
