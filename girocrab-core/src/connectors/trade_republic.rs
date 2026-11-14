//! Trade Republic – web login + WebSocket API.
//!
//! Trade Republic publishes no official API; this connector follows the
//! publicly observable behaviour of the web app (as also used by the
//! open-source `pytr` project):
//!
//!  POST https://api.traderepublic.com/api/v1/auth/web/login       (fallback: /api/v2/…)
//!       {"phoneNumber": "+49…", "pin": "1234"}   -> {"processId", "countdownInSeconds"}
//!  POST …/auth/web/login/{processId}/sms                          (optional: code per SMS)
//!  POST …/auth/web/login/{processId}/{code}  -> HTTP 200, often EMPTY body;
//!       the session arrives as Set-Cookie (tr_session, tr_refresh)
//!  GET  …/api/v1/auth/web/session            -> refreshes a stored session
//!  WSS  wss://api.traderepublic.com  (Cookie + Origin headers)
//!       "connect 31 {…}" -> "connected"
//!       "sub 1 {\"type\":\"cash\"}"                         (fallback "availableCash")
//!       "sub 2 {\"type\":\"timelineTransactions\",\"after\":…}"
//!       frames: "<id> A <json>" (answer), "<id> E <json>" (error), "<id> C" (complete)
//!
//! The session cookies are stored (encrypted) in the connection state so the
//! next sync needs no new 2FA code. Cookies from the in-app browser login
//! (WKWebView) can be handed over with `Vault::set_connection_session`.
//! It may break whenever Trade Republic changes its web app.

use std::sync::Arc;

use async_trait::async_trait;
use futures_util::{SinkExt, StreamExt};
use reqwest::cookie::{CookieStore, Jar};
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, ORIGIN, REFERER, SET_COOKIE, USER_AGENT};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;

use super::{
    BankConnector, Challenge, ChallengeKind, ChallengeResponse, ConnectContext, FetchResult, Phase,
    RemoteAccount, RemoteTransaction,
};
use crate::error::{CoreError, CoreResult};
use crate::i18n::{tr, trf};
use crate::models::AccountKind;
use crate::money::json_number_to_cents;

const API: &str = "https://api.traderepublic.com";
const WS: &str = "wss://api.traderepublic.com";
pub const BROWSER_UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";
const APP_ORIGIN: &str = "https://app.traderepublic.com";

/// Strict E.164 for German numbers: "0171 1234567", "0049171…", "49171…",
/// "17012345678" -> "+491711234567" / "+4917012345678".
#[uniffi::export]
pub fn normalize_phone_number(input: String) -> String {
    normalize_phone(&input)
}

pub fn normalize_phone(input: &str) -> String {
    let t = input.trim();
    let plus = t.starts_with('+');
    let digits: String = t.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return String::new();
    }
    if plus {
        return format!("+{digits}");
    }
    if let Some(rest) = digits.strip_prefix("00") {
        return format!("+{rest}");
    }
    if let Some(rest) = digits.strip_prefix('0') {
        return format!("+49{rest}");
    }
    if digits.starts_with("49") && digits.len() >= 12 {
        return format!("+{digits}");
    }
    // German mobile numbers without the trunk 0 ("1512…", "171…")
    format!("+49{digits}")
}

/// Value of one cookie in a "a=1; b=2" header string.
fn cookie_value(cookies: &str, name: &str) -> Option<String> {
    cookies
        .split(';')
        .filter_map(|p| p.trim().split_once('='))
        .find(|(k, _)| k.trim() == name)
        .map(|(_, v)| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

/// "a=1; b=2" + Set-Cookie values -> merged "name=value; …" (later wins).
fn merge_cookies(existing: &str, set_cookie_values: &[String]) -> String {
    let mut pairs: Vec<(String, String)> = existing
        .split(';')
        .filter_map(|p| {
            p.trim()
                .split_once('=')
                .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
        })
        .filter(|(k, _)| !k.is_empty())
        .collect();
    for sc in set_cookie_values {
        let first = sc.split(';').next().unwrap_or("");
        if let Some((k, v)) = first.split_once('=') {
            let (k, v) = (k.trim().to_string(), v.trim().to_string());
            pairs.retain(|(pk, _)| *pk != k);
            if !v.is_empty() {
                pairs.push((k, v));
            }
        }
    }
    pairs
        .into_iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("; ")
}

fn snippet(body: &str) -> String {
    let b = body.trim();
    if b.is_empty() {
        "(leere Antwort)".into()
    } else if b.chars().count() > 300 {
        format!("{}…", b.chars().take(300).collect::<String>())
    } else {
        b.to_string()
    }
}

/// Amounts arrive as JSON numbers that may carry float noise (-4.040000000000001).
fn amount_cents(v: &Value) -> i64 {
    json_number_to_cents(v)
        .unwrap_or_else(|_| v.as_f64().map(|f| (f * 100.0).round() as i64).unwrap_or(0))
}

/// A number in a detail text such as "1.234,56 €", "0,5" or "12.5": German
/// notation first. A lone `.` followed by exactly three digits after at most
/// three is a thousands separator ("1.234"), otherwise a decimal point.
fn parse_decimal_text(text: &str) -> Option<f64> {
    let t: String = text
        .chars()
        .filter(|c| c.is_ascii_digit() || matches!(c, ',' | '.' | '-' | '−'))
        .map(|c| if c == '−' { '-' } else { c })
        .collect();
    if t.is_empty() || !t.chars().any(|c| c.is_ascii_digit()) {
        return None;
    }
    let norm = match (t.rfind(','), t.rfind('.')) {
        (Some(c), Some(d)) if c > d => t.replace('.', "").replace(',', "."),
        (Some(_), Some(_)) => t.replace(',', ""),
        (Some(_), None) => t.replace(',', "."),
        (None, Some(d)) => {
            let (head, tail) = t.split_at(d);
            let thousands = tail.len() == 4
                && head.trim_start_matches('-').len() <= 3
                && !head.trim_start_matches('-').contains('.');
            if thousands {
                t.replace('.', "")
            } else {
                t
            }
        }
        (None, None) => t,
    };
    norm.parse().ok()
}

/// What a trade's detail screen (`timelineDetailV2`) tells besides the
/// timeline row: ISIN, units, price per unit, fees and taxes.
#[derive(Debug, Default, PartialEq)]
struct TradeDetail {
    isin: Option<String>,
    quantity: Option<f64>,
    price_cents: Option<i64>,
    fees_cents: Option<i64>,
    taxes_cents: Option<i64>,
}

/// `logos/US0378331005/v2` or a bare ISIN → the ISIN.
fn isin_of(icon: &str) -> Option<String> {
    let rest = icon.find('/').map_or(icon, |i| &icon[i + 1..]);
    let isin = rest.split('/').next().unwrap_or_default();
    (isin.len() == 12
        && isin[..2].chars().all(|c| c.is_ascii_uppercase())
        && isin[2..]
            .chars()
            .all(|c| c.is_ascii_digit() || c.is_ascii_uppercase()))
    .then(|| isin.to_string())
}

fn walk_rows(v: &Value, f: &mut dyn FnMut(&str, &str)) {
    match v {
        Value::Object(m) => {
            if let Some(title) = m.get("title").and_then(Value::as_str) {
                let text = m
                    .get("detail")
                    .and_then(|d| d["text"].as_str().or_else(|| d.as_str()))
                    .unwrap_or_default();
                f(title, text);
            }
            m.values().for_each(|x| walk_rows(x, f));
        }
        Value::Array(a) => a.iter().for_each(|x| walk_rows(x, f)),
        _ => {}
    }
}

fn parse_trade_detail(item_icon: &str, detail: &Value) -> TradeDetail {
    let mut d = TradeDetail {
        isin: isin_of(item_icon),
        ..Default::default()
    };
    if d.isin.is_none() {
        // header section carries the instrument icon, an action its ISIN
        if let Some(sections) = detail["sections"].as_array() {
            d.isin = sections.iter().find_map(|s| {
                let icon = s["data"]["icon"]
                    .as_str()
                    .or_else(|| s["data"]["icon"]["asset"].as_str());
                icon.and_then(isin_of).or_else(|| {
                    (s["action"]["type"] == "instrumentDetail")
                        .then(|| s["action"]["payload"].as_str().and_then(isin_of))
                        .flatten()
                })
            });
        }
    }
    let cents = |t: &str| parse_decimal_text(t).map(|f| (f * 100.0).round() as i64);
    walk_rows(detail, &mut |title, text| {
        match title {
            "Aktien" | "Anteile" | "Shares" | "Aktien hinzugefügt" | "Aktien entfernt"
                if d.quantity.is_none() =>
            {
                d.quantity = parse_decimal_text(text).map(f64::abs);
            }
            "Preis" | "Kurs" | "Aktienkurs" | "Quotation" | "Price" if d.price_cents.is_none() => {
                d.price_cents = cents(text).map(i64::abs);
            }
            "Gebühr" | "Gebühren" | "Fee" if d.fees_cents.is_none() => {
                d.fees_cents = cents(text).map(i64::abs);
            }
            "Steuer" | "Steuern" | "Tax" if d.taxes_cents.is_none() => {
                d.taxes_cents = cents(text).map(i64::abs);
            }
            _ => {}
        };
    });
    d
}

/// A timeline row of a trade, dividend or savings plan that has a detail screen.
struct TradeRow {
    id: String,
    date: String,
    title: String,
    kind_text: String,
    amount_cents: i64,
    currency: String,
    icon: String,
}

fn is_trade_kind(kind_text: &str) -> bool {
    [
        "kauf",
        "sparplan",
        "savings_plan",
        "trade",
        "dividende",
        "dividend",
        "ausschüttung",
    ]
    .iter()
    .any(|k| kind_text.contains(k))
}

/// The securities side of a trade row (#314). Direction from the row's text
/// (sell before buy: "Verkauf" contains "kauf"), ISIN, units, price, fees and
/// taxes from the detail screen. Without ISIN or direction there is no
/// securities transaction. Value: units × price, else the cash amount
/// without fees and taxes. Best effort: the screen is not a documented API.
fn trade_security(row: &TradeRow, detail: &Value) -> Option<super::RemoteSecurityTransaction> {
    use crate::models::{SecurityDirection, SecurityTransaction};
    let k = &row.kind_text;
    let direction = if k.contains("dividend") || k.contains("ausschüttung") {
        SecurityDirection::Dividend
    } else if k.contains("verkauf") || k.contains("sell") {
        SecurityDirection::Sell
    } else if k.contains("kauf")
        || k.contains("sparplan")
        || k.contains("savings_plan")
        || k.contains("buy")
    {
        SecurityDirection::Buy
    } else {
        return None;
    };
    let d = parse_trade_detail(&row.icon, detail);
    let isin = d.isin?;
    let fees = d.fees_cents.unwrap_or(0);
    let taxes = d.taxes_cents.unwrap_or(0);
    let cash = row.amount_cents.abs();
    let quantity = d.quantity.unwrap_or(0.0);
    let by_price = d
        .price_cents
        .filter(|_| quantity > 0.0)
        .map(|p| (p as f64 * quantity).round() as i64);
    let value = by_price.unwrap_or(match direction {
        SecurityDirection::Buy => (cash - fees - taxes).max(0),
        SecurityDirection::Sell => cash + fees + taxes,
        _ => cash + taxes,
    });
    let price_cents = d.price_cents.unwrap_or(if quantity > 0.0 {
        (value as f64 / quantity).round() as i64
    } else {
        0
    });
    Some(super::RemoteSecurityTransaction {
        account_ref: "tr:depot".into(),
        external_id: row.id.clone(),
        cash_external_id: row.id.clone(),
        transaction: SecurityTransaction {
            booking_date: row.date.clone(),
            isin,
            name: row.title.clone(),
            direction,
            quantity,
            price_cents,
            currency: if row.currency.is_empty() {
                "EUR".into()
            } else {
                row.currency.clone()
            },
            value_cents: value,
            fees_cents: fees,
            taxes_cents: taxes,
            booking_text: row.kind_text.trim().to_string(),
            ..Default::default()
        },
    })
}

pub struct TradeRepublicConnector {
    jar: Arc<Jar>,
    client: Option<reqwest::Client>,
    process_id: String,
    phone: String,
    /// "tr_session=…; tr_refresh=…"
    cookies: String,
    session_token: String,
    challenge: Option<Challenge>,
    /// Timeline item ids whose documents were already downloaded.
    known_doc_items: Vec<String>,
}

impl TradeRepublicConnector {
    pub fn new() -> Self {
        TradeRepublicConnector {
            jar: Arc::new(Jar::default()),
            client: None,
            process_id: String::new(),
            phone: String::new(),
            cookies: String::new(),
            session_token: String::new(),
            challenge: None,
            known_doc_items: Vec::new(),
        }
    }

    fn ws_err(e: impl std::fmt::Display) -> CoreError {
        CoreError::Network {
            message: format!("WebSocket: {e}"),
        }
    }

    fn client(&mut self) -> CoreResult<reqwest::Client> {
        if let Some(c) = &self.client {
            return Ok(c.clone());
        }
        let mut h = HeaderMap::new();
        h.insert(USER_AGENT, HeaderValue::from_static(BROWSER_UA));
        h.insert(ORIGIN, HeaderValue::from_static(APP_ORIGIN));
        h.insert(
            REFERER,
            HeaderValue::from_static("https://app.traderepublic.com/"),
        );
        h.insert(ACCEPT, HeaderValue::from_static("application/json"));
        h.insert(
            "Accept-Language",
            HeaderValue::from_static("de-DE,de;q=0.9"),
        );
        let c = reqwest::Client::builder()
            .cookie_provider(self.jar.clone())
            .default_headers(h)
            .timeout(std::time::Duration::from_secs(30))
            .build()?;
        self.client = Some(c.clone());
        Ok(c)
    }

    /// Reads status, Set-Cookie headers and body of a response.
    async fn read(resp: reqwest::Response) -> (u16, Vec<String>, String) {
        let status = resp.status().as_u16();
        let cookies = resp
            .headers()
            .get_all(SET_COOKIE)
            .iter()
            .filter_map(|v| v.to_str().ok().map(|s| s.to_string()))
            .collect();
        let body = super::read_text_limited(resp).await.unwrap_or_default();
        (status, cookies, body)
    }

    fn http_error(step: &str, status: u16, body: &str) -> CoreError {
        let hint = match status {
            403 | 405 => tr(" – AWS-WAF-Schutz von Trade Republic. Bitte „Im Browser-Fenster anmelden“ verwenden."),
            426 => tr(" – CLIENT_VERSION_OUTDATED: Trade Republic verlangt einen neueren Client. Bitte „Im Browser-Fenster anmelden“ verwenden."),
            401 => tr(" – PIN, Code oder Sitzung ungültig."),
            429 => tr(" – zu viele Versuche, bitte etwas warten."),
            _ => "",
        };
        CoreError::Bank {
            code: format!("HTTP {status}"),
            message: trf(
                "Trade Republic {0}{1} Antwort: {2}",
                &[&step, &hint, &snippet(body)],
            ),
        }
    }

    fn code_challenge(&mut self, message: String, countdown: Option<u32>) -> Phase {
        let c = Challenge {
            kind: ChallengeKind::Code,
            title: "Trade Republic 2FA".into(),
            message,
            method_name: tr("App-Code (oder SMS)").into(),
            redirect_url: None,
            image: None,
            expires_in_seconds: countdown,
            poll_interval_seconds: 0,
        };
        self.challenge = Some(c.clone());
        Phase::Challenge(c)
    }

    fn state(&self) -> Value {
        let keep: Vec<&String> = self.known_doc_items.iter().rev().take(2000).collect();
        json!({
            "cookies": self.cookies,
            "session_token": self.session_token,
            "phone": self.phone,
            "saved_unix": chrono::Utc::now().timestamp(),
            "doc_items": keep,
        })
    }

    /// Tries to refresh a stored session. Ok(true) = usable.
    async fn refresh_session(&mut self) -> CoreResult<bool> {
        let client = self.client()?;
        let resp = client
            .get(format!("{API}/api/v1/auth/web/session"))
            .header("Cookie", self.cookies.clone())
            .send()
            .await?;
        let (status, set, _body) = Self::read(resp).await;
        if (200..300).contains(&status) {
            self.cookies = merge_cookies(&self.cookies, &set);
            return Ok(true);
        }
        // 401/403: expired. Anything else (endpoint moved …): try the WebSocket anyway.
        Ok(!(status == 401 || status == 403))
    }
}

/// Browser login needed (no WAF token). `expired`: a stored session was just
/// refused by Trade Republic.
fn browser_login_message(expired: bool) -> &'static str {
    if expired {
        tr("Die Trade-Republic-Sitzung ist abgelaufen. Bitte im Browser-Fenster neu anmelden – die neue Sitzung wird danach gespeichert.")
    } else {
        tr("Trade Republic schützt die Anmeldung mit AWS WAF. Bitte im Browser-Fenster anmelden – die Sitzung wird danach gespeichert und wiederverwendet.")
    }
}

/// PIN needed for a direct login. `expired`: as above.
fn pin_prompt_message(expired: bool) -> &'static str {
    if expired {
        tr("Die Trade-Republic-Sitzung ist abgelaufen. Bitte die 4-stellige PIN eingeben (oder „Im Browser-Fenster anmelden“).")
    } else {
        tr("Bitte die 4-stellige Trade-Republic-PIN eingeben (oder „Im Browser-Fenster anmelden“).")
    }
}

impl Default for TradeRepublicConnector {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl BankConnector for TradeRepublicConnector {
    async fn begin(&mut self, ctx: &ConnectContext) -> CoreResult<Phase> {
        self.phone = normalize_phone(&ctx.login_name);
        self.cookies = ctx.state["cookies"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        self.session_token = ctx.state["session_token"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        self.known_doc_items = ctx.state["doc_items"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();
        // 1) Stored browser/API session (tr_session) -> no PIN, no 2FA.
        let had_session = self.cookies.contains("tr_session=");
        if had_session && self.refresh_session().await? {
            return Ok(Phase::Ready);
        }
        // A stored session that Trade Republic no longer accepts: say so, so
        // the PIN / browser prompt below doesn't look like a new problem.
        let expired = had_session;
        // 2) Direct login only with a WAF token harvested by the browser
        //    (aws-waf-token cookie); a bare request gets HTTP 405 from AWS WAF.
        let waf = cookie_value(&self.cookies, "aws-waf-token");
        if waf.is_none() {
            return Err(CoreError::BrowserLoginRequired {
                message: browser_login_message(expired).into(),
            });
        }
        if self.phone.len() < 8 {
            return Err(CoreError::InvalidInput { message: trf("Telefonnummer fehlt oder ist ungültig („{0}“). Bitte z. B. +4915112345678 eintragen.", &[&ctx.login_name]) });
        }
        if ctx.secret.is_empty() {
            return Err(CoreError::Authentication {
                message: pin_prompt_message(expired).into(),
            });
        }
        let client = self.client()?;
        let body = json!({"phoneNumber": self.phone, "pin": ctx.secret.expose()});
        let mut last = (0u16, String::new());
        for version in ["v1", "v2"] {
            let resp = client
                .post(format!("{API}/api/{version}/auth/web/login"))
                .header("x-aws-waf-token", waf.clone().unwrap_or_default())
                .header("Cookie", self.cookies.clone())
                .json(&body)
                .send()
                .await?;
            let (status, set, text) = Self::read(resp).await;
            self.cookies = merge_cookies(&self.cookies, &set);
            if (200..300).contains(&status) {
                let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
                self.process_id = v["processId"].as_str().unwrap_or_default().to_string();
                if self.process_id.is_empty() {
                    return Err(Self::http_error(
                        tr("Login (keine processId)"),
                        status,
                        &text,
                    ));
                }
                let countdown = v["countdownInSeconds"].as_u64().map(|s| s as u32);
                return Ok(self.code_challenge(
                    tr("Geben Sie den 4-stelligen Code ein, der in der Trade-Republic-App angezeigt wird. Keine Push-Nachricht erhalten? „Code per SMS“ wählen.").into(),
                    countdown,
                ));
            }
            last = (status, text);
            if !(status == 404 || status == 426) {
                break; // v2 only as fallback for "not found" / "outdated client"
            }
        }
        if matches!(last.0, 403 | 405) {
            return Err(CoreError::BrowserLoginRequired {
                message: trf(
                    "AWS WAF hat den Login abgelehnt (HTTP {0}). Bitte im Browser-Fenster anmelden.",
                    &[&last.0],
                ),
            });
        }
        Err(Self::http_error("Login", last.0, &last.1))
    }

    async fn respond(
        &mut self,
        _ctx: &ConnectContext,
        response: ChallengeResponse,
    ) -> CoreResult<Phase> {
        let ChallengeResponse::Code(code) = response else {
            return Err(CoreError::InvalidInput {
                message: tr("Trade Republic benötigt den 4-stelligen Code").into(),
            });
        };
        let client = self.client()?;
        let code = code.expose().trim().to_string();
        if code.eq_ignore_ascii_case("sms") {
            let resp = client
                .post(format!(
                    "{API}/api/v1/auth/web/login/{}/sms",
                    self.process_id
                ))
                .send()
                .await?;
            let (status, _, text) = Self::read(resp).await;
            if !(200..300).contains(&status) {
                return Err(Self::http_error(tr("SMS-Anforderung"), status, &text));
            }
            return Ok(self.code_challenge(
                tr("Der Code wurde per SMS gesendet. Bitte die 4 Ziffern eingeben.").into(),
                None,
            ));
        }
        if !(code.len() == 4 && code.chars().all(|c| c.is_ascii_digit())) {
            return Err(CoreError::InvalidInput {
                message: tr("Der Code muss aus 4 Ziffern bestehen.").into(),
            });
        }
        let resp = client
            .post(format!(
                "{API}/api/v1/auth/web/login/{}/{}",
                self.process_id, code
            ))
            .send()
            .await?;
        let (status, set, text) = Self::read(resp).await;
        if !(200..300).contains(&status) {
            return Err(Self::http_error(tr("2FA-Bestätigung"), status, &text));
        }
        // HTTP 200 with an EMPTY body (or {}) is normal: the session comes as Set-Cookie.
        self.cookies = merge_cookies(&self.cookies, &set);
        if let Ok(v) = serde_json::from_str::<Value>(&text) {
            if let Some(t) = v["sessionToken"].as_str() {
                self.session_token = t.to_string();
            }
        }
        if self.cookies.is_empty() {
            let url: url::Url = API.parse().map_err(|e| CoreError::Protocol {
                message: format!("{e}"),
            })?;
            if let Some(h) = self.jar.cookies(&url) {
                self.cookies = h.to_str().unwrap_or_default().to_string();
            }
        }
        if !self.cookies.contains("tr_session") && self.session_token.is_empty() {
            return Err(CoreError::Authentication {
                message: trf(
                    "Trade Republic hat keine Sitzung (tr_session) gesetzt. HTTP {0}, Antwort: {1}",
                    &[&status, &snippet(&text)],
                ),
            });
        }
        Ok(Phase::Ready)
    }

    async fn fetch(&mut self, ctx: &ConnectContext) -> CoreResult<FetchResult> {
        let mut req = WS.into_client_request().map_err(Self::ws_err)?;
        {
            let h = req.headers_mut();
            if !self.cookies.is_empty() {
                h.insert(
                    "Cookie",
                    HeaderValue::from_str(&self.cookies).map_err(Self::ws_err)?,
                );
            }
            h.insert("Origin", HeaderValue::from_static(APP_ORIGIN));
            h.insert("User-Agent", HeaderValue::from_static(BROWSER_UA));
        }
        let (mut ws, _) = tokio_tungstenite::connect_async(req).await.map_err(|e| {
            let detail = match &e {
                tokio_tungstenite::tungstenite::Error::Http(resp) => format!(
                    "HTTP {} {}",
                    resp.status(),
                    resp.body().as_ref().map(|b| snippet(&crate::text::decode_bank_bytes(b))).unwrap_or_default()
                ),
                other => other.to_string(),
            };
            if detail.starts_with("HTTP 401") || detail.starts_with("HTTP 403") {
                return CoreError::BrowserLoginRequired { message: trf("Trade-Republic-Sitzung abgelaufen ({0}). Bitte im Browser-Fenster neu anmelden.", &[&detail]) };
            }
            CoreError::Network { message: trf("WebSocket-Verbindung abgelehnt: {0}", &[&detail]) }
        })?;
        let hello = json!({"locale": "de", "platformId": "webtrading", "platformVersion": "safari - 18.0.0", "clientId": "app.traderepublic.com", "clientVersion": "1.2.0"});
        ws.send(Message::text(format!("connect 31 {hello}")))
            .await
            .map_err(Self::ws_err)?;
        // wait for "connected"
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(15);
        loop {
            let msg = tokio::time::timeout_at(deadline, ws.next())
                .await
                .map_err(|_| CoreError::Network {
                    message: tr(
                        "Trade Republic hat „connect 31“ nicht bestätigt (Zeitüberschreitung).",
                    )
                    .into(),
                })?
                .ok_or_else(|| CoreError::Network {
                    message: tr(
                        "WebSocket wurde vor „connected“ geschlossen – Sitzung abgelaufen?",
                    )
                    .into(),
                })?
                .map_err(Self::ws_err)?;
            if let Message::Text(t) = msg {
                let t = t.to_string();
                if t.trim() == "connected" {
                    break;
                }
                return Err(CoreError::Bank {
                    code: "WS".into(),
                    message: trf("Unerwartete Antwort auf connect: {0}", &[&snippet(&t)]),
                });
            }
        }

        let token = self.session_token.clone();
        // Waits for the first answer ("<id> A <json>") of a subscription.
        async fn request<S>(
            ws: &mut S,
            id: u32,
            mut payload: Value,
            token: &str,
        ) -> CoreResult<Value>
        where
            S: futures_util::Stream<Item = Result<Message, tokio_tungstenite::tungstenite::Error>>
                + futures_util::Sink<Message>
                + Unpin,
            <S as futures_util::Sink<Message>>::Error: std::fmt::Display,
        {
            if !token.is_empty() {
                payload["token"] = json!(token);
            }
            let kind = payload["type"].as_str().unwrap_or("?").to_string();
            ws.send(Message::text(format!("sub {id} {payload}")))
                .await
                .map_err(TradeRepublicConnector::ws_err)?;
            let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(20);
            loop {
                let msg = tokio::time::timeout_at(deadline, ws.next())
                    .await
                    .map_err(|_| CoreError::Network {
                        message: trf("Trade Republic hat auf „{0}“ nicht geantwortet.", &[&kind]),
                    })?
                    .ok_or_else(|| CoreError::Network {
                        message: trf("WebSocket während „{0}“ geschlossen.", &[&kind]),
                    })?
                    .map_err(TradeRepublicConnector::ws_err)?;
                let Message::Text(text) = msg else { continue };
                let text = text.to_string();
                let mut parts = text.splitn(3, ' ');
                let (Some(rid), Some(code)) = (parts.next(), parts.next()) else {
                    continue;
                };
                if rid != id.to_string() {
                    continue;
                }
                let body = parts.next().unwrap_or("null");
                let _ = ws.send(Message::text(format!("unsub {id}"))).await;
                return match code {
                    "A" => Ok(serde_json::from_str(body)?),
                    "E" => Err(CoreError::Bank {
                        code: format!("WS {kind}"),
                        message: trf("Fehler-Frame: {0}", &[&snippet(body)]),
                    }),
                    _ => Ok(Value::Null),
                };
            }
        }

        let mut out = FetchResult::default();
        let cash = match request(&mut ws, 1, json!({"type": "cash"}), &token).await {
            Ok(v) => v,
            Err(_) => request(&mut ws, 3, json!({"type": "availableCash"}), &token)
                .await
                .unwrap_or(Value::Null),
        };
        let items: Vec<Value> = match &cash {
            Value::Array(a) => a.clone(),
            Value::Object(_) => vec![cash.clone()],
            _ => vec![],
        };
        let eur = items
            .iter()
            .find(|c| c["currencyId"].as_str().unwrap_or("EUR") == "EUR")
            .cloned()
            .unwrap_or(Value::Null);
        let balance = if eur["amount"].is_null() {
            amount_cents(&eur["value"])
        } else {
            amount_cents(&eur["amount"])
        };
        let iban = ["iban", "accountNumber"]
            .iter()
            .find_map(|k| {
                eur[*k]
                    .as_str()
                    .filter(|s| s.len() > 10)
                    .map(|s| s.to_string())
            })
            .unwrap_or_default();
        out.accounts.push(RemoteAccount {
            external_ref: "tr:cash".into(),
            name: "Verrechnungskonto".into(),
            owner: String::new(),
            iban,
            account_number: self.phone.clone(),
            currency: "EUR".into(),
            kind: AccountKind::Checking,
            balance_cents: balance,
            balance_date: super::today(),
        });

        let mut cursor: Option<String> = None;
        let mut sub_id = 2u32;
        let mut doc_candidates: Vec<(String, String, String)> = Vec::new();
        let mut trade_rows: Vec<TradeRow> = Vec::new();
        'pages: for _ in 0..200 {
            let mut payload = json!({"type": "timelineTransactions"});
            if let Some(c) = &cursor {
                payload["after"] = json!(c);
            }
            let page = request(&mut ws, sub_id, payload, &token).await?;
            sub_id += 2;
            for item in page["items"].as_array().cloned().unwrap_or_default() {
                let date: String = item["timestamp"]
                    .as_str()
                    .unwrap_or("")
                    .chars()
                    .take(10)
                    .collect();
                if !date.is_empty() && date.as_str() < ctx.since.as_str() {
                    break 'pages;
                }
                if item["amount"].is_null() || item["status"].as_str() == Some("CANCELED") {
                    continue;
                }
                let subtitle = item["subtitle"].as_str().unwrap_or_default().to_string();
                let item_id = item["id"].as_str().unwrap_or_default().to_string();
                let kind_text = format!(
                    "{} {} {}",
                    subtitle,
                    item["eventType"].as_str().unwrap_or(""),
                    item["title"].as_str().unwrap_or("")
                )
                .to_lowercase();
                if !item_id.is_empty()
                    && !self.known_doc_items.contains(&item_id)
                    && [
                        "sparplan",
                        "savings_plan",
                        "kauf",
                        "verkauf",
                        "order",
                        "trade",
                        "zinsen",
                        "interest",
                        "dividende",
                        "dividend",
                        "steuer",
                        "tax",
                        "saveback",
                        "round up",
                        "spare_change",
                        "ausschüttung",
                        "corporate_action",
                    ]
                    .iter()
                    .any(|k| kind_text.contains(k))
                {
                    doc_candidates.push((
                        item_id.clone(),
                        date.clone(),
                        item["title"].as_str().unwrap_or_default().to_string(),
                    ));
                }
                if !item_id.is_empty() && is_trade_kind(&kind_text) {
                    trade_rows.push(TradeRow {
                        id: item_id.clone(),
                        date: date.clone(),
                        title: item["title"].as_str().unwrap_or_default().to_string(),
                        kind_text: kind_text.clone(),
                        amount_cents: amount_cents(&item["amount"]["value"]),
                        currency: item["amount"]["currency"]
                            .as_str()
                            .unwrap_or("EUR")
                            .to_string(),
                        icon: item["icon"].as_str().unwrap_or_default().to_string(),
                    });
                }
                out.transactions.push(RemoteTransaction {
                    account_ref: "tr:cash".into(),
                    external_id: item["id"].as_str().unwrap_or_default().to_string(),
                    booking_date: date.clone(),
                    value_date: date,
                    amount_cents: amount_cents(&item["amount"]["value"]),
                    currency: item["amount"]["currency"]
                        .as_str()
                        .unwrap_or("EUR")
                        .to_string(),
                    counterparty: item["title"].as_str().unwrap_or_default().to_string(),
                    counterparty_iban: String::new(),
                    purpose: subtitle.clone(),
                    booking_text: if subtitle.is_empty() {
                        item["eventType"].as_str().unwrap_or_default().to_string()
                    } else {
                        subtitle
                    },
                    ..Default::default()
                });
            }
            cursor = page["cursors"]["after"].as_str().map(|s| s.to_string());
            if cursor.is_none() {
                break;
            }
        }
        // --- Beleg-Abruf: timelineDetailV2 -> "Dokumente" section -> PDF download
        let client = self.client()?;
        let mut details: std::collections::HashMap<String, Value> = Default::default();
        for (item_id, date, title) in doc_candidates.into_iter().take(40) {
            sub_id += 2;
            let Ok(detail) = request(
                &mut ws,
                sub_id,
                json!({"type": "timelineDetailV2", "id": item_id}),
                &token,
            )
            .await
            else {
                continue;
            };
            details.insert(item_id.clone(), detail.clone());
            for section in detail["sections"].as_array().cloned().unwrap_or_default() {
                let is_docs = section["type"].as_str() == Some("documents")
                    || section["title"]
                        .as_str()
                        .map(|t| t.contains("Dokument"))
                        .unwrap_or(false);
                if !is_docs {
                    continue;
                }
                for d in section["data"].as_array().cloned().unwrap_or_default() {
                    let url = d["action"]["payload"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string();
                    let Ok(parsed) = reqwest::Url::parse(&url) else {
                        continue;
                    };
                    if parsed.scheme() != "https" {
                        continue;
                    }
                    // Only send the session cookie to Trade Republic hosts; presigned
                    // CDN/S3 URLs get a cookie-free request. (reqwest also strips the
                    // Cookie header on cross-host redirects.)
                    let mut req = client.get(parsed.clone());
                    if is_trade_republic_host(&parsed) {
                        req = req.header("Cookie", self.cookies.clone());
                    }
                    let Ok(resp) = req.send().await else {
                        continue;
                    };
                    if !resp.status().is_success() {
                        continue;
                    }
                    let Ok(bytes) = super::read_body_limited(resp, super::MAX_DOC_BYTES).await
                    else {
                        continue;
                    };
                    if !bytes.starts_with(b"%PDF") {
                        continue;
                    }
                    let doc_title = d["title"].as_str().unwrap_or("Dokument").to_string();
                    let lower = doc_title.to_lowercase();
                    let doc_type = if lower.contains("steuer") {
                        "steuer"
                    } else if lower.contains("abrechnung") || lower.contains("bestätigung") {
                        "abrechnung"
                    } else {
                        "beleg"
                    };
                    let doc_date = d["detail"]
                        .as_str()
                        .and_then(|s| crate::documents::dates_in(s).into_iter().next())
                        .unwrap_or_else(|| date.clone());
                    // strip the presigned query part for a stable de-dup key
                    let stable = url.split('?').next().unwrap_or(&url).to_string();
                    out.documents.push(crate::documents::RemoteDocument {
                        account_ref: "tr:cash".into(),
                        booking_external_id: Some(item_id.clone()),
                        title: format!("{doc_title} – {title}"),
                        doc_type: doc_type.into(),
                        mime_type: "application/pdf".into(),
                        file_name: format!("{}_{}.pdf", doc_date, doc_title.replace(' ', "_")),
                        bytes: bytes.to_vec(),
                        source_url: stable,
                        date: doc_date,
                    });
                }
            }
            self.known_doc_items.push(item_id);
        }
        // --- Wertpapierseite (#314): units, price, fees and taxes of the newest
        // trades from their detail screens (cached from the document pass).
        // A trade whose screen fails is skipped; the cash booking stays.
        for row in trade_rows.iter().take(100) {
            let detail = match details.remove(&row.id) {
                Some(d) => d,
                None => {
                    sub_id += 2;
                    match request(
                        &mut ws,
                        sub_id,
                        json!({"type": "timelineDetailV2", "id": row.id}),
                        &token,
                    )
                    .await
                    {
                        Ok(d) => d,
                        Err(_) => continue,
                    }
                }
            };
            if let Some(t) = trade_security(row, &detail) {
                out.security_transactions.push(t);
            }
        }
        if !out.security_transactions.is_empty() {
            // Trade Republic reports no positions here: the depot only carries
            // the transactions (value 0), the cash account keeps the balance.
            out.accounts.push(RemoteAccount {
                external_ref: "tr:depot".into(),
                name: "Depot".into(),
                owner: String::new(),
                iban: String::new(),
                // no phone number here: it would show up as an account number
                account_number: String::new(),
                currency: "EUR".into(),
                kind: AccountKind::Brokerage,
                balance_cents: 0,
                balance_date: super::today(),
            });
        }
        let _ = ws.close(None).await;
        out.state = Some(self.state());
        Ok(out)
    }
}

/// True if the URL's host is `traderepublic.com` or a subdomain of it.
fn is_trade_republic_host(url: &reqwest::Url) -> bool {
    url.host_str()
        .map(|h| {
            let h = h.to_ascii_lowercase();
            h == "traderepublic.com" || h.ends_with(".traderepublic.com")
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detail(extra_rows: serde_json::Value) -> Value {
        json!({"sections": [
            {"type": "header", "data": {"icon": "logos/US0378331005/v2"}},
            {"title": "Übersicht", "type": "table", "data": [
                {"title": "Gebühr", "detail": {"text": "1,00 €"}},
                {"title": "Steuer", "detail": {"text": "0,50 €"}},
                {"title": "Transaktion", "detail": {"action": {"payload": {"sections": [
                    {"type": "table", "data": extra_rows}
                ]}}}}
            ]}
        ]})
    }

    fn row(kind: &str, amount: i64) -> TradeRow {
        TradeRow {
            id: "evt-1".into(),
            date: "2026-11-05".into(),
            title: "Apple".into(),
            kind_text: kind.into(),
            amount_cents: amount,
            currency: "EUR".into(),
            icon: String::new(),
        }
    }

    #[test]
    fn parses_decimal_texts() {
        assert_eq!(parse_decimal_text("1.234,56 €"), Some(1234.56));
        assert_eq!(parse_decimal_text("0,5"), Some(0.5));
        assert_eq!(parse_decimal_text("12.5"), Some(12.5));
        assert_eq!(parse_decimal_text("1.234"), Some(1234.0));
        assert_eq!(parse_decimal_text("1,234.50"), Some(1234.5));
        assert_eq!(parse_decimal_text("−3,00 €"), Some(-3.0));
        assert_eq!(parse_decimal_text("– €"), None);
        assert_eq!(parse_decimal_text(""), None);
    }

    #[test]
    fn reads_trade_details_and_builds_the_securities_side() {
        use crate::models::SecurityDirection;
        let d = detail(json!([
            {"title": "Aktien", "detail": {"text": "2,5"}},
            {"title": "Preis", "detail": {"text": "160,00 €"}}
        ]));
        let t = trade_security(&row("kauf apple", -40_150), &d).unwrap();
        assert_eq!(
            (
                t.account_ref.as_str(),
                t.external_id.as_str(),
                t.cash_external_id.as_str()
            ),
            ("tr:depot", "evt-1", "evt-1")
        );
        let x = &t.transaction;
        assert_eq!(x.isin, "US0378331005");
        assert_eq!(x.direction, SecurityDirection::Buy);
        assert_eq!(
            (x.quantity, x.price_cents, x.value_cents),
            (2.5, 16_000, 40_000)
        );
        assert_eq!((x.fees_cents, x.taxes_cents), (100, 50));
        // without a price the value is the cash amount minus fees and taxes
        let d2 = detail(json!([{"title": "Aktien", "detail": {"text": "2,5"}}]));
        let b = trade_security(&row("kauf apple", -40_150), &d2)
            .unwrap()
            .transaction;
        assert_eq!((b.value_cents, b.price_cents), (40_000, 16_000));
        // "Verkauf" is a sell although it contains "kauf"; sells add fees back
        let s = trade_security(&row("verkaufsorder", 39_850), &d2)
            .unwrap()
            .transaction;
        assert_eq!(s.direction, SecurityDirection::Sell);
        assert_eq!(s.value_cents, 40_000);
        let div = trade_security(&row("dividende", 1_000), &detail(json!([])))
            .unwrap()
            .transaction;
        assert_eq!(div.direction, SecurityDirection::Dividend);
        // no ISIN anywhere: not a securities transaction
        assert!(trade_security(&row("kauf", -100), &json!({"sections": []})).is_none());
        assert!(trade_security(&row("zinsen", 100), &d2).is_none());
    }

    #[test]
    fn isin_comes_from_the_icon_or_the_header() {
        assert_eq!(
            isin_of("logos/IE00B4L5Y983/v2").as_deref(),
            Some("IE00B4L5Y983")
        );
        assert_eq!(isin_of("DE0007164600").as_deref(), Some("DE0007164600"));
        assert_eq!(isin_of("logos/company/v2"), None);
        assert_eq!(
            parse_trade_detail("logos/DE0007164600/v2", &json!({}))
                .isin
                .as_deref(),
            Some("DE0007164600")
        );
        let d = json!({"sections": [{"action": {"type": "instrumentDetail", "payload": "IE00B4L5Y983"}}]});
        assert_eq!(
            parse_trade_detail("", &d).isin.as_deref(),
            Some("IE00B4L5Y983")
        );
    }

    #[test]
    fn expired_session_is_named_in_the_login_prompts() {
        assert!(pin_prompt_message(true).contains("abgelaufen"));
        assert!(browser_login_message(true).contains("abgelaufen"));
        // no stored session: the usual prompts, without "expired"
        assert!(!pin_prompt_message(false).contains("abgelaufen"));
        assert!(browser_login_message(false).contains("AWS WAF"));
    }

    #[test]
    fn cookie_host_check() {
        let p = |s: &str| reqwest::Url::parse(s).unwrap();
        assert!(is_trade_republic_host(&p(
            "https://api.traderepublic.com/x"
        )));
        assert!(is_trade_republic_host(&p(
            "https://a.b.traderepublic.com/x"
        )));
        assert!(!is_trade_republic_host(&p("https://evil.com/x")));
        assert!(!is_trade_republic_host(&p(
            "https://traderepublic.com.evil.com/x"
        )));
        assert!(!is_trade_republic_host(&p(
            "https://eviltraderepublic.com/x"
        )));
        assert!(!is_trade_republic_host(&p(
            "https://bucket.s3.amazonaws.com/x?traderepublic.com"
        )));
    }

    #[test]
    fn normalises_phone_numbers() {
        assert_eq!(normalize_phone("0171 1234567"), "+491711234567");
        assert_eq!(normalize_phone("0049171/1234567"), "+491711234567");
        assert_eq!(normalize_phone("17012345678"), "+4917012345678");
        assert_eq!(normalize_phone("017012345678"), "+4917012345678");
        assert_eq!(normalize_phone("+49 170 1234 5678"), "+4917012345678");
        assert_eq!(normalize_phone("4917012345678"), "+4917012345678");
        assert_eq!(normalize_phone(""), "");
    }

    #[test]
    fn merges_set_cookie_headers() {
        let c = merge_cookies(
            "tr_refresh=old; other=1",
            &[
                "tr_session=abc; Path=/; HttpOnly; Secure".into(),
                "tr_refresh=new; Path=/".into(),
            ],
        );
        assert_eq!(c, "other=1; tr_session=abc; tr_refresh=new");
    }

    #[test]
    fn float_amounts_round_to_cents() {
        assert_eq!(amount_cents(&json!(-4.040000000000001)), -4_04);
        assert_eq!(amount_cents(&json!(-5.78)), -5_78);
        assert_eq!(amount_cents(&json!(47.32)), 4732);
    }
}
