//! Uberspace (uberspace.de) hosting accounts: credit balance and bookings of
//! every Asteroid (host) under one dashboard login. There is no API: the
//! connector reads the HTML pages of `dashboard.uberspace.de` (unofficial,
//! the pages may change at any time).
//!
//!  GET  /login                 -> login form; its hidden fields are sent back
//!  POST <form action>          -> session cookie; the login form again = wrong credentials
//!  GET  /meta                  -> table `#dotqmailtable`, first cell of a row = Asteroid
//!  GET  /dashboard/accounting?show_all_transactions=1&asteroid=<name>
//!                              -> table `#transactions` (date | text | amount),
//!                                 element `#total` = balance
//!  GET  /logout                -> best effort
//!
//! Pages and element ids as used by the MoneyMoney extension
//! github.com/doersino/moneymoney-uberspace (MPL-2.0); no code was taken over.
//! The dashboard delivers no booking ids, so bookings get content ids.

use std::sync::LazyLock;

use async_trait::async_trait;
use regex::Regex;
use zeroize::Zeroize;

use super::{
    http_client, BankConnector, ChallengeResponse, ConnectContext, ContentIds, FetchResult, Phase,
    RemoteAccount, RemoteTransaction,
};
use crate::dates::{find_de_date, iso};
use crate::error::{CoreError, CoreResult};
use crate::i18n::tr;
use crate::models::AccountKind;

const HOST: &str = "dashboard.uberspace.de";
const BASE: &str = "https://dashboard.uberspace.de";
/// Account external refs: `uberspace:<asteroid>`.
pub(crate) const REF_PREFIX: &str = "uberspace:";

static TAG: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?s)<([a-zA-Z][a-zA-Z0-9]*)\b([^>]*)>").unwrap());
static ATTR: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?s)([A-Za-z_:][-A-Za-z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?"#)
        .unwrap()
});
pub(super) static FORM: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?is)<form\b([^>]*)>(.*?)</form\s*>").unwrap());
pub(super) static INPUT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?is)<input\b([^>]*)>").unwrap());
static ROW: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?is)<tr\b[^>]*>(.*?)</tr\s*>").unwrap());
static CELL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?is)<(td|th)\b[^>]*>(.*?)</(?:td|th)\s*>").unwrap());
static ANY_TAG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<[^>]*>").unwrap());
pub(super) static LINK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?is)<a\b[^>]*>.*?</a\s*>").unwrap());
static ASTEROID: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[a-z][a-z0-9_-]{0,31}$").unwrap());

fn page_changed() -> CoreError {
    CoreError::Protocol {
        message: tr("Uberspace: Anmeldeseite nicht erkannt (Dashboard geändert?).").into(),
    }
}

fn invalid() -> CoreError {
    CoreError::InvalidInput {
        message: tr("Uberspace: Unvollständige oder ungültige Dashboard-Antwort. Es wurden keine Daten übernommen.").into(),
    }
}

fn wrong_credentials() -> CoreError {
    CoreError::Authentication {
        message: tr(
            "Uberspace: Anmeldung fehlgeschlagen. Bitte E-Mail-Adresse und Passwort prüfen.",
        )
        .into(),
    }
}

// ------------------------------------------------------------------ HTML helpers

/// Attributes of a tag body (`name="x" type=hidden checked`), names lower-case.
pub(super) fn attrs(body: &str) -> Vec<(String, String)> {
    ATTR.captures_iter(body)
        .map(|c| {
            let v = c
                .get(2)
                .or(c.get(3))
                .or(c.get(4))
                .map(|m| crate::text::decode_html_entities(m.as_str()))
                .unwrap_or_default();
            (c[1].to_ascii_lowercase(), v)
        })
        .collect()
}

pub(super) fn attr<'a>(a: &'a [(String, String)], name: &str) -> Option<&'a str> {
    a.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
}

/// Visible text of an HTML fragment, whitespace collapsed.
pub(super) fn text(fragment: &str) -> String {
    let plain = ANY_TAG.replace_all(fragment, " ");
    crate::text::decode_html_entities(&plain)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Inner HTML of the element with `id` (nested elements of the same tag are
/// counted, so the matching end tag is found).
pub(super) fn element_by_id<'a>(html: &'a str, id: &str) -> Option<&'a str> {
    let open = TAG
        .captures_iter(html)
        .find(|c| attr(&attrs(&c[2]), "id") == Some(id))?;
    let name = open[1].to_ascii_lowercase();
    let start = open.get(0)?.end();
    if open[2].trim_end().ends_with('/') {
        return Some("");
    }
    let lower = html[start..].to_ascii_lowercase();
    let (o, c) = (format!("<{name}"), format!("</{name}"));
    // Next `<name` that is the whole tag name (`<b` must not match `<br`).
    let find_open = |from: usize| {
        let mut from = from;
        while let Some(i) = lower[from..].find(&o).map(|i| from + i) {
            let end = i + o.len();
            if lower[end..]
                .chars()
                .next()
                .is_none_or(|ch| !ch.is_ascii_alphanumeric())
            {
                return Some(i);
            }
            from = end;
        }
        None
    };
    let mut depth = 1usize;
    let mut pos = 0usize;
    loop {
        let next_close = lower[pos..].find(&c).map(|i| pos + i)?;
        match find_open(pos) {
            Some(i) if i < next_close => {
                depth += 1;
                pos = i + o.len();
            }
            _ => {
                depth -= 1;
                if depth == 0 {
                    return Some(&html[start..start + next_close]);
                }
                pos = next_close + c.len();
            }
        }
    }
}

/// Inner HTML of the `<td>` cells of each `<tr>`; rows of only `<th>` cells
/// come back empty.
pub(super) fn table_cells(table: &str) -> Vec<Vec<&str>> {
    ROW.captures_iter(table)
        .map(|r| {
            let row = r.get(1).map_or("", |m| m.as_str());
            CELL.captures_iter(row)
                .filter(|c| c[1].eq_ignore_ascii_case("td"))
                .filter_map(|c| c.get(2).map(|m| m.as_str()))
                .collect()
        })
        .collect()
}

/// `<td>` texts of each `<tr>`; rows of only `<th>` cells come back empty.
fn table_rows(table: &str) -> Vec<Vec<String>> {
    table_cells(table)
        .into_iter()
        .map(|cells| cells.into_iter().map(text).collect())
        .collect()
}

/// Text of a booking cell without its links: those are actions next to the
/// booking ("Einzahlung | <a>Quittung</a>" issues a receipt), not part of
/// it. Separators left dangling by a removed link are dropped as well.
fn booking_text_of(cell: &str) -> String {
    text(&LINK.replace_all(cell, " "))
        .trim_matches(|c: char| c.is_whitespace() || matches!(c, '|' | '·' | '–'))
        .to_string()
}

fn has_password_field(html: &str) -> bool {
    INPUT.captures_iter(html).any(|c| {
        let a = attrs(&c[1]);
        attr(&a, "name") == Some("password")
            || attr(&a, "type").is_some_and(|t| t.eq_ignore_ascii_case("password"))
    })
}

/// The dashboard shows its login form (wrong credentials or session ended):
/// a form with a password field and a `login` field. Other password inputs
/// (e.g. in settings forms) do not count.
fn is_login_page(html: &str) -> bool {
    FORM.captures_iter(html).any(|f| {
        has_password_field(&f[2])
            && INPUT
                .captures_iter(&f[2])
                .any(|i| attr(&attrs(&i[1]), "name") == Some("login"))
    })
}

// ------------------------------------------------------------------ login form

/// The dashboard's login form: where to post and which fields to send.
#[derive(Debug, PartialEq)]
struct LoginForm {
    action: url::Url,
    /// Hidden fields (CSRF token …) and the submit button, as the browser sends them.
    fields: Vec<(String, String)>,
    login_field: String,
    password_field: String,
}

impl LoginForm {
    fn filled(&self, login: &str, password: &str) -> Vec<(String, String)> {
        let mut out = self.fields.clone();
        out.push((self.login_field.clone(), login.to_string()));
        out.push((self.password_field.clone(), password.to_string()));
        out
    }
}

/// Only `https://dashboard.uberspace.de` may receive the password or cookies.
fn ensure_dashboard(url: &url::Url) -> CoreResult<()> {
    if url.scheme() == "https" && url.host_str() == Some(HOST) {
        return Ok(());
    }
    Err(CoreError::Protocol {
        message: tr("Uberspace: Unerwartete Weiterleitung zu einer fremden Adresse – abgebrochen.")
            .into(),
    })
}

fn login_form(html: &str, page: &url::Url) -> CoreResult<LoginForm> {
    let form = FORM
        .captures_iter(html)
        .find(|f| has_password_field(&f[2]))
        .ok_or_else(page_changed)?;
    let form_attrs = attrs(&form[1]);
    if attr(&form_attrs, "method").is_some_and(|m| !m.eq_ignore_ascii_case("post")) {
        return Err(page_changed()); // never put the password into a URL
    }
    let action = match attr(&form_attrs, "action").map(str::trim) {
        Some(a) if !a.is_empty() => page.join(a).map_err(|_| page_changed())?,
        _ => page.clone(),
    };
    ensure_dashboard(&action)?;

    let mut fields = Vec::new();
    let mut login_field = None;
    let mut password_field = None;
    let mut fallback_login = None;
    let mut submitted = false;
    for input in INPUT.captures_iter(&form[2]) {
        let a = attrs(&input[1]);
        let Some(name) = attr(&a, "name").filter(|n| !n.is_empty()) else {
            continue;
        };
        let kind = attr(&a, "type").unwrap_or("text").to_ascii_lowercase();
        let value = attr(&a, "value").unwrap_or("").to_string();
        match kind.as_str() {
            "password" => password_field = Some(name.to_string()),
            _ if name == "login" => login_field = Some(name.to_string()),
            "text" | "email" => {
                fallback_login.get_or_insert_with(|| name.to_string());
            }
            "hidden" => fields.push((name.to_string(), value)),
            "submit" if !submitted => {
                submitted = true;
                fields.push((name.to_string(), value));
            }
            "checkbox" | "radio" if attr(&a, "checked").is_some() => fields.push((
                name.to_string(),
                if value.is_empty() { "on".into() } else { value },
            )),
            _ => {}
        }
    }
    Ok(LoginForm {
        action,
        fields,
        login_field: login_field.or(fallback_login).ok_or_else(page_changed)?,
        password_field: password_field.ok_or_else(page_changed)?,
    })
}

// ------------------------------------------------------------------ data pages

/// Asteroid names from `/meta` (first cell of each row of `#dotqmailtable`).
fn parse_asteroids(html: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let Some(table) = element_by_id(html, "dotqmailtable") else {
        return out;
    };
    for row in table_rows(table) {
        let Some(name) = row.first().map(|s| s.trim().to_string()) else {
            continue;
        };
        if ASTEROID.is_match(&name) && !out.contains(&name) {
            out.push(name);
        }
    }
    out
}

/// "-12,34 €", "1.234,56&nbsp;EUR", "−5,00" → cents.
fn parse_amount(s: &str) -> Option<i64> {
    let cleaned: String = s
        .replace(['\u{2212}', '\u{2013}'], "-")
        .replace("EUR", "")
        .chars()
        .filter(|c| c.is_ascii_digit() || matches!(c, '-' | '+' | ',' | '.'))
        .collect();
    if !cleaned.chars().any(|c| c.is_ascii_digit()) {
        return None;
    }
    crate::money::parse_cents(&cleaned).ok()
}

/// `DD.MM.YYYY` anywhere in the cell → `YYYY-MM-DD`.
pub(super) fn parse_date(s: &str) -> Option<String> {
    find_de_date(s).map(iso)
}

/// Balance and bookings of one Asteroid from its accounting page. Rows
/// without a date (sums, carry-overs) are skipped; a dated row with an
/// unreadable amount rejects the whole page so nothing half-read is stored.
fn parse_accounting(
    html: &str,
    asteroid: &str,
    since: &str,
) -> CoreResult<(RemoteAccount, Vec<RemoteTransaction>)> {
    let balance_cents = element_by_id(html, "total")
        .map(text)
        .and_then(|t| parse_amount(&t))
        .ok_or_else(invalid)?;
    let account_ref = format!("{REF_PREFIX}{asteroid}");
    let mut ids = ContentIds::default();
    let mut transactions = Vec::new();
    for row in element_by_id(html, "transactions")
        .map(table_cells)
        .unwrap_or_default()
    {
        if row.len() != 3 {
            continue;
        }
        let Some(date) = parse_date(&text(row[0])) else {
            continue;
        };
        let amount_cents = parse_amount(&text(row[2])).ok_or_else(invalid)?;
        let mut t = RemoteTransaction {
            account_ref: account_ref.clone(),
            booking_date: date.clone(),
            value_date: date,
            amount_cents,
            currency: "EUR".into(),
            counterparty: if amount_cents < 0 {
                "Uberspace".into()
            } else {
                String::new()
            },
            purpose: booking_text_of(row[1]),
            ..Default::default()
        };
        t.external_id = ids.next(&t);
        if t.booking_date.as_str() >= since {
            transactions.push(t);
        }
    }
    let account = RemoteAccount {
        external_ref: account_ref,
        name: format!("Uberspace {asteroid}"),
        owner: String::new(),
        iban: String::new(),
        account_number: asteroid.to_string(),
        currency: "EUR".into(),
        kind: AccountKind::PaymentService,
        balance_cents,
        balance_date: super::today(),
    };
    Ok((account, transactions))
}

// ------------------------------------------------------------------ connector

#[derive(Default)]
pub struct UberspaceConnector {
    client: Option<reqwest::Client>,
}

impl UberspaceConnector {
    pub fn new() -> Self {
        Self::default()
    }

    /// GET a dashboard page; the login form instead means the session ended.
    async fn page(&self, path_and_query: &str) -> CoreResult<String> {
        let client = self.client.as_ref().ok_or(CoreError::SessionClosed)?;
        let resp = client.get(format!("{BASE}{path_and_query}")).send().await?;
        ensure_dashboard(resp.url())?;
        let status = resp.status();
        let html = super::read_text_limited(resp).await?;
        if !status.is_success() {
            return Err(CoreError::Bank {
                code: status.as_u16().to_string(),
                message: tr("Uberspace: Die Anfrage wurde abgelehnt.").into(),
            });
        }
        if is_login_page(&html) {
            return Err(wrong_credentials());
        }
        Ok(html)
    }
}

#[async_trait]
impl BankConnector for UberspaceConnector {
    async fn begin(&mut self, ctx: &ConnectContext) -> CoreResult<Phase> {
        let login = ctx.login_name.trim();
        if login.is_empty() || ctx.secret.expose().is_empty() {
            return Err(CoreError::Authentication {
                message: tr("Uberspace: E-Mail-Adresse und Passwort erforderlich.").into(),
            });
        }
        let client = http_client()?;
        let resp = client.get(format!("{BASE}/login")).send().await?;
        let page_url = resp.url().clone();
        ensure_dashboard(&page_url)?;
        let html = super::read_text_limited(resp).await?;
        let form = login_form(&html, &page_url)?;

        let mut fields = form.filled(login, ctx.secret.expose());
        let sent = client.post(form.action.clone()).form(&fields).send().await;
        for (_, v) in fields.iter_mut() {
            v.zeroize();
        }
        let resp = sent?;
        ensure_dashboard(resp.url())?;
        let status = resp.status();
        let html = super::read_text_limited(resp).await?;
        if is_login_page(&html) {
            return Err(wrong_credentials());
        }
        if !status.is_success() {
            return Err(CoreError::Bank {
                code: status.as_u16().to_string(),
                message: tr("Uberspace: Die Anfrage wurde abgelehnt.").into(),
            });
        }
        self.client = Some(client);
        Ok(Phase::Ready)
    }

    async fn respond(&mut self, _ctx: &ConnectContext, _r: ChallengeResponse) -> CoreResult<Phase> {
        Ok(Phase::Ready)
    }

    async fn fetch(&mut self, ctx: &ConnectContext) -> CoreResult<FetchResult> {
        let asteroids = parse_asteroids(&self.page("/meta").await?);
        if asteroids.is_empty() {
            return Err(CoreError::Protocol {
                message: tr("Uberspace: Keine Asteroids gefunden (Dashboard geändert?).").into(),
            });
        }
        let mut out = FetchResult::default();
        for asteroid in asteroids {
            let query: String = url::form_urlencoded::Serializer::new(String::new())
                .append_pair("show_all_transactions", "1")
                .append_pair("asteroid", &asteroid)
                .finish();
            let html = self.page(&format!("/dashboard/accounting?{query}")).await?;
            let since = ctx
                .since_for(&format!("{REF_PREFIX}{asteroid}"))
                .to_string();
            let (account, transactions) = parse_accounting(&html, &asteroid, &since)?;
            out.accounts.push(account);
            out.transactions.extend(transactions);
        }
        out.accounts_complete = true;
        Ok(out)
    }

    async fn finish(&mut self, _ctx: &ConnectContext) {
        if let Some(client) = self.client.take() {
            let _ = client.get(format!("{BASE}/logout")).send().await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Invented pages in the shape of the dashboard; no real data.
    const LOGIN: &str = r#"<html><body>
      <form class="search" action="/search" method="get"><input name="q"></form>
      <form method="post" action="/login">
        <input type="hidden" name="csrf_token" value="tok&amp;123">
        <input type="email" name="login" value="">
        <input type="password" name="password">
        <input type="checkbox" name="remember">
        <input type="submit" name="submit" value="Anmelden">
      </form></body></html>"#;

    const META: &str = r#"<table id="dotqmailtable">
      <tr><th>Asteroid</th><th>Server</th></tr>
      <tr><td><a href="/x">isabell</a></td><td>stardust</td></tr>
      <tr><td>
         maxi </td><td>andromeda</td></tr>
      <tr><td>isabell</td><td>stardust</td></tr>
    </table><table id="other"><tr><td>nope</td></tr></table>"#;

    const ACCOUNTING: &str = r#"<div id="content">
      <p>Guthaben: <span id="total">1.012,34&nbsp;&euro;</span></p>
      <table id="transactions"><thead><tr><th>Datum</th><th>Text</th><th>Betrag</th></tr></thead>
      <tbody>
        <tr><td>01.11.2026</td><td>Monatsbeitrag <b>isabell</b></td><td class="neg">&minus;5,00 €</td></tr>
        <tr><td>01.11.2026</td><td>Monatsbeitrag <b>isabell</b></td><td class="neg">-5,00 €</td></tr>
        <tr><td>15.10.2026</td><td>Überweisung Erika Mustermann</td><td>60,00 €</td></tr>
        <tr><td>01.10.2026</td><td>Monatsbeitrag</td><td>-5,00 €</td></tr>
        <tr><td></td><td>Summe</td><td>45,00 €</td></tr>
      </tbody></table></div>"#;

    #[test]
    fn login_form_keeps_hidden_fields_and_resolves_action() {
        let page = url::Url::parse("https://dashboard.uberspace.de/login").unwrap();
        let f = login_form(LOGIN, &page).unwrap();
        assert_eq!(f.action.as_str(), "https://dashboard.uberspace.de/login");
        assert_eq!(
            (f.login_field.as_str(), f.password_field.as_str()),
            ("login", "password")
        );
        let filled = f.filled("erika@example.org", "geheim");
        assert_eq!(
            filled,
            vec![
                ("csrf_token".to_string(), "tok&123".to_string()),
                ("submit".into(), "Anmelden".into()),
                ("login".into(), "erika@example.org".into()),
                ("password".into(), "geheim".into()),
            ]
        );
    }

    #[test]
    fn login_form_never_posts_to_another_host_or_via_get() {
        let page = url::Url::parse("https://dashboard.uberspace.de/login").unwrap();
        let foreign = LOGIN.replace(r#"action="/login""#, r#"action="https://evil.example/x""#);
        assert!(login_form(&foreign, &page).is_err());
        let plain = LOGIN.replace(
            r#"action="/login""#,
            r#"action="http://dashboard.uberspace.de/login""#,
        );
        assert!(login_form(&plain, &page).is_err());
        let get = LOGIN.replace(r#"method="post" action="/login""#, r#"method="get""#);
        assert!(login_form(&get, &page).is_err());
        assert!(login_form("<html>Wartungsarbeiten</html>", &page).is_err());
    }

    #[test]
    fn detects_login_page_as_failed_login() {
        assert!(is_login_page(LOGIN));
        assert!(!is_login_page(ACCOUNTING));
        let settings = r#"<form method="post"><input type="password" name="password"></form>"#;
        assert!(
            !is_login_page(settings),
            "a password form without login field"
        );
    }

    #[test]
    fn lists_asteroids_once_and_skips_headers() {
        assert_eq!(parse_asteroids(META), vec!["isabell", "maxi"]);
        assert!(parse_asteroids("<p>leer</p>").is_empty());
    }

    #[test]
    fn reads_balance_and_bookings_with_signs_and_stable_ids() {
        let (acc, tx) = parse_accounting(ACCOUNTING, "isabell", "2000-01-01").unwrap();
        assert_eq!(acc.external_ref, "uberspace:isabell");
        assert_eq!(acc.balance_cents, 101_234);
        assert_eq!(acc.kind, AccountKind::PaymentService);
        assert_eq!(tx.len(), 4, "sum row without date is skipped");
        assert_eq!(tx[0].booking_date, "2026-11-01");
        assert_eq!(tx[0].amount_cents, -500);
        assert_eq!(tx[0].purpose, "Monatsbeitrag isabell");
        assert_eq!(tx[0].counterparty, "Uberspace");
        assert_eq!(tx[2].amount_cents, 6000);
        assert_eq!(tx[2].counterparty, "");
        // Two identical charges on the same day stay two bookings.
        assert_ne!(tx[0].external_id, tx[1].external_id);
        // Same page again → same ids (de-duplication across syncs).
        let (_, again) = parse_accounting(ACCOUNTING, "isabell", "2000-01-01").unwrap();
        let ids =
            |v: &[RemoteTransaction]| v.iter().map(|t| t.external_id.clone()).collect::<Vec<_>>();
        assert_eq!(ids(&tx), ids(&again));
    }

    #[test]
    fn receipt_links_are_not_part_of_the_booking() {
        let page = ACCOUNTING.replace(
            "<td>Überweisung Erika Mustermann</td>",
            r#"<td>Einzahlung | <a href="/receipt/42">Quittung</a></td>"#,
        );
        let (_, tx) = parse_accounting(&page, "isabell", "2000-01-01").unwrap();
        assert_eq!(tx[2].purpose, "Einzahlung");
        assert_eq!(tx[2].amount_cents, 6000);
        assert_eq!(
            booking_text_of(r#"<a href="/q">Quittung</a> · Einzahlung"#),
            "Einzahlung"
        );
        assert_eq!(
            booking_text_of("Monatsbeitrag <b>isabell</b>"),
            "Monatsbeitrag isabell"
        );
    }

    #[test]
    fn since_filters_without_changing_ids() {
        let (_, all) = parse_accounting(ACCOUNTING, "isabell", "2000-01-01").unwrap();
        let (_, recent) = parse_accounting(ACCOUNTING, "isabell", "2026-10-15").unwrap();
        assert_eq!(recent.len(), 3);
        assert_eq!(recent[2].external_id, all[2].external_id);
    }

    #[test]
    fn rejects_pages_without_balance_or_with_broken_amounts() {
        let no_total = ACCOUNTING.replace(r#"id="total""#, r#"id="x""#);
        assert!(parse_accounting(&no_total, "isabell", "2000-01-01").is_err());
        let broken = ACCOUNTING.replace("60,00 €", "n/a");
        assert!(parse_accounting(&broken, "isabell", "2000-01-01").is_err());
        // A new Asteroid without a bookings table still has a balance.
        let (acc, tx) =
            parse_accounting(r#"<b id="total">0,00 €</b>"#, "neu", "2000-01-01").unwrap();
        assert_eq!((acc.balance_cents, tx.len()), (0, 0));
    }

    #[test]
    fn element_by_id_handles_nesting() {
        let html = r#"<div id="a"><div>x</div><div>y</div></div><div>z</div>"#;
        assert_eq!(element_by_id(html, "a"), Some("<div>x</div><div>y</div>"));
        assert_eq!(element_by_id(html, "b"), None);
        let bold = r#"<b id="t">1<br>2<b>3</b>4</b>rest"#;
        assert_eq!(element_by_id(bold, "t"), Some("1<br>2<b>3</b>4"));
    }

    #[test]
    fn amounts_and_dates() {
        assert_eq!(parse_amount("−12,30 €"), Some(-1230));
        assert_eq!(parse_amount("1.234,56 EUR"), Some(123_456));
        assert_eq!(parse_amount("+0,07"), Some(7));
        assert_eq!(parse_amount("—"), None);
        assert_eq!(parse_date("1.2.2026").as_deref(), Some("2026-02-01"));
        assert_eq!(parse_date("31.02.2026"), None);
    }
}
