//! SEPA direct debit mandates and creditor IDs (GitHub #143).
//!
//! A mandate belongs to the account that collects (the creditor account). The
//! sequence type of the next collection follows from the mandate: a one-off
//! mandate is `OOFF`, otherwise the first collection is `FRST` and every later
//! one `RCUR`. The creditor ID is kept per account.

use rusqlite::{params, Connection, OptionalExtension};

use crate::connectors::fints::pain008::{validate_creditor_id, DebitScheme, SequenceType};
use crate::connectors::fints::sepa::{normalize_iban, validate_bic, validate_iban};
use crate::error::{CoreError, CoreResult};
use crate::i18n::tr;
use crate::vault::Vault;

const MANDATES: &str = "
CREATE TABLE IF NOT EXISTS mandates (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id           INTEGER NOT NULL REFERENCES accounts(id),
    debtor_name          TEXT    NOT NULL,
    debtor_iban          TEXT    NOT NULL,
    debtor_bic           TEXT    NOT NULL DEFAULT '',
    reference            TEXT    NOT NULL,              -- Mandatsreferenz
    signed_date          TEXT    NOT NULL,              -- YYYY-MM-DD
    scheme               TEXT    NOT NULL DEFAULT 'CORE', -- CORE | COR1 | B2B
    one_off              INTEGER NOT NULL DEFAULT 0,
    default_amount_cents INTEGER NOT NULL DEFAULT 0,
    default_purpose      TEXT    NOT NULL DEFAULT '',
    note                 TEXT    NOT NULL DEFAULT '',
    active               INTEGER NOT NULL DEFAULT 1,
    last_collected       TEXT,                          -- due date of the last collection
    created_ms           INTEGER NOT NULL,
    UNIQUE(account_id, reference)
);
CREATE INDEX IF NOT EXISTS mandates_account ON mandates(account_id);
CREATE TABLE IF NOT EXISTS creditor_ids (
    account_id   INTEGER PRIMARY KEY REFERENCES accounts(id),
    creditor_id  TEXT    NOT NULL,
    updated_ms   INTEGER NOT NULL
);
";

/// Step 19: mandates and creditor IDs (guarded like steps 16/17).
pub(crate) fn mandates_tables(conn: &Connection) -> CoreResult<()> {
    conn.execute_batch(MANDATES)?;
    Ok(())
}

/// Direct debit scheme of a mandate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum MandateScheme {
    Core,
    Cor1,
    B2b,
}

impl MandateScheme {
    pub(crate) fn debit(self) -> DebitScheme {
        match self {
            MandateScheme::Core => DebitScheme::Core,
            MandateScheme::Cor1 => DebitScheme::Cor1,
            MandateScheme::B2b => DebitScheme::B2b,
        }
    }

    fn from_code(code: &str) -> Self {
        match DebitScheme::from_code(code) {
            Some(DebitScheme::Cor1) => MandateScheme::Cor1,
            Some(DebitScheme::B2b) => MandateScheme::B2b,
            _ => MandateScheme::Core,
        }
    }
}

/// What the user enters for a mandate.
#[derive(Debug, Clone, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct MandateInput {
    pub account_id: i64,
    pub debtor_name: String,
    pub debtor_iban: String,
    pub debtor_bic: String,
    pub reference: String,
    /// `YYYY-MM-DD`
    pub signed_date: String,
    pub scheme: MandateScheme,
    pub one_off: bool,
    /// 0 = none.
    pub default_amount_cents: i64,
    pub default_purpose: String,
    pub note: String,
    pub active: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Mandate {
    pub id: i64,
    pub account_id: i64,
    pub debtor_name: String,
    pub debtor_iban: String,
    pub debtor_bic: String,
    pub reference: String,
    pub signed_date: String,
    pub scheme: MandateScheme,
    pub one_off: bool,
    pub default_amount_cents: i64,
    pub default_purpose: String,
    pub note: String,
    pub active: bool,
    /// Due date of the last collection, if any.
    pub last_collected: Option<String>,
    /// Sequence type the next collection gets (`FRST`, `RCUR`, `OOFF`).
    pub next_sequence: String,
}

/// Sequence type of the next collection under a mandate.
pub fn next_sequence(one_off: bool, last_collected: Option<&str>) -> SequenceType {
    if one_off {
        SequenceType::OneOff
    } else if last_collected.is_some_and(|d| !d.is_empty()) {
        SequenceType::Recurring
    } else {
        SequenceType::First
    }
}

fn scheme_code(s: MandateScheme) -> &'static str {
    s.debit().code()
}

fn invalid(msg: &str) -> CoreError {
    CoreError::InvalidInput {
        message: msg.to_string(),
    }
}

fn check(input: &MandateInput) -> CoreResult<()> {
    if input.debtor_name.trim().is_empty() {
        return Err(invalid(tr("Der Name des Zahlungspflichtigen fehlt.")));
    }
    if !validate_iban(&input.debtor_iban) {
        return Err(invalid(tr(
            "Die IBAN des Zahlungspflichtigen ist ungültig.",
        )));
    }
    if !input.debtor_bic.trim().is_empty() && !validate_bic(&input.debtor_bic) {
        return Err(invalid(tr("Die BIC ist ungültig.")));
    }
    let r = input.reference.trim();
    if r.is_empty() || r.chars().count() > 35 {
        return Err(invalid(tr(
            "Die Mandatsreferenz fehlt oder ist länger als 35 Zeichen.",
        )));
    }
    if chrono::NaiveDate::parse_from_str(&input.signed_date, "%Y-%m-%d").is_err() {
        return Err(invalid(tr("Das Datum der Mandatsunterschrift fehlt.")));
    }
    if input.default_amount_cents < 0 {
        return Err(invalid(tr("Der Betrag muss größer als 0 sein.")));
    }
    Ok(())
}

const COLUMNS: &str =
    "id, account_id, debtor_name, debtor_iban, debtor_bic, reference, signed_date,
    scheme, one_off, default_amount_cents, default_purpose, note, active, last_collected";

fn row(r: &rusqlite::Row) -> rusqlite::Result<Mandate> {
    let one_off: i64 = r.get(8)?;
    let last: Option<String> = r.get(13)?;
    let scheme: String = r.get(7)?;
    Ok(Mandate {
        id: r.get(0)?,
        account_id: r.get(1)?,
        debtor_name: r.get(2)?,
        debtor_iban: r.get(3)?,
        debtor_bic: r.get(4)?,
        reference: r.get(5)?,
        signed_date: r.get(6)?,
        scheme: MandateScheme::from_code(&scheme),
        one_off: one_off != 0,
        default_amount_cents: r.get(9)?,
        default_purpose: r.get(10)?,
        note: r.get(11)?,
        active: r.get::<_, i64>(12)? != 0,
        next_sequence: next_sequence(one_off != 0, last.as_deref())
            .code()
            .to_string(),
        last_collected: last,
    })
}

impl Vault {
    pub(crate) fn mandate(&self, id: i64) -> CoreResult<Option<Mandate>> {
        let db = self.db()?;
        Ok(db
            .query_row(
                &format!("SELECT {COLUMNS} FROM mandates WHERE id = ?1"),
                [id],
                row,
            )
            .optional()?)
    }
}

#[uniffi::export]
impl Vault {
    /// Mandates, active first, then by debtor. `account_id` = one creditor
    /// account, `None` = all.
    pub fn list_mandates(&self, account_id: Option<i64>) -> Result<Vec<Mandate>, CoreError> {
        let db = self.db()?;
        let mut stmt = db.prepare(&format!(
            "SELECT {COLUMNS} FROM mandates WHERE (?1 IS NULL OR account_id = ?1)
             ORDER BY active DESC, debtor_name COLLATE NOCASE, id"
        ))?;
        let rows = stmt.query_map([account_id], row)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Creates (`id` = `None`) or changes a mandate. The reference must be
    /// unique per creditor account.
    pub fn save_mandate(&self, id: Option<i64>, input: MandateInput) -> Result<Mandate, CoreError> {
        check(&input)?;
        let iban = normalize_iban(&input.debtor_iban);
        let bic = normalize_iban(&input.debtor_bic);
        let reference = input.reference.trim().to_string();
        let db = self.db()?;
        let clash: Option<i64> = db
            .query_row(
                "SELECT id FROM mandates WHERE account_id = ?1 AND reference = ?2",
                params![input.account_id, reference],
                |r| r.get(0),
            )
            .optional()?;
        if clash.is_some_and(|c| Some(c) != id) {
            return Err(invalid(tr(
                "Diese Mandatsreferenz gibt es für dieses Konto schon.",
            )));
        }
        let new_id = match id {
            Some(id) => {
                let n = db.execute(
                    "UPDATE mandates SET account_id=?2, debtor_name=?3, debtor_iban=?4, debtor_bic=?5,
                        reference=?6, signed_date=?7, scheme=?8, one_off=?9, default_amount_cents=?10,
                        default_purpose=?11, note=?12, active=?13 WHERE id = ?1",
                    params![
                        id,
                        input.account_id,
                        input.debtor_name.trim(),
                        iban,
                        bic,
                        reference,
                        input.signed_date,
                        scheme_code(input.scheme),
                        input.one_off,
                        input.default_amount_cents,
                        input.default_purpose.trim(),
                        input.note.trim(),
                        input.active
                    ],
                )?;
                if n == 0 {
                    return Err(invalid(tr("Das Mandat gibt es nicht mehr.")));
                }
                id
            }
            None => {
                db.execute(
                    "INSERT INTO mandates(account_id, debtor_name, debtor_iban, debtor_bic, reference,
                        signed_date, scheme, one_off, default_amount_cents, default_purpose, note,
                        active, created_ms)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                    params![
                        input.account_id,
                        input.debtor_name.trim(),
                        iban,
                        bic,
                        reference,
                        input.signed_date,
                        scheme_code(input.scheme),
                        input.one_off,
                        input.default_amount_cents,
                        input.default_purpose.trim(),
                        input.note.trim(),
                        input.active,
                        crate::user_groups::now_ms()
                    ],
                )?;
                db.last_insert_rowid()
            }
        };
        drop(db);
        self.mandate(new_id)?
            .ok_or_else(|| invalid(tr("Das Mandat gibt es nicht mehr.")))
    }

    /// Removes a mandate for good. Collections already submitted stay in the
    /// bookings; the mandate reference remains in their text.
    pub fn delete_mandate(&self, id: i64) -> Result<(), CoreError> {
        let db = self.db()?;
        db.execute("DELETE FROM mandates WHERE id = ?1", [id])?;
        Ok(())
    }

    /// Creditor ID of an account, "" if none was set.
    pub fn creditor_id(&self, account_id: i64) -> Result<String, CoreError> {
        let db = self.db()?;
        Ok(db
            .query_row(
                "SELECT creditor_id FROM creditor_ids WHERE account_id = ?1",
                [account_id],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or_default())
    }

    /// Sets the creditor ID of an account; "" removes it. A wrong check digit
    /// is refused.
    pub fn set_creditor_id(&self, account_id: i64, creditor_id: String) -> Result<(), CoreError> {
        let id = creditor_id.trim().to_ascii_uppercase();
        let db = self.db()?;
        if id.is_empty() {
            db.execute(
                "DELETE FROM creditor_ids WHERE account_id = ?1",
                [account_id],
            )?;
            return Ok(());
        }
        if !validate_creditor_id(&id) {
            return Err(invalid(tr("Die Gläubiger-ID ist ungültig.")));
        }
        db.execute(
            "INSERT INTO creditor_ids(account_id, creditor_id, updated_ms) VALUES (?1, ?2, ?3)
             ON CONFLICT(account_id) DO UPDATE SET creditor_id = ?2, updated_ms = ?3",
            params![account_id, id, crate::user_groups::now_ms()],
        )?;
        Ok(())
    }

    /// The creditor ID set most recently on any account, to prefill the field
    /// for another account ("" if none).
    pub fn suggested_creditor_id(&self) -> Result<String, CoreError> {
        let db = self.db()?;
        Ok(db
            .query_row(
                "SELECT creditor_id FROM creditor_ids ORDER BY updated_ms DESC, account_id LIMIT 1",
                [],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or_default())
    }
}

#[cfg(test)]
mod tests;
