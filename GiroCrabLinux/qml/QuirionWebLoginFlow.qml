import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// QuirionUI.swift › QuirionWebSheet: the user signs in to banking.quirion.de. A script
// installed before the portal's first authenticated request keeps the Authorization in
// the page's JavaScript closure (never in QML, logs or the vault) and fetches depot,
// accounts, history and postbox PDFs for the core (`import_quirion_snapshot`,
// `pending_quirion_documents`, `import_quirion_document`).
WebLoginFlow {
    id: flow
    title: connection ? qsTr("%1 – quirion").arg(AppModel.masking(connection.display_name)) : ""
    busy: running
    infoWarning: !running && notice !== ""
    info: running ? progress : notice !== "" ? notice
        : ready ? qsTr("Angemeldet – Depot, Konten und Historie können abgerufen werden.")
        : qsTr("Melden Sie sich bei quirion an und bestätigen Sie gegebenenfalls die Anmeldung.")
    userScript: hook

    property bool ready: false
    property bool running: false
    property string progress: ""
    property string notice: ""
    property int generation: 0
    readonly property string unreadable: qsTr("quirion: Die Portalantwort konnte nicht gelesen werden.")
    readonly property var cancelled: ({ quirion: "cancelled" })

    /// QuirionScripts.hook (main frame, document start, page world).
    readonly property string hook: `(() => {
  if (location.origin !== 'https://banking.quirion.de' || window.__gcQuirion) return;
  const origin = 'https://api.it-aws-prod.quirion.de';
  const prefix = '/legacy/v1/';
  const nativeFetch = window.fetch;
  let authorization = null;
  const trusted = url => {
    try { const u = new URL(url, location.href);
      return u.origin === origin && u.pathname.startsWith(prefix);
    } catch { return false; }
  };
  const remember = (url, headers) => {
    if (!trusted(url)) return;
    const value = new Headers(headers || {}).get('authorization');
    if (value) authorization = value;
  };
  window.fetch = function(input, init) {
    const url = input instanceof Request ? input.url : String(input);
    const headers = init?.headers || (input instanceof Request ? input.headers : {});
    const response = nativeFetch.apply(this, arguments);
    if (trusted(url)) response.then(r => { if (r.ok) remember(url, headers); }).catch(() => {});
    return response;
  };
  const open = XMLHttpRequest.prototype.open;
  const setHeader = XMLHttpRequest.prototype.setRequestHeader;
  const requests = new WeakMap();
  XMLHttpRequest.prototype.open = function(method, url) {
    const request = {url: String(url), headers: {}};
    requests.set(this, request);
    this.addEventListener('load', () => {
      if (this.status >= 200 && this.status < 300) remember(request.url, request.headers);
    }, {once:true});
    return open.apply(this, arguments);
  };
  XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
    const request = requests.get(this);
    if (request && trusted(request.url)) request.headers[name] = value;
    return setHeader.apply(this, arguments);
  };
  const request = async (path, body) => {
    if (location.origin !== 'https://banking.quirion.de' || !authorization)
      throw new Error('quirion: Bitte erneut anmelden.');
    if (!path.startsWith(prefix) || path.includes('://')) throw new Error('quirion: Ungültiger Abruf.');
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 30000);
    try {
      const r = await nativeFetch.call(window, origin + path, {
        method: body === undefined ? 'GET' : 'POST', credentials: 'omit', redirect: 'error',
        headers: {'Authorization':authorization, 'Accept':'application/json', 'Content-Type':'application/json'},
        ...(body === undefined ? {} : {body:JSON.stringify(body)}), signal:controller.signal
      });
      if (!r.ok) {
        if (r.status === 401 || r.status === 403) authorization = null;
        throw new Error('quirion: Abruf fehlgeschlagen (HTTP ' + r.status + '). Bitte erneut anmelden.');
      }
      return r;
    } finally { clearTimeout(timeout); }
  };
  const json = async (path, body) => (await request(path, body)).json();
  const identifier = n => {
    if (!Number.isSafeInteger(n) || n <= 0) throw new Error('quirion: Ungültige Konto-ID.');
    return String(n);
  };
  const fields = (object, keys) => Object.fromEntries(keys.filter(k => object?.[k] !== undefined).map(k => [k, object[k]]));
  const cashKeys = ['accountHolder','iban','sortKey','currency','exchangeRate','balance'];
  const txKeys = ['amount','currency','status','bookingDate','valutaDate','type','verwendungszweck','Verwendungszweck',
    'creditorAccountHolder','creditorIban','debtorAccountHolder','debtorIban'];
  const history = async (businessPartnerId, ipsId, start) => {
    const timestamp = Date.parse(start);
    if (!Number.isFinite(timestamp)) throw new Error('quirion: Unbekannter Beginn der Umsatzhistorie.');
    const range = Math.max(3000, Math.ceil((Date.now() - timestamp) / 86400000) + 366);
    const body = {businessPartnerId, range, status:'CLOSED', type:'ALL'};
    if (ipsId !== undefined) body.ipsId = ipsId;
    const tx = await json(prefix + 'transactions', body);
    if (!Array.isArray(tx)) throw new Error('quirion: Ungültige Umsatzhistorie.');
    return tx.map(t => fields(t, txKeys));
  };
  window.__gcQuirion = {
    ready: () => !!authorization,
    collect: async () => {
      const user = await json(prefix + 'user');
      if (!Array.isArray(user.businessPartner)) throw new Error('quirion: Keine Konten erkannt.');
      const partners = [];
      for (const bp of user.businessPartner.filter(b => b.status === 'OPEN')) {
        const bpId = identifier(bp.businessPartnerId);
        const base = prefix + 'business-partners/' + bpId;
        const b = await json(base + '?clearing=true&products=true&history=false&historyYear=false&reference=false&users=false&wphg=false');
        if (b.businessPartnerId !== bp.businessPartnerId || !Array.isArray(b.products)) throw new Error('quirion: Unvollständige Kontoübersicht.');
        const partner = {businessPartnerId:bp.businessPartnerId, name:bp.name, balanceDate:bp.balanceDate,
          clearing:b.clearing ? fields(b.clearing, cashKeys) : null, products:[]};
        if (partner.clearing) partner.clearingTransactions = await history(bp.businessPartnerId, undefined, bp.createdAt);
        for (const p of b.products.filter(p => p.status === 'OPEN')) {
          const productId = identifier(p.ipsId);
          const d = await json(base + '/products/' + productId + '?condition=false&debit=false&depotitems=true&liquid=true&history=false&historyYear=false&savingsplans=false&transactions=false&wphg=false');
          if (!d.liquid || !Array.isArray(d.depotItems)) throw new Error('quirion: Unvollständiges Depot.');
          partner.products.push({
            summary:fields(p,['ipsId','businessPartnerId','name','status','depotBalance','balance','balanceDate']),
            detail:{liquid:fields(d.liquid,cashKeys), depotItems:d.depotItems.map(i => fields(i,
              ['isin','name','shortName','quantity','value','aktuellerKurs','einstandskurs','exchangeRate']))},
            transactions:await history(bp.businessPartnerId, p.ipsId, p.createdAt)
          });
        }
        partners.push(partner);
      }
      return JSON.stringify({version:1,partners});
    },
    documents: async () => {
      const data = await json(prefix + 'postbox?status=ALL&from=2000-01-01&to=' + new Date().toISOString().slice(0,10));
      if (!Array.isArray(data.documents)) throw new Error('quirion: Ungültige Postbox.');
      return JSON.stringify(data.documents.map(d => fields(d,['id','businessPartnerId','displayName','createdAt'])));
    },
    pdf: async id => {
      if (typeof id !== 'string' || !id) throw new Error('quirion: Ungültige Dokument-ID.');
      let encoded = await (await request(prefix + 'postbox/download', {doc:id})).text();
      if (encoded.startsWith('"')) encoded = JSON.parse(encoded);
      if (!atob(encoded).startsWith('%PDF-')) throw new Error('quirion: Der Download ist kein PDF.');
      return encoded;
    }
  };
})();`

    readonly property string probe: "location.origin === 'https://banking.quirion.de' && !!window.__gcQuirion?.ready()"
    readonly property string guardScript: "if (location.origin !== 'https://banking.quirion.de' || !window.__gcQuirion) throw new Error('quirion: Bitte erneut anmelden.');\n"

    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: flow.browser.evaluate(flow.probe, flow.browser.mainWorld, r => {
            const ok = flow.browser.onPortal && !flow.browser.onLoginPage && r === true
            if (flow.ready !== ok) flow.ready = ok
        })
    }

    function close(success) {
        generation++
        if (success) AppModel.closeWebLogin()
        else AppModel.cancelWebLogin()
    }
    function cancel() { if (!running) close(false) }

    function run(script, args, gen) {
        if (gen !== generation) return Promise.reject(cancelled)
        return browser.runAsync(guardScript + script, args || {}, browser.mainWorld).then(r => {
            if (gen !== generation) throw cancelled
            if (typeof r !== "string") throw new Error(unreadable)
            return r
        }, e => { throw gen !== generation ? cancelled : new Error(e === null ? qsTr("quirion: Bitte erneut anmelden.") : e) })
    }

    function start() {
        running = true
        notice = ""
        const gen = ++generation
        const id = connection.id
        let summary = null, downloaded = 0, failed = 0
        progress = qsTr("Depotpositionen und Umsatzhistorie abrufen …")
        run("return await window.__gcQuirion.collect();", {}, gen)
            .then(snapshot => AppModel.corePromise("import_quirion_snapshot", { connection_id: id, snapshot_json: snapshot }))
            .then(s => {
                summary = s
                if (!includeDocuments.checked) return null
                progress = qsTr("Postbox und Archiv auflisten …")
                return run("return await window.__gcQuirion.documents();", {}, gen)
                    .then(list => AppModel.corePromise("pending_quirion_documents", { connection_id: id, documents_json: list }))
                    .then(pending => {
                        // QuirionFailureStreak: abort after 3 failures in a row (expired session, portal change).
                        let streak = 0
                        const next = i => {
                            if (gen !== generation) return Promise.reject(cancelled)
                            if (i >= pending.length) return null
                            progress = qsTr("PDF %1 von %2 …").arg(i + 1).arg(pending.length)
                            const metadata = pending[i]
                            let docId = ""
                            try { docId = JSON.parse(metadata).id } catch (e) {}
                            const step = typeof docId === "string" && docId
                                ? run("return await window.__gcQuirion.pdf(id);", { id: docId }, gen)
                                    .then(b64 => AppModel.corePromise("import_quirion_document", { connection_id: id, document_json: metadata, bytes_base64: b64 }))
                                : Promise.reject(new Error(unreadable))
                            return step.then(stored => {
                                if (stored) downloaded++
                                streak = 0
                                return next(i + 1)
                            }, e => {
                                if (e === cancelled) throw e
                                failed++
                                if (++streak >= 3) { failed += pending.length - i - 1; return null }
                                return next(i + 1)
                            })
                        }
                        return next(0)
                    })
            })
            .then(() => {
                const message = qsTr("quirion: %1 Konten/Depots aktualisiert, %2 neue Buchungen, %3 neue PDFs.")
                    .arg(summary.accounts_updated).arg(summary.transactions_imported).arg(downloaded)
                AppModel.toast = message
                if (failed === 0) { finish(); close(true); return }
                notice = message + " " + qsTr("%1 PDFs nicht abrufbar. Ein erneuter Abruf lädt nur fehlende Dokumente.").arg(failed)
                finish()
            }, e => {
                if (e !== cancelled) notice = e && e.message ? e.message : String(e)
                finish()
            })
    }
    function finish() {
        try { AppModel.core("checkpoint") } catch (e) {}
        running = false
        AppModel.documentsVersion++
        AppModel.reloadAll()
        // accounts another login already delivers wait for a choice (#346)
        AppModel.checkPendingAccountSelection()
    }

    Button { text: qsTr("Schließen"); onClicked: flow.close(false) }
    CheckBox { id: includeDocuments; text: qsTr("PDF-Postbox inkl. Archiv"); checked: true; enabled: !flow.running }
    Item { Layout.fillWidth: true }
    Button {
        text: qsTr("Depot und Konten abrufen")
        highlighted: true
        enabled: flow.ready && !flow.running
        onClicked: flow.start()
    }
}
