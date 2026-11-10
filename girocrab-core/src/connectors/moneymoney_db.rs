//! MoneyMoney migration straight from MoneyMoney's own SQLCipher database.
//!
//! The file is opened **read-only** with the MoneyMoney password (SQLCipher
//! defaults, fallback `cipher_compatibility = 3` for older versions); nothing is
//! ever written to it. Only explicit, harmless columns are selected – login
//! secrets (`banks.credential`, keys, BPD/UPD, `accounts.cred` …) are never
//! read, and the `pins` table only when the user opts in.
//!
//! Bookings go through the same pipeline as the CSV/XML import
//! ([`moneymoney_import::merge_rows`]): fingerprint de-duplication, category
//! tree, notes. Accounts are recognised again by IBAN or by the stored
//! MoneyMoney account id, so a second run changes nothing.
//!
//! Balance assumption (to be verified against a real database in the preview):
//! `balance = initial balance + Σ booked bookings`, where the initial balance is
//! the newest `balances.initial_balance` row of the account/currency, falling
//! back to `accounts.initial_balance`. Pending bookings (`booked = 0`) are
//! neither imported nor counted – GiroCrab has no "vorgemerkt" state and the
//! bank delivers them again once they are booked.

use std::collections::{HashMap, HashSet};

use rusqlite::types::Value;
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, Row};
use zeroize::Zeroizing;

use crate::connectors::fints::sepa;
use crate::connectors::group_for;
use crate::connectors::moneymoney_import::{find_or_create_category, merge_rows, MmRow, Stats};
use crate::error::{CoreError, CoreResult};
use crate::i18n::{tr, trf};
use crate::models::{AccountKind, ConnectorKind};
use crate::secret::SecretString;
use crate::vault::Vault;

/// `accounts.external_ref` prefix of accounts created by this importer.
const EXT_PREFIX: &str = "moneymoney-db:";

// ------------------------------------------------------------------ FFI types

/// One MoneyMoney account as found in the database.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MoneyMoneyDbAccount {
    pub mm_id: i64,
    pub name: String,
    pub iban: String,
    pub account_number: String,
    pub currency: String,
    pub bank_code: String,
    pub bank_name: String,
    pub owner: String,
    /// MoneyMoney sidebar group (display only).
    pub group_name: String,
    pub mm_bank_id: Option<i64>,
    pub is_portfolio: bool,
    /// Best guess; the user can override it per account.
    pub suggested_kind: AccountKind,
    /// GiroCrab account with the same IBAN (or imported from this MoneyMoney
    /// account before) – the suggested merge target.
    pub existing_account_id: Option<i64>,
    pub existing_account_name: Option<String>,
    /// Booked bookings that would be imported (split parts instead of parents).
    pub booking_count: u32,
    /// Pending (vorgemerkte) bookings – not imported.
    pub pending_count: u32,
    pub notes_count: u32,
    pub first_date: Option<String>,
    pub last_date: Option<String>,
    /// Balance GiroCrab will show (see module docs for the assumption).
    pub computed_balance_cents: i64,
    /// Where the starting value of the balance came from (German, for the UI).
    pub balance_source: String,
}

/// One bank login in MoneyMoney. Secrets are never part of this record.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MoneyMoneyDbBank {
    pub mm_id: i64,
    pub bank_code: String,
    pub name: String,
    pub login_name: String,
    pub customer_id: String,
    /// GiroCrab connector for this bank, `None` = not supported (skipped).
    pub connector: Option<ConnectorKind>,
    /// MoneyMoney has a saved PIN for this login (the PIN itself is not read).
    pub has_saved_pin: bool,
    pub existing_connection_id: Option<i64>,
    pub account_count: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MoneyMoneyDbPreview {
    pub accounts: Vec<MoneyMoneyDbAccount>,
    pub banks: Vec<MoneyMoneyDbBank>,
    /// Category paths ("Haushalt › Lebensmittel").
    pub category_paths: Vec<String>,
    pub total_bookings: u32,
    pub pending_bookings: u32,
    pub notes_count: u32,
    pub split_parts: u32,
    pub date_range_start: Option<String>,
    pub date_range_end: Option<String>,
    /// The vault has no bookings yet, so MoneyMoney's categories replace
    /// GiroCrab's starter categories (and their rules) instead of being added.
    pub replaces_starter_categories: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MoneyMoneyDbAccountChoice {
    pub mm_id: i64,
    pub import: bool,
    pub kind: AccountKind,
    /// `None` = new account (or the one created by an earlier run).
    pub target_account_id: Option<i64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MoneyMoneyDbImportOptions {
    /// Accounts not listed here are not imported.
    pub accounts: Vec<MoneyMoneyDbAccountChoice>,
    pub import_categories: bool,
    pub import_notes: bool,
    pub create_connections: bool,
    /// Copy saved PINs into the encrypted vault (only with `create_connections`).
    pub import_pins: bool,
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct MoneyMoneyDbImportResult {
    pub accounts_created: u32,
    pub accounts_merged: u32,
    pub bookings_new: u32,
    pub bookings_duplicates: u32,
    /// Existing bookings that received a category and/or note.
    pub bookings_enriched: u32,
    pub pending_skipped: u32,
    pub notes_imported: u32,
    pub categories_created: u32,
    pub connections_created: u32,
    pub connections_existing: u32,
    pub pins_stored: u32,
    pub banks_skipped_unsupported: u32,
}

// ------------------------------------------------------------------ source model

#[derive(Debug, Clone, Default)]
struct SrcAccount {
    id: i64,
    bank_key: Option<i64>,
    account: String,
    bankcode: String,
    portfolio: bool,
    iban: String,
    currency: String,
    name: String,
    owner: String,
    initial_balance: Option<f64>,
    group_key: Option<i64>,
}

#[derive(Debug, Clone, Default)]
struct SrcBank {
    id: i64,
    bankcode: String,
    username: String,
    customer: String,
    name: String,
}

#[derive(Debug, Clone, Default)]
struct SrcTx {
    id: i64,
    account_key: i64,
    cp_account: String,
    cp_bankcode: String,
    amount: Option<f64>,
    currency: String,
    ts: Option<i64>,
    value_ts: Option<i64>,
    eref: String,
    mref: String,
    cred: String,
    comment: String,
    booked: bool,
    booking_text: String,
    purpose: String,
    name: String,
    checkmark: bool,
    split_key: Option<i64>,
    category_key: Option<i64>,
}

#[derive(Default)]
struct Source {
    accounts: Vec<SrcAccount>,
    banks: Vec<SrcBank>,
    account_groups: HashMap<i64, String>,
    /// category rowid -> path (uncategorised / invalid entries are absent)
    categories: HashMap<i64, Vec<String>>,
    /// all category paths in MoneyMoney order
    category_order: Vec<Vec<String>>,
    txs: Vec<SrcTx>,
    /// newest `balances` row per (account, currency): (timestamp, initial balance)
    balances: HashMap<(i64, String), (i64, f64)>,
    /// banks with a saved PIN (from `SELECT bank_key FROM pins`)
    pin_banks: HashSet<i64>,
    /// the PINs themselves – only filled when the user opted in
    pins: HashMap<i64, SecretString>,
}

// ------------------------------------------------------------------ helpers

fn vtext(v: Value) -> String {
    match v {
        Value::Text(s) => s.trim().to_string(),
        Value::Integer(i) => i.to_string(),
        Value::Real(f) => f.to_string(),
        Value::Null | Value::Blob(_) => String::new(),
    }
}

fn vint(v: Value) -> Option<i64> {
    match v {
        Value::Integer(i) => Some(i),
        Value::Real(f) if f.is_finite() => Some(f as i64),
        Value::Text(s) => s.trim().parse().ok(),
        _ => None,
    }
}

fn vreal(v: Value) -> Option<f64> {
    match v {
        Value::Integer(i) => Some(i as f64),
        Value::Real(f) => Some(f),
        Value::Text(s) => s.trim().parse().ok(),
        _ => None,
    }
}

fn get(r: &Row, i: usize) -> rusqlite::Result<Value> {
    r.get::<_, Value>(i)
}

/// MoneyMoney stores amounts as REAL. Converted via the shortest decimal
/// representation, rounded half away from zero (0.285 → 29 cents, not 28).
pub(crate) fn real_to_cents(x: f64) -> Option<i64> {
    if !x.is_finite() {
        return None;
    }
    let s = format!("{}", x.abs());
    let (int, frac) = s.split_once('.').unwrap_or((s.as_str(), ""));
    let d: Vec<i64> = frac
        .bytes()
        .chain(std::iter::repeat(b'0'))
        .take(3)
        .map(|b| (b - b'0') as i64)
        .collect();
    let mut cents = int
        .parse::<i64>()
        .ok()?
        .checked_mul(100)?
        .checked_add(d[0] * 10 + d[1])?;
    if d[2] >= 5 {
        cents += 1;
    }
    Some(if x < 0.0 { -cents } else { cents })
}

/// MoneyMoney dates are Unix seconds at 12:00 UTC → `YYYY-MM-DD` (UTC).
pub(crate) fn unix_to_date(ts: i64) -> Option<String> {
    chrono::DateTime::from_timestamp(ts, 0).map(|d| d.date_naive().format("%Y-%m-%d").to_string())
}

fn looks_like_bic(s: &str) -> bool {
    let s = s.trim();
    (s.len() == 8 || s.len() == 11)
        && s.chars().all(|c| c.is_ascii_alphanumeric())
        && s.chars().take(6).all(|c| c.is_ascii_alphabetic())
}

fn fnv(s: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{:08x}", h as u32)
}

fn ext_ref(a: &SrcAccount) -> String {
    format!(
        "{EXT_PREFIX}{}:{}",
        a.id,
        fnv(&format!("{}|{}", a.bankcode, a.account))
    )
}

fn has_any(hay: &str, needles: &[&str]) -> bool {
    needles.iter().any(|n| hay.contains(n))
}

/// Suggested GiroCrab kind. MoneyMoney's `type` codes are undocumented, so the
/// guess uses `portfolio` and keywords in the account / bank name.
fn suggest_kind(a: &SrcAccount, bank_name: &str) -> AccountKind {
    let name = a.name.to_lowercase();
    let both = format!("{name} {}", bank_name.to_lowercase());
    if a.portfolio {
        AccountKind::Brokerage
    } else if has_any(
        &both,
        &[
            "kreditkarte",
            "credit card",
            "creditcard",
            "visa",
            "mastercard",
            "american express",
            "amex",
        ],
    ) {
        AccountKind::CreditCard
    } else if has_any(&both, &["paypal"]) {
        AccountKind::PaymentService
    } else if has_any(
        &name,
        &[
            "tagesgeld",
            "sparkonto",
            "sparbuch",
            "festgeld",
            "geldmarkt",
            "savings",
            "extra-konto",
        ],
    ) {
        AccountKind::Savings
    } else if has_any(
        &name,
        &["darlehen", "baufinanzierung", "hypothek", "kredit", "loan"],
    ) {
        AccountKind::Loan
    } else if has_any(
        &name,
        &["bargeld", "kasse", "portemonnaie", "geldbörse", "cash"],
    ) {
        AccountKind::Cash
    } else if has_any(&name, &["depot", "wertpapier"]) {
        AccountKind::Brokerage
    } else {
        AccountKind::Checking
    }
}

/// GiroCrab connector for a MoneyMoney bank login: bank code first, name for
/// institutions without a German bank code.
fn connector_for(bankcode: &str, name: &str) -> Option<ConnectorKind> {
    let code: String = bankcode.chars().filter(|c| c.is_ascii_digit()).collect();
    match code.as_str() {
        "52090000" => return Some(ConnectorKind::VolksbankKasselGoettingen),
        "50050201" => return Some(ConnectorKind::Direkt1822),
        "20041111" | "20041133" | "20041144" | "20041155" => return Some(ConnectorKind::Comdirect),
        _ => {}
    }
    if code.len() == 8 {
        return None; // another German bank
    }
    let n = name.to_lowercase();
    if n.contains("paypal") {
        Some(ConnectorKind::PayPal)
    } else if n.contains("trade republic") {
        Some(ConnectorKind::TradeRepublic)
    } else if n.contains("american express") || n.contains("amex") {
        Some(ConnectorKind::AmericanExpress)
    } else if n.contains("amazon") {
        Some(ConnectorKind::AmazonVisa)
    } else if n.contains("comdirect") {
        Some(ConnectorKind::Comdirect)
    } else {
        None
    }
}

/// Connectors that actually use a stored PIN (`begin_sync` without typing).
fn pin_usable(kind: ConnectorKind) -> bool {
    matches!(
        kind,
        ConnectorKind::VolksbankKasselGoettingen
            | ConnectorKind::Direkt1822
            | ConnectorKind::Comdirect
            | ConnectorKind::TradeRepublic
    )
}

fn wrong_password() -> CoreError {
    CoreError::Authentication {
        message: tr("Falsches Passwort oder keine MoneyMoney-Datenbank.").into(),
    }
}

// ------------------------------------------------------------------ reading

/// Opens the MoneyMoney database read-only and unlocks it. The password is
/// only placed in a zeroized `PRAGMA key` statement and never logged.
fn open_source(path: &str, password: &SecretString) -> CoreResult<Connection> {
    if !std::path::Path::new(path).is_file() {
        return Err(CoreError::NotFound {
            what: tr("MoneyMoney-Datenbank").into(),
        });
    }
    if password.is_empty() {
        return Err(wrong_password());
    }
    let mut pragma = Zeroizing::new(String::from("PRAGMA key = '"));
    for c in password.expose().chars() {
        if c == '\'' {
            pragma.push('\'');
        }
        pragma.push(c);
    }
    pragma.push_str("';");
    for compat in [None, Some(3)] {
        let conn = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|_| wrong_password())?;
        // Errors of the key statement are swallowed: they must never carry the SQL.
        if conn.execute_batch(&pragma).is_err() {
            continue;
        }
        if let Some(v) = compat {
            if conn
                .execute_batch(&format!("PRAGMA cipher_compatibility = {v};"))
                .is_err()
            {
                continue;
            }
        }
        if conn
            .query_row("SELECT count(*) FROM sqlite_master", [], |r| {
                r.get::<_, i64>(0)
            })
            .is_ok()
        {
            return Ok(conn);
        }
    }
    Err(wrong_password())
}

fn objects(conn: &Connection) -> CoreResult<HashSet<String>> {
    let mut st =
        conn.prepare("SELECT lower(name) FROM sqlite_master WHERE type IN ('table', 'view')")?;
    let names = st
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<Result<HashSet<_>, _>>()?;
    Ok(names)
}

/// `SELECT <explicit columns> FROM <table>`; columns missing in older
/// MoneyMoney versions read as NULL. Never `SELECT *`.
fn select(conn: &Connection, table: &str, cols: &[&str], tail: &str) -> CoreResult<String> {
    let have: HashSet<String> = {
        let mut st = conn.prepare("SELECT lower(name) FROM pragma_table_info(?1)")?;
        let r = st
            .query_map([table], |r| r.get::<_, String>(0))?
            .collect::<Result<_, _>>()?;
        r
    };
    let list = cols
        .iter()
        .map(|c| {
            if *c == "rowid" || have.contains(*c) {
                format!("\"{c}\"")
            } else {
                "NULL".to_string()
            }
        })
        .collect::<Vec<_>>()
        .join(", ");
    Ok(format!("SELECT {list} FROM \"{table}\" {tail}"))
}

/// Reads everything the importer needs. `with_pins` must only be true when the
/// user explicitly asked to take over saved PINs.
fn read_source(path: &str, password: &SecretString, with_pins: bool) -> CoreResult<Source> {
    let conn = open_source(path, password)?;
    let have = objects(&conn)?;
    if !["accounts", "transactions", "categories"]
        .iter()
        .all(|t| have.contains(*t))
    {
        return Err(wrong_password());
    }
    let mut src = Source::default();

    // accounts – never cred / userdata / transientdata / web_ops
    {
        let sql = select(
            &conn,
            "accounts",
            &[
                "rowid",
                "bank_key",
                "account",
                "bankcode",
                "portfolio",
                "iban",
                "currency",
                "name",
                "owner",
                "initial_balance",
                "group_key",
            ],
            "ORDER BY sort, rowid",
        )?;
        let mut st = conn.prepare(&sql)?;
        let rows = st.query_map([], |r| {
            Ok(SrcAccount {
                id: vint(get(r, 0)?).unwrap_or_default(),
                bank_key: vint(get(r, 1)?).filter(|k| *k > 0),
                account: vtext(get(r, 2)?),
                bankcode: vtext(get(r, 3)?),
                portfolio: vint(get(r, 4)?).unwrap_or(0) != 0,
                iban: sepa::normalize_iban(&vtext(get(r, 5)?)),
                currency: {
                    let c = vtext(get(r, 6)?).to_uppercase();
                    if c.is_empty() {
                        "EUR".into()
                    } else {
                        c
                    }
                },
                name: vtext(get(r, 7)?),
                owner: vtext(get(r, 8)?),
                initial_balance: vreal(get(r, 9)?),
                group_key: vint(get(r, 10)?).filter(|k| *k > 0),
            })
        })?;
        src.accounts = rows.collect::<Result<_, _>>()?;
    }

    // banks – never credential / keys / systemid / bpd / upd / local_storage / userdata
    if have.contains("banks") {
        let sql = select(
            &conn,
            "banks",
            &["rowid", "bankcode", "username", "customer", "name"],
            "ORDER BY rowid",
        )?;
        let mut st = conn.prepare(&sql)?;
        let rows = st.query_map([], |r| {
            Ok(SrcBank {
                id: vint(get(r, 0)?).unwrap_or_default(),
                bankcode: vtext(get(r, 1)?),
                username: vtext(get(r, 2)?),
                customer: vtext(get(r, 3)?),
                name: vtext(get(r, 4)?),
            })
        })?;
        src.banks = rows.collect::<Result<_, _>>()?;
    }

    if have.contains("account_groups") {
        let sql = select(&conn, "account_groups", &["rowid", "name"], "")?;
        let mut st = conn.prepare(&sql)?;
        let rows = st.query_map([], |r| {
            Ok((vint(get(r, 0)?).unwrap_or_default(), vtext(get(r, 1)?)))
        })?;
        src.account_groups = rows.collect::<Result<_, _>>()?;
    }

    // categories (+ nested groups)
    {
        let mut groups: HashMap<i64, (String, i64)> = HashMap::new();
        if have.contains("category_groups") {
            let sql = select(
                &conn,
                "category_groups",
                &["rowid", "name", "group_key"],
                "",
            )?;
            let mut st = conn.prepare(&sql)?;
            let rows = st.query_map([], |r| {
                Ok((
                    vint(get(r, 0)?).unwrap_or_default(),
                    (vtext(get(r, 1)?), vint(get(r, 2)?).unwrap_or(0)),
                ))
            })?;
            groups = rows.collect::<Result<_, _>>()?;
        }
        let sql = select(
            &conn,
            "categories",
            &["rowid", "name", "type", "group_key"],
            "ORDER BY group_key, sort, rowid",
        )?;
        let mut st = conn.prepare(&sql)?;
        let rows = st.query_map([], |r| {
            Ok((
                vint(get(r, 0)?).unwrap_or_default(),
                vtext(get(r, 1)?),
                vint(get(r, 2)?),
                vint(get(r, 3)?).unwrap_or(0),
            ))
        })?;
        for row in rows {
            let (id, name, typ, group) = row?;
            // rowid 1 / type 0 / empty name = "Ohne Kategorie"
            if name.is_empty() || typ == Some(0) {
                continue;
            }
            let mut path = vec![name];
            let mut g = group;
            let mut guard = 0;
            while g > 0 && guard < 32 {
                guard += 1;
                let Some((gname, parent)) = groups.get(&g) else {
                    break;
                };
                if !gname.is_empty() {
                    path.push(gname.clone());
                }
                g = *parent;
            }
            path.reverse();
            src.category_order.push(path.clone());
            src.categories.insert(id, path);
        }
    }

    // transactions – counterparty, texts, references; `pn` unused
    {
        let sql = select(
            &conn,
            "transactions",
            &[
                "rowid",
                "local_account_key",
                "account",
                "bankcode",
                "amount",
                "currency",
                "timestamp",
                "value_timestamp",
                "eref",
                "mref",
                "cred",
                "comment",
                "booked",
                "unformatted_type",
                "unformatted_purpose",
                "name",
                "checkmark",
                "split_key",
                "category_key",
            ],
            "ORDER BY timestamp, rowid",
        )?;
        let mut st = conn.prepare(&sql)?;
        let rows = st.query_map([], |r| {
            Ok(SrcTx {
                id: vint(get(r, 0)?).unwrap_or_default(),
                account_key: vint(get(r, 1)?).unwrap_or_default(),
                cp_account: vtext(get(r, 2)?),
                cp_bankcode: vtext(get(r, 3)?),
                amount: vreal(get(r, 4)?),
                currency: vtext(get(r, 5)?).to_uppercase(),
                ts: vint(get(r, 6)?),
                value_ts: vint(get(r, 7)?).filter(|t| *t > 0),
                eref: vtext(get(r, 8)?),
                mref: vtext(get(r, 9)?),
                cred: vtext(get(r, 10)?),
                comment: vtext(get(r, 11)?),
                booked: vint(get(r, 12)?).unwrap_or(1) != 0,
                booking_text: vtext(get(r, 13)?),
                purpose: vtext(get(r, 14)?),
                name: vtext(get(r, 15)?),
                checkmark: vint(get(r, 16)?).unwrap_or(0) != 0,
                split_key: vint(get(r, 17)?).filter(|k| *k > 0),
                category_key: vint(get(r, 18)?),
            })
        })?;
        src.txs = rows.collect::<Result<_, _>>()?;
    }

    if have.contains("balances") {
        let sql = select(
            &conn,
            "balances",
            &["account_key", "currency", "timestamp", "initial_balance"],
            "ORDER BY timestamp",
        )?;
        let mut st = conn.prepare(&sql)?;
        let rows = st.query_map([], |r| {
            Ok((
                vint(get(r, 0)?),
                vtext(get(r, 1)?).to_uppercase(),
                vint(get(r, 2)?).unwrap_or(0),
                vreal(get(r, 3)?),
            ))
        })?;
        for row in rows {
            if let (Some(acc), cur, ts, Some(v)) = row? {
                // ordered by timestamp: the newest row wins
                src.balances.insert((acc, cur), (ts, v));
            }
        }
    }

    if have.contains("pins") {
        // Only which banks have a PIN – the pin column is not touched here.
        let mut st = conn.prepare("SELECT bank_key FROM pins")?;
        let rows = st.query_map([], |r| Ok(vint(get(r, 0)?)))?;
        for k in rows {
            if let Some(k) = k? {
                src.pin_banks.insert(k);
            }
        }
        if with_pins {
            // Only for banks GiroCrab supports and whose connector uses a PIN.
            let mut st = conn.prepare("SELECT pin FROM pins WHERE bank_key = ?1")?;
            for b in &src.banks {
                if !connector_for(&b.bankcode, &b.name).is_some_and(pin_usable)
                    || !src.pin_banks.contains(&b.id)
                {
                    continue;
                }
                let pin: Option<Value> = st.query_row([b.id], |r| get(r, 0)).optional()?;
                if let Some(Value::Text(p)) = pin {
                    let p = SecretString::new(p);
                    if !p.expose().trim().is_empty() {
                        src.pins.insert(b.id, p);
                    }
                }
            }
        }
    }
    Ok(src)
}

// ------------------------------------------------------------------ rows

struct AccountRows {
    rows: Vec<MmRow>,
    pending: u32,
    split_parts: u32,
    balance_cents: i64,
    balance_source: String,
    balance_date: String,
}

impl Source {
    fn bank(&self, key: Option<i64>) -> Option<&SrcBank> {
        key.and_then(|k| self.banks.iter().find(|b| b.id == k))
    }

    fn account_name(&self, a: &SrcAccount) -> String {
        if !a.name.is_empty() {
            return a.name.clone();
        }
        let bank = self.bank(a.bank_key).map(|b| b.name.as_str()).unwrap_or("");
        let s = format!("{bank} {}", a.account).trim().to_string();
        if s.is_empty() {
            format!("MoneyMoney-Konto {}", a.id)
        } else {
            s
        }
    }

    /// Normalised bookings of one account: booked only, split parts instead of
    /// their parent, plus the balance (see module docs).
    fn rows_for(&self, a: &SrcAccount) -> AccountRows {
        let txs: Vec<&SrcTx> = self.txs.iter().filter(|t| t.account_key == a.id).collect();
        let ids: HashSet<i64> = txs.iter().map(|t| t.id).collect();
        let is_part = |t: &SrcTx| t.split_key.is_some_and(|k| k != t.id && ids.contains(&k));
        let parents: HashSet<i64> = txs
            .iter()
            .filter(|t| is_part(t))
            .filter_map(|t| t.split_key)
            .collect();
        let mut out = AccountRows {
            rows: Vec::new(),
            pending: 0,
            split_parts: 0,
            balance_cents: 0,
            balance_source: String::new(),
            balance_date: String::new(),
        };
        let mut sum = 0i64;
        for t in &txs {
            let (Some(ts), Some(amount)) = (t.ts, t.amount) else {
                continue;
            };
            let (Some(date), Some(cents)) = (unix_to_date(ts), real_to_cents(amount)) else {
                continue;
            };
            if !t.booked {
                out.pending += 1;
                continue;
            }
            let part = is_part(t);
            if !part {
                sum += cents; // the parent carries the full amount
            }
            if parents.contains(&t.id) {
                continue; // imported as its parts
            }
            if part {
                out.split_parts += 1;
            }
            let clean = |s: &str| crate::text::clean_bank_text(s.trim());
            let path = t
                .category_key
                .and_then(|k| self.categories.get(&k))
                .cloned()
                .unwrap_or_default();
            out.rows.push(MmRow {
                booking_date: date,
                value_date: t.value_ts.and_then(unix_to_date).unwrap_or_default(),
                amount_cents: cents,
                currency: if t.currency.is_empty() {
                    a.currency.clone()
                } else {
                    t.currency.clone()
                },
                name: clean(&t.name),
                iban: if sepa::validate_iban(&t.cp_account) {
                    sepa::normalize_iban(&t.cp_account)
                } else {
                    String::new()
                },
                bic: if looks_like_bic(&t.cp_bankcode) {
                    t.cp_bankcode.to_uppercase()
                } else {
                    String::new()
                },
                purpose: clean(&t.purpose),
                booking_text: clean(&t.booking_text),
                category: path.join("\\"),
                category_parts: path,
                note: t.comment.clone(),
                checkmark: t.checkmark,
                mandate_ref: t.mref.clone(),
                creditor_id: t.cred.clone(),
                end_to_end: t.eref.clone(),
            });
        }
        let last = out
            .rows
            .iter()
            .map(|r| r.booking_date.clone())
            .max()
            .unwrap_or_default();
        let (base, source, base_date) = match self.balances.get(&(a.id, a.currency.clone())) {
            Some((ts, v)) => {
                let d = unix_to_date(*ts).unwrap_or_default();
                (
                    *v,
                    trf(
                        "Anfangssaldo laut MoneyMoney-Saldenverlauf ({0}) + Umsätze",
                        &[&d],
                    ),
                    d,
                )
            }
            None => match a.initial_balance {
                Some(v) if v != 0.0 => (
                    v,
                    tr("Anfangssaldo des Kontos + Umsätze").into(),
                    String::new(),
                ),
                _ => (0.0, tr("Summe der Umsätze").into(), String::new()),
            },
        };
        out.balance_cents = real_to_cents(base).unwrap_or(0) + sum;
        out.balance_source = source;
        out.balance_date = last.max(base_date);
        out
    }
}

// ------------------------------------------------------------------ vault side

fn find_existing_account(
    conn: &Connection,
    ext: &str,
    iban: &str,
) -> CoreResult<Option<(i64, String)>> {
    let by_ref: Option<(i64, String)> = conn
        .query_row(
            "SELECT id, name FROM accounts WHERE external_ref = ?1 ORDER BY id LIMIT 1",
            [ext],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if by_ref.is_some() || iban.is_empty() {
        return Ok(by_ref);
    }
    Ok(conn
        .query_row(
            "SELECT id, name FROM accounts WHERE upper(replace(iban, ' ', '')) = ?1
             ORDER BY (connection_id IS NULL), id LIMIT 1",
            [iban],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?)
}

fn find_connection(conn: &Connection, kind: ConnectorKind, login: &str) -> CoreResult<Option<i64>> {
    let login = crate::connections::normalize_login(kind, login);
    let mut st = conn
        .prepare("SELECT id, login_name FROM bank_connections WHERE connector = ?1 ORDER BY id")?;
    let rows: Vec<(i64, String)> = st
        .query_map([kind.as_str()], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<Result<_, _>>()?;
    Ok(rows
        .into_iter()
        .find(|(_, l)| crate::connections::normalize_login(kind, l).eq_ignore_ascii_case(&login))
        .map(|(id, _)| id))
}

/// Called by `store_fetch` when a synced account is not known yet: takes over
/// an account created by this importer instead of adding a second one. Matched
/// by IBAN; without one (credit cards, PayPal) only when exactly one imported
/// account of that kind is linked to this bank login.
pub(crate) fn adopt_account(
    conn: &Connection,
    connection_id: i64,
    external_ref: &str,
    iban: &str,
    kind: AccountKind,
) -> CoreResult<Option<i64>> {
    let iban = sepa::normalize_iban(iban);
    let id: Option<i64> = if iban.is_empty() {
        let mut st = conn.prepare(
            "SELECT id FROM accounts WHERE connection_id = ?1 AND external_ref LIKE 'moneymoney-db:%'
               AND kind = ?2 AND replace(IFNULL(iban, ''), ' ', '') = '' LIMIT 2",
        )?;
        let ids: Vec<i64> = st
            .query_map(params![connection_id, kind.as_str()], |r| r.get(0))?
            .collect::<Result<_, _>>()?;
        if ids.len() == 1 {
            Some(ids[0])
        } else {
            None
        }
    } else {
        conn.query_row(
            "SELECT id FROM accounts WHERE (connection_id IS NULL OR connection_id = ?1)
               AND external_ref LIKE 'moneymoney-db:%' AND upper(replace(iban, ' ', '')) = ?2
             ORDER BY (connection_id IS NULL), id LIMIT 1",
            params![connection_id, iban],
            |r| r.get(0),
        )
        .optional()?
    };
    if let Some(id) = id {
        conn.execute(
            "UPDATE accounts SET connection_id = ?1, external_ref = ?2 WHERE id = ?3",
            params![connection_id, external_ref, id],
        )?;
    }
    Ok(id)
}

/// MoneyMoney's tree replaces the starter categories only in a vault without
/// bookings: nothing can be assigned to them yet, so nothing is lost.
fn replaces_starter_categories(conn: &Connection, src: &Source) -> CoreResult<bool> {
    if src.category_order.is_empty() {
        return Ok(false);
    }
    let bookings: i64 = conn.query_row("SELECT count(*) FROM transactions", [], |r| r.get(0))?;
    Ok(bookings == 0)
}

fn preview(conn: &Connection, src: &Source) -> CoreResult<MoneyMoneyDbPreview> {
    let mut accounts = Vec::new();
    let (mut total, mut pending, mut notes, mut parts) = (0u32, 0u32, 0u32, 0u32);
    let mut first: Option<String> = None;
    let mut last: Option<String> = None;
    for a in &src.accounts {
        let r = src.rows_for(a);
        let bank = src.bank(a.bank_key);
        let bank_name = bank.map(|b| b.name.clone()).unwrap_or_default();
        let existing = find_existing_account(conn, &ext_ref(a), &a.iban)?;
        let f = r.rows.iter().map(|x| x.booking_date.clone()).min();
        let l = r.rows.iter().map(|x| x.booking_date.clone()).max();
        let n = r.rows.iter().filter(|x| !x.note.trim().is_empty()).count() as u32;
        total += r.rows.len() as u32;
        pending += r.pending;
        notes += n;
        parts += r.split_parts;
        first = match (first, f.clone()) {
            (Some(x), Some(y)) => Some(x.min(y)),
            (x, y) => x.or(y),
        };
        last = last.max(l.clone());
        accounts.push(MoneyMoneyDbAccount {
            mm_id: a.id,
            name: src.account_name(a),
            iban: a.iban.clone(),
            account_number: a.account.clone(),
            currency: a.currency.clone(),
            bank_code: bank
                .map(|b| b.bankcode.clone())
                .filter(|c| !c.is_empty())
                .unwrap_or_else(|| a.bankcode.clone()),
            suggested_kind: suggest_kind(a, &bank_name),
            bank_name,
            owner: a.owner.clone(),
            group_name: a
                .group_key
                .and_then(|g| src.account_groups.get(&g))
                .cloned()
                .unwrap_or_default(),
            mm_bank_id: a.bank_key,
            is_portfolio: a.portfolio,
            existing_account_id: existing.as_ref().map(|e| e.0),
            existing_account_name: existing.map(|e| e.1),
            booking_count: r.rows.len() as u32,
            pending_count: r.pending,
            notes_count: n,
            first_date: f,
            last_date: l,
            computed_balance_cents: r.balance_cents,
            balance_source: r.balance_source,
        });
    }
    let mut banks = Vec::new();
    for b in &src.banks {
        let connector = connector_for(&b.bankcode, &b.name);
        banks.push(MoneyMoneyDbBank {
            mm_id: b.id,
            bank_code: b.bankcode.clone(),
            name: b.name.clone(),
            login_name: b.username.clone(),
            customer_id: b.customer.clone(),
            connector,
            has_saved_pin: src.pin_banks.contains(&b.id),
            existing_connection_id: match connector {
                Some(k) => find_connection(conn, k, &b.username)?,
                None => None,
            },
            account_count: src
                .accounts
                .iter()
                .filter(|a| a.bank_key == Some(b.id))
                .count() as u32,
        });
    }
    Ok(MoneyMoneyDbPreview {
        accounts,
        banks,
        category_paths: src.category_order.iter().map(|p| p.join(" › ")).collect(),
        total_bookings: total,
        pending_bookings: pending,
        notes_count: notes,
        split_parts: parts,
        date_range_start: first,
        date_range_end: last,
        replaces_starter_categories: replaces_starter_categories(conn, src)?,
    })
}

fn import(
    conn: &Connection,
    src: &Source,
    options: &MoneyMoneyDbImportOptions,
) -> CoreResult<MoneyMoneyDbImportResult> {
    let mut res = MoneyMoneyDbImportResult::default();
    let mut cat_cache = HashMap::new();
    if options.import_categories && replaces_starter_categories(conn, src)? {
        // rules and assignments go with them (ON DELETE CASCADE / SET NULL)
        conn.execute("DELETE FROM categories", [])?;
    }
    if options.import_categories {
        // the whole tree, also categories without bookings
        for path in &src.category_order {
            find_or_create_category(conn, path, &mut cat_cache, &mut res.categories_created)?;
        }
    }
    let mut to_link: Vec<(i64, i64)> = Vec::new();
    for choice in options.accounts.iter().filter(|c| c.import) {
        let a = src
            .accounts
            .iter()
            .find(|a| a.id == choice.mm_id)
            .ok_or_else(|| CoreError::NotFound {
                what: format!("MoneyMoney-Konto {}", choice.mm_id),
            })?;
        let r = src.rows_for(a);
        let ext = ext_ref(a);
        let kind = choice.kind;
        let target = match choice.target_account_id {
            Some(id) => Some(id),
            None => conn
                .query_row(
                    "SELECT id FROM accounts WHERE external_ref = ?1 ORDER BY id LIMIT 1",
                    [&ext],
                    |r| r.get::<_, i64>(0),
                )
                .optional()?,
        };
        let (account_id, currency) = match target {
            Some(id) => {
                let cur: String = conn
                    .query_row("SELECT currency FROM accounts WHERE id = ?1", [id], |r| {
                        r.get(0)
                    })
                    .optional()?
                    .ok_or_else(|| CoreError::NotFound {
                        what: format!("account {id}"),
                    })?;
                res.accounts_merged += 1;
                (id, cur)
            }
            None => {
                let (group, sym, order) = group_for(kind);
                let gid = Vault::ensure_group(conn, group, sym, order)?;
                let bank_name = src
                    .bank(a.bank_key)
                    .map(|b| b.name.clone())
                    .filter(|n| !n.is_empty())
                    .unwrap_or_else(|| "MoneyMoney-Import".into());
                conn.execute(
                    "INSERT INTO accounts(connection_id, group_id, external_ref, name, bank_name, owner, iban, account_number,
                                          currency, kind, balance_cents, balance_date, sf_symbol, sort_order)
                     VALUES (NULL, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0, '', ?10,
                             (SELECT IFNULL(MAX(sort_order),0)+1 FROM accounts))",
                    params![
                        gid,
                        ext,
                        src.account_name(a),
                        bank_name,
                        a.owner,
                        a.iban,
                        a.account,
                        a.currency,
                        kind.as_str(),
                        kind.sf_symbol()
                    ],
                )?;
                res.accounts_created += 1;
                (conn.last_insert_rowid(), a.currency.clone())
            }
        };
        // Accounts owned by the importer (not synced with a bank) follow MoneyMoney:
        // chosen kind and MoneyMoney's balance. Bank-synced accounts keep theirs.
        let owned: bool = conn.query_row(
            "SELECT external_ref LIKE 'moneymoney-db:%' FROM accounts WHERE id = ?1",
            [account_id],
            |r| r.get(0),
        )?;
        let mut st = Stats {
            total: r.rows.len() as u32,
            account_id,
            ..Default::default()
        };
        merge_rows(
            conn,
            &r.rows,
            &currency,
            options.import_categories,
            options.import_notes,
            &mut cat_cache,
            &mut st,
        )?;
        if owned {
            let (group, sym, order) = group_for(kind);
            let gid = Vault::ensure_group(conn, group, sym, order)?;
            conn.execute(
                "UPDATE accounts SET kind = ?1, sf_symbol = ?2, group_id = ?3, balance_cents = ?4, balance_date = ?5 WHERE id = ?6",
                params![kind.as_str(), kind.sf_symbol(), gid, r.balance_cents, r.balance_date, account_id],
            )?;
            if kind == AccountKind::Loan {
                Vault::derive_initial_balance(conn, account_id)?;
            }
        }
        res.bookings_new += st.new;
        res.bookings_duplicates += st.duplicates;
        res.bookings_enriched += st.enriched;
        res.notes_imported += st.notes;
        res.categories_created += st.categories_created;
        res.pending_skipped += r.pending;
        if let (true, Some(bank)) = (owned, a.bank_key) {
            to_link.push((account_id, bank));
        }
    }

    let mut bank_connection: HashMap<i64, i64> = HashMap::new();
    for b in &src.banks {
        let Some(kind) = connector_for(&b.bankcode, &b.name) else {
            res.banks_skipped_unsupported += 1;
            continue;
        };
        if !options.create_connections {
            continue;
        }
        let id = match find_connection(conn, kind, &b.username)? {
            Some(id) => {
                res.connections_existing += 1;
                id
            }
            None => {
                let (id, created) = Vault::add_bank_connection_inner(
                    conn,
                    kind,
                    b.name.clone(),
                    b.username.clone(),
                )?;
                if created {
                    res.connections_created += 1;
                } else {
                    res.connections_existing += 1;
                }
                id
            }
        };
        bank_connection.insert(b.id, id);
        if options.import_pins {
            if let Some(pin) = src.pins.get(&b.id) {
                let stored: bool = conn
                    .query_row(
                        "SELECT 1 FROM settings WHERE key = ?1",
                        [crate::connections::pin_key(id)],
                        |_| Ok(true),
                    )
                    .optional()?
                    .unwrap_or(false);
                // never overwrite a PIN the user already stored in GiroCrab
                if !stored {
                    crate::connections::set_pin_inner(conn, id, Some(pin.expose()))?;
                    res.pins_stored += 1;
                }
            }
        }
    }
    // Show imported accounts under their bank login right away; the first
    // sync then takes them over (adopt_account) instead of adding new ones.
    for (account_id, bank) in to_link {
        if let Some(cid) = bank_connection.get(&bank) {
            conn.execute(
                "UPDATE accounts SET connection_id = ?1 WHERE id = ?2 AND connection_id IS NULL",
                params![cid, account_id],
            )?;
        }
    }
    Vault::apply_rules_inner(conn, true)?;
    Ok(res)
}

#[uniffi::export]
impl Vault {
    /// Dry run of a MoneyMoney database import: reads the database read-only
    /// and lists accounts, bank logins and categories. Nothing is stored and
    /// no PIN is read.
    pub fn preview_moneymoney_database(
        &self,
        path: String,
        password: String,
    ) -> Result<MoneyMoneyDbPreview, CoreError> {
        let password = SecretString::new(password);
        let src = read_source(&path, &password, false)?;
        drop(password);
        let db = self.db()?;
        preview(&db, &src)
    }

    /// Imports a MoneyMoney database in one go (accounts, bookings, categories,
    /// notes, optionally bank logins and saved PINs). Idempotent.
    pub fn import_moneymoney_database(
        &self,
        path: String,
        password: String,
        options: MoneyMoneyDbImportOptions,
    ) -> Result<MoneyMoneyDbImportResult, CoreError> {
        let password = SecretString::new(password);
        let with_pins = options.import_pins && options.create_connections;
        let src = read_source(&path, &password, with_pins)?;
        drop(password);
        let db = self.db()?;
        let tx = db.unchecked_transaction()?;
        let res = import(&tx, &src, &options)?;
        tx.commit()?;
        Ok(res)
    }
}

#[cfg(test)]
mod tests;
