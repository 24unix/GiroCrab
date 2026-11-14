//! MoneyMoney twins: a fetch takes over an imported MoneyMoney account by
//! giving it the bank's `external_ref` (`adopt_account`). A device that did
//! not fetch still holds that account under its `moneymoney-db:` key, so the
//! merge used to add it as a second account with every MoneyMoney booking
//! again. The merge now lets such an account take over the bank's key, and
//! twins already in a vault are folded into the bank account.
//!
//! Two accounts are twins when they belong to the same bank login, one is a
//! MoneyMoney account and the other a bank account, their IBANs match (or,
//! without IBAN, kind and account number), and most of the MoneyMoney
//! account's bookings are in the bank account (same external id or import
//! fingerprint). Issue #94: MoneyMoney keeps closed accounts with the same
//! IBAN; `mm-` ids are content hashes, so a closed account shares the few
//! bookings MoneyMoney fetched again for its successor, but not most of its
//! own. Accounts without any booking (depots) are twins when name and
//! account number match too.

use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashMap;

use crate::error::CoreResult;

const MM_PREFIX: &str = "moneymoney-db:";

/// What decides whether two accounts can be the same one.
struct Ident {
    id: i64,
    iban: String,
    currency: String,
    kind: String,
    number: String,
    name: String,
}

const IDENT_COLUMNS: &str = "id, upper(replace(IFNULL(iban, ''), ' ', '')),
    upper(IFNULL(currency, '')), kind, IFNULL(account_number, ''), name";

fn ident(r: &rusqlite::Row) -> rusqlite::Result<Ident> {
    Ok(Ident {
        id: r.get(0)?,
        iban: r.get(1)?,
        currency: r.get(2)?,
        kind: r.get(3)?,
        number: r.get(4)?,
        name: r.get(5)?,
    })
}

fn same_account(a: &Ident, b: &Ident) -> bool {
    if a.iban.is_empty() != b.iban.is_empty() {
        return false;
    }
    if a.iban.is_empty() {
        return a.kind == b.kind && !a.number.is_empty() && a.number == b.number;
    }
    a.iban == b.iban && (a.currency.is_empty() || b.currency.is_empty() || a.currency == b.currency)
}

/// How well the bank account `bank` (in schema `bank_schema`) holds the
/// MoneyMoney account `mm` (in `mm_schema`): the number of its bookings found
/// there, if that is most of them. Two accounts without any booking and with
/// the same name score 0.
fn twin_score(
    conn: &Connection,
    mm_schema: &str,
    mm: &Ident,
    bank_schema: &str,
    bank: &Ident,
) -> CoreResult<Option<i64>> {
    // includes soft-deleted rows: tombstones still tell which bookings the
    // MoneyMoney account had; a booking a fetch took over keeps its fingerprint
    let (total, found): (i64, i64) = conn.query_row(
        &format!(
            "SELECT count(*), IFNULL(sum(
                    EXISTS (SELECT 1 FROM {bank_schema}.transactions b
                             WHERE b.account_id = ?2 AND b.external_id = m.external_id)
                 OR (m.import_fp != '' AND EXISTS (SELECT 1 FROM {bank_schema}.transactions b
                             WHERE b.account_id = ?2 AND b.import_fp = m.import_fp))), 0)
               FROM {mm_schema}.transactions m WHERE m.account_id = ?1"
        ),
        params![mm.id, bank.id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    if total > 0 {
        return Ok((found * 2 > total).then_some(found));
    }
    // includes soft-deleted rows
    let bank_empty: bool = conn.query_row(
        &format!(
            "SELECT NOT EXISTS (SELECT 1 FROM {bank_schema}.transactions WHERE account_id = ?1)"
        ),
        [bank.id],
        |r| r.get(0),
    )?;
    Ok((bank_empty && mm.name == bank.name).then_some(0))
}

/// The candidate with the best score, if any qualifies.
fn best<'a>(
    candidates: impl Iterator<Item = &'a Ident>,
    score: impl Fn(&Ident) -> CoreResult<Option<i64>>,
) -> CoreResult<Option<i64>> {
    let mut best: Option<(i64, i64)> = None;
    for c in candidates {
        if let Some(s) = score(c)? {
            if best.is_none_or(|(top, _)| s > top) {
                best = Some((s, c.id));
            }
        }
    }
    Ok(best.map(|(_, id)| id))
}

/// Merge: the other device's bank account `other_id` (not a MoneyMoney key,
/// no local row with its key) is the local MoneyMoney account a fetch over
/// there took over. That local account takes over the bank's key, as the
/// fetch did, and is returned.
pub(crate) fn adopt_on_merge(
    conn: &Connection,
    connection_id: i64,
    other_id: i64,
) -> CoreResult<Option<i64>> {
    let (bank, ext): (Ident, String) = conn.query_row(
        &format!("SELECT {IDENT_COLUMNS}, external_ref FROM other.accounts WHERE id = ?1"),
        [other_id],
        |r| Ok((ident(r)?, r.get(6)?)),
    )?;
    if ext.starts_with(MM_PREFIX) {
        return Ok(None);
    }
    let candidates: Vec<Ident> = conn
        .prepare(&format!(
            "SELECT {IDENT_COLUMNS} FROM main.accounts
              WHERE connection_id = ?1 AND external_ref LIKE 'moneymoney-db:%' AND deleted_ms IS NULL
              ORDER BY id"
        ))?
        .query_map([connection_id], ident)?
        .collect::<Result<_, _>>()?;
    let found = best(
        candidates.iter().filter(|mm| same_account(mm, &bank)),
        |mm| twin_score(conn, "main", mm, "other", &bank),
    )?;
    if let Some(id) = found {
        conn.execute(
            "UPDATE accounts SET external_ref = ?2 WHERE id = ?1",
            params![id, ext],
        )?;
    }
    Ok(found)
}

/// The live bank account the MoneyMoney account `mm` is a twin of.
fn bank_twin(conn: &Connection, mm: &Ident, connection_id: i64) -> CoreResult<Option<i64>> {
    let banks: Vec<Ident> = conn
        .prepare(&format!(
            "SELECT {IDENT_COLUMNS} FROM main.accounts
              WHERE connection_id = ?1 AND external_ref NOT LIKE 'moneymoney-db:%' AND deleted_ms IS NULL
              ORDER BY id"
        ))?
        .query_map([connection_id], ident)?
        .collect::<Result<_, _>>()?;
    best(banks.iter().filter(|b| same_account(mm, b)), |bank| {
        twin_score(conn, "main", mm, "main", bank)
    })
}

/// Import: the account a MoneyMoney key found is a folded twin (deleted,
/// its bank account live). The import then goes to the bank account
/// instead of reviving the twin.
pub(crate) fn folded_into(conn: &Connection, id: i64) -> CoreResult<Option<i64>> {
    let row: Option<(Ident, i64)> = conn
        .query_row(
            // includes soft-deleted rows
            &format!(
                "SELECT {IDENT_COLUMNS}, connection_id FROM main.accounts
                  WHERE id = ?1 AND deleted_ms IS NOT NULL AND connection_id IS NOT NULL
                    AND external_ref LIKE 'moneymoney-db:%'"
            ),
            [id],
            |r| Ok((ident(r)?, r.get(6)?)),
        )
        .optional()?;
    match row {
        Some((mm, connection_id)) => bank_twin(conn, &mm, connection_id),
        None => Ok(None),
    }
}

/// Folds every live MoneyMoney twin into its bank account: its bookings
/// merge into the bank account the way a device merge does (matched by
/// external id, else import fingerprint; newest edit per field wins), rules,
/// documents and loan links move over, and the twin is soft-deleted, so the other
/// devices drop it on merge. Runs outside a transaction (it attaches a
/// scratch database); each twin is folded all or nothing. Returns the count.
pub(crate) fn fold_twins(conn: &Connection) -> CoreResult<u32> {
    let twins: Vec<(Ident, i64)> = conn
        .prepare(&format!(
            "SELECT {IDENT_COLUMNS}, connection_id FROM main.accounts
              WHERE connection_id IS NOT NULL AND external_ref LIKE 'moneymoney-db:%' AND deleted_ms IS NULL
              ORDER BY id"
        ))?
        .query_map([], |r| Ok((ident(r)?, r.get(6)?)))?
        .collect::<Result<_, _>>()?;
    let mut pairs = Vec::new();
    for (mm, connection_id) in &twins {
        if let Some(bank) = bank_twin(conn, mm, *connection_id)? {
            pairs.push((mm.id, bank));
        }
    }
    if pairs.is_empty() {
        return Ok(0);
    }
    conn.execute_batch("ATTACH DATABASE ':memory:' AS other KEY ''")?;
    let res = pairs
        .iter()
        .try_for_each(|&(twin, bank)| fold(conn, twin, bank));
    let detached = conn.execute_batch("DETACH DATABASE other");
    res?;
    detached?;
    Ok(pairs.len() as u32)
}

fn fold(conn: &Connection, twin: i64, bank: i64) -> CoreResult<()> {
    conn.execute_batch("SAVEPOINT fold_twin")?;
    match fold_inner(conn, twin, bank) {
        Ok(()) => Ok(conn.execute_batch("RELEASE fold_twin")?),
        Err(e) => {
            let _ = conn.execute_batch("ROLLBACK TO fold_twin; RELEASE fold_twin");
            Err(e)
        }
    }
}

fn fold_inner(conn: &Connection, twin: i64, bank: i64) -> CoreResult<()> {
    // the twin as "the other device": its account row, bookings and splits
    conn.execute_batch(&format!(
        "DROP TABLE IF EXISTS other.accounts;
         DROP TABLE IF EXISTS other.transactions;
         DROP TABLE IF EXISTS other.transaction_splits;
         CREATE TABLE other.accounts AS SELECT * FROM main.accounts WHERE id = {twin};
         CREATE TABLE other.transactions AS SELECT * FROM main.transactions WHERE account_id = {twin};
         CREATE TABLE other.transaction_splits AS SELECT * FROM main.transaction_splits
             WHERE transaction_id IN (SELECT id FROM other.transactions);"
    ))?;
    // same vault: categories and rules map onto themselves
    let identity = |table: &str| -> CoreResult<HashMap<i64, i64>> {
        Ok(conn
            .prepare(&format!(
                "SELECT id FROM main.{table} WHERE deleted_ms IS NULL"
            ))?
            .query_map([], |r| r.get(0))?
            .map(|id| id.map(|id: i64| (id, id)))
            .collect::<Result<_, _>>()?)
    };
    let cat_map = identity("categories")?;
    let rule_map = identity("rules")?;
    let acc_map = HashMap::from([(twin, bank)]);
    let mut stats = crate::vault::MergeStats::default();
    super::merge_bookings(conn, &acc_map, &cat_map, &rule_map, &mut stats)?;
    // stamped: a device still holding the rule on the twin's key loses
    conn.execute(
        "UPDATE rules SET account_id = ?2, updated_ms = max(updated_ms + 1, ?3) WHERE account_id = ?1",
        params![twin, bank, crate::user_groups::now_ms()],
    )?;
    // documents and manual loan links follow each booking to the bank
    // account's copy (same external id, else import fingerprint)
    let counterpart = "(SELECT b.id FROM transactions b, transactions m
                         WHERE m.id = {col} AND b.account_id = ?2
                           AND (b.external_id = m.external_id
                                OR (m.import_fp != '' AND b.import_fp = m.import_fp))
                         ORDER BY b.external_id = m.external_id DESC, b.deleted_ms IS NOT NULL, b.id
                         LIMIT 1)";
    conn.execute(
        &format!(
            "UPDATE booking_documents SET booking_id = IFNULL({}, booking_id)
              WHERE booking_id IN (SELECT id FROM transactions WHERE account_id = ?1)",
            counterpart.replace("{col}", "booking_documents.booking_id")
        ),
        params![twin, bank],
    )?;
    conn.execute(
        "UPDATE booking_documents SET account_id = ?2 WHERE account_id = ?1",
        params![twin, bank],
    )?;
    conn.execute(
        &format!(
            "UPDATE OR IGNORE loan_links SET transaction_id = {}
              WHERE transaction_id IN (SELECT id FROM transactions WHERE account_id = ?1)
                AND {} IS NOT NULL",
            counterpart.replace("{col}", "loan_links.transaction_id"),
            counterpart.replace("{col}", "loan_links.transaction_id")
        ),
        params![twin, bank],
    )?;
    super::soft_delete_account(conn, twin)?;
    Ok(())
}
