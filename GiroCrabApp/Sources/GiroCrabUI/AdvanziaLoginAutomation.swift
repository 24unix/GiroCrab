import Foundation
import WebKit

enum AdvanziaAuthMethod: String, CaseIterable, Identifiable, Sendable {
    case sms, app
    var id: String { rawValue }
    var title: String { self == .sms ? "SMS" : "Advanzia-App" }
}

/// The scripts fill only explicitly saved credentials, never read or fill an OTP.
enum AdvanziaLoginScripts {
    static let credentials = #"""
    if (location.origin !== 'https://id.advanzia.com') return false;
    const inputs = Array.from(document.querySelectorAll('input'));
    const isCode = x => x.autocomplete === 'one-time-code' || /(otp|tan|sms|verification|one.?time|(^|_)code)/i.test((x.name || '') + ' ' + (x.id || ''));
    const pwd = inputs.find(x => x.type === 'password' && !x.disabled && !isCode(x));
    const eligible = inputs.filter(x => x !== pwd && !x.disabled && x.autocomplete !== 'one-time-code' && !/(otp|tan|sms|verification|one.?time|(^|_)code)/i.test((x.name || '') + ' ' + (x.id || '')));
    const user = eligible.find(x => x.autocomplete === 'username') || eligible.find(x => x.type === 'text' || x.type === 'email');
    if (!user || !pwd) return false;
    for (const [el,value] of [[user,username],[pwd,password]]) {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(el,value);
      el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true}));
    }
    const submit = Array.from(document.querySelectorAll('button,input[type=submit]'))
      .find(x => x.type === 'submit' || /^anmelden$/i.test((x.innerText || x.value || '').trim()));
    if (!submit || submit.disabled) return false;
    submit.click(); return true;
    """#
    static let method = #"""
    if (location.origin !== 'https://id.advanzia.com') return false;
    const normalize = x => (x || '').replace(/\s+/g,' ').trim().toLowerCase();
    const wanted = method === 'sms' ? ['sms-versand','sms'] :
      method === 'app' ? ['authentifizierung über app','authentifizierung ueber app','advanzia app','advanzia-app','freigabe per app','app-freigabe'] : [];
    const matches = Array.from(document.querySelectorAll('button,a,[role="button"],label,span,div,p'))
      .filter(x => wanted.includes(normalize(x.textContent)) &&
        !Array.from(x.children).some(c => wanted.includes(normalize(c.textContent))));
    if (matches.length !== 1) return false;
    const leaf = matches[0];
    let target = leaf.closest('button,a,[role="button"],[tabindex]');
    if (!target) {
      let parent=leaf.parentElement;
      for (let i=0;i<4 && parent;i++,parent=parent.parentElement) {
        if (parent.onclick || getComputedStyle(parent).cursor === 'pointer') { target=parent;break; }
      }
    }
    if (!target) target=leaf;
    if (target.disabled || target.getBoundingClientRect().width <= 0) return false;
    target.click(); return true;
    """#
}

@MainActor
enum AdvanziaLoginAutomation {
    static func step(webView: WKWebView, loginName: String, password: String?, method: AdvanziaAuthMethod,
                     loginSubmitted: Bool, methodSelected: Bool) async -> Int {
        guard AdvanziaSecurity.isLoginURL(webView.url) else { return 0 }
        if !loginSubmitted, !loginName.isEmpty, let password, !password.isEmpty {
            if (try? await webView.callAsyncJavaScript(AdvanziaLoginScripts.credentials,
                arguments: ["username": loginName, "password": password], in: nil, contentWorld: .page) as? Bool) == true { return 1 }
        }
        if !methodSelected, (try? await webView.callAsyncJavaScript(AdvanziaLoginScripts.method,
            arguments: ["method": method.rawValue], in: nil, contentWorld: .page) as? Bool) == true { return 2 }
        return 0
    }
}
