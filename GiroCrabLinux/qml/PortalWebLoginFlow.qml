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
        if (openHolds.length > 0 && importedCount > 0)
            return qsTr("%1 Umsätze übernommen. %2 vorgemerkte Umsätze sind nicht mehr offen, ihre Buchung wurde aber noch nicht gefunden. Öffnen Sie im Portal den vorherigen Abrechnungszeitraum.").arg(importedCount).arg(openHolds.length)
        if (openHolds.length > 0)
            return qsTr("%1 vorgemerkte Umsätze sind nicht mehr offen, ihre Buchung wurde aber noch nicht gefunden. Öffnen Sie im Portal den vorherigen Abrechnungszeitraum.").arg(openHolds.length)
        if (holdsToCheck > 0)
            return qsTr("%1 vorgemerkte Umsätze sind nicht mehr offen. „Umsätze übernehmen“ gleicht sie mit den Buchungen ab – liegt eine Buchung in einem früheren Abrechnungszeitraum, öffnen Sie diesen vorher im Portal.").arg(holdsToCheck)
        if (browsingHistory)
            return qsTr("Öffnen Sie im Portal frühere Abrechnungszeiträume. „Umsätze übernehmen“ übernimmt alle erkannten Umsätze und schließt das Fenster.")
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
    /// ConnectorKind.portalHasBillingPeriods (#629): the portal shows one billing period at a
    /// time; older ones are picked in the portal itself while the sheet stays open.
    readonly property bool hasBillingPeriods: kind === "AmericanExpress"
    /// The user browses older billing periods: no automatic import, the blue button imports
    /// everything recognised and closes. Bookings are only stored on closing.
    property bool browsingHistory: false
    /// Pending charges no longer open whose posting is not among the captured pages ([PortalHold]).
    property var openHolds: []
    /// Stored pending charges the portal no longer lists, found before importing: they are
    /// matched on the blue button, so the automatic import (which closes) stays off.
    property int holdsToCheck: 0
    // Billing-period portals: the first sync of a connection offers the older periods.
    Component.onCompleted: if (hasBillingPeriods && !portalDefaults.value(historyOfferedKey, false)) browsingHistory = true

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
        // Never while browsing older periods: the automatic import closes the sheet.
        if (!browsingHistory && n > importedCount && !away && !p.more && Date.now() - lastChange > 4000) {
            // The automatic import closes the sheet, so it never runs while stored pending
            // charges are no longer listed: they are matched (or discarded) via the button.
            openHoldsNow(unlisted => {
                if (finished) return
                if (unlisted.length) {
                    holdsToCheck = unlisted.length
                    browsingHistory = true
                    ticking = false
                    return
                }
                // First sync with older history on offer: store what is there, but keep the
                // sheet open so the user can unlock the rest (SMS code).
                const firstSync = importedCount === 0 && !portalDefaults.value(historyOfferedKey, false)
                const keepOpen = p.older && firstSync
                attempt(!keepOpen, false, ok => {
                    if (ok && (keepOpen || openHolds.length)) importedCount = n
                    ticking = false
                })
            })
            return
        }
        ticking = false
    }

    /// AppModel.portalOpenHolds: off the GUI thread; [] on failure.
    function openHoldsNow(done) {
        AppModel.coreAsync("portal_open_holds", { connection_id: connection.id, json_bodies: bodies },
                           h => done(h || []), () => done([]))
    }

    /// Imports what is recognised and closes. Unresolved pending charges (#629) keep the
    /// sheet open in history mode: from the button with the discard warning right away,
    /// from the automatic import with the hint only.
    function attempt(closing, fromButton, done) {
        importing = true
        domRows(rows => {
            const ok = AppModel.importPortalCapture(connection, bodies, rows)
            if (!ok) { importing = false; if (done) done(false); return }
            importedCount = Math.max(importedCount, recognized)
            holdsToCheck = 0
            openHoldsNow(holds => {
                importing = false
                if (finished) return
                openHolds = holds
                if (holds.length) {
                    // its posting may be in an older billing period
                    browsingHistory = true
                    if (fromButton) confirmDiscard.open()
                } else if (closing) close(true)
                if (done) done(true)
            })
        })
    }

    /// Closing with unresolved pending charges asks first: they would be discarded.
    function requestClose() {
        if (openHolds.length === 0) close(false); else confirmDiscard.open()
    }
    /// discardMessage (an alert on the Mac, never part of a bug report picture)
    readonly property string discardMessage: qsTr("Zu diesen Vormerkungen wurde weder ein offener noch ein gebuchter Umsatz gefunden. Sie werden verworfen:")
        + "\n\n" + openHolds.map(h => Fmt.medium(h.booking_date) + " · " + h.counterparty + " · " + Fmt.money(h.amount_cents)).join("\n")
    ConfirmDialog {
        id: confirmDiscard
        heading: qsTr("Vorgemerkte Umsätze nicht gefunden")
        message: flow.discardMessage
        actionTitle: qsTr("Verwerfen und schließen")
        // "Weiter suchen" is the cancel button of the Mac's alert
        cancelTitle: qsTr("Weiter suchen")
        onConfirmed: {
            AppModel.coreAsync("discard_portal_holds", { connection_id: flow.connection.id, ids: flow.openHolds.map(h => h.id) }, () => {
                AppModel.reloadAll()
                flow.close(true)
            }, err => {
                AppModel.errorTitle = qsTr("Vormerkungen konnten nicht verworfen werden")
                AppModel.errorMessage = AppModel.parseCoreError(err).message
                flow.close(true)
            })
        }
    }

    function close(success) {
        if (finished) return
        finished = true
        if (importedCount > 0) portalDefaults.setValue(historyOfferedKey, true)
        // Nothing taken over: in a batch this login counts as skipped.
        if (success || importedCount > 0) AppModel.closeWebLogin()
        else AppModel.cancelWebLogin()
    }
    function cancel() { requestClose() }

    FileDialog {
        id: statementDialog
        title: qsTr("CSV- oder PDF-Kontoauszug importieren …")
        nameFilters: [qsTr("Kontoauszüge (*.csv *.txt *.pdf)"), qsTr("Alle Dateien (*)")]
        currentFolder: StandardPaths.writableLocation(StandardPaths.DownloadLocation)
        onAccepted: { AppModel.importStatement(flow.connection, selectedFile); flow.close(true) }
    }

    Button { text: flow.importedCount > 0 ? qsTr("Fertig") : qsTr("Abbrechen"); onClicked: flow.requestClose() }
    IconButton {
        visible: flow.hasBillingPeriods && !flow.browsingHistory
        symbol: "clock.arrow.circlepath"; text: qsTr("Ältere Abrechnungen laden"); tint: Theme.accent
        onClicked: flow.browsingHistory = true
        ToolTip.text: qsTr("Lässt dieses Fenster offen, damit Sie im Portal frühere Abrechnungszeiträume öffnen können.")
    }
    IconButton { symbol: "doc.badge.plus"; text: qsTr("CSV- oder PDF-Kontoauszug importieren …"); tint: Theme.accent; onClicked: statementDialog.open() }
    Item { Layout.fillWidth: true }
    Button {
        text: qsTr("Umsätze übernehmen (%1 erkannt)").arg(flow.recognized)
        highlighted: true
        enabled: !flow.importing && flow.recognized > 0
        onClicked: flow.attempt(true, true)
    }
}
