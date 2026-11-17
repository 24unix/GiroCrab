import Foundation

/// Only transaction responses are retained in the page. No authentication header,
/// cookie, customer response or /details body is copied into Swift or diagnostics.
enum AdvanziaScripts {
    static let hook = #"""
    (() => {
      if (location.origin !== 'https://mein.advanzia.com' || window.__gcAdvanzia) return;
      const nativeFetch = window.fetch.bind(window);
      const history = new Map();
      const accounts = new Set();
      const controllers = new Set();
      const path = value => {
        try {
          const u = new URL(value, location.href);
          if (u.origin !== 'https://mein.advanzia.com') return null;
          const m = u.pathname.match(/^\/api\/accounts\/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\/(transactions(?:\/\d{4}\/\d{1,2})?|details)$/);
          return m ? {url:u.pathname,id:m[1].toLowerCase(),transactions:m[2].startsWith('transactions')} : null;
        } catch { return null; }
      };
      const project = j => {
        if (!j || !Array.isArray(j.transactions) || j.transactions.length > 1000) throw new Error('SCHEMA');
        const keys = ['amount','currency','transactionDate','merchantName','text','status','reference','uniqueReference'];
        return JSON.stringify({transactions:j.transactions.map(t => Object.fromEntries(keys.filter(k => t?.[k] !== undefined).map(k => [k,t[k]])))});
      };
      const remember = (url, text) => {
        const p = path(url);
        if (!p || typeof text !== 'string' || text.length > 3000000) return;
        accounts.add(p.id);
        if (!p.transactions) return;
        try {
          history.set(p.url, project(JSON.parse(text)));
          while (history.size > 36) history.delete(history.keys().next().value);
        } catch { /* Parser and explicit fresh fetch report invalid responses. */ }
      };
      window.fetch = function(input) {
        const url = input instanceof Request ? input.url : String(input);
        const p = path(url);
        if (p) accounts.add(p.id);
        const response = nativeFetch(...arguments);
        if (p?.transactions) response.then(r => { if (r.ok) r.clone().text().then(t => remember(url,t)).catch(() => {}); }).catch(() => {});
        return response;
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method,url) {
        const p = path(String(url));
        if (p) {
          accounts.add(p.id);
          this.addEventListener('load', () => {
            if (p.transactions && this.status >= 200 && this.status < 300 && (this.responseType === '' || this.responseType === 'text')) remember(String(url),this.responseText);
          }, {once:true});
        }
        return open.apply(this,arguments);
      };
      const read = async (url, signal) => {
        const r = await nativeFetch(url,{method:'GET',credentials:'same-origin',cache:'no-store',redirect:'error',headers:{Accept:'application/json'},signal});
        if (!r.ok) throw new Error(r.status === 401 || r.status === 403 ? 'AUTH' : 'HTTP');
        if (!(r.headers.get('content-type') || '').toLowerCase().includes('json')) throw new Error('SCHEMA');
        const reader = r.body.getReader();
        const decoder = new TextDecoder();
        let size=0, text='';
        while (true) {
          const {done,value} = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > 3000000) { await reader.cancel(); throw new Error('SIZE'); }
          text += decoder.decode(value,{stream:true});
        }
        return JSON.parse(text + decoder.decode());
      };
      window.__gcAdvanzia = {
        discover: () => {
          for (const r of performance.getEntriesByType('resource')) { const p=path(r.name); if(p) accounts.add(p.id); }
          return Array.from(accounts);
        },
        openTransactions: () => {
          const labels=['umsätze','umsatzübersicht','transaktionen'];
          const candidates=Array.from(document.querySelectorAll('a,button,[role="tab"]')).filter(e =>
            labels.includes((e.textContent || '').replace(/\s+/g,' ').trim().toLowerCase()) &&
            !e.disabled && e.getBoundingClientRect().width>0);
          if(candidates.length!==1) return false;
          const link=candidates[0];
          if(link.href && new URL(link.href,location.href).origin!==location.origin) return false;
          link.click();return true;
        },
        cancel: () => { for (const c of controllers) c.abort(); },
        collect: async id => {
          if (location.origin !== 'https://mein.advanzia.com' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id) || accounts.size > 1 || (accounts.size === 1 && !accounts.has(id))) return {error:'ACCOUNT'};
          const c = new AbortController(); controllers.add(c);
          const timeout = setTimeout(() => c.abort(),30000);
          try {
            const base = '/api/accounts/' + id;
            const current = project(await read(base + '/transactions',c.signal));
            const details = await read(base + '/details',c.signal);
            if (typeof details?.accountId !== 'string' || details.accountId.toLowerCase() !== id || details.currency !== 'EUR' ||
                typeof details.balance !== 'number' || !Number.isFinite(details.balance)) throw new Error('BALANCE');
            const bodies = Array.from(history.entries()).filter(([url]) => url.startsWith(base + '/transactions/')).map(([,body])=>body);
            bodies.push(current);
            if (bodies.reduce((n,b)=>n+b.length,0)>12000000) throw new Error('SIZE');
            return {bodies,balance:JSON.stringify(details.balance)};
          } catch(e) {
            const safe = ['AUTH','HTTP','SCHEMA','SIZE','BALANCE','ACCOUNT'];
            return {error:e.name==='AbortError'?'TIMEOUT':safe.includes(e.message)?e.message:'NETWORK'};
          } finally {clearTimeout(timeout);controllers.delete(c);}
        }
      };
    })();
    """#
}

enum AdvanziaSecurity {
    static func isPortalURL(_ url: URL?) -> Bool { allowed(url, host: "mein.advanzia.com") }
    static func isLoginURL(_ url: URL?) -> Bool { allowed(url, host: "id.advanzia.com") }
    private static func allowed(_ url: URL?, host: String) -> Bool {
        url?.scheme == "https" && url?.host == host && (url?.port == nil || url?.port == 443)
            && url?.user == nil && url?.password == nil
    }
    static func account(_ value: String) -> String? { UUID(uuidString: value)?.uuidString.lowercased() }
    static func errorMessage(_ code: String) -> String {
        switch code {
        case "AUTH": return String(localized: "Advanzia-Sitzung abgelaufen. Bitte erneut anmelden und die gewählte Freigabe bestätigen.")
        case "TIMEOUT": return String(localized: "Advanzia hat nicht rechtzeitig geantwortet. Bitte den Abruf erneut starten.")
        case "ACCOUNT": return String(localized: "Advanzia meldet eine andere Karte. Der Import wurde gestoppt.")
        case "DISCOVERY": return String(localized: "Die Advanzia-Karte wurde noch nicht erkannt. Öffnen Sie im Bankfenster die Umsatzübersicht; GiroCrab übernimmt die Daten anschließend automatisch.")
        case "HTTP": return String(localized: "Die Advanzia-API hat den Abruf abgelehnt. Bitte erneut anmelden oder den Abruf wiederholen.")
        case "SCHEMA": return String(localized: "Die Advanzia-Antwort hat ein unerwartetes Format. Es wurden keine unvollständigen Daten importiert.")
        case "SIZE": return String(localized: "Die Advanzia-Antwort ist zu groß. Es wurden keine unvollständigen Daten importiert.")
        case "BALANCE": return String(localized: "Der Advanzia-Bankkontostand konnte nicht bestätigt werden. Es wurden keine Umsätze importiert.")
        default: return String(localized: "Advanzia konnte nicht sicher abgerufen werden. Bitte die Umsatzübersicht öffnen und erneut versuchen.")
        }
    }
}
