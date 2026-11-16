import SwiftUI
import WebKit
import GiroCrabCore

/// Bausparkasse Schwäbisch Hall, "Mein Konto" (#290). The user signs in in the
/// embedded browser (Azure AD B2C at login.schwaebisch-hall.de); the scripts
/// below then call the portal's own JSON endpoints in the signed-in page with
/// its session cookies. Cookies and credentials stay in the web view: only the
/// contract fields the core needs and the PDF attachments cross to Swift.
/// The scripts only read (GET); they never delete or send anything. Whether the
/// portal marks a message as read when its attachment is downloaded is not
/// known. They run in their own JavaScript world (`.defaultClient`): the
/// portal's third-party scripts (tag manager) cannot hook their `fetch` or read
/// the data, while the page's cookies still apply. Tested in
/// `scripts/test-schwaebisch-hall-portal.cjs`.
enum SchwaebischHallScripts {
    static let origin = "https://www.schwaebisch-hall.de"
    /// Starts the portal's B2C sign-in (302 to login.schwaebisch-hall.de).
    static let loginURL = URL(string: "https://www.schwaebisch-hall.de/bin/bshweb/authentication")!

    /// The fixed error codes of the scripts (`bsh:…` in the JavaScript exception) as
    /// localized messages. Anything else (WebKit, a parser) becomes "unreadable" and
    /// is never shown itself: such texts can quote the portal page.
    static func errorMessage(for exceptionText: String?) -> String {
        let code = exceptionText.flatMap { text in
            text.range(of: #"bsh:[a-z-]+(:[0-9]{1,3})?"#, options: .regularExpression).map { String(text[$0]) }
        }
        switch code {
        case "bsh:session":
            return String(localized: "Schwäbisch Hall: Sitzung abgelaufen oder nicht angemeldet. Bitte erneut anmelden.")
        case "bsh:timeout":
            return String(localized: "Schwäbisch Hall: Das Portal antwortet nicht. Bitte erneut versuchen.")
        case "bsh:too-large":
            return String(localized: "Schwäbisch Hall: Dokument zu groß (über 25 MB).")
        case "bsh:not-pdf":
            return String(localized: "Schwäbisch Hall: Der Download ist kein PDF.")
        case let code? where code.hasPrefix("bsh:http:"):
            let status = Int(code.dropFirst("bsh:http:".count)) ?? 0
            return String(localized: "Schwäbisch Hall: Abruf fehlgeschlagen (HTTP \(status)). Bitte erneut anmelden.")
        default:
            return String(localized: "Schwäbisch Hall: Die Portalantwort konnte nicht gelesen werden.")
        }
    }

    /// Prepended to every script: only the portal page itself may run them.
    /// Scripts throw only the fixed codes of `errorMessage(for:)` (`bsh:…`), never
    /// a browser or parser message: those can quote the portal page.
    static let prelude = #"""
    const fail = code => { throw new Error('bsh:' + code); };
    if (location.origin !== 'https://www.schwaebisch-hall.de') fail('session');
    const origin = 'https://www.schwaebisch-hall.de';
    const get = async (path, accept = 'application/json') => {
      if (!path.startsWith('/') || path.startsWith('//')) fail('invalid');
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 30000);
      let r;
      try {
        r = await fetch(origin + path, {credentials:'same-origin', redirect:'error',
          headers:{'Accept':accept}, signal:controller.signal});
      } catch (e) {
        // a redirect (to the sign-in) is a network error with redirect:'error'
        fail(e?.name === 'AbortError' ? 'timeout' : 'session');
      } finally { clearTimeout(timer); }
      if (!r.ok) fail('http:' + (Number.isInteger(r.status) ? r.status : 0));
      return r;
    };
    const json = async path => {
      let data;
      // HTML instead of JSON: the portal shows its sign-in page.
      try { data = await (await get(path)).json(); }
      catch (e) { if (String(e?.message).startsWith('bsh:')) throw e; fail('session'); }
      if (data && data.status === 'error') fail('session');
      return data;
    };
    const contractList = async () => {
      const list = await json('/bin/bshweb/accountcontracts');
      const contracts = list?.data?.contracts;
      if (list?.status !== 'success' || !Array.isArray(contracts)) fail('invalid');
      for (const c of contracts)
        if (typeof c?.vtn !== 'string' || !/^\d{6,24}$/.test(c.vtn)) fail('invalid');
      return contracts;
    };
    const pick = (o, keys) => Object.fromEntries(keys.filter(k => o?.[k] !== undefined).map(k => [k, o[k]]));
    """#

    /// Signed in: the contract list answers with `status: "success"` (without a
    /// session it is `status: "error"`, code `timeout`).
    static let probe = #"""
    try {
      const r = await fetch(origin + '/bin/bshweb/accountcontracts', {credentials:'same-origin', redirect:'error',
        headers:{'Accept':'application/json'}});
      if (!r.ok) return 'false';
      const data = await r.json();
      return String(data?.status === 'success' && Array.isArray(data?.data?.contracts));
    } catch { return 'false'; }
    """#

    /// Contracts with their details (type, phase, bookings). Nothing else of
    /// the detail response (personal data, debit account) is passed on.
    static let snapshot = #"""
    const details = '/content/bshweb/startseite/mein-konto/vertraege/_jcr_content/root/container/par/container/myaccount_accounts.account_details.json?vtn=';
    const out = [];
    for (const c of await contractList()) {
      let d = await json(details + encodeURIComponent(c.vtn));
      // Some portal answers wrap the payload in `data` like the contract list.
      if (d?.data && typeof d.data === 'object' && !Array.isArray(d.data)
          && ('transactions' in d.data || 'contracttype' in d.data)) d = d.data;
      if (!d || typeof d !== 'object' || Array.isArray(d)) fail('invalid');
      // only what the core reads (schwaebisch_hall.rs › snapshot)
      out.push({...pick(c, ['type','bsn','accountBalance','vtn']),
        details:pick(d, ['contracttype','contractphase','transactions'])});
    }
    return JSON.stringify({version:1, contracts:out});
    """#

    /// Postbox attachments as `[{id, date, title, vtn?}]`. The portal's download
    /// uses the message id (`/bin/bshweb/postbox/attachment?id=<message id>`) for
    /// messages with `type: "data"` (e.g. the annual statement); `type: "message"`
    /// ones are text only (#290). An explicit attachment id – a download form
    /// (`<form action="/bin/bshweb/postbox/attachment"><input name="id">`), a link
    /// or an attachment field – wins. `vtn` is set when exactly one contract number
    /// appears in the message.
    static let documents = #"""
    const contracts = await contractList();
    const data = await json('/content/bshweb/startseite/mein-konto/nachrichten.bin.postboxmessage?command=getmessages');
    const messages = [data, data?.messages, data?.data, data?.data?.messages].find(Array.isArray);
    if (!messages) fail('invalid');
    const decode = s => String(s).replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'");
    const attr = (tag, name) => {
      const m = tag.match(new RegExp('\\b' + name + '\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))', 'i'));
      return m ? decode(m[1] ?? m[2] ?? m[3]) : null;
    };
    const squash = s => String(s ?? '').replace(/\s+/g, '');
    const out = [], seen = new Set();
    for (const m of messages) {
      if (!m || typeof m !== 'object') continue;
      const html = typeof m.text === 'string' ? m.text : '';
      const ids = [];
      for (const f of html.matchAll(/<form\b([^>]*)>([\s\S]*?)<\/form>/gi)) {
        if (!(attr(f[1], 'action') || '').includes('/bin/bshweb/postbox/attachment')) continue;
        for (const i of f[2].matchAll(/<input\b[^>]*>/gi))
          if ((attr(i[0], 'name') || '').toLowerCase() === 'id') ids.push(attr(i[0], 'value'));
      }
      for (const a of html.matchAll(/\/bin\/bshweb\/postbox\/attachment\?([^"'\s<>]+)/gi))
        ids.push(new URLSearchParams(decode(a[1])).get('id'));
      if (Array.isArray(m.attachments))
        for (const a of m.attachments) ids.push(typeof a === 'string' ? a : a?.id ?? a?.attachmentId);
      if (m.attachmentId !== undefined) ids.push(m.attachmentId);
      if (!ids.length && m.type === 'data') ids.push(m.id);
      const plain = squash((m.title ?? '') + ' ' + html.replace(/<[^>]*>/g, ' '));
      const named = contracts.filter(c => plain.includes(c.vtn) || (c.bsn && plain.includes(squash(c.bsn))));
      for (const raw of ids) {
        const id = raw === null || raw === undefined ? '' : String(raw).trim();
        if (!id || id.length > 256 || seen.has(id)) continue;
        seen.add(id);
        out.push({id, date:m.date ?? null,
          title:String(m.title || m.typeName || ''), ...(named.length === 1 ? {vtn:named[0].vtn} : {})});
      }
    }
    return JSON.stringify(out);
    """#

    /// `id` is passed as an argument, never interpolated into JavaScript.
    static let pdf = #"""
    if (typeof id !== 'string' || !id) fail('invalid');
    const r = await get('/bin/bshweb/postbox/attachment?id=' + encodeURIComponent(id), 'application/pdf,*/*');
    const max = 25 * 1024 * 1024;
    if (Number(r.headers.get('content-length') || 0) > max) fail('too-large');
    // Read in chunks and stop at the limit: a body without a length never fills memory.
    const parts = [];
    let size = 0;
    if (r.body?.getReader) {
      const reader = r.body.getReader();
      for (;;) {
        const {done, value} = await reader.read();
        if (done) break;
        size += value.length;
        if (size > max) { reader.cancel().catch(() => {}); fail('too-large'); }
        parts.push(value);
      }
    } else {
      const all = new Uint8Array(await r.arrayBuffer());
      size = all.length;
      if (size > max) fail('too-large');
      parts.push(all);
    }
    const buf = new Uint8Array(size);
    let offset = 0;
    for (const p of parts) { buf.set(p, offset); offset += p.length; }
    if (String.fromCharCode(...buf.subarray(0, 5)) !== '%PDF-') fail('not-pdf');
    let bin = '';
    for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000));
    return btoa(bin);
    """#
}

struct SchwaebischHallWebSheet: View {
    @Environment(\.reportRedaction) private var redaction
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connection: BankConnection
    @State private var browser = PortalBrowser(url: SchwaebischHallScripts.loginURL,
        domains: PortalDomains(kind: .schwaebischHall), captureTraffic: false)
    @State private var uiDelegate = AmazonUIDelegate()
    @State private var ready = false
    @State private var running = false
    @State private var includeDocuments = true
    @State private var progress = ""
    @State private var notice: String?
    @State private var task: Task<Void, Never>?
    /// Contracts another login already delivers: asked before the documents are downloaded (#346).
    @State private var choosing = false
    @State private var askedInFlow = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(redaction.masking(connection.displayName)) – Schwäbisch Hall").appFont(.headline)
                    if running { Text(progress).appFont(.caption) }
                    else if let notice { Text(notice).appFont(.caption).foregroundStyle(.orange) }
                    else if let blocked = browser.blockedHost {
                        Text("Unsichere Seite blockiert (\(blocked)) – nur HTTPS-Seiten werden geöffnet.").appFont(.caption).foregroundStyle(.orange)
                    }
                    else if ready { Text("Angemeldet – Bausparverträge, Umsätze und Postfach können abgerufen werden.").appFont(.caption) }
                    else { Text("Melden Sie sich bei „Mein Konto“ von Schwäbisch Hall an.").appFont(.caption) }
                }
                Spacer()
                if running || browser.loading { ProgressView().controlSize(.small) }
            }.padding(14)
            Divider()
            PortalWebView(browser: browser).macFrame(minWidth: 760, minHeight: 620)
                .overlay {
                    if choosing {
                        AccountSelectionPanel(connection: connection) { choosing = false }
                            .background(.background)
                    }
                }
            Divider()
            HStack {
                Button("Schließen", role: .cancel) { task?.cancel(); close() }.keyboardShortcut(.cancelAction)
                Toggle("PDF-Dokumente aus dem Postfach", isOn: $includeDocuments).disabled(running)
                Spacer()
                Button("Verträge abrufen") { start() }.buttonStyle(.borderedProminent).disabled(!ready || running)
            }.padding(12)
        }
        .webPageDialogs(uiDelegate)
        .task {
            browser.webView.uiDelegate = uiDelegate
            while !Task.isCancelled {
                if !running {
                    let onPortal = browser.currentURL?.host?.lowercased() == "www.schwaebisch-hall.de" && !browser.loading
                    let ok = onPortal ? ((try? await run(SchwaebischHallScripts.probe)) == "true") : false
                    if ready != ok { ready = ok }
                }
                // Signed in: check rarely; the next fetch reports an expired session anyway.
                try? await Task.sleep(nanoseconds: ready ? 10_000_000_000 : 2_000_000_000)
            }
        }
        .onDisappear { task?.cancel(); browser.teardown() }
        .interactiveDismissDisabled(running)
    }

    private func run(_ script: String, arguments: [String: Any] = [:]) async throws -> String {
        try Task.checkCancellation()
        let result: Any?
        do {
            result = try await browser.webView.callAsyncJavaScript(SchwaebischHallScripts.prelude + "\n" + script,
                arguments: arguments, in: nil, contentWorld: .defaultClient)
        } catch {
            try Task.checkCancellation()
            let exception = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            throw SchwaebischHallError.portal(SchwaebischHallScripts.errorMessage(for: exception))
        }
        try Task.checkCancellation()
        guard let string = result as? String else { throw SchwaebischHallError.unreadable }
        return string
    }

    private func start() {
        running = true
        notice = nil
        task = Task {
            // Pinned: a lock or demo switch mid-run must not send later steps to another vault.
            guard let pin = model.pinVault() else { running = false; return }
            let connectionId = connection.id
            do {
                progress = String(localized: "Bausparverträge und Umsätze abrufen …")
                let snapshot = try await run(SchwaebischHallScripts.snapshot)
                let summary = try await pin.run { try $0.importSchwaebischHallSnapshot(connectionId: connectionId, snapshotJson: snapshot) }
                var downloaded = 0
                var failed = 0
                // Held-back contracts: ask now, so their documents are fetched (or skipped) accordingly.
                let open = try await pin.run { try $0.pendingAccountSelectionConnections() }
                if open.contains(connectionId) {
                    askedInFlow = true
                    progress = String(localized: "Auswahl der Konten …")
                    choosing = true
                    while choosing { try await Task.sleep(nanoseconds: 200_000_000) }
                }
                if includeDocuments {
                    progress = String(localized: "Postfach auflisten …")
                    let list = try await run(SchwaebischHallScripts.documents)
                    let pending = try await pin.run { try $0.pendingSchwaebischHallDocuments(connectionId: connectionId, documentsJson: list) }
                    var streak = QuirionFailureStreak()
                    for (index, metadata) in pending.enumerated() {
                        try Task.checkCancellation()
                        progress = String(localized: "PDF \(index + 1) von \(pending.count) …")
                        do {
                            guard let data = metadata.data(using: .utf8),
                                  let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let id = doc["id"] as? String else { throw SchwaebischHallError.unreadable }
                            let encoded = try await run(SchwaebischHallScripts.pdf, arguments: ["id": id])
                            guard let bytes = Data(base64Encoded: encoded) else { throw SchwaebischHallError.unreadable }
                            if try await pin.run({ try $0.importSchwaebischHallDocument(connectionId: connectionId, documentJson: metadata, bytes: bytes) }) {
                                downloaded += 1
                            }
                            streak.succeeded()
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            failed += 1
                            // A lost session must not cause hundreds of failed requests.
                            if streak.failed() { failed += pending.count - index - 1; break }
                        }
                    }
                }
                let message = String(localized: "Schwäbisch Hall: \(summary.accountsUpdated) Verträge aktualisiert, \(summary.transactionsImported) neue Buchungen, \(downloaded) neue PDFs.")
                model.toast = message
                if failed == 0 { close() }
                else { notice = message + " " + String(localized: "\(failed) PDFs nicht abrufbar. Ein erneuter Abruf lädt nur fehlende Dokumente.") }
            } catch is CancellationError {
            } catch {
                notice = describe(error)
                ready = false
            }
            // PDFs are committed one by one: flush them on success, cancellation and partial failure.
            await pin.checkpoint()
            running = false
            choosing = false
            model.documentsVersion += 1
            model.reloadAll()
            // Skipped ("Später") contracts were already offered in this run.
            if !askedInFlow { model.checkPendingAccountSelection() }
            askedInFlow = false
        }
    }

    private func close() { model.webLoginConnection = nil; dismiss() }
}

private enum SchwaebischHallError: LocalizedError {
    case unreadable
    /// A fixed, localized message from `SchwaebischHallScripts.errorMessage(for:)`.
    case portal(String)
    var errorDescription: String? {
        switch self {
        case .unreadable: return SchwaebischHallScripts.errorMessage(for: nil)
        case .portal(let message): return message
        }
    }
}
