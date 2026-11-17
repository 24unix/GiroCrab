import Foundation

/// Only structural states cross from the login page. Never return page text or OTP values.
enum AdvanziaAuthentication: String, Sendable {
    case loading, credentials, method, sms, app, rejected, unknown
}

enum AdvanziaAuthenticationScripts {
    static let inspect = #"""
    if (location.origin !== 'https://id.advanzia.com') return 'unknown';
    const visible = e => !e.disabled && e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().height > 0;
    const inputs = Array.from(document.querySelectorAll('input')).filter(visible);
    const codes = inputs.filter(e => ['text','tel','number','password'].includes(e.type) &&
      (e.autocomplete === 'one-time-code' || /(^|[_-])(otp|sms|tan|code|verification)([_-]|$)/i.test((e.name || '') + '_' + (e.id || ''))));
    const rejected = Array.from(document.querySelectorAll('[role="alert"],.alert-danger,.error-message'))
      .some(e => visible(e) && (e.textContent || '').trim().length > 0);
    if (rejected) return 'rejected';
    if (codes.length === 1) return 'sms';
    if (codes.length > 1) return 'unknown';
    if (inputs.some(e => e.type === 'password')) return 'credentials';
    const labels = Array.from(document.querySelectorAll('button,a,[role="button"],label,span,div,p')).filter(visible)
      .map(e => (e.textContent || '').replace(/\s+/g,' ').trim().toLowerCase());
    if (labels.some(t => ['sms-versand','sms','authentifizierung über app','authentifizierung ueber app','advanzia app','advanzia-app','freigabe per app','app-freigabe'].includes(t))) return 'method';
    if (labels.some(t => t.length < 300 && /(?:bitte|bestätigen|freigabe|anmeldung)/.test(t) && /(?:advanzia.?app|in der app|über die app)/.test(t))) return 'app';
    return 'unknown';
    """#

    /// The code comes only from an explicit user submission. It is written once,
    /// never read back and never passed to Rust, the keychain, logs or diagnostics.
    static let submit = #"""
    if (location.origin !== 'https://id.advanzia.com' || !/^[0-9]{4,10}$/.test(code)) return false;
    const visible = e => !e.disabled && e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().height > 0;
    const fields = Array.from(document.querySelectorAll('input')).filter(e => visible(e) &&
      ['text','tel','number','password'].includes(e.type) &&
      (e.autocomplete === 'one-time-code' || /(^|[_-])(otp|sms|tan|code|verification)([_-]|$)/i.test((e.name || '') + '_' + (e.id || ''))));
    if (fields.length !== 1) return false;
    const field = fields[0];
    const form = field.closest('form');
    if (!form) return false;
    const buttons = Array.from(form.querySelectorAll('button,input[type=submit]')).filter(e => visible(e) &&
      (e.type === 'submit' || /^(bestätigen|weiter|prüfen|verifizieren|anmelden|confirm|verify|continue)$/i.test((e.innerText || e.value || '').trim())));
    if (buttons.length !== 1) return false;
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(field,code);
    field.dispatchEvent(new Event('input',{bubbles:true})); field.dispatchEvent(new Event('change',{bubbles:true}));
    buttons[0].click(); return true;
    """#
}
