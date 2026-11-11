//! Merging two device vaults: newest edit wins, deletions stay deleted.
//!
//! This module holds the groundwork shared by the merge steps: the v8 schema
//! (per-field edit stamps, soft-delete columns, uuids), the sync keys that
//! identify a row on every device, and deterministic uuids so that two vaults
//! which never met still agree on what "Lebensmittel > Supermarkt" is.
//!
//! Sync keys:
//! - category, rule: `uuid`
//! - connection: `connector|normalized login|bank_code`
//! - account: `<connection key>|external_ref` (`|external_ref` without connection)
//! - booking: `<account key>|external_id`
//!
//! Stamps are milliseconds from [`crate::user_groups::now_ms`]; `deleted_ms`
//! NULL means live. A merge never stamps anything itself.

use rusqlite::{params, Connection, OptionalExtension};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

use crate::error::{CoreError, CoreResult};
use crate::models::ConnectorKind;

/// Fixed namespace for the deterministic (v5) uuids.
const NAMESPACE: Uuid = Uuid::from_bytes([
    0x67, 0x69, 0x72, 0x6f, 0x63, 0x72, 0x61, 0x62, 0x73, 0x79, 0x6e, 0x63, 0x6d, 0x72, 0x67, 0x31,
]);

const SEP: char = '\u{1f}';

/// (table, column, definition)
const COLUMNS: &[(&str, &str, &str)] = &[
    ("transactions", "category_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("transactions", "note_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("transactions", "checked_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("transactions", "text_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("transactions", "splits_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("transactions", "deleted_ms", "INTEGER"),
    ("categories", "uuid", "TEXT"),
    ("categories", "name_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("categories", "parent_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("categories", "symbol_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("categories", "color_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("categories", "budget_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("categories", "order_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("categories", "deleted_ms", "INTEGER"),
    ("categories", "merged_into", "TEXT"),
    ("rules", "uuid", "TEXT"),
    ("rules", "updated_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("rules", "deleted_ms", "INTEGER"),
    ("rules", "merged_into", "TEXT"),
    (
        "bank_connections",
        "created_ms",
        "INTEGER NOT NULL DEFAULT 0",
    ),
    ("bank_connections", "deleted_ms", "INTEGER"),
    ("accounts", "created_ms", "INTEGER NOT NULL DEFAULT 0"),
    ("accounts", "deleted_ms", "INTEGER"),
];

/// Schema v8 – idempotent, also for vaults that skipped versions.
pub(crate) fn migrate(conn: &Connection) -> CoreResult<()> {
    for (table, col, def) in COLUMNS {
        let has: i64 = conn.query_row(
            "SELECT count(*) FROM pragma_table_info(?1) WHERE name = ?2",
            [table, col],
            |r| r.get(0),
        )?;
        if has == 0 {
            conn.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {col} {def};"))?;
        }
    }
    // a deleted category's name can be used again
    let partial: bool = conn
        .query_row(
            "SELECT sql LIKE '%deleted_ms%' FROM sqlite_master
             WHERE type = 'index' AND name = 'categories_unique_name'",
            [],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or(false);
    if !partial {
        conn.execute_batch(
            "DROP INDEX IF EXISTS categories_unique_name;
             CREATE UNIQUE INDEX categories_unique_name
                 ON categories(IFNULL(parent_id, 0), name) WHERE deleted_ms IS NULL;",
        )?;
    }
    conn.execute_batch(
        "CREATE UNIQUE INDEX IF NOT EXISTS categories_uuid ON categories(uuid);
         CREATE UNIQUE INDEX IF NOT EXISTS rules_uuid ON rules(uuid);",
    )?;
    fill_missing_uuids(conn)
}

fn fold(name: &str) -> String {
    name.trim().to_lowercase()
}

/// Same path (case-folded, trimmed names from the root) -> same uuid.
pub(crate) fn category_uuid_for_path(path: &[&str]) -> String {
    let joined = path
        .iter()
        .map(|p| fold(p))
        .collect::<Vec<_>>()
        .join(&SEP.to_string());
    Uuid::new_v5(&NAMESPACE, format!("category{SEP}{joined}").as_bytes()).to_string()
}

/// Same content -> same uuid. `account_key` is the sync key of the account a
/// rule is restricted to.
#[allow(clippy::too_many_arguments)]
pub(crate) fn rule_uuid_for_content(
    field: &str,
    match_kind: &str,
    pattern: &str,
    case_sensitive: bool,
    min: Option<i64>,
    max: Option<i64>,
    account_key: Option<&str>,
    category_uuid: &str,
) -> String {
    let opt = |v: Option<i64>| v.map(|v| v.to_string()).unwrap_or_default();
    let parts = [
        "rule".to_string(),
        field.to_string(),
        match_kind.to_string(),
        pattern.to_string(),
        (case_sensitive as i32).to_string(),
        opt(min),
        opt(max),
        account_key.unwrap_or_default().to_string(),
        category_uuid.to_string(),
    ];
    Uuid::new_v5(&NAMESPACE, parts.join(&SEP.to_string()).as_bytes()).to_string()
}

type RuleRow = (
    i64,
    String,
    String,
    String,
    bool,
    Option<i64>,
    Option<i64>,
    Option<i64>,
    i64,
);

/// Gives every category and rule without a uuid one: the deterministic uuid if
/// no row (live or deleted) has it yet, else a random one.
pub(crate) fn fill_missing_uuids(conn: &Connection) -> CoreResult<()> {
    let missing: i64 = conn.query_row(
        "SELECT (SELECT count(*) FROM categories WHERE uuid IS NULL)
              + (SELECT count(*) FROM rules WHERE uuid IS NULL)",
        [],
        |r| r.get(0),
    )?;
    if missing == 0 {
        return Ok(());
    }
    // categories
    let rows: Vec<(i64, Option<i64>, String, Option<String>)> = conn
        .prepare("SELECT id, parent_id, name, uuid FROM categories ORDER BY id")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
        .collect::<Result<_, _>>()?;
    let by_id: HashMap<i64, (Option<i64>, &str)> = rows
        .iter()
        .map(|(id, p, n, _)| (*id, (*p, n.as_str())))
        .collect();
    let mut used: HashSet<String> = rows.iter().filter_map(|r| r.3.clone()).collect();
    for (id, _, _, uuid) in &rows {
        if uuid.is_some() {
            continue;
        }
        let mut path = Vec::new();
        let mut cur = Some(*id);
        while let Some(c) = cur {
            let Some((p, n)) = by_id.get(&c) else { break };
            path.push(*n);
            if path.len() > 64 {
                break;
            }
            cur = *p;
        }
        path.reverse();
        let mut u = category_uuid_for_path(&path);
        if used.contains(&u) {
            u = Uuid::new_v4().to_string();
        }
        used.insert(u.clone());
        conn.execute(
            "UPDATE categories SET uuid = ?1 WHERE id = ?2",
            params![u, id],
        )?;
    }
    // rules
    let rules: Vec<RuleRow> = conn
        .prepare(
            "SELECT id, field, match_kind, pattern, case_sensitive, min_amount_cents,
                    max_amount_cents, account_id, category_id
             FROM rules WHERE uuid IS NULL ORDER BY id",
        )?
        .query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
                r.get(6)?,
                r.get(7)?,
                r.get(8)?,
            ))
        })?
        .collect::<Result<_, _>>()?;
    let mut used: HashSet<String> = conn
        .prepare("SELECT uuid FROM rules WHERE uuid IS NOT NULL")?
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    for (id, field, kind, pattern, cs, min, max, account, category) in rules {
        let cat_uuid: String = conn
            .query_row(
                "SELECT uuid FROM categories WHERE id = ?1",
                [category],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or_default();
        let account_key = match account {
            Some(a) => Some(account_key(conn, a)?),
            None => None,
        };
        let mut u = rule_uuid_for_content(
            &field,
            &kind,
            &pattern,
            cs,
            min,
            max,
            account_key.as_deref(),
            &cat_uuid,
        );
        if used.contains(&u) {
            u = Uuid::new_v4().to_string();
        }
        used.insert(u.clone());
        conn.execute("UPDATE rules SET uuid = ?1 WHERE id = ?2", params![u, id])?;
    }
    Ok(())
}

fn not_found(what: &str, id: i64) -> CoreError {
    CoreError::NotFound {
        what: format!("{what} {id}"),
    }
}

/// `connector|normalized login|bank_code`
/// Soft-deletes a category with all its descendants and their rules, and
/// uncategorises their bookings and splits (what the foreign-key cascades did
/// before deletions became soft). The uncategorising is a derived change: no
/// `category_ms` stamp.
pub(crate) fn soft_delete_categories(conn: &Connection, root: i64) -> CoreResult<()> {
    let now = crate::user_groups::now_ms();
    conn.execute_batch(
        "CREATE TEMP TABLE IF NOT EXISTS doomed_categories(id INTEGER PRIMARY KEY);
         DELETE FROM doomed_categories;",
    )?;
    conn.execute(
        "WITH RECURSIVE sub(id) AS (
             SELECT id FROM categories WHERE id = ?1 AND deleted_ms IS NULL
             UNION SELECT c.id FROM categories c JOIN sub ON c.parent_id = sub.id WHERE c.deleted_ms IS NULL)
         INSERT INTO doomed_categories SELECT id FROM sub",
        [root],
    )?;
    let r = (|| -> CoreResult<()> {
        conn.execute(
            "UPDATE transactions SET category_id = NULL, rule_id = NULL, category_source = 'none'
             WHERE category_id IN (SELECT id FROM doomed_categories)
                OR rule_id IN (SELECT id FROM rules WHERE category_id IN (SELECT id FROM doomed_categories))",
            [],
        )?;
        conn.execute(
            "UPDATE transaction_splits SET category_id = NULL
             WHERE category_id IN (SELECT id FROM doomed_categories)",
            [],
        )?;
        conn.execute(
            "UPDATE rules SET deleted_ms = ?1
             WHERE deleted_ms IS NULL AND category_id IN (SELECT id FROM doomed_categories)",
            [now],
        )?;
        conn.execute(
            "UPDATE categories SET deleted_ms = ?1 WHERE id IN (SELECT id FROM doomed_categories)",
            [now],
        )?;
        Ok(())
    })();
    conn.execute("DELETE FROM doomed_categories", [])?;
    r
}

/// Soft-deletes one booking (bank-side removal, twin merge).
pub(crate) fn soft_delete_booking(conn: &Connection, id: i64) -> CoreResult<()> {
    conn.execute("DELETE FROM loan_links WHERE transaction_id = ?1", [id])?;
    conn.execute(
        "UPDATE transactions SET deleted_ms = ?1 WHERE id = ?2 AND deleted_ms IS NULL",
        params![crate::user_groups::now_ms(), id],
    )?;
    Ok(())
}

/// Soft-deletes an account and its bookings (what the FK cascade did).
pub(crate) fn soft_delete_account(conn: &Connection, id: i64) -> CoreResult<()> {
    let now = crate::user_groups::now_ms();
    // derived loan links went with the rows (FK cascade) before
    conn.execute(
        "DELETE FROM loan_links WHERE loan_account_id = ?1
            OR transaction_id IN (SELECT id FROM transactions WHERE account_id = ?1)",
        [id],
    )?;
    conn.execute(
        "UPDATE transactions SET deleted_ms = ?1 WHERE account_id = ?2 AND deleted_ms IS NULL",
        params![now, id],
    )?;
    conn.execute(
        "UPDATE accounts SET deleted_ms = ?1 WHERE id = ?2 AND deleted_ms IS NULL",
        params![now, id],
    )?;
    Ok(())
}

/// Soft-deletes a connection, its accounts and their bookings.
pub(crate) fn soft_delete_connection(conn: &Connection, id: i64) -> CoreResult<()> {
    let accounts: Vec<i64> = {
        let mut q = conn.prepare("SELECT id FROM accounts WHERE connection_id = ?1")?;
        let rows = q.query_map([id], |r| r.get(0))?;
        rows.collect::<Result<_, _>>()?
    };
    for a in accounts {
        soft_delete_account(conn, a)?;
    }
    conn.execute(
        "UPDATE bank_connections SET deleted_ms = ?1 WHERE id = ?2 AND deleted_ms IS NULL",
        params![crate::user_groups::now_ms(), id],
    )?;
    Ok(())
}

/// A deleted connection added again comes back as a new row in time.
pub(crate) fn revive_connection(conn: &Connection, id: i64) -> CoreResult<()> {
    conn.execute(
        "UPDATE bank_connections SET deleted_ms = NULL, created_ms = ?1 WHERE id = ?2",
        params![crate::user_groups::now_ms(), id],
    )?;
    Ok(())
}

/// A deleted account the bank (or an import) delivers again comes back with a
/// new `created_ms`; its deleted bookings stay deleted.
pub(crate) fn revive_account_if_deleted(conn: &Connection, id: i64) -> CoreResult<()> {
    conn.execute(
        "UPDATE accounts SET deleted_ms = NULL, archived_unix = NULL, created_ms = ?1
         WHERE id = ?2 AND deleted_ms IS NOT NULL",
        params![crate::user_groups::now_ms(), id],
    )?;
    Ok(())
}

/// Whether the booking `(account, external_id)` exists as a soft-deleted row:
/// fetch and import must not insert or update it.
pub(crate) fn booking_is_deleted(
    conn: &Connection,
    account_id: i64,
    external_id: &str,
) -> CoreResult<bool> {
    Ok(conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM transactions
          WHERE account_id = ?1 AND external_id = ?2 AND deleted_ms IS NOT NULL)",
        params![account_id, external_id],
        |r| r.get(0),
    )?)
}

pub(crate) fn connection_key(conn: &Connection, id: i64) -> CoreResult<String> {
    let (connector, login, bank): (String, String, String) = conn
        .query_row(
            "SELECT connector, login_name, bank_code FROM bank_connections WHERE id = ?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?
        .ok_or_else(|| not_found("connection", id))?;
    let login = match ConnectorKind::from_str(&connector) {
        Some(kind) => crate::connections::normalize_login(kind, &login),
        None => login.trim().to_string(),
    };
    Ok(format!("{connector}|{login}|{bank}"))
}

/// `<connection key>|external_ref`, or `|external_ref` without a connection.
pub(crate) fn account_key(conn: &Connection, id: i64) -> CoreResult<String> {
    let (connection, external_ref): (Option<i64>, String) = conn
        .query_row(
            "SELECT connection_id, external_ref FROM accounts WHERE id = ?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?
        .ok_or_else(|| not_found("account", id))?;
    let prefix = match connection {
        Some(c) => connection_key(conn, c)?,
        None => String::new(),
    };
    Ok(format!("{prefix}|{external_ref}"))
}

/// `<account key>|external_id`
#[allow(dead_code)] // used by the merge steps that follow
pub(crate) fn booking_key(conn: &Connection, id: i64) -> CoreResult<String> {
    let (account, external_id): (i64, String) = conn
        .query_row(
            "SELECT account_id, external_id FROM transactions WHERE id = ?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?
        .ok_or_else(|| not_found("booking", id))?;
    Ok(format!("{}|{external_id}", account_key(conn, account)?))
}

/// The synced state of a vault, one line per row, ordered by sync key and
/// including soft-deleted rows.
#[cfg(test)]
fn synced_state(v: &crate::vault::Vault) -> Vec<String> {
    use rusqlite::types::Value;
    let db = v.db().unwrap();
    let rows = |sql: &str| -> Vec<Vec<Value>> {
        let mut st = db.prepare(sql).unwrap();
        let n = st.column_count();
        st.query_map([], |r| (0..n).map(|i| r.get::<_, Value>(i)).collect())
            .unwrap()
            .map(|r| r.unwrap())
            .collect()
    };
    let show = |vals: &[Value]| format!("{vals:?}");
    // replaces the leading local id by the row's sync key
    let keyed = |sql: &str, key: &dyn Fn(i64) -> String| -> Vec<(String, String)> {
        rows(sql)
            .into_iter()
            .map(|r| {
                let Value::Integer(id) = r[0] else {
                    unreachable!()
                };
                let mut line = vec![Value::Text(key(id))];
                line.extend_from_slice(&r[1..]);
                (show(&line[..1]), show(&line))
            })
            .collect()
    };
    let mut out = Vec::new();
    let mut section = |name: &str, mut lines: Vec<(String, String)>| {
        lines.sort();
        out.extend(lines.into_iter().map(|(_, l)| format!("{name}: {l}")));
    };
    section(
        "category",
        rows(
            "SELECT c.uuid, c.name, p.uuid, c.sf_symbol, c.color_hex, c.budget_cents, c.sort_order,
                    c.name_ms, c.parent_ms, c.symbol_ms, c.color_ms, c.budget_ms, c.order_ms,
                    c.deleted_ms, c.merged_into
             FROM categories c LEFT JOIN categories p ON p.id = c.parent_id",
        )
        .iter()
        .map(|r| (show(&r[..1]), show(r)))
        .collect(),
    );
    section(
        "rule",
        rows(
            "SELECT r.uuid, r.name, c.uuid, r.field, r.match_kind, r.pattern, r.case_sensitive,
                    r.min_amount_cents, r.max_amount_cents, r.account_id, r.priority, r.enabled,
                    r.updated_ms, r.deleted_ms, r.merged_into
             FROM rules r LEFT JOIN categories c ON c.id = r.category_id",
        )
        .into_iter()
        .map(|mut r| {
            if let Value::Integer(a) = r[9] {
                r[9] = Value::Text(account_key(&db, a).unwrap());
            }
            (show(&r[..1]), show(&r))
        })
        .collect(),
    );
    section(
        "booking",
        keyed(
            "SELECT t.id, CASE WHEN t.category_source = 'manual' THEN c.uuid END, t.note,
                    t.checked, t.counterparty, t.purpose, t.category_ms, t.note_ms, t.checked_ms,
                    t.text_ms, t.splits_ms, t.deleted_ms
             FROM transactions t LEFT JOIN categories c ON c.id = t.category_id",
            &|id| booking_key(&db, id).unwrap(),
        ),
    );
    section(
        "split",
        keyed(
            "SELECT s.transaction_id, c.uuid, s.amount_cents, s.note
             FROM transaction_splits s LEFT JOIN categories c ON c.id = s.category_id",
            &|id| booking_key(&db, id).unwrap(),
        )
        .into_iter()
        .map(|(_, l)| (l.clone(), l))
        .collect(),
    );
    section(
        "account",
        keyed("SELECT id, created_ms, deleted_ms FROM accounts", &|id| {
            account_key(&db, id).unwrap()
        }),
    );
    section(
        "connection",
        keyed(
            "SELECT id, created_ms, deleted_ms FROM bank_connections",
            &|id| connection_key(&db, id).unwrap(),
        ),
    );
    out
}

/// Test helper: two vaults hold the same synced state.
#[cfg(test)]
pub(crate) fn assert_converged(a: &crate::vault::Vault, b: &crate::vault::Vault) {
    assert_eq!(synced_state(a), synced_state(b), "vaults did not converge");
}

#[cfg(test)]
mod tests;
