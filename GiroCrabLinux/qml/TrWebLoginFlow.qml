import QtQuick
import QtQuick.Layouts

// ConnectionsUI.swift › WebLoginSheet: app.traderepublic.com/login in the embedded
// browser (it passes the AWS WAF). As soon as a new `tr_session` cookie shows up, the
// Trade Republic cookies go to the core (src/web_login.rs › apply_web_session), which
// then opens the WebSocket.
WebLoginFlow {
    id: flow
    title: qsTr("Trade Republic – Anmeldung im Browser-Fenster")
    info: qsTr("Melden Sie sich wie gewohnt an (Telefonnummer, PIN, Code aus der App).")
    showBatchProgress: true
    badgeText: found ? qsTr("Sitzung gefunden") : ""
    badgeSymbol: "checkmark.seal.fill"
    badgeColor: Theme.inflow
    busy: !found
    // TRWebView: a plain web view without the portal's navigation guard
    navigationGuard: false
    readyToLoad: false
    property bool found: false

    // "Alle abrufen": cancelling skips this login (see SyncPromptButtons)
    function cancel() { AppModel.cancelWebLogin() }
    function apply() { applyTimer.stop(); AppModel.applyBrowserSession(connection) }

    // A session cookie left from an earlier (expired) login would be taken over at
    // once, rejected by Trade Republic and bring this sheet back in a loop: drop it
    // before the login page loads.
    Component.onCompleted: {
        try { AppModel.core("web_attach") } catch (e) {}
        AppModel.clearTradeRepublicWebData(true)
        storeCleared.start()
    }
    Timer { id: storeCleared; interval: 300; onTriggered: flow.readyToLoad = true }

    // Poll the cookie store until a new tr_session shows up.
    Timer {
        interval: 1000
        repeat: true
        running: flow.readyToLoad && !flow.found
        onTriggered: flow.check()
    }
    function check() {
        let has = false
        try { has = AppModel.core("web_has_cookie", { domains: AppModel.portalHosts("TradeRepublic"), name: "tr_session" }) } catch (e) {}
        if (!has || found) return
        found = true
        // Last automatic hand-over per login: if the core rejects a fresh session right
        // away, the sheet comes back – then the user decides (no loop).
        const last = browser.lastAutoApply[connection.id]
        if (last && Date.now() - last < 120000) {
            info = qsTr("Sitzung gefunden – bitte „Sitzung übernehmen“ wählen.")
            return
        }
        browser.lastAutoApply[connection.id] = Date.now()
        info = qsTr("Angemeldet – Sitzung wird übernommen …")
        applyTimer.start()
    }
    Timer { id: applyTimer; interval: 800; onTriggered: flow.apply() }

    /// TRWebCoordinator: pre-fills the saved +49… phone number into Trade Republic's own
    /// form (React-controlled input: native value setter + input event), retrying while
    /// the single-page app renders.
    function pageLoaded(url) {
        const phone = connection ? connection.login_name : ""
        const u = browser.urlParts(url)
        if (!phone || !u || u.protocol !== "https:" || !AppModel.domainAllows(AppModel.portalHosts("TradeRepublic"), u.hostname)) return
        browser.evaluate("(function fill(tries) {"
            + "var el = document.querySelector('input[type=\"tel\"], input[autocomplete=\"tel\"], input[name*=\"phone\" i], input[id*=\"phone\" i]');"
            + "if (!el) { if (tries > 0) setTimeout(function(){ fill(tries - 1); }, 500); return; }"
            + "var v = " + JSON.stringify(phone) + ";"
            + "if (el.maxLength > 0 && el.maxLength < v.length && v.startsWith('+49')) v = v.substring(3);"
            + "var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;"
            + "setter.call(el, v);"
            + "el.dispatchEvent(new Event('input', { bubbles: true }));"
            + "el.dispatchEvent(new Event('change', { bubbles: true }));"
            + "})(20);", browser.mainWorld)
    }

    SyncPromptButtons {
        Layout.fillWidth: true
        defaultTitle: qsTr("Sitzung übernehmen")
        defaultEnabled: flow.found
        onCancel: flow.cancel()
        onAccept: flow.apply()
    }
}
