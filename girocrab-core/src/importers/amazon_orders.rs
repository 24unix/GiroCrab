//! Amazon customer account ("Meine Bestellungen"): every order becomes one
//! booking on a synthetic account, refunds become credit bookings.
//!
//! Amazon has no API and guards its login with WAF / captcha / 2FA, so the app
//! signs in inside an embedded WKWebView (same keyless approach as the card
//! portals). A script running in that logged-in page walks the order history,
//! reads every order-details page and hands compact JSON ([`Capture`]) to
//! [`Vault::import_amazon_orders`]. All interpretation (dates, amounts, refund
//! detection) happens here so it is unit-testable without a browser.
//!
//! Ported from the MoneyMoney extension `amazon-bestellungen.lua`; Business /
//! analytics-report handling is intentionally not included.

use std::sync::Arc;

use regex::Regex;
use serde::Deserialize;

use super::portal_import::parse_amount;
use crate::connectors::{store_fetch, FetchResult, RemoteAccount, RemoteTransaction, SyncSummary};
use crate::error::CoreError;
use crate::i18n::tr;
use crate::models::{AccountKind, ConnectorKind};
use crate::vault::Vault;

/// JSON produced by the in-page scraper.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Capture {
    #[serde(default)]
    pub orders: Vec<Order>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Order {
    /// e.g. `028-1234567-1234567` (or `D01-…` for digital orders)
    pub code: String,
    /// Order date as displayed, e.g. `12. März 2025`.
    #[serde(default)]
    pub date: String,
    #[serde(default)]
    pub items: Vec<Item>,
    /// Order summary rows (label / value text), e.g. "Gesamtsumme" / "45,98 €".
    #[serde(default)]
    pub rows: Vec<Row>,
    /// Details page said the order was cancelled before it was billed.
    #[serde(default)]
    pub cancelled: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Item {
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub qty: Option<u32>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Row {
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub value: String,
    #[serde(default)]
    pub bold: bool,
}

/// One normalised booking derived from an order.
#[derive(Debug, Clone, PartialEq)]
pub struct Booking {
    pub id: String,
    pub date: String,
    pub cents: i64,
    pub purpose: String,
    pub text: &'static str,
}

const MONTHS: [(&str, u32); 21] = [
    ("januar", 1),
    ("january", 1),
    ("februar", 2),
    ("february", 2),
    ("märz", 3),
    ("maerz", 3),
    ("march", 3),
    ("april", 4),
    ("mai", 5),
    ("may", 5),
    ("juni", 6),
    ("june", 6),
    ("juli", 7),
    ("july", 7),
    ("august", 8),
    ("september", 9),
    ("oktober", 10),
    ("october", 10),
    ("november", 11),
    ("dezember", 12),
    ("december", 12),
];

/// "12. März 2025", "March 12, 2025", "12.03.2025" -> "2025-03-12".
pub fn parse_date(s: &str) -> Option<String> {
    let s = s.trim();
    if let Some(c) = Regex::new(r"(\d{1,2})\.(\d{1,2})\.(\d{4})")
        .ok()?
        .captures(s)
    {
        return iso(c[3].parse().ok()?, c[2].parse().ok()?, c[1].parse().ok()?);
    }
    let lower = s.to_lowercase();
    let month = MONTHS
        .iter()
        .filter(|(name, _)| lower.contains(name))
        .max_by_key(|(name, _)| name.len())
        .map(|(_, m)| *m)?;
    let nums: Vec<u32> = Regex::new(r"\d+")
        .ok()?
        .find_iter(&lower)
        .filter_map(|m| m.as_str().parse().ok())
        .collect();
    let year = *nums.iter().find(|n| **n >= 1990)?;
    let day = *nums.iter().find(|n| (1..=31).contains(*n))?;
    iso(year, month, day)
}

fn iso(y: u32, m: u32, d: u32) -> Option<String> {
    ((1..=12).contains(&m) && (1..=31).contains(&d)).then(|| format!("{y:04}-{m:02}-{d:02}"))
}

/// First price found in free text ("EUR 12,99", "12,99 €", "Gesamt: 1.234,56 €").
/// Also accepts the English format amazon.de shows when the site language is
/// English ("€1,329.00", "€45.98"); a German-only pattern read "€1,329.00" as
/// 1,32 € and missed every amount below 1.000 €.
pub fn price_cents(s: &str) -> Option<i64> {
    let re = Regex::new(r"-?\s*(?:€\s*)?(?:\d{1,3}(?:[.,]\d{3})+|\d+)[.,]\d{2}\b").ok()?;
    let m = re.find(s)?;
    parse_amount(m.as_str())
}

fn has(label: &str, needles: &[&str]) -> bool {
    let l = label.to_lowercase();
    needles.iter().any(|n| l.contains(n))
}

/// Order grand total in cents: the "Gesamtsumme"/"Grand Total" row, else the
/// last bold row (refund rows are never the total).
fn total_cents(o: &Order) -> Option<i64> {
    let rows = || {
        o.rows
            .iter()
            .filter(|r| !has(&r.label, &["erstattung", "refund"]))
    };
    rows()
        .filter(|r| {
            has(
                &r.label,
                &[
                    "gesamtsumme",
                    "gesamtbetrag für",
                    "grand total",
                    "order total",
                ],
            )
        })
        .filter(|r| {
            !has(
                &r.label,
                &["zwischensumme", "subtotal", "ohne mwst", "vor "],
            )
        })
        .filter_map(|r| price_cents(&r.value))
        .next_back()
        .or_else(|| {
            rows()
                .filter(|r| r.bold)
                .filter_map(|r| price_cents(&r.value))
                .next_back()
        })
}

fn purpose(o: &Order) -> String {
    let items: Vec<String> = o
        .items
        .iter()
        .filter(|i| !i.title.trim().is_empty())
        .map(|i| {
            let t = i.title.split_whitespace().collect::<Vec<_>>().join(" ");
            match i.qty {
                Some(q) if q > 1 => format!("{q}× {t}"),
                _ => t,
            }
        })
        .collect();
    if items.is_empty() {
        format!("Bestellung {}", o.code)
    } else {
        format!("{} – Bestellung {}", items.join("; "), o.code)
    }
}

/// Orders -> bookings. Cancelled / unbilled / undated orders are skipped.
pub fn bookings(orders: &[Order]) -> Vec<Booking> {
    let mut out = Vec::new();
    for o in orders {
        let code = o.code.trim();
        let Some(date) = parse_date(&o.date) else {
            continue;
        };
        if code.is_empty() || o.cancelled {
            continue;
        }
        let purpose = purpose(o);
        // 0,00 € orders (Audible credits, fully promo-covered) stay visible as 0 € bookings
        if let Some(total) = total_cents(o).filter(|t| *t >= 0) {
            out.push(Booking {
                id: format!("amazon:{code}"),
                date: date.clone(),
                cents: -total,
                purpose: purpose.clone(),
                text: "Amazon-Bestellung",
            });
        }
        for (i, r) in o
            .rows
            .iter()
            .filter(|r| has(&r.label, &["erstattung", "refund"]))
            .enumerate()
        {
            if let Some(c) = price_cents(&r.value).filter(|c| *c > 0) {
                out.push(Booking {
                    id: format!("amazon-refund:{code}:{i}:{c}"),
                    date: date.clone(),
                    cents: c,
                    purpose: format!("Erstattung für Bestellung {code}"),
                    text: "Amazon-Erstattung",
                });
            }
        }
    }
    out
}

fn to_fetch(connection_id: i64, name: &str, bookings: Vec<Booking>) -> FetchResult {
    let account_ref = format!("amazon-orders-{connection_id}");
    let transactions = bookings
        .into_iter()
        .map(|b| RemoteTransaction {
            account_ref: account_ref.clone(),
            external_id: b.id,
            booking_date: b.date.clone(),
            value_date: b.date,
            amount_cents: b.cents,
            currency: "EUR".into(),
            counterparty: "Amazon".into(),
            counterparty_iban: String::new(),
            purpose: b.purpose,
            booking_text: b.text.into(),
            ..Default::default()
        })
        .collect();
    FetchResult {
        accounts: vec![RemoteAccount {
            external_ref: account_ref,
            name: name.to_string(),
            owner: String::new(),
            iban: String::new(),
            account_number: String::new(),
            currency: "EUR".into(),
            kind: AccountKind::PaymentService,
            balance_cents: 0,
            balance_date: crate::connectors::today(),
        }],
        transactions,
        state: None,
        // orders are not a real balance: accumulate the imported bookings
        adjust_balances: true,
        ..Default::default()
    }
}

/// Amazon has no API: a sync request always asks the app for the in-app
/// browser login, which then calls [`Vault::import_amazon_orders`].
pub struct WebOnlyConnector;

#[async_trait::async_trait]
impl crate::connectors::BankConnector for WebOnlyConnector {
    async fn begin(
        &mut self,
        _ctx: &crate::connectors::ConnectContext,
    ) -> crate::error::CoreResult<crate::connectors::Phase> {
        Err(CoreError::BrowserLoginRequired {
            message: tr("Bitte im Browser-Fenster bei Amazon anmelden.").into(),
        })
    }
    async fn respond(
        &mut self,
        _ctx: &crate::connectors::ConnectContext,
        _response: crate::connectors::ChallengeResponse,
    ) -> crate::error::CoreResult<crate::connectors::Phase> {
        Err(CoreError::BrowserLoginRequired {
            message: tr("Bitte im Browser-Fenster bei Amazon anmelden.").into(),
        })
    }
    async fn fetch(
        &mut self,
        _ctx: &crate::connectors::ConnectContext,
    ) -> crate::error::CoreResult<FetchResult> {
        Err(CoreError::BrowserLoginRequired {
            message: tr("Bitte im Browser-Fenster bei Amazon anmelden.").into(),
        })
    }
}

fn parse_capture(json: &str) -> Vec<Booking> {
    serde_json::from_str::<Capture>(json)
        .map(|c| bookings(&c.orders))
        .unwrap_or_default()
}

#[uniffi::export]
impl Vault {
    /// Imports the JSON captured from the Amazon order history (see module docs).
    pub fn import_amazon_orders(
        self: Arc<Self>,
        connection_id: i64,
        orders_json: String,
    ) -> Result<SyncSummary, CoreError> {
        let (kind, name) = self.portal_connection(connection_id)?;
        if kind != ConnectorKind::AmazonOrders {
            return Err(CoreError::InvalidInput {
                message: "not an Amazon connection".into(),
            });
        }
        let parsed = parse_capture(&orders_json);
        if parsed.is_empty() {
            return Err(CoreError::InvalidInput {
                message: tr("Keine Bestellungen erkannt.").into(),
            });
        }
        self.heal_amazon_amounts(connection_id, &parsed)?;
        let summary = store_fetch(
            &self,
            kind,
            connection_id,
            to_fetch(connection_id, &name, parsed),
        )?;
        // Fold the import into the main file; best effort, it is committed.
        let _ = self.checkpoint();
        Ok(summary)
    }
}

impl Vault {
    /// Order bookings already stored with a different total (e.g. the wrong
    /// 1,32 € read from "€1,329.00" by an older parser) are corrected in place;
    /// `store_fetch` only inserts new ids. The synthetic balance follows.
    fn heal_amazon_amounts(&self, connection_id: i64, parsed: &[Booking]) -> Result<(), CoreError> {
        let account_ref = format!("amazon-orders-{connection_id}");
        let db = self.db()?;
        let Ok(acc_id) = db.query_row(
            "SELECT id FROM accounts WHERE connection_id = ?1 AND external_ref = ?2",
            rusqlite::params![connection_id, account_ref],
            |r| r.get::<_, i64>(0),
        ) else {
            return Ok(());
        };
        for b in parsed.iter().filter(|b| b.id.starts_with("amazon:")) {
            let old: Option<i64> = db
                .query_row(
                    "SELECT amount_cents FROM transactions WHERE account_id = ?1 AND external_id = ?2 AND deleted_ms IS NULL",
                    rusqlite::params![acc_id, b.id],
                    |r| r.get(0),
                )
                .ok();
            if let Some(old) = old.filter(|o| *o != b.cents) {
                db.execute(
                    "UPDATE transactions SET amount_cents = ?1 WHERE account_id = ?2 AND external_id = ?3",
                    rusqlite::params![b.cents, acc_id, b.id],
                )?;
                db.execute(
                    "UPDATE accounts SET balance_cents = balance_cents + ?1 WHERE id = ?2",
                    rusqlite::params![b.cents - old, acc_id],
                )?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn order(json: &str) -> Order {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn dates() {
        assert_eq!(parse_date("12. März 2025").as_deref(), Some("2025-03-12"));
        assert_eq!(parse_date("3. Januar 2024").as_deref(), Some("2024-01-03"));
        assert_eq!(parse_date("March 12, 2025").as_deref(), Some("2025-03-12"));
        assert_eq!(parse_date("05.11.2025").as_deref(), Some("2025-11-05"));
        assert_eq!(parse_date("bald"), None);
    }

    #[test]
    fn prices() {
        assert_eq!(price_cents("169,98€"), Some(16998));
        assert_eq!(price_cents("EUR 1.234,56"), Some(123456));
        assert_eq!(price_cents("-5,00 €"), Some(-500));
        assert_eq!(price_cents("gratis"), None);
        // English site language on amazon.de
        assert_eq!(price_cents("€1,329.00"), Some(132900));
        assert_eq!(price_cents("€45.98"), Some(4598));
        assert_eq!(price_cents("-€5.00"), Some(-500));
        assert_eq!(price_cents("€0.00"), Some(0));
    }

    #[test]
    fn english_site_language_order_totals() {
        // amazon.de with English UI: "€1,329.00" used to become -1,32 €, and
        // every order below 1.000 € ("€45.98") produced no booking at all.
        let iphone = order(
            r#"{"code":"302-1","date":"February 14, 2026","items":[{"title":"Apple iPhone 17 Pro Max 256 GB"}],
                "rows":[{"label":"Item(s) Subtotal:","value":"€1,329.00"},
                        {"label":"Postage & Packing:","value":"€0.00"},
                        {"label":"Total before VAT:","value":"€1,116.81"},
                        {"label":"Grand Total:","value":"€1,329.00","bold":true}]}"#,
        );
        let small = order(
            r#"{"code":"302-2","date":"March 1, 2026",
                "rows":[{"label":"Item(s) Subtotal:","value":"€45.98"},
                        {"label":"Grand Total:","value":"€45.98","bold":true},
                        {"label":"Refund Total","value":"€10.00"}]}"#,
        );
        let b = bookings(&[iphone, small]);
        assert_eq!(b.len(), 3);
        assert_eq!((b[0].cents, b[0].date.as_str()), (-132900, "2026-02-14"));
        assert_eq!(b[1].cents, -4598);
        assert_eq!(b[2].cents, 1000);
    }

    #[test]
    fn order_becomes_debit_and_refund_credit() {
        let o = order(
            r#"{"code":"028-1234567-1234567","date":"12. März 2025",
                "items":[{"title":"USB-Kabel","qty":2},{"title":"Buch"}],
                "rows":[{"label":"Zwischensumme:","value":"40,00 €"},
                        {"label":"Gesamtsumme:","value":"45,98 €","bold":true},
                        {"label":"Erstattung gesamt","value":"10,00 €"}]}"#,
        );
        let b = bookings(&[o]);
        assert_eq!(b.len(), 2);
        assert_eq!((b[0].cents, b[0].date.as_str()), (-4598, "2025-03-12"));
        assert_eq!(b[0].id, "amazon:028-1234567-1234567");
        assert!(b[0].purpose.contains("2× USB-Kabel; Buch"));
        assert_eq!(b[1].cents, 1000);
    }

    #[test]
    fn cancelled_or_undated_orders_are_skipped() {
        let c = order(
            r#"{"code":"1","date":"1. Mai 2025","cancelled":true,"rows":[{"label":"Gesamtsumme","value":"9,99 €"}]}"#,
        );
        let u =
            order(r#"{"code":"2","date":"","rows":[{"label":"Gesamtsumme","value":"9,99 €"}]}"#);
        assert!(bookings(&[c, u]).is_empty());
    }

    #[test]
    fn digital_order_total_ignores_pre_tax_row() {
        let o = order(
            r#"{"code":"D01-1","date":"9. November 2026","rows":[{"label":"Artikel-Zwischensumme:","value":"9,30 €"},{"label":"Gesamtbetrag vor Steuern:","value":"8,40 €"},{"label":"MwSt:","value":"1,59 €"},{"label":"Gesamtbetrag für diese Bestellung:","value":"9,99 €"}]}"#,
        );
        assert_eq!(bookings(&[o])[0].cents, -999);
    }

    #[test]
    fn zero_euro_order_is_kept_as_zero_booking() {
        let o = order(
            r#"{"code":"D01-2","date":"3. November 2026","items":[{"title":"Hörbuch"}],"rows":[{"label":"Artikel-Zwischensumme:","value":"0,00 €"},{"label":"Gesamtbetrag für diese Bestellung:","value":"0,00 €"}]}"#,
        );
        let b = bookings(&[o]);
        assert_eq!(b.len(), 1);
        assert_eq!(b[0].cents, 0);
        assert!(b[0].purpose.contains("Hörbuch"));
    }

    #[test]
    fn falls_back_to_last_bold_row() {
        let o = order(
            r#"{"code":"3","date":"1. Mai 2025","rows":[{"label":"Summe","value":"7,00 €"},{"label":"Endbetrag","value":"8,50 €","bold":true}]}"#,
        );
        assert_eq!(bookings(&[o])[0].cents, -850);
    }

    #[test]
    fn reimport_corrects_wrong_stored_total() {
        let p_dir = crate::test_support::TempDir::new("girocrab-amazon");
        let p = p_dir.join("v.db");
        let v = Vault::open(p.to_string_lossy().to_string(), vec![7u8; 32]).unwrap();
        let conn = v
            .add_bank_connection(
                ConnectorKind::AmazonOrders,
                "Amazon Bestellungen".into(),
                String::new(),
            )
            .unwrap();
        let acc = format!("amazon-orders-{conn}");
        let wrong = vec![Booking {
            id: "amazon:302-1".into(),
            date: "2026-02-14".into(),
            cents: -132,
            purpose: "iPhone".into(),
            text: "Amazon-Bestellung",
        }];
        store_fetch(
            &v,
            ConnectorKind::AmazonOrders,
            conn,
            to_fetch(conn, "Amazon", wrong),
        )
        .unwrap();
        let json = r#"{"orders":[{"code":"302-1","date":"February 14, 2026","items":[{"title":"iPhone"}],
            "rows":[{"label":"Grand Total:","value":"€1,329.00","bold":true}]}]}"#;
        Arc::clone(&v)
            .import_amazon_orders(conn, json.into())
            .unwrap();
        let db = v.db().unwrap();
        let (amount, balance): (i64, i64) = db
            .query_row(
                "SELECT t.amount_cents, a.balance_cents FROM transactions t JOIN accounts a ON a.id = t.account_id
                 WHERE a.external_ref = ?1",
                [acc],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!((amount, balance), (-132900, -132900));
        drop(db);
        let _ = std::fs::remove_file(p);
    }
}
