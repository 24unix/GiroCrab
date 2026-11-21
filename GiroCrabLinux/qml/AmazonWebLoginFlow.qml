import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// AmazonUI.swift › AmazonWebSheet: the user signs in to amazon.de; same-origin `fetch` +
// `DOMParser` scripts inside the page read the order history (the page's own session
// cookies authenticate the requests, no credentials leave the web view) and the orders
// go to the core (`import_amazon_orders`).
WebLoginFlow {
    id: flow
    title: connection ? qsTr("%1 – Amazon-Konto").arg(AppModel.masking(connection.display_name)) : ""
    symbol: "shippingbox.fill"
    busy: running
    info: {
        if (running) return progress
        if (notice !== "") return notice
        if (browser.blockedHost !== "")
            return qsTr("Unsichere Seite blockiert (%1) – nur HTTPS-Seiten werden geöffnet.").arg(browser.blockedHost)
        if (pageIsOrders) return qsTr("Angemeldet – „Bestellungen abrufen“ liest Ihre Bestellhistorie.")
        return qsTr("Melden Sie sich bei Amazon an (Passwort, Captcha, 2FA wie gewohnt).")
    }

    property bool running: false
    property string progress: ""
    property string notice: ""
    /// Order details read so far / to read (determinate progress bar).
    property int done: 0
    property int total: 0
    /// Bumped by "Abrufen stoppen" / closing: a running scrape stops at its next step.
    property int generation: 0
    /// Signed in only when the page is an account/order page without any sign-in, 2FA
    /// or captcha form (URL hints alone miss Amazon's /ap/ verification pages).
    property bool pageIsOrders: false
    readonly property int years: [1, 2, 5, 25][yearsBox.currentIndex]
    readonly property string orderHistoryURL: "https://www.amazon.de/gp/css/order-history"

    readonly property string probe: `(function() {
  var p = location.pathname;
  if (p.indexOf('/ap/') === 0 || p.indexOf('/a/') === 0) return false;
  if (!/order-history|your-orders|\\/gp\\/css\\/|your-account/.test(p)) return false;
  return !document.querySelector('form[name="signIn"], #ap_password, #auth-mfa-form, input[name="otpCode"], input[name="code"], #auth-captcha-image');
})()`

    /// args: filter ("year-2025" / "months-3"). Returns {"codes":[…]} or {"error":"login"}.
    readonly property string orderCodesScript: `const re = new RegExp("[D\\\\d]\\\\d\\\\d-\\\\d{7}-\\\\d{7}");
const codes = [];
let url = "/your-orders/orders?timeFilter=" + encodeURIComponent(filter);
for (let page = 0; page < 60 && url; page++) {
  const r = await fetch(url, {credentials: "same-origin"});
  const html = await r.text();
  if (/ap\\/signin|name="signIn"/.test(r.url + html.slice(0, 20000))) return JSON.stringify({error: "login"});
  const doc = new DOMParser().parseFromString(html, "text/html");
  doc.querySelectorAll('div.order-card, [class*="order-card"]').forEach(function(card) {
    const m = re.exec(card.getAttribute("data-csa-c-slot-id") || "") || re.exec(card.innerHTML);
    if (m && codes.indexOf(m[0]) < 0) codes.push(m[0]);
  });
  const next = doc.querySelector("li.a-last a[href]");
  url = next ? next.getAttribute("href") : null;
}
return JSON.stringify({codes: codes});`

    /// args: code. Returns one order object understood by `amazon_orders::Order`.
    readonly property string orderDetailsScript: `const r = await fetch("/your-orders/order-details?orderID=" + encodeURIComponent(code), {credentials: "same-origin"});
const html = await r.text();
if (/ap\\/signin|name="signIn"/.test(r.url + html.slice(0, 20000))) return JSON.stringify({error: "login"});
const doc = new DOMParser().parseFromString(html, "text/html");
const root = doc.querySelector('div[id*="orderDetails"]') || doc.body;
const txt = function(n) { return n ? (n.textContent || "").replace(/\\s+/g, " ").trim() : ""; };
let date = txt(root.querySelector('[data-component="orderDate"]'));
if (!date) {
  const m = /\\d{1,2}\\.\\s*[A-Za-zÄÖÜäöüß]+\\s+\\d{4}|\\d{1,2}\\.\\d{1,2}\\.\\d{4}|[A-Z][a-z]+ \\d{1,2}, \\d{4}/.exec(txt(root));
  date = m ? m[0] : "";
}
const items = [];
root.querySelectorAll('[data-component="purchasedItemsRightGrid"]').forEach(function(it) {
  const title = txt(it.querySelector('[data-component="itemTitle"]'));
  const grid = it.closest(".a-fixed-left-grid-inner");
  const q = txt((grid && grid.querySelector(".od-item-view-qty")) || it.querySelector('[data-component="quantity"]'));
  const qm = /\\d+/.exec(q);
  // product link of the title (".../dp/<ASIN>"): kept apart from the title text (#354)
  const link = it.querySelector('a[href*="/dp/"]') || (grid || it).querySelector('a[href*="/dp/"]');
  const am = link ? /\\/dp\\/([A-Z0-9]{10})(?:[/?#]|$)/.exec(link.getAttribute("href") || "") : null;
  if (title) items.push({title: title, qty: qm ? parseInt(qm[0], 10) : 1, asin: am ? am[1] : ""});
});
const rows = [];
root.querySelectorAll(".od-line-item-row").forEach(function(row) {
  const label = txt(row.querySelector(".od-line-item-row-label"));
  const value = txt(row.querySelector(".od-line-item-row-content"));
  if (label && value) rows.push({label: label, value: value, bold: !!row.querySelector(".a-text-bold")});
});
const all = txt(root);
const cancelled = /wurde storniert|order was cancelled|Bestellung storniert/i.test(all) && !rows.some(function(x) { return /gesamtsumme|grand total/i.test(x.label); });
return JSON.stringify({code: code, date: date, items: items, rows: rows, cancelled: cancelled});`

    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            if (!flow.browser.onPortal) { flow.pageIsOrders = false; return }
            flow.browser.evaluate(flow.probe, flow.browser.appWorld, r => { if (flow.pageIsOrders !== (r === true)) flow.pageIsOrders = r === true })
        }
    }

    function close(success) {
        generation++
        if (success) AppModel.closeWebLogin()
        else AppModel.cancelWebLogin()
    }
    function cancel() { close(false) }

    // Errors of a scrape (AmazonError + cancellation).
    readonly property var cancelled: ({ amazon: "cancelled" })
    readonly property var loggedOut: ({ amazon: "loggedOut" })
    readonly property var noOrders: ({ amazon: "noOrders" })
    readonly property var unreadable: ({ amazon: "unreadable" })

    /// Own JS world: page scripts cannot replace fetch/DOMParser for the scraper.
    function run(script, args, gen) {
        if (gen !== generation) return Promise.reject(cancelled)
        // Checked before every call: the page may have navigated since "ready".
        if (!browser.onPortal) return Promise.reject(loggedOut)
        return browser.runAsync(script, args, browser.appWorld).then(s => {
            let o = null
            try { o = JSON.parse(s) } catch (e) {}
            if (!o || typeof o !== "object") throw unreadable
            if (o.error === "login") throw loggedOut
            return o
        }, e => { throw e === null ? loggedOut : e })
    }

    /// Order list (per year, newest first) -> order codes -> one detail page each.
    function scrape(gen) {
        const thisYear = new Date().getFullYear()
        let codes = [], emptyYears = 0
        const orders = []
        const year = y => {
            if (gen !== generation) return Promise.reject(cancelled)
            if (y >= years || (years > 5 && emptyYears >= 2)) return Promise.resolve()
            progress = qsTr("Bestellliste %1 …").arg(String(thisYear - y))
            return run(orderCodesScript, { filter: "year-" + (thisYear - y) }, gen).then(r => {
                const found = (r.codes || []).filter(c => codes.indexOf(c) < 0)
                codes = codes.concat(found)
                emptyYears = found.length ? 0 : emptyYears + 1
                return year(y + 1)
            })
        }
        const detail = i => {
            if (gen !== generation) return Promise.reject(cancelled)
            if (i >= codes.length) return Promise.resolve()
            done = i
            progress = qsTr("Bestellung %1 von %2 …").arg(i + 1).arg(codes.length)
            return run(orderDetailsScript, { code: codes[i] }, gen).then(o => { orders.push(o); return detail(i + 1) })
        }
        return year(0).then(() => {
            if (!codes.length) throw noOrders
            total = codes.length
            return detail(0)
        }).then(() => {
            done = codes.length
            return JSON.stringify({ orders: orders })
        })
    }

    function start() {
        running = true
        notice = ""
        done = 0
        total = 0
        const gen = ++generation
        scrape(gen).then(json => {
            running = false; total = 0
            if (AppModel.importAmazonOrders(connection, json)) close(true)
        }, e => {
            running = false; total = 0
            if (e === cancelled) {
                if (gen === generation - 1 && AppModel.webLoginConnection === connection) notice = qsTr("Abruf gestoppt – es wurde nichts übernommen.")
            } else if (e === loggedOut) {
                // Session expired (the page may just be a cached copy): show the sign-in page.
                notice = qsTr("Sitzung abgelaufen – bitte neu anmelden (Haken bei „Angemeldet bleiben“ setzen).")
                pageIsOrders = false
                browser.load(orderHistoryURL)
            } else {
                AppModel.errorTitle = qsTr("Amazon-Abruf fehlgeschlagen")
                AppModel.errorMessage = e === noOrders ? qsTr("Keine Bestellungen im gewählten Zeitraum gefunden.")
                    : e === unreadable ? qsTr("Amazon hat eine unerwartete Antwort geliefert.") : String(e)
            }
        })
    }

    Button { text: qsTr("Abbrechen"); onClicked: flow.close(false) }
    Text { text: qsTr("Zeitraum"); color: Theme.text; font.pixelSize: Theme.body; Layout.leftMargin: 8 }
    AppComboBox {
        id: yearsBox
        enabled: !flow.running
        currentIndex: 1
        model: [qsTr("Dieses Jahr"), qsTr("Letzte 2 Jahre"), qsTr("Letzte 5 Jahre"), qsTr("Alles")]
        implicitContentWidthPolicy: ComboBox.WidestText
        Accessible.name: qsTr("Zeitraum")
    }
    Item { Layout.fillWidth: true }
    ProgressBar {
        visible: flow.running && flow.total > 0
        Layout.preferredWidth: 160
        from: 0; to: Math.max(1, flow.total); value: flow.done
        Accessible.name: flow.progress
    }
    // HIG: a long task can be stopped without closing the window.
    Button { visible: flow.running; text: qsTr("Abrufen stoppen"); onClicked: flow.generation++ }
    Button {
        text: qsTr("Bestellungen abrufen")
        highlighted: true
        enabled: flow.pageIsOrders && !flow.running
        onClicked: flow.start()
    }
}
