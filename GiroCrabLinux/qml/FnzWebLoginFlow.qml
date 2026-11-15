import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// FnzUI.swift › FnzWebSheet: the user signs in to portal.fnz.de (FNZsecure); FNZ's own
// authenticated portal calls, run inside the page, fetch the account overview and the
// postbox PDFs for the core (`import_fnz_overview`, `pending_fnz_documents`,
// `import_fnz_document`).
WebLoginFlow {
    id: flow
    title: connection ? qsTr("%1 – FNZ Bank").arg(connection.display_name) : ""
    busy: running
    infoWarning: !running && (notice !== "" || browser.blockedHost !== "")
    info: {
        if (running) return progress
        if (notice !== "") return notice
        if (browser.blockedHost !== "")
            return qsTr("Unsichere Seite blockiert (%1) – nur HTTPS-Seiten werden geöffnet.").arg(browser.blockedHost)
        if (ready) return qsTr("Angemeldet – Kontosalden, Depotwerte und Postkorb können abgerufen werden.")
        return qsTr("Melden Sie sich bei FNZ an und bestätigen Sie in FNZsecure.")
    }

    property bool ready: false
    property bool running: false
    property string progress: ""
    property string notice: ""
    property int generation: 0
    readonly property string unreadable: qsTr("FNZ: Die Portalantwort konnte nicht gelesen werden.")
    readonly property var cancelled: ({ fnz: "cancelled" })

    readonly property string probe: `(() => {
  if (location.hostname !== 'portal.fnz.de' || !/\\/EOY\\/EL\\//.test(location.pathname)
    || !/#\\/eo\\//.test(location.hash)) return false;
  const text = document.body?.innerText || '';
  // The compact layout hides "Abmelden" inside the hamburger menu.
  // Account/depot detail links also prove the overview has finished loading.
  const signedIn = /Logout|Abmelden/i.test(text)
    || !!document.querySelector('a[href*="/services/logout"]')
    || !!document.querySelector('a[href*="#/eo/bestand/"]');
  return signedIn && /Gesamtbestand|Postkorb|Depot/i.test(text);
})()`

    readonly property string overviewScript: `const r = await fetch(location.origin + location.pathname + 'eox/rest/depot/getDepotOverviewDataForEndCustomer', {
  credentials: 'include', headers: {'Accept':'application/json', 'X-EOX-Session':'',
    'X-EOX-CLIENT-VERSION':'26.4.01', 'X-Context-ID':crypto.randomUUID()}
});
if (!r.ok) throw new Error('FNZ: Kontoübersicht nicht abrufbar (HTTP ' + r.status + '). Bitte erneut anmelden.');
const data = await r.json();
if (!Array.isArray(data.ownerGroups)) throw new Error('FNZ: Keine Kontoübersicht erkannt. Bitte erneut anmelden.');
return JSON.stringify(data);`

    readonly property string documentsScript: `const base = location.origin + location.pathname;
const dateTo = new Date().toISOString().slice(0, 19);
const all = [];
for (const archived of [false, true]) {
  let from = 0;
  const pageIds = new Set();
  for (;;) {
    const body = {postboxCategoryAndStateFilter:{dateFrom:'2000-01-01T00:00:00', dateTo,
      category:null, onlyUnread:false, onlyFavoured:false, archived}, postboxDepotFilter:null,
      indexFrom:String(from), indexTo:String(from + 100)};
    const r = await fetch(base + 'eox/rest/postbox/getCustomerPostboxForCustomer', {
      method:'POST', credentials:'include', headers:{'content-type':'application/json',
        'X-EOX-Session':'', 'X-EOX-CLIENT-VERSION':'26.4.01', 'X-Context-ID':crypto.randomUUID()},
      body:JSON.stringify(body)});
    if (!r.ok) throw new Error('FNZ: Postkorb nicht abrufbar (HTTP ' + r.status + ').');
    const j = await r.json();
    if (!Array.isArray(j.documents)) throw new Error('FNZ: Ungültige Dokumentenliste. Bitte erneut anmelden.');
    const docs = j.documents;
    if (docs.some(d => !d || typeof d.id !== 'string' || !d.id)) throw new Error('FNZ: Dokument ohne ID.');
    if (docs.length && docs.every(d => pageIds.has(d.id))) throw new Error('FNZ: Wiederholte Postkorbseite.');
    for (const d of docs) pageIds.add(d.id);
    all.push(...docs);
    from += 100;
    if (docs.length < 100 || (Number.isInteger(j.totalMessages) && j.totalMessages >= 0 && from >= j.totalMessages)) break;
    if (from >= 100000) throw new Error('FNZ: Zu viele Postkorbseiten.');
  }
}
const seen = new Set();
return JSON.stringify(all.filter(d => !seen.has(d.id) && seen.add(d.id)));`

    /// `id` is passed as an argument, never interpolated into JavaScript.
    readonly property string pdfScript: `const prefix = location.pathname.split('EOY')[0];
const r = await fetch(location.origin + prefix + 'p/postkorb.aspx?docId=' + encodeURIComponent(id)
  + '&download=true', {credentials:'include'});
const ct = (r.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
if (!r.ok || ct !== 'application/pdf') throw new Error('FNZ: PDF nicht abrufbar. Bitte Sitzung prüfen.');
const buf = new Uint8Array(await r.arrayBuffer());
if (String.fromCharCode(...buf.subarray(0,5)) !== '%PDF-') throw new Error('FNZ: Ungültiger PDF-Download.');
let bin = '';
for (let i=0; i<buf.length; i+=0x8000) bin += String.fromCharCode.apply(null, buf.subarray(i,i+0x8000));
return btoa(bin);`

    readonly property string guardScript: `if (location.hostname !== 'portal.fnz.de' || !/\\/EOY\\/EL\\//.test(location.pathname))
  throw new Error('FNZ: Bitte erneut anmelden.');
`

    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: flow.browser.evaluate(flow.probe, flow.browser.mainWorld, r => { if (flow.ready !== (r === true)) flow.ready = r === true })
    }

    function close(success) {
        generation++
        if (success) AppModel.closeWebLogin()
        else AppModel.cancelWebLogin()
    }
    function cancel() { if (!running) close(false) }

    function run(script, args, gen) {
        if (gen !== generation) return Promise.reject(cancelled)
        return browser.runAsync(guardScript + "\n" + script, args || {}, browser.mainWorld).then(r => {
            if (gen !== generation) throw cancelled
            if (typeof r !== "string") throw new Error(unreadable)
            return r
        }, e => { throw gen !== generation ? cancelled : new Error(e === null ? qsTr("FNZ: Bitte erneut anmelden.") : e) })
    }

    function start() {
        running = true
        notice = ""
        const gen = ++generation
        const id = connection.id
        let summary = null, downloaded = 0, failed = 0
        progress = qsTr("Kontosalden und Depotwerte abrufen …")
        run(overviewScript, {}, gen)
            .then(overview => AppModel.corePromise("import_fnz_overview", { connection_id: id, overview_json: overview }))
            .then(s => {
                summary = s
                if (!includeDocuments.checked) return null
                progress = qsTr("Postkorb und Archiv auflisten …")
                return run(documentsScript, {}, gen)
                    .then(list => AppModel.corePromise("pending_fnz_documents", { connection_id: id, documents_json: list }))
                    .then(pending => {
                        let consecutiveFailures = 0
                        const next = i => {
                            if (gen !== generation) return Promise.reject(cancelled)
                            if (i >= pending.length) return null
                            progress = qsTr("PDF %1 von %2 …").arg(i + 1).arg(pending.length)
                            const metadata = pending[i]
                            let docId = ""
                            try { docId = JSON.parse(metadata).id } catch (e) {}
                            const step = typeof docId === "string" && docId
                                ? run(pdfScript, { id: docId }, gen)
                                    .then(b64 => AppModel.corePromise("import_fnz_document", { connection_id: id, document_json: metadata, bytes_base64: b64 }))
                                : Promise.reject(new Error(unreadable))
                            return step.then(stored => {
                                if (stored) downloaded++
                                consecutiveFailures = 0
                                return next(i + 1)
                            }, e => {
                                if (e === cancelled) throw e
                                failed++
                                consecutiveFailures++
                                // A lost session must not cause hundreds of failed requests.
                                if (consecutiveFailures >= 3) { failed += pending.length - i - 1; return null }
                                return next(i + 1)
                            })
                        }
                        return next(0)
                    })
            })
            .then(() => {
                const message = qsTr("FNZ: %1 Konten/Depots aktualisiert, %2 neue PDFs.").arg(summary.accounts_updated).arg(downloaded)
                AppModel.toast = message
                if (failed === 0) { finish(); close(true); return }
                notice = message + " " + qsTr("%1 PDFs nicht abrufbar. Erfolgreiche Downloads bleiben gespeichert; ein erneuter Abruf lädt nur fehlende Dokumente.").arg(failed)
                finish()
            }, e => {
                if (e !== cancelled) notice = e && e.message ? e.message : String(e)
                finish()
            })
    }
    // PDFs are committed individually; flush them on success, cancellation and partial failure.
    function finish() {
        try { AppModel.core("checkpoint") } catch (e) {}
        running = false
        AppModel.documentsVersion++
        AppModel.reloadAll()
    }

    Button { text: qsTr("Schließen"); onClicked: flow.close(false) }
    CheckBox { id: includeDocuments; text: qsTr("PDF-Postkorb inkl. Archiv"); checked: true; enabled: !flow.running }
    Item { Layout.fillWidth: true }
    Button {
        text: qsTr("Salden und Dokumente abrufen")
        highlighted: true
        enabled: flow.ready && !flow.running
        onClicked: flow.start()
    }
}
