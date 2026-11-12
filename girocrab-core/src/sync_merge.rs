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
use std::collections::{BTreeMap, HashMap, HashSet};
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
    // includes soft-deleted rows
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
    soft_delete_account_at(conn, id, crate::user_groups::now_ms())
}

/// The cascade shares one stamp, so a revive can tell the bookings deleted
/// together with the account from individually deleted ones.
fn soft_delete_account_at(conn: &Connection, id: i64, now: i64) -> CoreResult<()> {
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
        // includes soft-deleted rows
        let mut q = conn.prepare("SELECT id FROM accounts WHERE connection_id = ?1")?;
        let rows = q.query_map([id], |r| r.get(0))?;
        rows.collect::<Result<_, _>>()?
    };
    let now = crate::user_groups::now_ms();
    for a in accounts {
        soft_delete_account_at(conn, a, now)?;
    }
    conn.execute(
        "UPDATE bank_connections SET deleted_ms = ?1 WHERE id = ?2 AND deleted_ms IS NULL",
        params![now, id],
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
/// new `created_ms`, together with the bookings deleted in the same cascade;
/// individually deleted bookings stay deleted.
pub(crate) fn revive_account_if_deleted(conn: &Connection, id: i64) -> CoreResult<()> {
    let stamp: Option<i64> = conn
        // includes soft-deleted rows
        .query_row("SELECT deleted_ms FROM accounts WHERE id = ?1", [id], |r| {
            r.get(0)
        })
        .optional()?
        .flatten();
    let Some(stamp) = stamp else { return Ok(()) };
    conn.execute(
        "UPDATE accounts SET deleted_ms = NULL, archived_unix = NULL, created_ms = ?1 WHERE id = ?2",
        params![crate::user_groups::now_ms(), id],
    )?;
    conn.execute(
        "UPDATE transactions SET deleted_ms = NULL WHERE account_id = ?1 AND deleted_ms = ?2",
        params![id, stamp],
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
        // includes soft-deleted rows
        "SELECT EXISTS (SELECT 1 FROM transactions
          WHERE account_id = ?1 AND external_id = ?2 AND deleted_ms IS NOT NULL)",
        params![account_id, external_id],
        |r| r.get(0),
    )?)
}

pub(crate) fn connection_key(conn: &Connection, id: i64) -> CoreResult<String> {
    let (connector, login, bank): (String, String, String) = conn
        .query_row(
            // includes soft-deleted rows
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
            // includes soft-deleted rows
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
            // includes soft-deleted rows
            "SELECT account_id, external_id FROM transactions WHERE id = ?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?
        .ok_or_else(|| not_found("booking", id))?;
    Ok(format!("{}|{external_id}", account_key(conn, account)?))
}

// ------------------------------------------------------------------ merge

/// Newest stamp wins; equal stamps with different values: the larger value.
fn take_newer<T: PartialOrd>(val: &mut T, ms: &mut i64, other: T, other_ms: i64) {
    if other_ms > *ms || (other_ms == *ms && other > *val) {
        *val = other;
        *ms = other_ms;
    }
}

/// A deletion only ever gets set: the larger `deleted_ms` wins, and
/// `merged_into` goes with it (equal stamps: the larger pointer).
fn merge_deletion(
    deleted: &mut Option<i64>,
    merged: &mut Option<String>,
    other_deleted: Option<i64>,
    other_merged: Option<String>,
) {
    let mut ms = deleted.unwrap_or(0);
    take_newer(merged, &mut ms, other_merged, other_deleted.unwrap_or(0));
    *deleted = (*deleted).max(other_deleted);
}

/// Follows `merged_into` to the live row a deleted one was combined into.
/// `None`: deleted without a live survivor.
fn survivor<'a>(
    uuid: &'a str,
    live: impl Fn(&str) -> Option<(bool, Option<&'a str>)>,
) -> Option<&'a str> {
    let mut cur = uuid;
    for _ in 0..64 {
        let (is_live, merged) = live(cur)?;
        if is_live {
            return Some(cur);
        }
        cur = merged?;
    }
    None
}

/// Picks the local row a v7 row (no uuid of its own) stands for: live rows
/// first, then the lowest uuid. Soft-deleted rows count, so that nothing
/// deleted comes back with a new uuid.
fn pick_match<'a>(cands: &[(&'a str, bool)]) -> Option<&'a str> {
    cands
        .iter()
        .min_by_key(|(u, live)| (!live, *u))
        .map(|(u, _)| *u)
}

#[derive(Clone, PartialEq, Debug)]
struct Cat {
    id: i64,
    uuid: String,
    name: String,
    parent: Option<String>,
    symbol: String,
    color: String,
    budget: Option<i64>,
    order: i64,
    name_ms: i64,
    parent_ms: i64,
    symbol_ms: i64,
    color_ms: i64,
    budget_ms: i64,
    order_ms: i64,
    deleted_ms: Option<i64>,
    merged_into: Option<String>,
}

impl Cat {
    fn merge(&mut self, o: Cat) {
        take_newer(&mut self.name, &mut self.name_ms, o.name, o.name_ms);
        take_newer(&mut self.parent, &mut self.parent_ms, o.parent, o.parent_ms);
        take_newer(&mut self.symbol, &mut self.symbol_ms, o.symbol, o.symbol_ms);
        take_newer(&mut self.color, &mut self.color_ms, o.color, o.color_ms);
        take_newer(&mut self.budget, &mut self.budget_ms, o.budget, o.budget_ms);
        take_newer(&mut self.order, &mut self.order_ms, o.order, o.order_ms);
        merge_deletion(
            &mut self.deleted_ms,
            &mut self.merged_into,
            o.deleted_ms,
            o.merged_into,
        );
    }
}

fn load_categories(conn: &Connection, schema: &str) -> CoreResult<Vec<Cat>> {
    // includes soft-deleted rows
    let sql = format!(
        "SELECT c.id, c.uuid, c.name, p.uuid, c.sf_symbol, c.color_hex, c.budget_cents,
                c.sort_order, c.name_ms, c.parent_ms, c.symbol_ms, c.color_ms, c.budget_ms,
                c.order_ms, c.deleted_ms, c.merged_into
         FROM {schema}.categories c LEFT JOIN {schema}.categories p ON p.id = c.parent_id
         ORDER BY c.id"
    );
    let rows = conn
        .prepare(&sql)?
        .query_map([], |r| {
            Ok(Cat {
                id: r.get(0)?,
                uuid: r.get(1)?,
                name: r.get(2)?,
                parent: r.get(3)?,
                symbol: r.get(4)?,
                color: r.get(5)?,
                budget: r.get(6)?,
                order: r.get(7)?,
                name_ms: r.get(8)?,
                parent_ms: r.get(9)?,
                symbol_ms: r.get(10)?,
                color_ms: r.get(11)?,
                budget_ms: r.get(12)?,
                order_ms: r.get(13)?,
                deleted_ms: r.get(14)?,
                merged_into: r.get(15)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    Ok(rows)
}

/// uuid -> uuid of the category's current path (names from the root).
fn path_uuids(cats: &[Cat]) -> HashMap<String, String> {
    let by_uuid: HashMap<&str, &Cat> = cats.iter().map(|c| (c.uuid.as_str(), c)).collect();
    cats.iter()
        .map(|c| {
            let mut path = vec![c.name.as_str()];
            let mut cur = c.parent.as_deref();
            while let Some(p) = cur.and_then(|p| by_uuid.get(p)) {
                if path.len() > 64 {
                    break;
                }
                path.push(p.name.as_str());
                cur = p.parent.as_deref();
            }
            path.reverse();
            (c.uuid.clone(), category_uuid_for_path(&path))
        })
        .collect()
}

fn cat_survivor<'a>(state: &'a BTreeMap<String, Cat>, uuid: &'a str) -> Option<&'a str> {
    survivor(uuid, |u| {
        state
            .get(u)
            .map(|c| (c.deleted_ms.is_none(), c.merged_into.as_deref()))
    })
}

/// A parent that was combined into another moves its children to the
/// survivor; a live child of a deleted parent moves to the top level (a
/// deleted child keeps it). A cycle from crossing moves is cut at its oldest
/// move (smallest `parent_ms`, then uuid): that child goes to the top level.
/// Derived: no stamps.
fn resolve_parents(state: &mut BTreeMap<String, Cat>) {
    let all: Vec<String> = state.keys().cloned().collect();
    for u in &all {
        let c = &state[u];
        let parent = c
            .parent
            .as_deref()
            .and_then(|p| match cat_survivor(state, p) {
                Some(s) => Some(s),
                None if c.deleted_ms.is_some() => Some(p),
                None => None,
            })
            .filter(|p| *p != u.as_str())
            .map(str::to_string);
        state.get_mut(u).unwrap().parent = parent;
    }
    let live: Vec<String> = state
        .values()
        .filter(|c| c.deleted_ms.is_none())
        .map(|c| c.uuid.clone())
        .collect();
    loop {
        let mut cycle: Option<Vec<String>> = None;
        for u in &live {
            let mut seen = vec![u.clone()];
            let mut cur = state[u].parent.clone();
            while let Some(p) = cur {
                if p == *u {
                    cycle = Some(seen);
                    break;
                }
                if seen.len() > state.len() {
                    break;
                }
                cur = state.get(&p).and_then(|c| c.parent.clone());
                seen.push(p);
            }
            if cycle.is_some() {
                break;
            }
        }
        let Some(cycle) = cycle else { break };
        // the older move loses (ties: lower uuid); its stamp stays
        let oldest = cycle
            .iter()
            .min_by_key(|u| (state[*u].parent_ms, (*u).clone()))
            .unwrap()
            .clone();
        state.get_mut(&oldest).unwrap().parent = None;
    }
}

/// Live categories with the same parent and case-folded name are combined
/// into the lowest uuid. Returns whether anything was combined.
fn combine_categories(state: &mut BTreeMap<String, Cat>) -> bool {
    let mut groups: BTreeMap<(Option<String>, String), Vec<String>> = BTreeMap::new();
    for c in state.values().filter(|c| c.deleted_ms.is_none()) {
        groups
            .entry((c.parent.clone(), fold(&c.name)))
            .or_default()
            .push(c.uuid.clone());
    }
    let mut any = false;
    for uuids in groups.into_values().filter(|g| g.len() > 1) {
        // BTreeMap order: the first is the lowest uuid
        let keep = &uuids[0];
        let keep_ms = state[keep].name_ms;
        for u in &uuids[1..] {
            let c = state.get_mut(u).unwrap();
            c.deleted_ms = Some(c.name_ms.max(keep_ms).max(1));
            c.merged_into = Some(keep.clone());
            any = true;
        }
    }
    any
}

/// Merges `other.categories` into this vault: upsert by uuid, newest stamp per
/// field, deletions win, same-named live siblings combined. Returns other id
/// -> local id (combined rows map to their survivor; a deleted row without a
/// survivor maps to its own deleted local row).
///
/// `legacy`: the other vault had no uuids (v7); its rows were given path
/// uuids and are matched by their path against every local row, deleted ones
/// included, so they cannot revive anything.
pub(crate) fn merge_categories(
    conn: &Connection,
    legacy: bool,
    stats: &mut crate::vault::MergeStats,
) -> CoreResult<HashMap<i64, i64>> {
    fill_missing_uuids(conn)?;
    let local = load_categories(conn, "main")?;
    let other = load_categories(conn, "other")?;
    let original: HashMap<String, Cat> =
        local.iter().map(|c| (c.uuid.clone(), c.clone())).collect();
    let mut state: BTreeMap<String, Cat> =
        local.iter().map(|c| (c.uuid.clone(), c.clone())).collect();

    // v7 rows: other uuid -> the local uuid they stand for
    let mut alias: HashMap<String, String> = HashMap::new();
    if legacy {
        let mut by_path: HashMap<String, Vec<(&str, bool)>> = HashMap::new();
        for (u, p) in path_uuids(&local) {
            let live = original[&u].deleted_ms.is_none();
            let u = original.get_key_value(&u).unwrap().0.as_str();
            by_path.entry(p).or_default().push((u, live));
        }
        for (u, p) in path_uuids(&other) {
            if original.contains_key(&u) {
                continue;
            }
            if let Some(m) = by_path.get(&p).and_then(|c| pick_match(c)) {
                alias.insert(u, m.to_string());
            }
        }
    }
    let local_uuid = |u: Option<String>| u.map(|u| alias.get(&u).cloned().unwrap_or(u));

    for o in &other {
        let mut row = o.clone();
        row.parent = local_uuid(row.parent);
        row.merged_into = local_uuid(row.merged_into);
        match alias.get(&o.uuid) {
            Some(target) => {
                // merged into its match; the row itself stays as a tombstone
                let t = state.get_mut(target).unwrap();
                t.merge(Cat {
                    uuid: target.clone(),
                    ..row.clone()
                });
                let ms = t.name_ms;
                row.id = 0;
                row.deleted_ms = Some(ms.max(1));
                row.merged_into = Some(target.clone());
                state.insert(row.uuid.clone(), row);
            }
            None => match state.get_mut(&o.uuid) {
                Some(c) => c.merge(row),
                None => {
                    row.id = 0;
                    state.insert(row.uuid.clone(), row);
                }
            },
        }
    }
    loop {
        resolve_parents(&mut state);
        if !combine_categories(&mut state) {
            break;
        }
    }

    // write: new rows first (parked as deleted = -1, outside the unique name
    // index), then every changed row, then unpark the live ones at once
    let mut ids: HashMap<String, i64> = state.values().map(|c| (c.uuid.clone(), c.id)).collect();
    let changed: Vec<&Cat> = state
        .values()
        .filter(|c| original.get(&c.uuid) != Some(c))
        .collect();
    for c in &changed {
        if c.id == 0 {
            conn.execute(
                "INSERT INTO categories(uuid, name, deleted_ms) VALUES (?1, ?2, -1)",
                params![c.uuid, c.name],
            )?;
            ids.insert(c.uuid.clone(), conn.last_insert_rowid());
            if c.deleted_ms.is_none() {
                stats.categories_added += 1;
            }
        } else {
            conn.execute(
                "UPDATE categories SET deleted_ms = -1 WHERE id = ?1",
                [c.id],
            )?;
        }
    }
    for c in &changed {
        let parent = c.parent.as_ref().and_then(|p| ids.get(p));
        conn.execute(
            "UPDATE categories SET name = ?2, parent_id = ?3, sf_symbol = ?4, color_hex = ?5,
                    budget_cents = ?6, sort_order = ?7, name_ms = ?8, parent_ms = ?9,
                    symbol_ms = ?10, color_ms = ?11, budget_ms = ?12, order_ms = ?13,
                    deleted_ms = IFNULL(?14, -1), merged_into = ?15
             WHERE id = ?1",
            params![
                ids[&c.uuid],
                c.name,
                parent,
                c.symbol,
                c.color,
                c.budget,
                c.order,
                c.name_ms,
                c.parent_ms,
                c.symbol_ms,
                c.color_ms,
                c.budget_ms,
                c.order_ms,
                c.deleted_ms,
                c.merged_into
            ],
        )?;
    }
    conn.execute(
        "UPDATE categories SET deleted_ms = NULL WHERE deleted_ms = -1",
        [],
    )?;

    // whatever points at a deleted category follows its survivor or becomes
    // uncategorised (as a deletion does); derived, no stamps
    for c in state.values().filter(|c| c.deleted_ms.is_some()) {
        let id = ids[&c.uuid];
        match cat_survivor(&state, &c.uuid) {
            Some(s) => {
                let s = ids[s];
                conn.execute(
                    "UPDATE transactions SET category_id = ?2 WHERE category_id = ?1",
                    [id, s],
                )?;
                conn.execute(
                    "UPDATE transaction_splits SET category_id = ?2 WHERE category_id = ?1",
                    [id, s],
                )?;
                conn.execute(
                    "UPDATE rules SET category_id = ?2 WHERE category_id = ?1",
                    [id, s],
                )?;
            }
            None => {
                conn.execute(
                    "UPDATE transactions SET category_id = NULL, rule_id = NULL, category_source = 'none'
                     WHERE category_id = ?1",
                    [id],
                )?;
                conn.execute(
                    "UPDATE transaction_splits SET category_id = NULL WHERE category_id = ?1",
                    [id],
                )?;
            }
        }
    }

    Ok(other
        .iter()
        .map(|o| {
            let u = alias.get(&o.uuid).unwrap_or(&o.uuid);
            let target = cat_survivor(&state, u).unwrap_or(u.as_str());
            (o.id, ids[target])
        })
        .collect())
}

/// The part of a rule that is replaced as a whole; compared for tie-breaks.
#[derive(Clone, PartialEq, PartialOrd, Debug)]
struct RuleBody {
    category: String,
    field: String,
    kind: String,
    pattern: String,
    case_sensitive: bool,
    min: Option<i64>,
    max: Option<i64>,
    account: Option<String>,
    name: String,
    priority: i64,
    enabled: bool,
}

impl RuleBody {
    fn content_uuid(&self) -> String {
        rule_uuid_for_content(
            &self.field,
            &self.kind,
            &self.pattern,
            self.case_sensitive,
            self.min,
            self.max,
            self.account.as_deref(),
            &self.category,
        )
    }
}

#[derive(Clone, PartialEq, Debug)]
struct MRule {
    id: i64,
    uuid: String,
    body: RuleBody,
    category_id: i64,
    account_id: Option<i64>,
    updated_ms: i64,
    deleted_ms: Option<i64>,
    merged_into: Option<String>,
}

impl MRule {
    fn merge(&mut self, o: MRule) {
        if o.updated_ms > self.updated_ms || (o.updated_ms == self.updated_ms && o.body > self.body)
        {
            self.body = o.body;
            self.category_id = o.category_id;
            self.account_id = o.account_id;
            self.updated_ms = o.updated_ms;
        }
        merge_deletion(
            &mut self.deleted_ms,
            &mut self.merged_into,
            o.deleted_ms,
            o.merged_into,
        );
    }
}

type RawRule = (
    i64,
    String,
    String,
    i64,
    String,
    String,
    String,
    bool,
    Option<i64>,
    Option<i64>,
    Option<i64>,
    i64,
    bool,
    i64,
    Option<i64>,
    Option<String>,
);

fn load_rules(conn: &Connection, schema: &str) -> CoreResult<Vec<RawRule>> {
    // includes soft-deleted rows
    let sql = format!(
        "SELECT id, uuid, name, category_id, field, match_kind, pattern, case_sensitive,
                min_amount_cents, max_amount_cents, account_id, priority, enabled,
                updated_ms, deleted_ms, merged_into
         FROM {schema}.rules ORDER BY id"
    );
    let rows = conn
        .prepare(&sql)?
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
                r.get(9)?,
                r.get(10)?,
                r.get(11)?,
                r.get(12)?,
                r.get(13)?,
                r.get(14)?,
                r.get(15)?,
            ))
        })?
        .collect::<Result<_, _>>()?;
    Ok(rows)
}

/// Local categories: id -> (uuid, live, merged_into).
type CatInfo = HashMap<i64, (String, bool, Option<String>)>;

fn category_info(conn: &Connection) -> CoreResult<CatInfo> {
    // includes soft-deleted rows
    let rows = conn
        .prepare("SELECT id, uuid, deleted_ms IS NULL, merged_into FROM categories")?
        .query_map([], |r| Ok((r.get(0)?, (r.get(1)?, r.get(2)?, r.get(3)?))))?
        .collect::<Result<_, _>>()?;
    Ok(rows)
}

fn rule_survivor<'a>(state: &'a BTreeMap<String, MRule>, uuid: &'a str) -> Option<&'a str> {
    survivor(uuid, |u| {
        state
            .get(u)
            .map(|r| (r.deleted_ms.is_none(), r.merged_into.as_deref()))
    })
}

/// Merges `other.rules`: upsert by uuid, the newer `updated_ms` replaces the
/// whole rule, deletions win, rules of a deleted category are deleted with
/// it, identical live rules are combined into the lowest uuid. `cat_map` and
/// `acc_map` translate the other vault's ids. Returns other id -> local id
/// (combined rules map to their survivor).
pub(crate) fn merge_rules(
    conn: &Connection,
    cat_map: &HashMap<i64, i64>,
    acc_map: &HashMap<i64, i64>,
    legacy: bool,
    stats: &mut crate::vault::MergeStats,
) -> CoreResult<HashMap<i64, i64>> {
    let cats = category_info(conn)?;
    let cat_id_of: HashMap<&str, i64> = cats.iter().map(|(id, c)| (c.0.as_str(), *id)).collect();
    let mut keys: HashMap<i64, String> = HashMap::new();
    let mut key_of = |conn: &Connection, id: i64| -> CoreResult<String> {
        if let Some(k) = keys.get(&id) {
            return Ok(k.clone());
        }
        let k = account_key(conn, id)?;
        keys.insert(id, k.clone());
        Ok(k)
    };
    let mut build = |conn: &Connection,
                     raw: RawRule,
                     cat: i64,
                     acc: Option<i64>|
     -> CoreResult<MRule> {
        let (id, uuid, name, _, field, kind, pattern, cs, min, max, _, prio, en, upd, del, merged) =
            raw;
        let account = match acc {
            Some(a) => Some(key_of(conn, a)?),
            None => None,
        };
        Ok(MRule {
            id,
            uuid,
            body: RuleBody {
                category: cats.get(&cat).map(|c| c.0.clone()).unwrap_or_default(),
                field,
                kind,
                pattern,
                case_sensitive: cs,
                min,
                max,
                account,
                name,
                priority: prio,
                enabled: en,
            },
            category_id: cat,
            account_id: acc,
            updated_ms: upd,
            deleted_ms: del,
            merged_into: merged,
        })
    };

    let mut local = Vec::new();
    for raw in load_rules(conn, "main")? {
        let (cat, acc) = (raw.3, raw.10);
        local.push(build(conn, raw, cat, acc)?);
    }
    let mut other = Vec::new();
    for raw in load_rules(conn, "other")? {
        let Some(&cat) = cat_map.get(&raw.3) else {
            continue;
        };
        if raw.6.len() > crate::rules::MAX_PATTERN_LEN {
            continue;
        }
        let acc = raw.10.and_then(|a| acc_map.get(&a).copied());
        if raw.10.is_some() && acc.is_none() {
            continue;
        }
        other.push(build(conn, raw, cat, acc)?);
    }
    let original: HashMap<String, MRule> =
        local.iter().map(|r| (r.uuid.clone(), r.clone())).collect();
    let mut state: BTreeMap<String, MRule> =
        local.iter().map(|r| (r.uuid.clone(), r.clone())).collect();

    // v7 rows: matched by content against every local rule, deleted ones too
    let mut alias: HashMap<String, String> = HashMap::new();
    if legacy {
        let mut by_content: HashMap<String, Vec<(&str, bool)>> = HashMap::new();
        for r in &local {
            by_content
                .entry(r.body.content_uuid())
                .or_default()
                .push((r.uuid.as_str(), r.deleted_ms.is_none()));
        }
        for o in other.iter().filter(|o| !original.contains_key(&o.uuid)) {
            if let Some(m) = by_content
                .get(&o.body.content_uuid())
                .and_then(|c| pick_match(c))
            {
                alias.insert(o.uuid.clone(), m.to_string());
            }
        }
    }

    let mut other_ids = Vec::new();
    for mut row in other {
        other_ids.push((row.id, row.uuid.clone()));
        row.merged_into = row.merged_into.map(|u| alias.get(&u).cloned().unwrap_or(u));
        match alias.get(&row.uuid) {
            Some(target) => {
                let t = state.get_mut(target).unwrap();
                t.merge(MRule {
                    uuid: target.clone(),
                    ..row.clone()
                });
                let ms = t.updated_ms;
                row.id = 0;
                row.deleted_ms = Some(ms.max(1));
                row.merged_into = Some(target.clone());
                state.insert(row.uuid.clone(), row);
            }
            None => match state.get_mut(&row.uuid) {
                Some(r) => r.merge(row),
                None => {
                    row.id = 0;
                    state.insert(row.uuid.clone(), row);
                }
            },
        }
    }

    // a rule follows its category's survivor, or is deleted with it
    for r in state.values_mut() {
        let Some((_, false, _)) = cats.get(&r.category_id) else {
            continue;
        };
        let s = survivor(&r.body.category, |u| {
            cat_id_of
                .get(u)
                .and_then(|id| cats.get(id))
                .map(|c| (c.1, c.2.as_deref()))
        })
        .map(str::to_string);
        match s {
            Some(s) => {
                r.category_id = cat_id_of[s.as_str()];
                r.body.category = s;
            }
            None if r.deleted_ms.is_none() => {
                let del: Option<i64> = conn.query_row(
                    // includes soft-deleted rows
                    "SELECT deleted_ms FROM categories WHERE id = ?1",
                    [r.category_id],
                    |q| q.get(0),
                )?;
                r.deleted_ms = del;
            }
            None => {}
        }
    }

    // identical live rules are combined into the lowest uuid
    let mut groups: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for r in state.values().filter(|r| r.deleted_ms.is_none()) {
        groups
            .entry(r.body.content_uuid())
            .or_default()
            .push(r.uuid.clone());
    }
    for uuids in groups.into_values().filter(|g| g.len() > 1) {
        let keep = uuids[0].clone();
        let keep_ms = state[&keep].updated_ms;
        for u in &uuids[1..] {
            let r = state.get_mut(u).unwrap();
            r.deleted_ms = Some(r.updated_ms.max(keep_ms).max(1));
            r.merged_into = Some(keep.clone());
        }
    }

    let mut ids: HashMap<String, i64> = state.values().map(|r| (r.uuid.clone(), r.id)).collect();
    for r in state.values().filter(|r| original.get(&r.uuid) != Some(r)) {
        let b = &r.body;
        if r.id == 0 {
            conn.execute(
                "INSERT INTO rules(uuid, name, category_id, pattern) VALUES (?1, ?2, ?3, ?4)",
                params![r.uuid, b.name, r.category_id, b.pattern],
            )?;
            ids.insert(r.uuid.clone(), conn.last_insert_rowid());
            if r.deleted_ms.is_none() {
                stats.rules_added += 1;
            }
        }
        conn.execute(
            "UPDATE rules SET name = ?2, category_id = ?3, field = ?4, match_kind = ?5,
                    pattern = ?6, case_sensitive = ?7, min_amount_cents = ?8,
                    max_amount_cents = ?9, account_id = ?10, priority = ?11, enabled = ?12,
                    updated_ms = ?13, deleted_ms = ?14, merged_into = ?15
             WHERE id = ?1",
            params![
                ids[&r.uuid],
                b.name,
                r.category_id,
                b.field,
                b.kind,
                b.pattern,
                b.case_sensitive,
                b.min,
                b.max,
                r.account_id,
                b.priority,
                b.enabled,
                r.updated_ms,
                r.deleted_ms,
                r.merged_into
            ],
        )?;
    }

    // bookings follow a combined rule; a deleted rule's bookings are
    // uncategorised (as `delete_rule` does); derived, no stamps
    for r in state.values().filter(|r| r.deleted_ms.is_some()) {
        let id = ids[&r.uuid];
        match rule_survivor(&state, &r.uuid) {
            Some(s) => {
                conn.execute(
                    "UPDATE transactions SET rule_id = ?2 WHERE rule_id = ?1",
                    [id, ids[s]],
                )?;
            }
            None => {
                conn.execute(
                    "UPDATE transactions SET category_id = NULL, category_source = 'none', rule_id = NULL
                     WHERE rule_id = ?1",
                    [id],
                )?;
            }
        }
    }

    Ok(other_ids
        .iter()
        .map(|(oid, u)| {
            let u = alias.get(u).unwrap_or(u);
            let target = rule_survivor(&state, u).unwrap_or(u.as_str());
            (*oid, ids[target])
        })
        .collect())
}

/// Keeps the entries of an other-id -> local-id map whose local row is live.
pub(crate) fn live_targets(
    conn: &Connection,
    table: &str,
    map: &HashMap<i64, i64>,
) -> CoreResult<HashMap<i64, i64>> {
    // includes soft-deleted rows
    let deleted: HashSet<i64> = conn
        .prepare(&format!(
            "SELECT id FROM {table} WHERE deleted_ms IS NOT NULL"
        ))?
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    Ok(map
        .iter()
        .filter(|(_, l)| !deleted.contains(l))
        .map(|(o, l)| (*o, *l))
        .collect())
}

/// The synced state of a vault, one line per row, ordered by sync key and
/// including soft-deleted rows.
#[cfg(test)]
fn synced_state(v: &crate::vault::Vault) -> Vec<String> {
    use rusqlite::types::Value;
    let db = v.db().unwrap();
    // includes soft-deleted rows
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
