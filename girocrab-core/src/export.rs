//! Booking export generators (GitHub #372, #401, #483): Excel CSV and ISO 20022
//! CAMT.053 account statements (`camt.053.001.02` and `.08`).
//!
//! CSV is a pure function: the app loads bookings, prepares rows (order,
//! purpose line, balance column) and the core writes the file. CAMT.053 reads
//! statement entries and booked balances straight from the vault, so pending
//! entries, an older bank balance, foreign currency and a computed balance do
//! not distort OPBD/CLBD. Tests validate the XML against the official XSDs in
//! `tests/fixtures/iso20022/` and read it back with the FinTS CAMT parser.

use crate::error::{CoreError, CoreResult};
use crate::i18n::{tr, trf};
use crate::iban::{has_iban_shape, normalize_iban};
use crate::models::{Account, AccountKind};
use crate::vault::Vault;
use rusqlite::{params, Connection};

// MARK: - CSV

/// One CSV line, already in output order.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct ExportCsvRow {
    pub date: String,
    pub account_name: String,
    pub counterparty: String,
    /// Counterparty IBAN (column "IBAN").
    #[uniffi(default)]
    #[cfg_attr(feature = "serde", serde(default))]
    pub counterparty_iban: String,
    pub purpose: String,
    pub category: String,
    pub note: String,
    /// Tag names, comma-separated (column "Tags", #228).
    #[uniffi(default)]
    #[cfg_attr(feature = "serde", serde(default))]
    pub tags: String,
    pub amount_cents: i64,
    pub currency: String,
    /// End-of-day balance, set on the last row of a day; `None` = empty cell.
    pub day_balance_cents: Option<i64>,
    /// Balance after this booking (#577); `None` = empty cell.
    #[uniffi(default)]
    #[cfg_attr(feature = "serde", serde(default))]
    pub balance_cents: Option<i64>,
}

/// `# Konto;Saldo;Währung;Datum` line above the header.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct ExportCsvBalanceLine {
    pub name: String,
    pub balance_cents: i64,
    pub currency: String,
    pub date: String,
}

/// Optional CSV columns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct ExportCsvColumns {
    pub category: bool,
    pub note: bool,
    pub daily_balance: bool,
    /// "Saldo" after each booking (#577).
    #[uniffi(default)]
    #[cfg_attr(feature = "serde", serde(default))]
    pub running_balance: bool,
    /// Counterparty IBAN after "Name".
    #[uniffi(default)]
    #[cfg_attr(feature = "serde", serde(default))]
    pub iban: bool,
    /// Tag names after "Notiz".
    #[uniffi(default)]
    #[cfg_attr(feature = "serde", serde(default))]
    pub tags: bool,
}

/// Excel CSV (UTF-8 BOM, semicolon, decimal comma, CRLF).
pub fn export_csv(
    rows: Vec<ExportCsvRow>,
    columns: ExportCsvColumns,
    balance_lines: Vec<ExportCsvBalanceLine>,
) -> String {
    let mut out = String::from("\u{FEFF}");
    for l in &balance_lines {
        out.push_str(&format!(
            "# {};{};{};{}\r\n",
            csv_field(&l.name, true),
            csv_amount(l.balance_cents),
            csv_field(&l.currency, true),
            csv_field(&l.date, false)
        ));
    }
    let mut header = vec!["Datum", "Konto", "Name"];
    if columns.iban {
        header.push("IBAN");
    }
    header.push("Verwendungszweck");
    if columns.category {
        header.push("Kategorie");
    }
    if columns.note {
        header.push("Notiz");
    }
    if columns.tags {
        header.push("Tags");
    }
    header.extend(["Betrag", "Währung"]);
    if columns.running_balance {
        header.push("Saldo");
    }
    if columns.daily_balance {
        header.push("Tagessaldo");
    }
    out.push_str(&header.join(";"));
    out.push_str("\r\n");
    for r in &rows {
        let mut cols = vec![
            csv_field(&r.date, false),
            csv_field(&r.account_name, true),
            csv_field(&r.counterparty, true),
        ];
        if columns.iban {
            cols.push(csv_field(&r.counterparty_iban, false));
        }
        cols.push(csv_field(&r.purpose, true));
        if columns.category {
            cols.push(csv_field(&r.category, true));
        }
        if columns.note {
            cols.push(csv_field(&r.note, true));
        }
        if columns.tags {
            cols.push(csv_field(&r.tags, true));
        }
        cols.push(csv_amount(r.amount_cents));
        cols.push(csv_field(&r.currency, true));
        if columns.running_balance {
            cols.push(r.balance_cents.map(csv_amount).unwrap_or_default());
        }
        if columns.daily_balance {
            cols.push(r.day_balance_cents.map(csv_amount).unwrap_or_default());
        }
        out.push_str(&cols.join(";"));
        out.push_str("\r\n");
    }
    out
}

/// Quotes a CSV field (semicolon dialect). `text` fields get the formula guard:
/// a leading `=`, `+`, `-`, `@`, tab or CR makes Excel/Numbers evaluate the
/// cell (`-2+3`, `=HYPERLINK(…)`), so it is prefixed with `'`.
pub(crate) fn csv_field(v: &str, text: bool) -> String {
    let guarded = text && v.starts_with(['=', '+', '-', '@', '\t', '\r']);
    let mut s = v.replace(['\r', '\n'], " ");
    if guarded {
        s.insert(0, '\'');
    }
    if s.contains([';', '"']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s
    }
}

/// Formats cents as `-1234,56` (German decimal comma, no grouping).
pub(crate) fn csv_amount(cents: i64) -> String {
    let sign = if cents < 0 { "-" } else { "" };
    let a = cents.unsigned_abs();
    format!("{sign}{},{:02}", a / 100, a % 100)
}

// MARK: - CAMT.053

/// ISO 20022 message version of a CAMT.053 export.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum CamtVersion {
    /// `camt.053.001.02` – what older programs import.
    V02,
    /// `camt.053.001.08` – current standard.
    V08,
}

/// What a CAMT.053 export covers.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Camt053Request {
    pub account_id: i64,
    /// First day (`YYYY-MM-DD`); `None` = the day of the first exported booking.
    pub date_from: Option<String>,
    /// Last day; `None` = the day of the last exported booking. A day after
    /// today is capped at today (or at the last exported booking).
    pub date_to: Option<String>,
    /// Only these bookings (marked in the list); `None` = all of the period.
    pub booking_ids: Option<Vec<i64>>,
    pub version: CamtVersion,
    /// ISO date-time for `CreDtTm` (`2025-03-31T12:00:00+02:00`).
    pub created_at: String,
}

/// A booking as the bank delivered it (no merchant names, no cleaned purpose).
#[derive(Debug, Clone, Default)]
struct CamtEntry {
    date: String,
    value_date: String,
    amount_cents: i64,
    currency: String,
    counterparty: String,
    counterparty_iban: String,
    purpose: String,
    booking_text: String,
    purpose_code: String,
    gvc: String,
    end_to_end_id: String,
    mandate_id: String,
    creditor_id: String,
    /// Bank's own reference (`camt:<ref>` in `external_id`), for `AcctSvcrRef`.
    external_id: String,
    pending: bool,
}

/// Day part of a stored date (`2025-03-01T10:00:00` → `2025-03-01`).
const DAY_SQL: &str = "substr(t.booking_date, 1, 10)";
pub(crate) const PENDING_SQL: &str = "t.external_id LIKE 'pending-%'";

#[uniffi::export]
impl Vault {
    /// CAMT.053 statement of one account, read straight from the vault
    /// (#372, #483). Names, purposes and references are written as the bank
    /// delivered them. OPBD is the booked balance at the start of the first
    /// day, CLBD the one at the end of the last day, both in the account
    /// currency (see [`booked_balance`]). Pending entries are listed as
    /// `PDNG`, entries in another currency with their own; neither counts.
    /// For a period CLBD = OPBD + booked entries; for marked bookings both
    /// stay the account's real balances, so a marking must not leave out a
    /// booked booking between its first and last day. Loans and depots are refused: their
    /// balance is no sum of own bookings.
    pub fn camt053_export(&self, request: Camt053Request) -> Result<String, CoreError> {
        let mut account = self
            .list_accounts()?
            .into_iter()
            .find(|a| a.id == request.account_id)
            .ok_or_else(|| CoreError::NotFound {
                what: trf("Konto {0}", &[&request.account_id]),
            })?;
        if matches!(account.kind, AccountKind::Loan | AccountKind::Brokerage) {
            return Err(CoreError::InvalidInput {
                message: tr("CAMT.053 gibt es nicht für Darlehen und Depots: Ihr Saldo ergibt sich nicht aus eigenen Umsätzen.").to_string(),
            });
        }
        let date_from = request.date_from.as_deref().map(parse_day).transpose()?;
        let date_to = request.date_to.as_deref().map(parse_day).transpose()?;
        let currency = account_currency(&account.currency);
        let today = chrono::Local::now()
            .date_naive()
            .format("%Y-%m-%d")
            .to_string();
        let db = self.db()?;
        // `list_accounts` replaces a stored 0 of a credit card with the open
        // cycle's amount, counted over every row; the balance walk below counts
        // booked rows in the account currency only, so recompute that amount.
        if !account.balance_derived && account.kind == AccountKind::CreditCard {
            let stored: i64 = db.query_row(
                "SELECT balance_cents FROM accounts WHERE id = ?1",
                [account.id],
                |r| r.get(0),
            )?;
            if stored == 0 && account.balance_cents != 0 {
                let mut st = db.prepare(&format!(
                    "SELECT t.booking_date, t.amount_cents,
                            t.counterparty || ' ' || t.purpose || ' ' || t.booking_text
                       FROM transactions t
                      WHERE t.account_id = ?1 AND t.deleted_ms IS NULL
                        AND NOT ({PENDING_SQL})
                        AND (trim(t.currency) = '' OR upper(trim(t.currency)) = ?2)
                      ORDER BY t.booking_date, t.id"
                ))?;
                let rows: Vec<(String, i64, String)> = st
                    .query_map(params![account.id, currency], |r| {
                        Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                    })?
                    .collect::<Result<_, _>>()?;
                account.balance_cents = crate::connectors::open_card_balance(&rows).unwrap_or(0);
                account.balance_date = today.clone();
            }
        }
        let ids: Option<std::collections::HashSet<i64>> = request
            .booking_ids
            .as_ref()
            .map(|ids| ids.iter().copied().collect());
        let entries = camt_entries(
            &db,
            account.id,
            date_from.as_deref(),
            date_to.as_deref(),
            ids.as_ref(),
        )?;
        let entries: Vec<CamtEntry> = entries.into_iter().map(|(_, e)| e).collect();
        let first = entries.first().map(|e| e.date.clone());
        let last = entries.last().map(|e| e.date.clone());
        // An end date after today describes a statement up to today (or up to
        // the last exported booking, when that lies further ahead).
        let to = date_to
            .map(|to| to.min(last.clone().unwrap_or_default().max(today.clone())))
            .or(last)
            .unwrap_or(today);
        // Without bookings the end date also bounds the start, so a request for
        // "everything up to <past day>" stays a valid, empty statement.
        let from = date_from.or(first).unwrap_or_else(|| to.clone());
        if to < from {
            return Err(CoreError::InvalidInput {
                message: tr("Der Zeitraum endet vor seinem Beginn.").to_string(),
            });
        }
        // Marked bookings: OPBD + entries = CLBD only holds when no booked
        // booking between the first and the last day is left out.
        if let Some(ids) = &ids {
            let gap = camt_entries(&db, account.id, Some(&from), Some(&to), None)?
                .iter()
                .any(|(id, e)| !e.pending && !ids.contains(id));
            if gap {
                return Err(CoreError::InvalidInput {
                    message: tr("CAMT.053 erfordert eine lückenlose Auswahl. Markiere alle Umsätze eines zusammenhängenden Zeitraums.").to_string(),
                });
            }
        }
        let opening = booked_balance(&db, &account, &currency, &previous_day(&from))?;
        let closing = booked_balance(&db, &account, &currency, &to)?;
        Ok(statement_xml(
            &account,
            &currency,
            &entries,
            request.version,
            (opening, &from),
            (closing, &to),
            &request.created_at,
        ))
    }
}

fn parse_day(s: &str) -> CoreResult<String> {
    let day: String = s.trim().chars().take(10).collect();
    chrono::NaiveDate::parse_from_str(&day, "%Y-%m-%d")
        .map(|d| d.format("%Y-%m-%d").to_string())
        .map_err(|_| CoreError::InvalidInput {
            message: trf("Ungültiges Datum: {0}", &[&s]),
        })
}

fn previous_day(day: &str) -> String {
    chrono::NaiveDate::parse_from_str(day, "%Y-%m-%d")
        .ok()
        .and_then(|d| d.pred_opt())
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

/// ISO 4217 code of the account; `EUR` where none is stored.
fn account_currency(s: &str) -> String {
    let c = s.trim().to_ascii_uppercase();
    if c.len() == 3 && c.bytes().all(|b| b.is_ascii_uppercase()) {
        c
    } else {
        "EUR".into()
    }
}

/// The account's bookings in `[from, to]` (by day), oldest first, with their
/// ids; `ids` narrows them without reading the others.
fn camt_entries(
    db: &Connection,
    account_id: i64,
    from: Option<&str>,
    to: Option<&str>,
    ids: Option<&std::collections::HashSet<i64>>,
) -> CoreResult<Vec<(i64, CamtEntry)>> {
    let id_filter = ids
        .map(|ids| {
            // SQLite has no `IN ()`: an empty marking is an empty statement.
            if ids.is_empty() {
                return "AND 0".to_string();
            }
            let list = (0..ids.len())
                .map(|n| format!("?{}", n + 4))
                .collect::<Vec<_>>()
                .join(",");
            format!("AND t.id IN ({list})")
        })
        .unwrap_or_default();
    let mut st = db.prepare(&format!(
        "SELECT t.id, {DAY_SQL}, substr(t.value_date, 1, 10), t.amount_cents, t.currency, t.counterparty,
                t.counterparty_iban, t.purpose, t.booking_text, t.purpose_code, t.gvc, t.end_to_end_id,
                t.mandate_id, t.creditor_id, t.external_id, {PENDING_SQL}
           FROM transactions t
          WHERE t.account_id = ?1 AND t.deleted_ms IS NULL
            AND (?2 IS NULL OR t.booking_date >= ?2)
            AND (?3 IS NULL OR t.booking_date < date(?3, '+1 day')) {id_filter}
          ORDER BY t.booking_date, t.id"
    ))?;
    let mut args = vec![
        rusqlite::types::Value::Integer(account_id),
        from.map_or(rusqlite::types::Value::Null, |s| {
            rusqlite::types::Value::Text(s.to_string())
        }),
        to.map_or(rusqlite::types::Value::Null, |s| {
            rusqlite::types::Value::Text(s.to_string())
        }),
    ];
    if let Some(ids) = ids {
        args.extend(ids.iter().map(|&id| rusqlite::types::Value::Integer(id)));
    }
    let rows = st.query_map(rusqlite::params_from_iter(args), |r| {
        Ok((
            r.get(0)?,
            CamtEntry {
                date: r.get(1)?,
                value_date: r.get(2)?,
                amount_cents: r.get(3)?,
                currency: r.get(4)?,
                counterparty: r.get(5)?,
                counterparty_iban: r.get(6)?,
                purpose: r.get(7)?,
                booking_text: r.get(8)?,
                purpose_code: r.get(9)?,
                gvc: r.get(10)?,
                end_to_end_id: r.get(11)?,
                mandate_id: r.get(12)?,
                creditor_id: r.get(13)?,
                external_id: r.get(14)?,
                pending: r.get(15)?,
            },
        ))
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// Booked balance at the end of `day` in `currency` – pending entries never
/// count, days lose their time part, other currencies stay out.
///
/// - A computed balance (`balance_derived`) is the opening balance plus every
///   booking from its date on, so the booked entries up to `day` are summed.
/// - A balance from the bank holds at the end of `balance_date` (today if
///   unknown) without pending entries: booked entries between that day and
///   `day` are taken off or added.
fn booked_balance(db: &Connection, a: &Account, currency: &str, day: &str) -> CoreResult<i64> {
    let booked = format!("t.deleted_ms IS NULL AND NOT ({PENDING_SQL})");
    let same_currency = "(trim(t.currency) = '' OR upper(trim(t.currency)) = ?4)";
    if a.balance_derived {
        let since = if a.opening_balance_cents.is_some() {
            a.opening_balance_date.as_str()
        } else {
            ""
        };
        // The Startsaldo is the balance at the start of its date, so it covers
        // every earlier booking. A day before that date takes the bookings
        // between it and the Startsaldo off again.
        let delta: i64 = db.query_row(
            &format!(
                "SELECT IFNULL(SUM(CASE
                      WHEN (?3 = '' OR {DAY_SQL} >= ?3) AND {DAY_SQL} <= ?2 THEN t.amount_cents
                      WHEN {DAY_SQL} > ?2 AND {DAY_SQL} < ?3 THEN -t.amount_cents
                      ELSE 0 END), 0)
                   FROM transactions t
                  WHERE t.account_id = ?1 AND {booked} AND {same_currency}
                    AND t.booking_date >= min(?2, ?3)
                    AND t.booking_date < date(max(?2, ?3), '+1 day')"
            ),
            params![a.id, day, since, currency],
            |r| r.get(0),
        )?;
        return Ok(a.opening_balance_cents.unwrap_or(0) + delta);
    }
    let at: String = a.balance_date.chars().take(10).collect();
    let anchor = if at.is_empty() {
        chrono::Local::now()
            .date_naive()
            .format("%Y-%m-%d")
            .to_string()
    } else {
        at
    };
    let delta: i64 = db.query_row(
        &format!(
            "SELECT IFNULL(SUM(CASE
                      WHEN {DAY_SQL} > ?3 AND {DAY_SQL} <= ?2 THEN t.amount_cents
                      WHEN {DAY_SQL} > ?2 AND {DAY_SQL} <= ?3 THEN -t.amount_cents
                      ELSE 0 END), 0)
               FROM transactions t
              WHERE t.account_id = ?1 AND {booked} AND {same_currency}
                AND t.booking_date >= min(?2, ?3)
                AND t.booking_date < date(max(?2, ?3), '+1 day')"
        ),
        params![a.id, day, anchor, currency],
        |r| r.get(0),
    )?;
    Ok(a.balance_cents + delta)
}

/// The XML of one statement; `entries` are sorted by day.
fn statement_xml(
    account: &Account,
    currency: &str,
    entries: &[CamtEntry],
    version: CamtVersion,
    opening: (i64, &str),
    closing: (i64, &str),
    created_at: &str,
) -> String {
    let v08 = version == CamtVersion::V08;
    let ns = if v08 { "08" } else { "02" };
    // Unique per export (ISO 20022): readers drop a repeated message id.
    let msg_id = format!("GC{}", uuid::Uuid::new_v4().simple());
    let iban = normalize_iban(&account.iban);
    let own_bic = if has_iban_shape(&iban) {
        crate::connectors::fints_directory::bic_for_iban(iban.clone()).unwrap_or_default()
    } else {
        String::new()
    };
    let bic_tag = if v08 { "BICFI" } else { "BIC" };

    let mut out = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    out += &format!("<Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:camt.053.001.{ns}\">\n");
    out += "<BkToCstmrStmt>\n";
    out += &format!(
        "<GrpHdr><MsgId>{msg_id}</MsgId><CreDtTm>{}</CreDtTm><MsgPgntn><PgNb>1</PgNb><LastPgInd>true</LastPgInd></MsgPgntn></GrpHdr>\n",
        esc(created_at)
    );
    out += "<Stmt>\n";
    out += &format!(
        "<Id>{msg_id}</Id><ElctrncSeqNb>1</ElctrncSeqNb><CreDtTm>{}</CreDtTm>",
        esc(created_at)
    );
    // The days OPBD/CLBD are dated for; `FrDtTm`/`ToDtTm` need a time part.
    if opening.1.len() == 10 && closing.1.len() == 10 {
        out += &format!(
            "<FrToDt><FrDtTm>{}T00:00:00</FrDtTm><ToDtTm>{}T23:59:59</ToDtTm></FrToDt>",
            esc(opening.1),
            esc(closing.1)
        );
    }
    out += "\n";
    // Acct: Id, Ccy, Nm, Ownr, Svcr – schema order.
    let fallback = format!("GC-{}", account.id);
    out += &format!(
        "<Acct><Id>{}</Id><Ccy>{currency}</Ccy>",
        account_id_xml(&iban, &account.account_number, &fallback)
    );
    if !account.name.trim().is_empty() {
        out += &format!("<Nm>{}</Nm>", esc(&truncate(account.name.trim(), 70)));
    }
    let owner = account.owner.trim();
    if !owner.is_empty() {
        out += &format!("<Ownr><Nm>{}</Nm></Ownr>", esc(&truncate(owner, 140)));
    }
    if !own_bic.is_empty() {
        out += &format!(
            "<Svcr><FinInstnId><{bic_tag}>{}</{bic_tag}></FinInstnId></Svcr>",
            esc(&own_bic)
        );
    }
    out += "</Acct>\n";
    out += &balance_xml("OPBD", opening.0, currency, opening.1);
    out += &balance_xml("CLBD", closing.0, currency, closing.1);
    for e in entries {
        out += &entry_xml(e, currency, owner, v08);
    }
    out += "</Stmt>\n</BkToCstmrStmt>\n</Document>\n";
    out
}

fn balance_xml(code: &str, cents: i64, currency: &str, date: &str) -> String {
    let ind = if cents < 0 { "DBIT" } else { "CRDT" };
    format!(
        "<Bal><Tp><CdOrPrtry><Cd>{code}</Cd></CdOrPrtry></Tp><Amt Ccy=\"{}\">{}</Amt><CdtDbtInd>{ind}</CdtDbtInd><Dt><Dt>{}</Dt></Dt></Bal>\n",
        esc(currency),
        xml_amount(cents),
        esc(date)
    )
}

/// A party of `RltdPties` (`Dbtr` / `Cdtr`): name and, for a creditor, the
/// SEPA creditor identifier (`Id/PrvtId/Othr`, scheme `SEPA`).
fn party_xml(tag: &str, name: &str, creditor_id: &str, v08: bool) -> String {
    let mut p = String::new();
    if !name.is_empty() {
        p += &format!("<Nm>{}</Nm>", esc(&truncate(name, 140)));
    }
    if !creditor_id.is_empty() {
        p += &format!(
            "<Id><PrvtId><Othr><Id>{}</Id><SchmeNm><Prtry>SEPA</Prtry></SchmeNm></Othr></PrvtId></Id>",
            esc(&truncate(creditor_id, 35))
        );
    }
    if p.is_empty() {
        return p;
    }
    if v08 {
        format!("<{tag}><Pty>{p}</Pty></{tag}>")
    } else {
        format!("<{tag}>{p}</{tag}>")
    }
}

/// ISO bank transaction code (`Domn/Fmly/SubFmlyCd`) and the German DK code
/// for a GVC; `SALA` purpose codes are salary payments.
fn bk_tx_code(
    gvc: &str,
    debit: bool,
    purpose_code: &str,
) -> (&'static str, &'static str, &'static str) {
    if purpose_code.eq_ignore_ascii_case("SALA") {
        return ("NTRF", if debit { "IRCT" } else { "ICDT" }, "SALA");
    }
    match gvc {
        "004" | "005" | "104" | "105" | "171" | "835" => ("NDDT", "IDDT", "ESDD"),
        "009" | "109" => ("NDDT", "IDDT", "UPDD"),
        "006" | "106" | "108" => ("NCAR", "CCRD", "POSD"),
        "083" | "183" => ("NCAR", "CCRD", "CWDL"),
        "008" | "152" => ("NSTO", if debit { "IRCT" } else { "ICDT" }, "STDO"),
        "805" | "806" | "809" => ("NCHG", "MDOP", "CHRG"),
        "808" | "814" => ("NINT", "MDOP", "INTR"),
        "201" | "202" | "205" | "226" => ("NSEC", "TRAD", "SECU"),
        "020" | "051" | "052" | "053" | "116" | "119" | "151" | "153" | "159" | "166" | "169" => {
            ("NTRF", if debit { "IRCT" } else { "ICDT" }, "ESCT")
        }
        _ if gvc.len() == 3 && gvc.bytes().all(|c| c.is_ascii_digit()) => {
            ("NTRF", if debit { "IRCT" } else { "ICDT" }, "OTHR")
        }
        _ => ("NMSC", if debit { "IRCT" } else { "ICDT" }, "OTHR"),
    }
}

/// The purpose without a SEPA envelope (`EREF+…`, `MREF+…`, `SVWZ+`) when the
/// bank delivered the references inside it.
fn raw_remittance_purpose<'a>(purpose: &'a str, e2e: &str, mndt: &str) -> &'a str {
    let mut rest = purpose.trim();
    if !e2e.is_empty() {
        let prefix = format!("EREF+{e2e}");
        if let Some(after) = rest.strip_prefix(&prefix) {
            rest = after.trim_start();
        }
    }
    if !mndt.is_empty() {
        let prefix = format!("MREF+{mndt}");
        if let Some(after) = rest.strip_prefix(&prefix) {
            rest = after.trim_start();
        }
    }
    if let Some(after) = rest.strip_prefix("SVWZ+") {
        return after.trim();
    }
    purpose
}

/// SEPA return reason (`RtrInf`) from the GVC or the bank's text, when the
/// booking is a return.
fn detect_return_reason(gvc: &str, purpose: &str, booking_text: &str) -> Option<&'static str> {
    const CODES: &[&str] = &[
        "AC01", "AC04", "AC06", "AG01", "AG02", "AM04", "AM05", "BE05", "CNOR", "DNOR", "FF01",
        "FOCR", "MD01", "MD02", "MD06", "MD07", "MS02", "MS03", "NARR", "RC01", "RR01", "RR02",
        "RR03", "RR04", "SL01", "TM01",
    ];
    let text = booking_text.to_lowercase();
    let is_return_context = matches!(gvc, "009" | "109" | "159")
        || text.contains("rücklastschrift")
        || text.contains("ruecklastschrift")
        || purpose.contains("RTRN+")
        || purpose.contains("RTCD+");
    for token in purpose
        .split(|c: char| !c.is_ascii_alphanumeric())
        .chain(booking_text.split(|c: char| !c.is_ascii_alphanumeric()))
    {
        if token.len() == 4 {
            let upper = token.to_ascii_uppercase();
            if let Some(&found) = CODES.iter().find(|&&c| c == upper) {
                if is_return_context || matches!(found, "AC04" | "MD01" | "MD06" | "MS03" | "AM04")
                {
                    return Some(found);
                }
            }
        }
    }
    if matches!(gvc, "009" | "109") {
        return Some("NARR");
    }
    None
}

fn entry_xml(b: &CamtEntry, account_currency: &str, owner: &str, v08: bool) -> String {
    let debit = b.amount_cents < 0;
    let ind = if debit { "DBIT" } else { "CRDT" };
    let status = if b.pending { "PDNG" } else { "BOOK" };
    let currency = account_currency_or(&b.currency, account_currency);
    let name = b.counterparty.trim();
    let e2e = b.end_to_end_id.trim();
    let mandate = b.mandate_id.trim();
    let creditor_id = b.creditor_id.trim();
    let gvc = b.gvc.trim();
    let purpose_code = b.purpose_code.trim();
    let purpose = raw_remittance_purpose(&b.purpose, e2e, mandate);
    // The bank's own reference; `external_id` is `camt:<ref>` for CAMT syncs.
    let svcr_ref = b
        .external_id
        .strip_prefix("camt:")
        .map(str::trim)
        .filter(|s| !s.is_empty() && *s != "NONREF");
    let peer_iban = normalize_iban(&b.counterparty_iban);
    let peer_bic = if has_iban_shape(&peer_iban) {
        crate::connectors::fints_directory::bic_for_iban(peer_iban.clone())
    } else {
        None
    };
    let bic_tag = if v08 { "BICFI" } else { "BIC" };

    let mut e = String::from("<Ntry>");
    e += &format!(
        "<Amt Ccy=\"{currency}\">{}</Amt><CdtDbtInd>{ind}</CdtDbtInd>",
        xml_amount(b.amount_cents)
    );
    // .08: Sts is a choice (ExternalEntryStatus1Code), .02: a plain code.
    e += &if v08 {
        format!("<Sts><Cd>{status}</Cd></Sts>")
    } else {
        format!("<Sts>{status}</Sts>")
    };
    e += &format!("<BookgDt><Dt>{}</Dt></BookgDt>", esc(&b.date));
    if !b.value_date.is_empty() {
        e += &format!("<ValDt><Dt>{}</Dt></ValDt>", esc(&b.value_date));
    }
    if let Some(reference) = svcr_ref {
        e += &format!(
            "<AcctSvcrRef>{}</AcctSvcrRef>",
            esc(&truncate(reference, 35))
        );
    }
    // BkTxCd is mandatory in both versions: the ISO domain/family for the GVC
    // plus, for a numeric GVC, the German DK form `NTRF+<GVC>+000` that
    // importers read. Anything else is classified by the ISO code alone (no
    // proprietary code without an issuer).
    let (swift_code, family, sub_family) = bk_tx_code(gvc, debit, purpose_code);
    let domain = format!(
        "<Domn><Cd>PMNT</Cd><Fmly><Cd>{family}</Cd><SubFmlyCd>{sub_family}</SubFmlyCd></Fmly></Domn>"
    );
    e += &if gvc.len() == 3 && gvc.bytes().all(|c| c.is_ascii_digit()) {
        format!("<BkTxCd>{domain}<Prtry><Cd>{swift_code}+{gvc}+000</Cd><Issr>DK</Issr></Prtry></BkTxCd>")
    } else {
        format!("<BkTxCd>{domain}</BkTxCd>")
    };
    e += "<NtryDtls><TxDtls>";
    // TxDtls order: Refs, RltdPties, RltdAgts, Purp, RmtInf, RtrInf.
    if svcr_ref.is_some() || !e2e.is_empty() || !mandate.is_empty() {
        e += "<Refs>";
        if let Some(reference) = svcr_ref {
            e += &format!(
                "<AcctSvcrRef>{}</AcctSvcrRef>",
                esc(&truncate(reference, 35))
            );
        }
        if !e2e.is_empty() {
            e += &format!("<EndToEndId>{}</EndToEndId>", esc(&truncate(e2e, 35)));
        }
        if !mandate.is_empty() {
            e += &format!("<MndtId>{}</MndtId>", esc(&truncate(mandate, 35)));
        }
        e += "</Refs>";
    }
    // Roles of the original payment: the peer is the creditor of a debit and
    // the debtor of a credit. A return (GVC 009/109/159 or a return reason)
    // turns this around: a returned direct debit is a credit, yet the peer stays
    // the creditor; a direct debit the owner collected (a credit with the
    // owner's creditor id) comes back as a debit, yet the peer stays the debtor.
    // The creditor id belongs to the creditor.
    let return_reason = detect_return_reason(gvc, &b.purpose, &b.booking_text);
    let is_return = matches!(gvc, "009" | "109" | "159") || return_reason.is_some();
    let peer_is_creditor = debit != is_return;
    let (debtor, creditor) = if peer_is_creditor {
        (
            party_xml("Dbtr", owner, "", v08),
            party_xml("Cdtr", name, creditor_id, v08),
        )
    } else {
        (
            party_xml("Dbtr", name, "", v08),
            party_xml("Cdtr", owner, creditor_id, v08),
        )
    };
    let peer_acct = if peer_iban.is_empty() {
        String::new()
    } else {
        let acct = if peer_is_creditor {
            "CdtrAcct"
        } else {
            "DbtrAcct"
        };
        format!(
            "<{acct}><Id>{}</Id></{acct}>",
            account_id_xml(&peer_iban, &peer_iban, "")
        )
    };
    // RltdPties order: Dbtr, DbtrAcct, Cdtr, CdtrAcct.
    let parties = if peer_is_creditor {
        format!("{debtor}{creditor}{peer_acct}")
    } else {
        format!("{debtor}{peer_acct}{creditor}")
    };
    if !parties.is_empty() {
        e += &format!("<RltdPties>{parties}</RltdPties>");
    }
    if let Some(bic) = peer_bic.filter(|b| !b.is_empty()) {
        let agent = if peer_is_creditor {
            "CdtrAgt"
        } else {
            "DbtrAgt"
        };
        e += &format!(
            "<RltdAgts><{agent}><FinInstnId><{bic_tag}>{}</{bic_tag}></FinInstnId></{agent}></RltdAgts>",
            esc(&bic)
        );
    }
    // ExternalPurpose1Code: 1–4 characters.
    if (1..=4).contains(&purpose_code.chars().count()) {
        e += &format!("<Purp><Cd>{}</Cd></Purp>", esc(purpose_code));
    }
    let lines = ustrd_lines(purpose);
    if !lines.is_empty() {
        e += "<RmtInf>";
        for l in lines {
            e += &format!("<Ustrd>{}</Ustrd>", esc(&l));
        }
        e += "</RmtInf>";
    }
    if let Some(reason) = return_reason {
        e += &format!("<RtrInf><Rsn><Cd>{reason}</Cd></Rsn></RtrInf>");
    }
    e += "</TxDtls></NtryDtls>";
    let text = b.booking_text.trim();
    if !text.is_empty() {
        e += &format!("<AddtlNtryInf>{}</AddtlNtryInf>", esc(&truncate(text, 500)));
    }
    e += "</Ntry>\n";
    e
}

/// An entry's ISO 4217 code; the account's where none (or no valid one) is stored.
fn account_currency_or(s: &str, account_currency: &str) -> String {
    let c = s.trim().to_ascii_uppercase();
    if c.len() == 3 && c.bytes().all(|b| b.is_ascii_uppercase()) {
        c
    } else {
        account_currency.to_string()
    }
}

/// `<IBAN>` when `iban` is one, else `<Othr><Id>` (Max34Text): the schema's
/// IBAN pattern rejects account and card numbers.
fn account_id_xml(iban: &str, other: &str, fallback: &str) -> String {
    if has_iban_shape(iban) {
        return format!("<IBAN>{}</IBAN>", esc(iban));
    }
    let other = other.trim();
    let id = if other.is_empty() { fallback } else { other };
    format!("<Othr><Id>{}</Id></Othr>", esc(&truncate(id, 34)))
}

/// Remittance text as `Ustrd` lines of at most 140 characters (Max140Text).
fn ustrd_lines(text: &str) -> Vec<String> {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let chars: Vec<char> = flat.chars().collect();
    chars
        .chunks(140)
        .map(|c| c.iter().collect::<String>().trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

fn truncate(s: &str, max: usize) -> String {
    s.chars().take(max).collect()
}

fn xml_amount(cents: i64) -> String {
    let a = cents.unsigned_abs();
    format!("{}.{:02}", a / 100, a % 100)
}

/// Escapes XML text and attribute values and drops what XML 1.0 forbids
/// (control characters below U+0020 except tab, LF, CR; U+FFFE, U+FFFF).
pub fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            '\t' | '\n' | '\r' => out.push(c),
            c if (c as u32) < 0x20 || c == '\u{FFFE}' || c == '\u{FFFF}' => {}
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::sync::Arc;

    fn vault(tag: &str) -> (Arc<Vault>, PathBuf) {
        let p = crate::test_support::thread_temp_path(tag);
        let v = Vault::open(p.to_string_lossy().into(), vec![7u8; 32]).unwrap();
        (v, p)
    }

    fn group(db: &Connection) -> i64 {
        db.execute(
            "INSERT INTO account_groups(name, sf_symbol, sort_order) VALUES ('G', 'tray', 1)
             ON CONFLICT DO NOTHING",
            [],
        )
        .unwrap();
        db.query_row("SELECT id FROM account_groups WHERE name = 'G'", [], |r| {
            r.get(0)
        })
        .unwrap()
    }

    /// An account with a balance the bank reported at `balance_date`.
    fn bank_account(v: &Vault, tag: &str, currency: &str, balance: i64, balance_date: &str) -> i64 {
        let db = v.db().unwrap();
        let g = group(&db);
        db.execute(
            "INSERT INTO bank_connections(connector, display_name) VALUES ('fints', 'Bank')",
            [],
        )
        .unwrap();
        let c = db.last_insert_rowid();
        db.execute(
            "INSERT INTO accounts(connection_id, group_id, external_ref, name, bank_name, owner, iban,
                                  account_number, currency, kind, balance_cents, balance_date, balance_derived)
             VALUES (?1, ?2, ?3, 'Giro', 'Bank', 'Erika Muster', 'DE02120300000000202051',
                     '4711', ?4, 'checking', ?5, ?6, 0)",
            params![c, g, format!("bank-{tag}"), currency, balance, balance_date],
        )
        .unwrap();
        db.last_insert_rowid()
    }

    /// An account whose balance GiroCrab computes: an optional Startsaldo plus
    /// the bookings. `balance_cents` mirrors what the list shows.
    fn computed_account(
        v: &Vault,
        tag: &str,
        kind: &str,
        opening: Option<i64>,
        opening_date: &str,
    ) -> i64 {
        let db = v.db().unwrap();
        let g = group(&db);
        db.execute(
            "INSERT INTO accounts(group_id, external_ref, name, currency, kind, balance_cents, balance_date)
             VALUES (?1, ?2, 'Konto', 'EUR', ?3, 0, '')",
            params![g, format!("computed-{tag}"), kind],
        )
        .unwrap();
        let id = db.last_insert_rowid();
        if let Some(cents) = opening {
            db.execute(
                "INSERT INTO opening_balances(account_id, opening_date, opening_cents, updated_ms)
                 VALUES (?1, ?2, ?3, 0)",
                params![id, opening_date, cents],
            )
            .unwrap();
        }
        id
    }

    fn add(v: &Vault, account: i64, tag: &str, day: &str, cents: i64) -> i64 {
        add_in(v, account, tag, day, cents, "EUR")
    }

    fn add_in(v: &Vault, account: i64, tag: &str, day: &str, cents: i64, currency: &str) -> i64 {
        let db = v.db().unwrap();
        db.execute(
            "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, currency,
                                      counterparty, counterparty_iban, purpose, booking_text)
             VALUES (?1, ?2, ?3, ?4, ?5, 'Gegenpartei', '', '', '')",
            params![account, tag, day, cents, currency],
        )
        .unwrap();
        db.last_insert_rowid()
    }

    /// `days` from today (`-5` = five days ago).
    fn day(offset: i64) -> String {
        (chrono::Local::now().date_naive() + chrono::Duration::days(offset))
            .format("%Y-%m-%d")
            .to_string()
    }

    fn export(
        v: &Vault,
        account: i64,
        from: Option<&str>,
        to: Option<&str>,
        ids: Option<Vec<i64>>,
        version: CamtVersion,
    ) -> String {
        v.camt053_export(Camt053Request {
            account_id: account,
            date_from: from.map(str::to_string),
            date_to: to.map(str::to_string),
            booking_ids: ids,
            version,
            created_at: "2026-03-31T12:00:00+02:00".into(),
        })
        .unwrap()
    }

    /// Cents and currency of the `OPBD` / `CLBD` balance.
    fn balance(xml: &str, code: &str) -> (i64, String) {
        let bal = xml
            .split("<Bal>")
            .find(|b| b.contains(&format!("<Cd>{code}</Cd>")))
            .and_then(|b| b.split("</Bal>").next())
            .unwrap_or_else(|| panic!("{code} in {xml}"));
        let amt = bal.split("<Amt Ccy=\"").nth(1).unwrap();
        let currency = amt.split('"').next().unwrap().to_string();
        let text = amt.split('>').nth(1).unwrap().split('<').next().unwrap();
        let (euro, cent) = text.split_once('.').unwrap();
        let mut cents = euro.parse::<i64>().unwrap() * 100 + cent.parse::<i64>().unwrap();
        if bal.contains("<CdtDbtInd>DBIT</CdtDbtInd>") {
            cents = -cents;
        }
        (cents, currency)
    }

    /// `xmllint --schema` against the official ISO 20022 XSD; skipped where
    /// xmllint is not installed (it ships with macOS and libxml2-utils).
    fn validate(xml: &str, schema: &str) {
        let xsd = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/iso20022")
            .join(format!("{schema}.xsd"));
        let file = std::env::temp_dir().join(format!("camt-{}.xml", uuid::Uuid::new_v4()));
        std::fs::write(&file, xml).unwrap();
        let run = Command::new("xmllint")
            .args(["--noout", "--schema"])
            .arg(&xsd)
            .arg(&file)
            .output();
        let _ = std::fs::remove_file(&file);
        match run {
            Ok(o) => assert!(
                o.status.success(),
                "{schema}: {}\n{xml}",
                String::from_utf8_lossy(&o.stderr)
            ),
            Err(e) => eprintln!("xmllint not available ({e}); XSD check skipped"),
        }
    }

    /// A bank statement with every optional detail: pending entry, control
    /// characters, a long purpose and counterparty, SEPA references, both GVC
    /// forms and a value date.
    fn rich(v: &Vault) -> i64 {
        let a = bank_account(v, "rich", "EUR", 1_000_000, &day(0));
        let one = add(v, a, "b1", &day(-20), 500_000);
        let pending = add(v, a, "pending-1", &day(-2), -50_000);
        let debit = add(v, a, "b3", &day(-5), -10_000);
        let gvc = add(v, a, "b4", &day(-1), -1_000);
        let svwz = add(v, a, "b5", &day(-4), 2_000);
        let ret = add(v, a, "b6", &day(-3), 7_000);
        let db = v.db().unwrap();
        db.execute(
            "UPDATE transactions SET purpose = ?1, purpose_code = 'SALA' WHERE id = ?2",
            params![
                format!("Rechnung\u{1}Nr. 7 & <Sonder> \u{b}{}", "x".repeat(300)),
                one
            ],
        )
        .unwrap();
        db.execute(
            "UPDATE transactions SET counterparty_iban = '1234567890' WHERE id = ?1",
            [pending],
        )
        .unwrap();
        db.execute(
            "UPDATE transactions SET counterparty = ?1, end_to_end_id = 'E2E-7', mandate_id = 'M-7',
                    creditor_id = 'DE98ZZZ09999999999', booking_text = 'SEPA-Lastschrift',
                    value_date = ?2, external_id = 'camt:BANKREF-77'
             WHERE id = ?3",
            params![format!("{} <&>", "N".repeat(200)), day(-6), debit],
        )
        .unwrap();
        db.execute(
            "UPDATE transactions SET purpose = 'EREF+SVWZ-9 MREF+M-9 SVWZ+Stripped purpose',
                    end_to_end_id = 'SVWZ-9', mandate_id = 'M-9'
             WHERE id = ?1",
            [svwz],
        )
        .unwrap();
        db.execute(
            "UPDATE transactions SET gvc = '109', booking_text = 'Rücklastschrift' WHERE id = ?1",
            [ret],
        )
        .unwrap();
        db.execute("UPDATE transactions SET gvc = '153' WHERE id = ?1", [gvc])
            .unwrap();
        drop(db);
        a
    }

    #[test]
    fn camt053_validates_against_iso20022_schemas() {
        let (v, _) = vault("camt-xsd");
        let a = rich(&v);
        for (version, schema) in [
            (CamtVersion::V02, "camt.053.001.02"),
            (CamtVersion::V08, "camt.053.001.08"),
        ] {
            let xml = export(&v, a, Some(&day(-30)), Some(&day(0)), None, version);
            assert!(!xml.contains('\u{1}'), "{xml}");
            validate(&xml, schema);
        }
        // Account without IBAN → <Othr><Id>
        let no_iban = bank_account(&v, "no-iban", "EUR", 0, &day(0));
        v.db()
            .unwrap()
            .execute(
                "UPDATE accounts SET iban = '', owner = '' WHERE id = ?1",
                [no_iban],
            )
            .unwrap();
        add(&v, no_iban, "n1", &day(-1), -100);
        let xml = export(
            &v,
            no_iban,
            Some(&day(-30)),
            Some(&day(0)),
            None,
            CamtVersion::V08,
        );
        assert!(xml.contains("<Othr><Id>4711</Id></Othr>"), "{xml}");
        // No owner: the account name stays in Nm, Ownr is omitted.
        assert!(xml.contains("<Nm>Giro</Nm>"), "{xml}");
        assert!(!xml.contains("<Ownr>"), "{xml}");
        validate(&xml, "camt.053.001.08");
    }

    /// #483 (1, 2, 6): pending entries and bookings after today never move the
    /// balances, and a time part in `booking_date` still lands on its day.
    #[test]
    fn camt053_balances_ignore_pending_and_future_bookings() {
        let (v, _) = vault("camt-balances");
        // Bank balance 1.000,00 from today.
        let bank = bank_account(&v, "pending", "EUR", 100_000, &day(0));
        add(&v, bank, "b1", &day(-20), 50_000);
        add(&v, bank, "b2", &day(-5), -10_000);
        v.db()
            .unwrap()
            .execute(
                "UPDATE transactions SET booking_date = ?1 WHERE account_id = ?2 AND external_id = 'b2'",
                params![format!("{}T10:00:00", day(-5)), bank],
            )
            .unwrap();
        add(&v, bank, "pending-1", &day(-2), -5_000);
        let xml = export(
            &v,
            bank,
            Some(&day(-30)),
            Some(&day(0)),
            None,
            CamtVersion::V08,
        );
        assert_eq!(balance(&xml, "OPBD").0, 60_000, "{xml}");
        assert_eq!(balance(&xml, "CLBD").0, 100_000, "{xml}");

        // Computed balance: sum of all bookings, the future one included.
        let computed = computed_account(&v, "future", "checking", None, "");
        add(&v, computed, "c1", &day(-40), 100_000);
        add(&v, computed, "c2", &day(-10), -10_000);
        add(&v, computed, "c3", &day(3), -20_000);
        let xml = export(
            &v,
            computed,
            Some(&day(-30)),
            Some(&day(0)),
            None,
            CamtVersion::V08,
        );
        assert_eq!(balance(&xml, "OPBD").0, 100_000, "{xml}");
        assert_eq!(balance(&xml, "CLBD").0, 90_000, "{xml}");
        // The future booking is not part of a statement that ends today.
        assert_eq!(xml.matches("<Ntry>").count(), 1, "{xml}");
    }

    /// #483 (3): a bank balance is valid at its `balance_date`, not today.
    #[test]
    fn camt053_honours_the_balance_date() {
        let (v, _) = vault("camt-balance-date");
        let a = bank_account(&v, "old", "EUR", 100_000, &day(-10));
        add(&v, a, "b1", &day(-20), 20_000);
        add(&v, a, "b2", &day(-3), -10_000);
        let xml = export(
            &v,
            a,
            Some(&day(-30)),
            Some(&day(0)),
            None,
            CamtVersion::V08,
        );
        assert_eq!(balance(&xml, "OPBD").0, 80_000, "{xml}");
        assert_eq!(balance(&xml, "CLBD").0, 90_000, "{xml}");
    }

    /// #483 (4): the statement uses the account's currency, entries in another
    /// one keep theirs and stay out of the balances, an empty code falls back.
    #[test]
    fn camt053_currency_comes_from_the_account() {
        let (v, _) = vault("camt-currency");
        let usd = bank_account(&v, "usd", "USD", 100_000, &day(0));
        add_in(&v, usd, "u1", &day(-5), -10_000, "USD");
        let xml = export(
            &v,
            usd,
            Some(&day(-30)),
            Some(&day(0)),
            None,
            CamtVersion::V08,
        );
        assert_eq!(balance(&xml, "OPBD"), (110_000, "USD".into()), "{xml}");
        assert_eq!(balance(&xml, "CLBD"), (100_000, "USD".into()), "{xml}");
        assert!(xml.contains("<Ccy>USD</Ccy>"), "{xml}");

        let eur = bank_account(&v, "eur-mixed", "EUR", 100_000, &day(0));
        add_in(&v, eur, "m1", &day(-6), -1_000, "USD");
        add_in(&v, eur, "m2", &day(-5), -10_000, "EUR");
        add_in(&v, eur, "m3", &day(-4), 500, "");
        let xml = export(
            &v,
            eur,
            Some(&day(-30)),
            Some(&day(0)),
            None,
            CamtVersion::V08,
        );
        assert_eq!(balance(&xml, "OPBD"), (109_500, "EUR".into()), "{xml}");
        assert_eq!(balance(&xml, "CLBD"), (100_000, "EUR".into()), "{xml}");
        assert!(xml.contains("<Amt Ccy=\"USD\">10.00</Amt>"), "{xml}");
        assert!(xml.contains("<Amt Ccy=\"EUR\">5.00</Amt>"), "{xml}");
        validate(&xml, "camt.053.001.08");
    }

    /// #483 (5): a loan's balance is no sum of its own bookings, a depot has
    /// none either – both are refused in the core.
    #[test]
    fn camt053_refuses_loans_and_depots() {
        let (v, _) = vault("camt-refused");
        for kind in ["loan", "brokerage"] {
            let id = computed_account(&v, kind, kind, None, "");
            add(&v, id, "x", &day(-1), -30_000);
            let err = v
                .camt053_export(Camt053Request {
                    account_id: id,
                    date_from: None,
                    date_to: None,
                    booking_ids: None,
                    version: CamtVersion::V08,
                    created_at: "2026-03-31T12:00:00+02:00".into(),
                })
                .unwrap_err();
            assert!(
                matches!(err, CoreError::InvalidInput { .. }),
                "{kind}: {err:?}"
            );
        }
    }

    /// #483 (#403): marked bookings are allowed – the balances stay the real
    /// ones at the edges of the marked period, so a marking with a gap is refused.
    #[test]
    fn camt053_marked_bookings_keep_the_real_balances() {
        let (v, _) = vault("camt-selection");
        let a = bank_account(&v, "selection", "EUR", 100_000, &day(0));
        let first = add(&v, a, "b1", &day(-20), 50_000);
        let middle = add(&v, a, "b2", &day(-5), -10_000);
        let last = add(&v, a, "b3", &day(-1), -2_000);
        let same_day = add(&v, a, "b4", &day(-1), -3_000);
        // The newest bookings without a gap: real balances, OPBD + entries = CLBD.
        let xml = export(
            &v,
            a,
            None,
            None,
            Some(vec![middle, last, same_day]),
            CamtVersion::V08,
        );
        assert_eq!(xml.matches("<Ntry>").count(), 3, "{xml}");
        assert_eq!(balance(&xml, "OPBD").0, 115_000, "{xml}");
        assert_eq!(balance(&xml, "CLBD").0, 100_000, "{xml}");
        // A marking that leaves out a booked booking between its first and last
        // day (also on the same day) would contradict itself: refused.
        for gap in [vec![first, last, same_day], vec![last]] {
            let err = v
                .camt053_export(Camt053Request {
                    account_id: a,
                    date_from: None,
                    date_to: None,
                    booking_ids: Some(gap),
                    version: CamtVersion::V08,
                    created_at: "2026-03-31T12:00:00+02:00".into(),
                })
                .unwrap_err();
            assert!(err.to_string().contains("lückenlose"), "{err}");
        }
    }

    /// A direct debit the account holder collected (own creditor id) and its
    /// return: the peer stays the debtor, the holder the creditor with its id.
    #[test]
    fn camt053_own_direct_debit_keeps_the_roles() {
        let (v, _) = vault("camt-collect");
        let a = bank_account(&v, "collect", "EUR", 100_000, &day(0));
        let collect = add(&v, a, "c1", &day(-10), 3_000);
        let returned = add(&v, a, "c2", &day(-8), -3_000);
        {
            let db = v.db().unwrap();
            for (id, gvc) in [(collect, "171"), (returned, "109")] {
                db.execute(
                    "UPDATE transactions SET counterparty = 'Max Mitglied', mandate_id = 'M-1',
                            creditor_id = 'DE11ZZZ00000000001', gvc = ?2 WHERE id = ?1",
                    params![id, gvc],
                )
                .unwrap();
            }
        }
        for version in [CamtVersion::V02, CamtVersion::V08] {
            let xml = export(&v, a, None, None, None, version);
            let (v08, schema) = if version == CamtVersion::V08 {
                (true, "camt.053.001.08")
            } else {
                (false, "camt.053.001.02")
            };
            validate(&xml, schema);
            let debtor = party_xml("Dbtr", "Max Mitglied", "", v08);
            let creditor = party_xml("Cdtr", "Erika Muster", "DE11ZZZ00000000001", v08);
            let entries: Vec<&str> = xml.split("<Ntry>").skip(1).collect();
            assert_eq!(entries.len(), 2, "{xml}");
            for e in entries {
                assert!(
                    e.contains(&format!("<RltdPties>{debtor}{creditor}</RltdPties>")),
                    "{e}"
                );
            }
        }
    }

    /// #483 (7–18): bank data stays as delivered, the missing references and
    /// parties are written, and two exports never share a message id.
    #[test]
    fn camt053_writes_bank_data_and_references() {
        let (v, _) = vault("camt-details");
        let a = rich(&v);
        let xml = export(
            &v,
            a,
            Some(&day(-30)),
            Some(&day(0)),
            None,
            CamtVersion::V08,
        );
        // Account: name, owner only when set.
        assert!(
            xml.contains(
                "<Acct><Id><IBAN>DE02120300000000202051</IBAN></Id><Ccy>EUR</Ccy><Nm>Giro</Nm>\
             <Ownr><Nm>Erika Muster</Nm></Ownr>"
            ),
            "{xml}"
        );
        // Pagination and statement period.
        assert!(
            xml.contains("<MsgPgntn><PgNb>1</PgNb><LastPgInd>true</LastPgInd></MsgPgntn>"),
            "{xml}"
        );
        assert!(
            xml.contains(&format!(
                "<FrToDt><FrDtTm>{}T00:00:00</FrDtTm><ToDtTm>{}T23:59:59</ToDtTm></FrToDt>",
                day(-30),
                day(0)
            )),
            "{xml}"
        );
        // Bank purpose (no cleaned text, control characters dropped).
        assert!(xml.contains("RechnungNr. 7 &amp; &lt;Sonder&gt;"), "{xml}");
        assert!(!xml.contains('\u{1}'));
        // A SEPA envelope around the purpose is unwrapped.
        assert!(xml.contains("<Ustrd>Stripped purpose</Ustrd>"), "{xml}");
        // Direct debit: bank reference, references, creditor id, owner as debtor.
        let debit = xml.split("<Ntry>").find(|e| e.contains("E2E-7")).unwrap();
        assert!(
            debit.contains("<AcctSvcrRef>BANKREF-77</AcctSvcrRef>"),
            "{debit}"
        );
        assert!(
            debit.contains(
                "<Refs><AcctSvcrRef>BANKREF-77</AcctSvcrRef><EndToEndId>E2E-7</EndToEndId>\
                 <MndtId>M-7</MndtId></Refs>"
            ),
            "{debit}"
        );
        assert!(debit.contains("<Cdtr><Pty><Nm>",), "{debit}");
        assert!(debit.contains(
            "<Id><PrvtId><Othr><Id>DE98ZZZ09999999999</Id><SchmeNm><Prtry>SEPA</Prtry></SchmeNm></Othr></PrvtId></Id>"
        ), "{debit}");
        assert!(
            debit.contains("<Dbtr><Pty><Nm>Erika Muster</Nm></Pty></Dbtr>"),
            "{debit}"
        );
        // Booking text as AddtlNtryInf; no GVC → ISO domain/family only.
        assert!(
            debit.contains("<AddtlNtryInf>SEPA-Lastschrift</AddtlNtryInf>"),
            "{debit}"
        );
        assert!(debit.contains(
            "<BkTxCd><Domn><Cd>PMNT</Cd><Fmly><Cd>IRCT</Cd><SubFmlyCd>OTHR</SubFmlyCd></Fmly></Domn></BkTxCd>"
        ), "{debit}");
        // A return carries its reason and keeps the direct debit's roles:
        // the peer stays the creditor even though the amount is a credit.
        let ret = xml.split("<Ntry>").find(|e| e.contains("NARR")).unwrap();
        assert!(
            ret.contains("<RtrInf><Rsn><Cd>NARR</Cd></Rsn></RtrInf>"),
            "{ret}"
        );
        assert!(
            ret.contains("<Dbtr><Pty><Nm>Erika Muster</Nm></Pty></Dbtr>"),
            "{ret}"
        );
        assert!(
            ret.contains("<Cdtr><Pty><Nm>Gegenpartei</Nm></Pty></Cdtr>"),
            "{ret}"
        );
        // A credit without mandate: the peer is the debtor, the owner the creditor.
        let credit = xml.split("<Ntry>").find(|e| e.contains("<Ustrd>")).unwrap();
        assert!(
            credit.contains("<Dbtr><Pty><Nm>Gegenpartei</Nm></Pty></Dbtr>"),
            "{credit}"
        );
        assert!(
            credit.contains("<Cdtr><Pty><Nm>Erika Muster</Nm></Pty></Cdtr>"),
            "{credit}"
        );
        // GVC 153: ISO domain/family plus the German DK form.
        assert!(xml.contains(
            "<BkTxCd><Domn><Cd>PMNT</Cd><Fmly><Cd>IRCT</Cd><SubFmlyCd>ESCT</SubFmlyCd></Fmly></Domn>\
             <Prtry><Cd>NTRF+153+000</Cd><Issr>DK</Issr></Prtry></BkTxCd>"
        ), "{xml}");
        // Value date only where the bank delivered one.
        assert_eq!(xml.matches("<ValDt>").count(), 1, "{xml}");
        // Pending entry listed as such.
        assert!(xml.contains("<Sts><Cd>PDNG</Cd></Sts>"), "{xml}");
        // A second export gets a new message id.
        let again = export(
            &v,
            a,
            Some(&day(-30)),
            Some(&day(0)),
            None,
            CamtVersion::V08,
        );
        let id = |x: &str| {
            x.split("<MsgId>")
                .nth(1)
                .unwrap()
                .split('<')
                .next()
                .unwrap()
                .to_string()
        };
        assert_ne!(id(&xml), id(&again));
        assert_eq!(
            id(&xml),
            xml.split("<Id>").nth(1).unwrap().split('<').next().unwrap()
        );
    }

    /// A GVC that is not a 3-digit DK code: the ISO domain/family classifies
    /// the entry, and no proprietary code without an issuer is invented.
    #[test]
    fn camt053_non_numeric_gvc_uses_the_iso_code_only() {
        let (v, _) = vault("camt-gvc-text");
        let a = bank_account(&v, "gvc-text", "EUR", 0, &day(0));
        let b = add(&v, a, "b1", &day(-1), -100);
        v.db()
            .unwrap()
            .execute("UPDATE transactions SET gvc = 'CARD' WHERE id = ?1", [b])
            .unwrap();
        let xml = export(
            &v,
            a,
            Some(&day(-30)),
            Some(&day(0)),
            None,
            CamtVersion::V08,
        );
        assert!(!xml.contains("<Prtry>"), "{xml}");
        assert!(
            xml.contains(
                "<BkTxCd><Domn><Cd>PMNT</Cd><Fmly><Cd>IRCT</Cd><SubFmlyCd>OTHR</SubFmlyCd></Fmly></Domn></BkTxCd>"
            ),
            "{xml}"
        );
        validate(&xml, "camt.053.001.08");
    }

    /// A dated Startsaldo is the balance at the start of its day and covers
    /// everything before it: periods before that day must take later bookings
    /// off it again, so CLBD = OPBD + booked entries holds on both sides.
    #[test]
    fn camt053_computed_balance_around_the_startsaldo() {
        let (v, _) = vault("camt-startsaldo");
        let a = computed_account(&v, "opening", "checking", Some(50_000), &day(-10));
        add(&v, a, "b1", &day(-20), 20_000);
        add(&v, a, "b2", &day(-5), -5_000);
        // Before the Startsaldo: +200,00 lies in the period, the balance
        // before it is the Startsaldo minus that entry.
        let xml = export(
            &v,
            a,
            Some(&day(-30)),
            Some(&day(-12)),
            None,
            CamtVersion::V08,
        );
        assert_eq!(balance(&xml, "OPBD").0, 30_000, "{xml}");
        assert_eq!(balance(&xml, "CLBD").0, 50_000, "{xml}");
        // From the Startsaldo on: it is the opening balance, bookings count.
        let xml = export(
            &v,
            a,
            Some(&day(-10)),
            Some(&day(0)),
            None,
            CamtVersion::V08,
        );
        assert_eq!(balance(&xml, "OPBD").0, 50_000, "{xml}");
        assert_eq!(balance(&xml, "CLBD").0, 45_000, "{xml}");
    }

    /// A card stored with balance 0 gets the open cycle's amount from
    /// `list_accounts`; that amount holds now, not at the stored date.
    #[test]
    fn camt053_anchors_a_zero_card_balance_at_today() {
        let (v, _) = vault("camt-card");
        let card = bank_account(&v, "card", "EUR", 0, &day(-20));
        v.db()
            .unwrap()
            .execute(
                "UPDATE accounts SET kind = 'credit_card' WHERE id = ?1",
                [card],
            )
            .unwrap();
        add(&v, card, "c1", &day(-10), -4_000);
        add(&v, card, "pending-1", &day(-5), -2_000);
        let xml = export(
            &v,
            card,
            Some(&day(-30)),
            Some(&day(0)),
            None,
            CamtVersion::V08,
        );
        // The hold is listed, but the anchor is the booked open cycle only.
        assert_eq!(xml.matches("<Sts><Cd>PDNG</Cd></Sts>").count(), 1, "{xml}");
        assert_eq!(balance(&xml, "OPBD").0, 0, "{xml}");
        assert_eq!(balance(&xml, "CLBD").0, -4_000, "{xml}");
    }

    /// An empty marking is a valid, empty statement – not a broken SQL list.
    #[test]
    fn camt053_empty_marking_is_an_empty_statement() {
        let (v, _) = vault("camt-empty-ids");
        let a = bank_account(&v, "empty-ids", "EUR", 100_000, &day(0));
        add(&v, a, "b1", &day(-1), -1_000);
        let xml = export(&v, a, None, None, Some(vec![]), CamtVersion::V08);
        assert_eq!(xml.matches("<Ntry>").count(), 0, "{xml}");
        assert_eq!(balance(&xml, "CLBD").0, 100_000, "{xml}");
    }

    /// An end date alone bounds an empty statement instead of failing.
    #[test]
    fn camt053_accepts_an_end_date_without_bookings() {
        let (v, _) = vault("camt-end-only");
        let a = bank_account(&v, "end-only", "EUR", 100_000, &day(0));
        add(&v, a, "later", &day(-20), -10_000);
        let xml = export(&v, a, None, Some(&day(-40)), None, CamtVersion::V08);
        assert_eq!(xml.matches("<Ntry>").count(), 0, "{xml}");
        // The -100,00 lies after the end date and is not in the balance yet.
        assert_eq!(balance(&xml, "OPBD").0, 110_000, "{xml}");
        assert_eq!(balance(&xml, "CLBD").0, 110_000, "{xml}");
    }

    /// The FinTS CAMT parser reads the export back: booked entries with their
    /// amounts and GVC, pending ones skipped, CLBD as written.
    #[test]
    fn camt053_round_trips_through_the_camt_parser() {
        let (v, _) = vault("camt-roundtrip");
        let a = rich(&v);
        for version in [CamtVersion::V02, CamtVersion::V08] {
            let xml = export(&v, a, Some(&day(-30)), Some(&day(0)), None, version);
            let (txs, report) = crate::connectors::fints::camt::parse(&xml, "");
            assert_eq!(txs.len(), 5, "{version:?}: {xml}");
            assert_eq!(report.closing_balance_cents, Some(balance(&xml, "CLBD").0));
            assert!(txs.iter().any(|t| t.gvc == "153"), "{version:?}");
            assert!(txs.iter().any(|t| t.purpose_code == "SALA"), "{version:?}");
        }
    }

    #[test]
    fn csv_formula_guard_and_escaping() {
        assert_eq!(csv_field("-2+3", true), "'-2+3");
        assert_eq!(csv_field("=SUM(A1)", true), "'=SUM(A1)");
        assert_eq!(csv_field("@x;y", true), "\"'@x;y\"");
        assert_eq!(csv_field("\tx", true), "'\tx");
        assert_eq!(csv_field("Miete", true), "Miete");
        assert_eq!(csv_field("-12,50", false), "-12,50");
        assert_eq!(csv_amount(-459), "-4,59");
        assert_eq!(csv_amount(250_000), "2500,00");
    }

    #[test]
    fn csv_columns_and_balance_lines() {
        let row = ExportCsvRow {
            date: "2025-03-02".into(),
            account_name: "Giro".into(),
            counterparty: "Supermarkt <Nord>".into(),
            counterparty_iban: "DE02120300000000202051".into(),
            purpose: "Einkauf".into(),
            category: "Lebensmittel".into(),
            note: "Woche".into(),
            tags: "Urlaub, Bar".into(),
            amount_cents: -4_599,
            currency: "EUR".into(),
            day_balance_cents: Some(1_000_000),
            balance_cents: Some(2_500),
        };
        let line = ExportCsvBalanceLine {
            name: "=HYPERLINK(\"x\")".into(),
            balance_cents: 1_000_000,
            currency: "EUR".into(),
            date: "2025-03-31".into(),
        };
        let all = ExportCsvColumns {
            category: true,
            note: true,
            daily_balance: true,
            running_balance: true,
            iban: true,
            tags: true,
        };
        let csv = export_csv(vec![row.clone()], all, vec![line]);
        assert!(csv.starts_with('\u{FEFF}'));
        assert!(csv.contains("# \"'=HYPERLINK(\"\"x\"\")\";10000,00;EUR;2025-03-31\r\n"));
        assert!(csv.contains(
            "Datum;Konto;Name;IBAN;Verwendungszweck;Kategorie;Notiz;Tags;Betrag;Währung;Saldo;Tagessaldo\r\n"
        ));
        assert!(csv.contains(
            "2025-03-02;Giro;Supermarkt <Nord>;DE02120300000000202051;Einkauf;Lebensmittel;Woche;Urlaub, Bar;-45,99;EUR;25,00;10000,00\r\n"
        ));
        let lean = export_csv(vec![row], ExportCsvColumns::default(), vec![]);
        assert!(lean.contains("Datum;Konto;Name;Verwendungszweck;Betrag;Währung\r\n"));
        assert!(!lean.contains("Woche"));
    }

    #[test]
    fn esc_drops_xml_forbidden_characters() {
        assert_eq!(esc("a\u{0}b\u{1f}c\u{fffe}"), "abc");
        assert_eq!(esc("a\tb\nc\r\nd"), "a\tb\nc\r\nd");
        assert_eq!(esc("<&>\"'"), "&lt;&amp;&gt;&quot;&#39;");
        assert!(has_iban_shape("DE02120300000000202051"));
        assert!(!has_iban_shape("1234567890"));
        assert!(!has_iban_shape("de02120300000000202051"));
    }
}
