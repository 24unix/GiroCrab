import SwiftUI
import WebKit
import CryptoKit
import GiroCrabCore

/// Session headers stay in the page closure. Only a whitelisted inventory
/// snapshot leaves WebKit; login traffic and raw responses are never captured.
enum EquatePlusScripts {
    static let hook = #"""
    (() => {
      const hosts = ['www.equateplus.com','www.emea.equateplus.com','www.na.equateplus.com'];
      const allowed = () => location.protocol === 'https:' && hosts.includes(location.hostname);
      if (!allowed() || window.__gcEquatePlus) return;
      const prefix = '/EquatePlusParticipant2/';
      const nativeFetch = window.fetch;
      let csrf = null, csrf2 = null, clientId = null, authenticated = false;
      let pendingProbe = null, nextProbe = 0;
      const trusted = raw => {
        try { const u = new URL(raw, location.href);
          return u.origin === location.origin && u.pathname.startsWith(prefix + 'services/');
        } catch { return false; }
      };
      const remember = (url, headers) => {
        if (!trusted(url)) return;
        const h = new Headers(headers || {}), u = new URL(url, location.href);
        csrf = h.get('csrfpId') || u.searchParams.get('csrfpId') || csrf;
        csrf2 = h.get('EQUATE-CSRF2-TOKEN-PARTICIPANT2') || csrf2;
        clientId = u.searchParams.get('_cId') || clientId;
      };
      const observeUser = (url, data) => {
        if (trusted(url) && new URL(url, location.href).pathname === prefix + 'services/user/get'
          && data?.participant?.userId !== undefined && data?.reportingCurrency?.code)
          authenticated = true;
      };
      window.fetch = function(input, init) {
        const url = input instanceof Request ? input.url : String(input);
        const headers = init?.headers || (input instanceof Request ? input.headers : {});
        const p = nativeFetch.apply(this, arguments);
        if (trusted(url)) p.then(async r => { if (r.ok) { remember(url, headers); observeUser(url,await r.clone().json()); } }).catch(() => {});
        return p;
      };
      const open = XMLHttpRequest.prototype.open, setHeader = XMLHttpRequest.prototype.setRequestHeader;
      const requests = new WeakMap();
      XMLHttpRequest.prototype.open = function(method, url) {
        const request = {url:String(url),headers:{}}; requests.set(this,request);
        this.addEventListener('load', () => {
          if (this.status >= 200 && this.status < 300 && trusted(request.url)) {
            remember(request.url,request.headers);
            try { observeUser(request.url, this.responseType === 'json' ? this.response : JSON.parse(this.responseText)); } catch {}
          }
        }, {once:true});
        return open.apply(this,arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function(name,value) {
        const request = requests.get(this);
        if (request && trusted(request.url)) request.headers[name] = value;
        return setHeader.apply(this,arguments);
      };
      const seed = () => {
        const string = value => typeof value === 'string' && value ? value : null;
        csrf ||= new URL(location.href).searchParams.get('csrfpId')
          || string(document.querySelector('[name="csrfpId"]')?.value);
        csrf2 ||= string(window.equateCsrfToken2);
        // Some portal versions put initial tokens in inline bootstrap scripts.
        for (const script of document.scripts) {
          const s = script.textContent || '';
          csrf ||= s.match(/csrf(?:RegisterAjax|ModifyLinks)\(\s*["']csrfpId["']\s*,\s*["']([^"']+)["']/)?.[1];
          csrf2 ||= s.match(/["']equateCsrfToken2["']\s*:\s*["']([^"']+)["']/)?.[1];
        }
        csrf2 ||= document.querySelector('[name="EQUATE-CSRF2-TOKEN-PARTICIPANT2"]')?.value;
      };
      const canRequest = () => {
        seed();
        return allowed() && location.pathname.startsWith(prefix) && !document.querySelector('#loginForm') && !!csrf;
      };
      const ready = () => canRequest() && authenticated;
      const get = async (path, body) => {
        if (!canRequest()) throw new Error('EquatePlus: Bitte vollständig anmelden.');
        const url = new URL(prefix + 'services/' + path, location.origin);
        url.searchParams.set('csrfpId',csrf);
        if (clientId) url.searchParams.set('_cId',clientId);
        url.searchParams.set('_rId',crypto.randomUUID());
        const headers = {'Accept':'application/json','Content-Type':'application/json;charset=UTF-8',
          'X-Requested-With':'XMLHttpRequest','csrfpId':csrf};
        if (csrf2) headers['EQUATE-CSRF2-TOKEN-PARTICIPANT2'] = csrf2;
        const controller = new AbortController(), timeout = setTimeout(() => controller.abort(),30000);
        try {
          const response = await nativeFetch.call(window,url.href,{
            method:body === undefined ? 'GET' : 'POST',credentials:'same-origin',redirect:'error',
            headers,signal:controller.signal,...(body === undefined ? {} : {body:JSON.stringify(body)})});
          if (!response.ok) {
            if ([401,403].includes(response.status)) authenticated = false;
            const error = new Error('EquatePlus: Abruf fehlgeschlagen (HTTP ' + response.status + '). Bitte erneut anmelden.');
            error.status = response.status;
            throw error;
          }
          const data = await response.json();
          if (!data || typeof data !== 'object' || /Error$/.test(data.$type || ''))
            throw new Error('EquatePlus: Keine gültigen Bestandsdaten erhalten.');
          if (typeof data.csrfpId === 'string' && data.csrfpId) csrf = data.csrfpId;
          return data;
        } finally { clearTimeout(timeout); }
      };
      const keys = ['totals','type','quantity','value','vehicle','productType','archived','entries','name','displayValue','canTrade','marketPrice','amount','unit','code','currency',
        'VEHICLE','VEHICLE_DESCRIPTION','SECURITY','VEHICLE_NAME','QUANTITY','AVAIL_QTY','AVAILABLE_UNITS',
        'LOCKED_QTY','LOCKED_PERF_QTY','TOTAL_UNITS','NET_UNITS','UNITS','SELL_PURCHASE_PRICE','COST_BASIS','PURCHASE_PRICE'];
      const clean = value => {
        if (Array.isArray(value)) return value.map(clean);
        if (value && typeof value === 'object') return Object.fromEntries(keys.filter(k => value[k] !== undefined).map(k => [k,clean(value[k])]));
        return value;
      };
      // The portal can bootstrap its user in the HTML instead of issuing an
      // observable user/get request. Verify that session explicitly; passive
      // request observation alone would leave a successful login disabled.
      const probe = async () => {
        if (!canRequest()) return false;
        if (authenticated) return true;
        if (pendingProbe) return pendingProbe;
        if (Date.now() < nextProbe) return false;
        nextProbe = Date.now() + 5000;
        pendingProbe = (async () => {
          try {
            const user = await get('user/get');
            observeUser(prefix + 'services/user/get', user);
            return ready();
          } catch { return false; }
          finally { pendingProbe = null; }
        })();
        return pendingProbe;
      };
      // Optional PDF import (library of statements, confirmations, tax certificates). Only the
      // portal's own two download services are ever requested, and only by document id.
      const downloadPath = /^\/services\/(documents|statements)\/download\?documentId=([A-Za-z0-9_.~%-]{1,200})$/;
      const base64 = bytes => {
        let text = '';
        for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        return btoa(text);
      };
      const stats = {attempts: 0};
      const download = async raw => {
        const match = typeof raw === 'string' ? raw.match(downloadPath) : null;
        if (!match) throw new Error('EquatePlus: Ungültige Dokumentadresse.');
        if (!canRequest()) throw new Error('EquatePlus: Bitte vollständig anmelden.');
        for (let attempt = 0; attempt < 8; attempt++) {
          const url = new URL(prefix + 'services/' + match[1] + '/download', location.origin);
          url.searchParams.set('documentId', decodeURIComponent(match[2]));
          url.searchParams.set('downloadType', 'attachment');
          url.searchParams.set('csrfpId', csrf);
          if (clientId) url.searchParams.set('_cId', clientId);
          url.searchParams.set('_rId', crypto.randomUUID());
          const headers = {'X-Requested-With':'XMLHttpRequest','csrfpId':csrf};
          if (csrf2) headers['EQUATE-CSRF2-TOKEN-PARTICIPANT2'] = csrf2;
          const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 60000);
          try {
            const response = await nativeFetch.call(window, url.href, {method:'GET', credentials:'same-origin', redirect:'error', headers, signal:controller.signal});
            if (!response.ok) {
              if ([401,403].includes(response.status)) authenticated = false;
              throw new Error('EquatePlus: Dokument nicht abrufbar (HTTP ' + response.status + ').');
            }
            const bytes = new Uint8Array(await response.arrayBuffer());
            if (bytes.length > 50 * 1024 * 1024) throw new Error('EquatePlus: Dokument zu groß.');
            // a PDF may have a few bytes in front of its header (the format allows 1024)
            const head = String.fromCharCode.apply(null, bytes.subarray(0, Math.min(1024, bytes.length)));
            if (head.includes('%PDF-')) { stats.attempts = attempt + 1; return base64(bytes); }
            // the portal answers with a short status while it prepares the file
            const type = (response.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
            if (!/json/.test(type))
              throw new Error('EquatePlus: Der Download ist kein PDF (' + (/^[a-z0-9.+\/-]{1,60}$/.test(type) ? type : 'unbekannt') + ', ' + bytes.length + ' B).');
          } finally { clearTimeout(timeout); }
          await new Promise(resolve => setTimeout(resolve, 1500));
        }
        throw new Error('EquatePlus: Das Dokument wurde nicht rechtzeitig bereitgestellt.');
      };
      window.__gcEquatePlus = {
        ready, probe,
        documents: async () => {
          const data = await get('documents/library', {$type:'Object'});
          if (!Array.isArray(data.documents) || data.documents.length > 5000)
            throw new Error('EquatePlus: Keine gültige Dokumentenliste erhalten.');
          return JSON.stringify(data.documents.map(d => ({id:d.id, date:d.date, addedDate:d.addedDate, description:d.description,
            documentType:d.documentType, plan:d.plan, language:d.language?.code, url:d.url})));
        },
        pdf: download,
        lastAttempts: () => String(stats.attempts),
        collect: async () => {
          const user = await get('user/get');
          let summary;
          try { summary = await get('planSummary/get',{$type:'Object'}); }
          catch (error) {
            if (![400,405].includes(error.status)) throw error;
            summary = await get('planSummary/get');
          }
          if (!Array.isArray(summary.entries) || !summary.entries.length) summary = await get('planSummary/get');
          if (!Array.isArray(summary.entries) || !summary.entries.length || summary.entries.length > 500)
            throw new Error('EquatePlus: Keine vollständige Programmübersicht erhalten.');
          const plans = [], seen = new Set();
          for (const plan of summary.entries) {
            if (!['string','number'].includes(typeof plan.id) || !String(plan.id) || seen.has(String(plan.id)))
              throw new Error('EquatePlus: Programm ohne eindeutige Kennung.');
            seen.add(String(plan.id));
            const details = await get('planDetails/get',{$type:'EntityIdentifier',id:plan.id});
            if (!Array.isArray(details.entries)) throw new Error('EquatePlus: Unvollständige Programmdetails.');
            plans.push({id:plan.id,name:clean(plan.name),details:clean(details)});
          }
          const now = new Date();
          return JSON.stringify({version:1,date:new Date(now.getTime()-now.getTimezoneOffset()*60000).toISOString().slice(0,10),
            user:{participant:{userId:user.participant?.userId},reportingCurrency:{code:user.reportingCurrency?.code}},plans});
        }
      };
    })();
    """#
    static let probe = "return (await window.__gcEquatePlus?.probe()) === true;"
}

struct EquatePlusWebSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connection: BankConnection
    @State private var browser = PortalBrowser(url: URL(string: "https://www.equateplus.com/EquatePlusParticipant2/?login")!,
        domains: PortalDomains(kind: .equatePlus), captureTraffic: false, userScript: EquatePlusScripts.hook)
    @State private var uiDelegate = AmazonUIDelegate()
    @State private var ready = false
    @State private var running = false
    @State private var notice: String?
    @State private var progress: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(connection.displayName) – EquatePlus").appFont(.headline)
                    if running { Text(progress ?? String(localized: "Programme und Bestände abrufen …")).appFont(.caption) }
                    else if let notice { Text(notice).appFont(.caption).foregroundStyle(.orange) }
                    else { Text(ready ? String(localized: "Angemeldet – verfügbare und gesperrte Bestände können abgerufen werden.") : String(localized: "Melden Sie sich bei EquatePlus an und bestätigen Sie mit EquateAccess oder der angebotenen Alternative.")).appFont(.caption) }
                }
                Spacer()
                if running || browser.loading { ProgressView().controlSize(.small) }
            }.padding(14)
            Divider()
            PortalWebView(browser: browser).macFrame(minWidth: 760, minHeight: 620)
            Divider()
            // where the optional PDFs go, before anyone looks for them in the accounts
            Text("Dokumente werden unter „Belege & PostBox“ abgelegt (Suche: equateplus) und nicht automatisch Umsätzen oder Aktivitäten zugeordnet. Nur wenn der Programmname im Dokument zu einem Programm passt, steht es auch bei dessen Konto.")
                .appFont(.caption2).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 8)
            HStack {
                Button("Schließen", role: .cancel) { task?.cancel(); close() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Dokumente laden …") { startDocuments() }
                    .disabled(!ready || running)
                    .help("Lädt die PDFs der Bibliothek (Bestätigungen, Auszüge, Steuerbescheinigungen). Bereits gespeicherte Dokumente werden übersprungen.")
                Button("Programme und Bestände abrufen") { start() }
                    .buttonStyle(.borderedProminent).disabled(!ready || running)
            }.padding(12)
        }
        .webPageDialogs(uiDelegate)
        .task {
            browser.webView.uiDelegate = uiDelegate
            while !Task.isCancelled {
                let ok = (try? await browser.webView.callAsyncJavaScript(EquatePlusScripts.probe,
                    arguments: [:], in: nil, contentWorld: .page)) as? Bool ?? false
                if ready != ok { ready = ok }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .onDisappear { task?.cancel(); browser.teardown() }
        .interactiveDismissDisabled(running)
    }

    private func start() {
        running = true
        notice = nil
        task = Task {
            guard let pin = model.pinVault() else { running = false; return }
            let connectionId = connection.id
            var stage = "portal"
            do {
                try Task.checkCancellation()
                let result = try await browser.webView.callAsyncJavaScript(
                    "if (!window.__gcEquatePlus?.ready()) throw new Error('EquatePlus: Bitte erneut anmelden.'); return await window.__gcEquatePlus.collect();",
                    arguments: [:], in: nil, contentWorld: .page)
                try Task.checkCancellation()
                guard let snapshot = result as? String else { throw EquatePlusError.unreadable }
                stage = "import"
                let summary = try await pin.run { try $0.importEquateplusSnapshot(connectionId: connectionId, snapshotJson: snapshot) }
                model.toast = String(localized: "EquatePlus: \(summary.accountsUpdated) Programme aktualisiert.")
                close()
            } catch is CancellationError {
            } catch {
                // Never expose WebKit's raw error: it can include token-bearing URLs.
                let native = error as NSError
                let exception = native.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
                let status = exception.range(of: "HTTP [0-9]{3}", options: .regularExpression).map { String(exception[$0]) }
                notice = stage == "import"
                    ? String(localized: "EquatePlus: Die gelieferten Bestandsdaten konnten nicht verarbeitet werden. Die bisherigen Bestände bleiben erhalten.")
                    : String(localized: "EquatePlus: Der Datenabruf ist fehlgeschlagen. Bitte erneut versuchen.")
                if let status { notice = (notice ?? "") + " (" + status + ")" }
            }
            await pin.checkpoint()
            running = false
            model.reloadAll()
            model.checkPendingAccountSelection()
        }
    }
    /// Runs a call of the page script; only on the portal's own hosts and with a valid session.
    private func runScript(_ script: String, arguments: [String: Any] = [:]) async throws -> String {
        try Task.checkCancellation()
        let guardScript = """
        if (location.protocol !== 'https:' || !['www.equateplus.com','www.emea.equateplus.com','www.na.equateplus.com'].includes(location.hostname)
            || !window.__gcEquatePlus?.ready()) throw new Error('EquatePlus: Bitte erneut anmelden.');

        """
        let result = try await browser.webView.callAsyncJavaScript(guardScript + script, arguments: arguments, in: nil, contentWorld: .page)
        try Task.checkCancellation()
        guard let string = result as? String else { throw EquatePlusError.unreadable }
        return string
    }

    /// Optional: the PDFs of the portal's library, only those not stored yet. Not part of the
    /// fetch of the programs, so it can be requested at any time later.
    private func startDocuments() {
        running = true
        notice = nil
        progress = String(localized: "Dokumentenliste abrufen …")
        task = Task {
            guard let pin = model.pinVault() else { running = false; progress = nil; return }
            let connectionId = connection.id
            var downloaded = 0
            var failed = 0
            var open = 0
            var failureSummary = ""
            do {
                let list = try await runScript("return await window.__gcEquatePlus.documents();")
                let pending = try await pin.run { try $0.pendingEquateplusDocuments(connectionId: connectionId, documentsJson: list) }
                open = pending.count
                // structure only: do the portal's document ids stay the same between sign-ins?
                let ids = ((try? JSONSerialization.jsonObject(with: Data(list.utf8))) as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                let sample = ids.prefix(3).map { id in SHA256.hash(data: Data(id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined() }
                NSLog("EquatePlus library: connection=%d total=%d new=%d id-hashes=%@", connectionId, ids.count, pending.count, sample.joined(separator: ","))
                var failures = EquatePlusDocumentFailures()
                for (index, metadata) in pending.enumerated() {
                    try Task.checkCancellation()
                    progress = String(localized: "PDF \(index + 1) von \(pending.count) …")
                    let meta = (try? JSONSerialization.jsonObject(with: Data(metadata.utf8))) as? [String: Any]
                    do {
                        guard let url = meta?["url"] as? String else { throw EquatePlusError.unreadable }
                        let started = Date()
                        let encoded = try await runScript("return await window.__gcEquatePlus.pdf(url);", arguments: ["url": url])
                        let fetched = Date()
                        guard let bytes = Data(base64Encoded: encoded) else { throw EquatePlusError.unreadable }
                        if try await pin.run({ try $0.importEquateplusDocument(connectionId: connectionId, documentJson: metadata, bytes: bytes) }) { downloaded += 1 }
                        // structure only (no names, ids or content): where the time goes
                        let attempts = (try? await runScript("return window.__gcEquatePlus.lastAttempts();")) ?? "?"
                        NSLog("EquatePlus PDF %d/%d type=%@ service=%@ fetch=%.2fs store=%.2fs attempts=%@ bytes=%d", index + 1, pending.count,
                              (meta?["documentType"] as? String) ?? "?", url.contains("/statements/") ? "statements" : "documents",
                              fetched.timeIntervalSince(started), Date().timeIntervalSince(fetched), attempts, bytes.count)
                        failures.succeeded()
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        failed += 1
                        let (reason, sessionLost) = EquatePlusDocumentFailures.reason(for: error)
                        let type = (meta?["documentType"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
                        // One document the portal cannot provide must not stop the others.
                        if failures.failed(reason: "\(reason) · \(type)", sessionLost: sessionLost) {
                            failed += pending.count - index - 1
                            break
                        }
                    }
                }
                failureSummary = failures.summary
                let message = open == 0
                    ? String(localized: "EquatePlus: Keine neuen Dokumente.")
                    : String(localized: "EquatePlus: \(downloaded) neue PDFs in „Belege & PostBox“.")
                model.toast = message
                if failed == 0 { close() }
                else {
                    let detail = failureSummary.isEmpty ? "" : " (\(failureSummary))"
                    notice = message + " " + String(localized: "\(failed) PDFs nicht abrufbar\(detail). Ein erneuter Abruf lädt nur fehlende Dokumente.")
                }
            } catch is CancellationError {
            } catch {
                // Never expose WebKit's raw error: it can include token-bearing URLs.
                notice = String(localized: "EquatePlus: Der Dokumentenabruf ist fehlgeschlagen. Bitte erneut versuchen.")
            }
            await pin.checkpoint()
            progress = nil
            running = false
            model.documentsVersion += 1
            model.reloadAll()
        }
    }

    private func close() { model.webLoginConnection = nil; dismiss() }
}

private enum EquatePlusError: Error { case unreadable }

/// Counts failed documents of one run. A single document that the portal cannot provide must not
/// stop the others; only a lost session or a long run of failures in a row does.
struct EquatePlusDocumentFailures {
    static let limit = 15
    private(set) var consecutive = 0
    private(set) var reasons: [String: Int] = [:]

    mutating func succeeded() { consecutive = 0 }

    /// Returns true when the run should stop.
    mutating func failed(reason: String, sessionLost: Bool) -> Bool {
        consecutive += 1
        reasons[reason, default: 0] += 1
        return sessionLost || consecutive >= Self.limit
    }

    /// The most frequent reasons, e.g. "HTTP 404 · Auftragsbestätigung: 12".
    var summary: String {
        reasons.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(4).map { "\($0.key): \($0.value)" }.joined(separator: ", ")
    }

    /// A short reason from the page script's own message (never raw WebKit text, which can
    /// carry token-bearing URLs) and whether the session is gone.
    static func reason(for error: Error) -> (reason: String, sessionLost: Bool) {
        let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
        if let status = message.range(of: "HTTP [0-9]{3}", options: .regularExpression).map({ String(message[$0]) }) {
            return (status, status.hasSuffix("401") || status.hasSuffix("403"))
        }
        if message.contains("anmelden") { return (String(localized: "nicht angemeldet"), true) }
        if message.contains("kein PDF") {
            // "(text/html, 4568 B)" from the page script: file type and size only
            let detail = message.range(of: "\\((?:[a-z0-9.+/-]{1,60}|unbekannt), [0-9]+ B\\)", options: .regularExpression).map { String(message[$0]) } ?? ""
            return (String(localized: "kein PDF") + (detail.isEmpty ? "" : " " + detail), false)
        }
        if message.contains("rechtzeitig") { return (String(localized: "Zeitüberschreitung"), false) }
        if message.contains("zu groß") { return (String(localized: "zu groß"), false) }
        return (String(localized: "unlesbar"), false)
    }
}
