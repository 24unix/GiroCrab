//! User-defined account groups: a tree of groups and accounts in the sidebar,
//! plus one built-in "Closed" group for accounts no longer in use.

use std::collections::HashMap;

use rusqlite::{Connection, OptionalExtension};

use crate::error::{CoreError, CoreResult};
use crate::i18n::{display_name, tr, trf};
use crate::models::{Account, AccountGroup, SidebarNode};
use crate::vault::Vault;

/// Stored (German) name of the built-in Closed group; shown via `display_name`.
pub(crate) const CLOSED_GROUP: &str = "Geschlossen";

/// Id of the built-in Closed group, created at the top level if missing. A
/// user group already named like it at the top level becomes the Closed group.
pub(crate) fn closed_group_id(conn: &Connection) -> CoreResult<i64> {
    if let Some(id) = conn
        .query_row(
            "SELECT id FROM account_groups WHERE role = 'closed'",
            [],
            |r| r.get(0),
        )
        .optional()?
    {
        return Ok(id);
    }
    let n = conn.execute(
        "UPDATE account_groups SET role = 'closed' WHERE parent_id IS NULL AND name = ?1",
        [CLOSED_GROUP],
    )?;
    if n == 0 {
        conn.execute(
            "INSERT INTO account_groups(name, sf_symbol, sort_order, role) VALUES (?1, 'archivebox', 1000, 'closed')",
            [CLOSED_GROUP],
        )?;
    }
    conn.query_row(
        "SELECT id FROM account_groups WHERE role = 'closed'",
        [],
        |r| r.get(0),
    )
    .map_err(Into::into)
}

/// Deeper nesting is cut off; guards against a parent cycle in a damaged file.
const MAX_DEPTH: u32 = 32;

struct GroupRow {
    id: i64,
    parent_id: Option<i64>,
    name: String,
    sf_symbol: String,
    sort_order: i32,
    closed: bool,
    connection_id: Option<i64>,
}

enum Child {
    Group(usize),
    Account(usize),
}

#[uniffi::export]
impl Vault {
    /// The sidebar in display order: each group before its children, siblings
    /// by `sort_order` (groups before accounts on a tie), the Closed group last.
    pub fn list_sidebar(&self) -> Result<Vec<SidebarNode>, CoreError> {
        let accounts = self.list_accounts()?;
        let groups: Vec<GroupRow> = {
            let db = self.db()?;
            let mut st = db.prepare(
                "SELECT id, parent_id, name, sf_symbol, sort_order, role = 'closed', connection_id FROM account_groups",
            )?;
            let rows = st.query_map([], |r| {
                Ok(GroupRow {
                    id: r.get(0)?,
                    parent_id: r.get(1)?,
                    name: r.get(2)?,
                    sf_symbol: r.get(3)?,
                    sort_order: r.get(4)?,
                    closed: r.get(5)?,
                    connection_id: r.get(6)?,
                })
            })?;
            rows.collect::<Result<_, _>>()?
        };
        let index: HashMap<i64, usize> =
            groups.iter().enumerate().map(|(i, g)| (g.id, i)).collect();
        // A missing parent (damaged file) puts the child at the top level.
        let parent = |p: Option<i64>| p.filter(|id| index.contains_key(id));
        let mut children: HashMap<Option<i64>, Vec<Child>> = HashMap::new();
        for (i, g) in groups.iter().enumerate() {
            children
                .entry(parent(g.parent_id))
                .or_default()
                .push(Child::Group(i));
        }
        for (i, a) in accounts.iter().enumerate() {
            children
                .entry(parent(a.group_id))
                .or_default()
                .push(Child::Account(i));
        }
        let key = |c: &Child| match c {
            Child::Group(i) => (groups[*i].closed, groups[*i].sort_order, 0, groups[*i].id),
            Child::Account(i) => (false, accounts[*i].sort_order, 1, accounts[*i].id),
        };
        for list in children.values_mut() {
            list.sort_by_key(key);
        }

        let mut out = Vec::new();
        walk(&groups, &accounts, &children, None, 0, &mut out);
        Ok(out)
    }
}

/// Appends the children of `parent` in pre-order and returns the EUR total
/// and the ids of all accounts below it.
fn walk(
    groups: &[GroupRow],
    accounts: &[Account],
    children: &HashMap<Option<i64>, Vec<Child>>,
    parent: Option<i64>,
    depth: u32,
    out: &mut Vec<SidebarNode>,
) -> (i64, Vec<i64>) {
    let (mut total, mut ids) = (0, Vec::new());
    if depth > MAX_DEPTH {
        return (total, ids);
    }
    for child in children.get(&parent).map(Vec::as_slice).unwrap_or_default() {
        match child {
            Child::Account(i) => {
                let a = &accounts[*i];
                if a.currency == "EUR" {
                    total += a.balance_cents;
                }
                ids.push(a.id);
                out.push(SidebarNode::Account {
                    account: a.clone(),
                    depth,
                });
            }
            Child::Group(i) => {
                let g = &groups[*i];
                let at = out.len();
                out.push(SidebarNode::Group {
                    group: AccountGroup {
                        id: g.id,
                        parent_id: g.parent_id,
                        name: display_name(&g.name),
                        sf_symbol: g.sf_symbol.clone(),
                        sort_order: g.sort_order,
                        depth,
                        is_closed_group: g.closed,
                        connection_id: g.connection_id,
                        balance_cents: 0,
                        account_ids: vec![],
                    },
                });
                let (sum, below) = walk(groups, accounts, children, Some(g.id), depth + 1, out);
                if let SidebarNode::Group { group } = &mut out[at] {
                    group.balance_cents = sum;
                    group.account_ids = below.clone();
                }
                total += sum;
                ids.extend(below);
            }
        }
    }
    (total, ids)
}
// ---------------------------------------------------------------- mutations

/// A group or an account among the children of one parent.
#[derive(Clone, Copy, PartialEq)]
enum Item {
    Group(i64),
    Account(i64),
}

/// Children of `parent` in sidebar order, without the Closed group (which is
/// always shown last and never renumbered).
fn siblings(conn: &Connection, parent: Option<i64>) -> CoreResult<Vec<Item>> {
    let mut st = conn.prepare(
        "SELECT 0, id, sort_order FROM account_groups WHERE parent_id IS ?1 AND role != 'closed'
         UNION ALL SELECT 1, id, sort_order FROM accounts WHERE group_id IS ?1
         ORDER BY 3, 1, 2",
    )?;
    let rows = st.query_map([parent], |r| {
        let id = r.get(1)?;
        Ok(if r.get::<_, i64>(0)? == 0 {
            Item::Group(id)
        } else {
            Item::Account(id)
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// Puts `items` under `parent` and numbers them 0..n.
fn write_order(conn: &Connection, parent: Option<i64>, items: &[Item]) -> CoreResult<()> {
    for (i, item) in items.iter().enumerate() {
        match item {
            Item::Group(id) => conn.execute(
                "UPDATE account_groups SET parent_id = ?1, sort_order = ?2 WHERE id = ?3",
                rusqlite::params![parent, i as i64, id],
            )?,
            Item::Account(id) => conn.execute(
                "UPDATE accounts SET group_id = ?1, sort_order = ?2 WHERE id = ?3",
                rusqlite::params![parent, i as i64, id],
            )?,
        };
    }
    Ok(())
}

/// Removes `item` from its current parent and inserts it under `parent` at
/// `index` (clamped to the end).
fn place(
    conn: &Connection,
    item: Item,
    from: Option<i64>,
    parent: Option<i64>,
    index: u32,
) -> CoreResult<()> {
    let mut old = siblings(conn, from)?;
    old.retain(|i| *i != item);
    write_order(conn, from, &old)?;
    let mut new = siblings(conn, parent)?;
    new.retain(|i| *i != item);
    new.insert((index as usize).min(new.len()), item);
    write_order(conn, parent, &new)
}

fn invalid(message: String) -> CoreError {
    CoreError::InvalidInput { message }
}

fn not_found(what: String) -> CoreError {
    CoreError::NotFound { what }
}

/// Parent and role of a group.
fn group_info(conn: &Connection, id: i64) -> CoreResult<(Option<i64>, bool)> {
    conn.query_row(
        "SELECT parent_id, role = 'closed' FROM account_groups WHERE id = ?1",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()?
    .ok_or_else(|| not_found(trf("Kontogruppe {0}", &[&id])))
}

/// `group` and its ancestors, nearest first.
fn ancestors(conn: &Connection, group: i64) -> CoreResult<Vec<i64>> {
    let mut out = vec![group];
    let mut cur = group;
    while let (Some(p), _) = group_info(conn, cur)? {
        if out.len() as u32 > MAX_DEPTH || out.contains(&p) {
            break;
        }
        out.push(p);
        cur = p;
    }
    Ok(out)
}

fn in_closed(conn: &Connection, group: i64) -> CoreResult<bool> {
    let closed = closed_group_id(conn)?;
    Ok(ancestors(conn, group)?.contains(&closed))
}

fn checked_name(name: &str) -> CoreResult<String> {
    let name = name.trim();
    if name.is_empty() {
        return Err(invalid(tr("Der Gruppenname darf nicht leer sein.").into()));
    }
    Ok(name.to_string())
}

/// Fails if `parent` already has a group called `name` (other than `except`).
fn check_free(
    conn: &Connection,
    parent: Option<i64>,
    name: &str,
    except: Option<i64>,
) -> CoreResult<()> {
    let taken: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM account_groups WHERE parent_id IS ?1 AND name = ?2 AND id IS NOT ?3)",
        rusqlite::params![parent, name, except],
        |r| r.get(0),
    )?;
    if taken {
        return Err(invalid(trf(
            "Eine Gruppe „{0}“ gibt es hier schon.",
            &[&name],
        )));
    }
    Ok(())
}

fn account_group(conn: &Connection, account: i64) -> CoreResult<Option<i64>> {
    conn.query_row(
        "SELECT group_id FROM accounts WHERE id = ?1",
        [account],
        |r| r.get(0),
    )
    .optional()?
    .ok_or_else(|| not_found(trf("Konto {0}", &[&account])))
}

#[uniffi::export]
impl Vault {
    /// New group as the last child of `parent_id` (None = top level).
    pub fn create_account_group(
        &self,
        name: String,
        parent_id: Option<i64>,
    ) -> Result<i64, CoreError> {
        let name = checked_name(&name)?;
        let db = self.db()?;
        let tx = db.unchecked_transaction()?;
        if let Some(p) = parent_id {
            if in_closed(&tx, p)? {
                return Err(invalid(
                    tr("Im Ordner „Geschlossen“ können keine Gruppen angelegt werden.").into(),
                ));
            }
        }
        check_free(&tx, parent_id, &name, None)?;
        tx.execute(
            "INSERT INTO account_groups(parent_id, name) VALUES (?1, ?2)",
            rusqlite::params![parent_id, name],
        )?;
        let id = tx.last_insert_rowid();
        place(&tx, Item::Group(id), parent_id, parent_id, u32::MAX)?;
        tx.commit()?;
        Ok(id)
    }

    pub fn rename_account_group(&self, id: i64, name: String) -> Result<(), CoreError> {
        let name = checked_name(&name)?;
        let db = self.db()?;
        let (parent, _) = group_info(&db, id)?;
        check_free(&db, parent, &name, Some(id))?;
        db.execute(
            "UPDATE account_groups SET name = ?1 WHERE id = ?2",
            rusqlite::params![name, id],
        )?;
        Ok(())
    }

    /// Deletes a group; its groups and accounts take its place in the parent.
    /// A child group whose name is taken there gets " 2", " 3", … appended.
    pub fn delete_account_group(&self, id: i64) -> Result<(), CoreError> {
        let db = self.db()?;
        let tx = db.unchecked_transaction()?;
        let (parent, closed) = group_info(&tx, id)?;
        if closed {
            return Err(invalid(
                tr("Die Gruppe „Geschlossen“ kann nicht gelöscht oder verschoben werden.").into(),
            ));
        }
        let inner = siblings(&tx, Some(id))?;
        for item in &inner {
            if let Item::Group(g) = item {
                let name: String =
                    tx.query_row("SELECT name FROM account_groups WHERE id = ?1", [g], |r| {
                        r.get(0)
                    })?;
                let mut candidate = name.clone();
                let mut n = 2;
                while check_free(&tx, parent, &candidate, Some(*g)).is_err() {
                    candidate = format!("{name} {n}");
                    n += 1;
                }
                // Detach first so the new name can't clash inside the old parent.
                tx.execute(
                    "UPDATE account_groups SET parent_id = ?1, name = ?2 WHERE id = ?3",
                    rusqlite::params![parent, candidate, g],
                )?;
            }
        }
        let mut order = siblings(&tx, parent)?;
        order.retain(|i| !inner.contains(i));
        let at = order
            .iter()
            .position(|i| *i == Item::Group(id))
            .unwrap_or(order.len());
        order.splice(
            at..=at.min(order.len().saturating_sub(1)),
            inner.iter().copied(),
        );
        write_order(&tx, parent, &order)?;
        tx.execute("DELETE FROM account_groups WHERE id = ?1", [id])?;
        tx.commit()?;
        Ok(())
    }

    /// Moves an account under `parent_id` (None = top level) at position
    /// `index` among its new siblings. Bank link, balance and bookings stay.
    pub fn move_account(
        &self,
        account_id: i64,
        parent_id: Option<i64>,
        index: u32,
    ) -> Result<(), CoreError> {
        let db = self.db()?;
        let tx = db.unchecked_transaction()?;
        let from = account_group(&tx, account_id)?;
        if let Some(p) = parent_id {
            group_info(&tx, p)?;
        }
        place(&tx, Item::Account(account_id), from, parent_id, index)?;
        tx.commit()?;
        Ok(())
    }

    /// Moves a group (with everything in it). Not into itself or a descendant;
    /// the Closed group stays where it is.
    pub fn move_account_group(
        &self,
        group_id: i64,
        parent_id: Option<i64>,
        index: u32,
    ) -> Result<(), CoreError> {
        let db = self.db()?;
        let tx = db.unchecked_transaction()?;
        let (from, closed) = group_info(&tx, group_id)?;
        if closed {
            return Err(invalid(
                tr("Die Gruppe „Geschlossen“ kann nicht gelöscht oder verschoben werden.").into(),
            ));
        }
        if let Some(p) = parent_id {
            if ancestors(&tx, p)?.contains(&group_id) {
                return Err(invalid(
                    tr("Eine Gruppe kann nicht in sich selbst verschoben werden.").into(),
                ));
            }
        }
        if from != parent_id {
            let name: String = tx.query_row(
                "SELECT name FROM account_groups WHERE id = ?1",
                [group_id],
                |r| r.get(0),
            )?;
            check_free(&tx, parent_id, &name, Some(group_id))?;
        }
        place(&tx, Item::Group(group_id), from, parent_id, index)?;
        tx.commit()?;
        Ok(())
    }

    /// Moves an account to the end of the Closed group.
    pub fn close_account(&self, account_id: i64) -> Result<(), CoreError> {
        let closed = {
            let db = self.db()?;
            closed_group_id(&db)?
        };
        self.move_account(account_id, Some(closed), u32::MAX)
    }

    /// Moves a closed account back: into its bank login's group if there is
    /// one, else to the top level.
    pub fn reopen_account(&self, account_id: i64) -> Result<(), CoreError> {
        let target = {
            let db = self.db()?;
            let linked: Vec<i64> = {
                let mut st = db.prepare(
                    "SELECT g.id FROM account_groups g JOIN accounts a ON a.connection_id = g.connection_id
                     WHERE a.id = ?1 ORDER BY g.id",
                )?;
                let rows = st.query_map([account_id], |r| r.get(0))?;
                rows.collect::<Result<_, _>>()?
            };
            let mut target = None;
            for g in linked {
                if !in_closed(&db, g)? {
                    target = Some(g);
                    break;
                }
            }
            target
        };
        self.move_account(account_id, target, u32::MAX)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vault::Vault;
    use std::sync::Arc;

    pub(crate) fn temp_vault() -> (Arc<Vault>, String) {
        let p = std::env::temp_dir().join(format!("girocrab-groups-{}.db", uuid::Uuid::new_v4()));
        let p = p.to_string_lossy().to_string();
        (Vault::open(p.clone(), vec![7u8; 32]).unwrap(), p)
    }

    /// Turns a fresh vault back into the v6 layout: flat, globally unique
    /// group names, `accounts.group_id NOT NULL`, no Closed group.
    fn downgrade_to_v6(v: &Vault) {
        let db = v.db().unwrap();
        db.execute_batch(
            "PRAGMA foreign_keys = OFF;
             BEGIN;
             DROP TABLE accounts;
             DROP TABLE account_groups;
             CREATE TABLE account_groups (
                 id          INTEGER PRIMARY KEY,
                 name        TEXT    NOT NULL UNIQUE,
                 sf_symbol   TEXT    NOT NULL DEFAULT 'folder',
                 sort_order  INTEGER NOT NULL DEFAULT 0
             );
             CREATE TABLE accounts (
                 id              INTEGER PRIMARY KEY,
                 connection_id   INTEGER REFERENCES bank_connections(id) ON DELETE SET NULL,
                 group_id        INTEGER NOT NULL REFERENCES account_groups(id),
                 external_ref    TEXT    NOT NULL DEFAULT '',
                 name            TEXT    NOT NULL,
                 bank_name       TEXT    NOT NULL DEFAULT '',
                 owner           TEXT    NOT NULL DEFAULT '',
                 iban            TEXT    NOT NULL DEFAULT '',
                 account_number  TEXT    NOT NULL DEFAULT '',
                 currency        TEXT    NOT NULL DEFAULT 'EUR',
                 kind            TEXT    NOT NULL DEFAULT 'checking',
                 balance_cents   INTEGER NOT NULL DEFAULT 0,
                 balance_date    TEXT    NOT NULL DEFAULT '',
                 sf_symbol       TEXT    NOT NULL DEFAULT 'building.columns',
                 sort_order      INTEGER NOT NULL DEFAULT 0,
                 initial_balance_cents INTEGER,
                 UNIQUE (connection_id, external_ref)
             );
             COMMIT;
             PRAGMA foreign_keys = ON;
             PRAGMA user_version = 6;",
        )
        .unwrap();
    }

    fn count(v: &Vault, sql: &str) -> i64 {
        v.db().unwrap().query_row(sql, [], |r| r.get(0)).unwrap()
    }

    #[test]
    fn migrates_v6_vault_without_losing_rows() {
        let (v, path) = temp_vault();
        downgrade_to_v6(&v);
        {
            let db = v.db().unwrap();
            db.execute_batch(
                "INSERT INTO bank_connections(id, connector, display_name) VALUES (1, 'comdirect', 'comdirect');
                 INSERT INTO account_groups(id, name, sf_symbol, sort_order) VALUES
                     (1, 'Giro & Tagesgeld', 'building.columns', 1), (2, 'Kreditkarten', 'creditcard', 2);
                 INSERT INTO accounts(id, connection_id, group_id, external_ref, name) VALUES
                     (1, 1, 1, 'DE1', 'Giro'), (2, 1, 2, 'card', 'Visa'), (3, NULL, 1, 'cash', 'Bargeld');
                 INSERT INTO transactions(account_id, external_id, booking_date, amount_cents) VALUES
                     (1, 'a', '2026-01-01', -100), (1, 'b', '2026-01-02', -200), (2, 'c', '2026-01-03', -300),
                     (3, 'd', '2026-01-04', -400), (3, 'e', '2026-01-05', -500);",
            )
            .unwrap();
        }
        drop(v);
        let v = Vault::open(path, vec![7u8; 32]).unwrap();

        assert_eq!(count(&v, "PRAGMA user_version"), 7);
        assert_eq!(count(&v, "SELECT count(*) FROM accounts"), 3);
        assert_eq!(count(&v, "SELECT count(*) FROM transactions"), 5);
        assert_eq!(
            count(&v, "SELECT count(*) FROM accounts WHERE (id, group_id) IN (VALUES (1, 1), (2, 2), (3, 1))"),
            3
        );
        assert_eq!(
            count(
                &v,
                "SELECT count(*) FROM account_groups WHERE parent_id IS NULL AND
                    ((id = 1 AND name = 'Giro & Tagesgeld' AND sort_order = 1) OR (id = 2 AND name = 'Kreditkarten' AND sort_order = 2))"
            ),
            2
        );
        assert_eq!(
            count(
                &v,
                "SELECT count(*) FROM account_groups WHERE role = 'closed'"
            ),
            1
        );
        assert_eq!(
            count(&v, "SELECT count(*) FROM pragma_foreign_key_check"),
            0
        );
        let dup = v.db().unwrap().execute(
            "INSERT INTO accounts(connection_id, group_id, external_ref, name) VALUES (1, 1, 'DE1', 'Dup')",
            [],
        );
        assert!(
            dup.is_err(),
            "UNIQUE (connection_id, external_ref) survives the rebuild"
        );
    }

    #[test]
    fn fresh_vault_has_closed_group_and_allows_top_level_accounts() {
        let (v, _) = temp_vault();
        assert_eq!(
            count(
                &v,
                "SELECT count(*) FROM account_groups WHERE role = 'closed'"
            ),
            1
        );
        let id = closed_group_id(&v.db().unwrap()).unwrap();
        assert_eq!(
            count(&v, &format!("SELECT count(*) FROM account_groups WHERE id = {id} AND name = '{CLOSED_GROUP}' AND parent_id IS NULL")),
            1
        );
        v.db()
            .unwrap()
            .execute(
                "INSERT INTO accounts(group_id, name) VALUES (NULL, 'X')",
                [],
            )
            .unwrap();
    }

    #[test]
    fn sibling_group_names_are_unique_per_parent() {
        let (v, _) = temp_vault();
        let db = v.db().unwrap();
        db.execute_batch(
            "INSERT INTO account_groups(id, name) VALUES (10, 'A'), (11, 'B');
             INSERT INTO account_groups(parent_id, name) VALUES (10, 'X'), (11, 'X');",
        )
        .unwrap();
        assert!(db
            .execute(
                "INSERT INTO account_groups(parent_id, name) VALUES (10, 'X')",
                []
            )
            .is_err());
        assert!(db
            .execute(
                "INSERT INTO account_groups(parent_id, name) VALUES (NULL, 'A')",
                []
            )
            .is_err());
    }

    /// Inserts an EUR account; `group` None = top level.
    pub(crate) fn add_account(
        v: &Vault,
        name: &str,
        group: Option<i64>,
        sort: i32,
        cents: i64,
        currency: &str,
    ) -> i64 {
        let db = v.db().unwrap();
        db.execute(
            "INSERT INTO accounts(group_id, external_ref, name, currency, balance_cents, sort_order) VALUES (?1, ?2, ?2, ?3, ?4, ?5)",
            rusqlite::params![group, name, currency, cents, sort],
        )
        .unwrap();
        db.last_insert_rowid()
    }

    pub(crate) fn add_group(v: &Vault, name: &str, parent: Option<i64>, sort: i32) -> i64 {
        let db = v.db().unwrap();
        db.execute(
            "INSERT INTO account_groups(parent_id, name, sort_order) VALUES (?1, ?2, ?3)",
            rusqlite::params![parent, name, sort],
        )
        .unwrap();
        db.last_insert_rowid()
    }

    /// Sidebar as (label, depth): groups as "G:<name>", accounts by name.
    pub(crate) fn outline(v: &Vault) -> Vec<(String, u32)> {
        v.list_sidebar()
            .unwrap()
            .into_iter()
            .map(|n| match n {
                SidebarNode::Group { group } => (format!("G:{}", group.name), group.depth),
                SidebarNode::Account { account, depth } => (account.name, depth),
            })
            .collect()
    }

    fn group<'a>(nodes: &'a [SidebarNode], name: &str) -> &'a AccountGroup {
        nodes
            .iter()
            .find_map(|n| match n {
                SidebarNode::Group { group } if group.name == name => Some(group),
                _ => None,
            })
            .unwrap()
    }

    #[test]
    fn list_sidebar_is_preorder_with_depths() {
        let (v, _) = temp_vault();
        let a = add_group(&v, "A", None, 1);
        add_account(&v, "x", None, 2, 0, "EUR");
        add_account(&v, "a1", Some(a), 0, 0, "EUR");
        let b = add_group(&v, "B", Some(a), 1);
        add_account(&v, "b1", Some(b), 0, 0, "EUR");
        let s = |l: &str, d: u32| (l.to_string(), d);
        assert_eq!(
            outline(&v),
            vec![
                s("G:A", 0),
                s("a1", 1),
                s("G:B", 1),
                s("b1", 2),
                s("x", 0),
                s("G:Geschlossen", 0)
            ]
        );
    }

    #[test]
    fn group_totals_are_recursive_and_eur_only() {
        let (v, _) = temp_vault();
        let a = add_group(&v, "A", None, 0);
        let a1 = add_account(&v, "a1", Some(a), 0, 10_000, "EUR");
        let b = add_group(&v, "B", Some(a), 1);
        let b1 = add_account(&v, "b1", Some(b), 0, 5_000, "EUR");
        let u1 = add_account(&v, "u1", Some(b), 1, 99_900, "USD");
        let nodes = v.list_sidebar().unwrap();
        assert_eq!(group(&nodes, "A").balance_cents, 15_000);
        assert_eq!(group(&nodes, "B").balance_cents, 5_000);
        let mut ids = group(&nodes, "A").account_ids.clone();
        ids.sort();
        assert_eq!(ids, vec![a1, b1, u1]);
    }

    #[test]
    fn closed_accounts_are_flagged_and_excluded_from_default_history() {
        let (v, _) = temp_vault();
        let closed = closed_group_id(&v.db().unwrap()).unwrap();
        let sub = add_group(&v, "Alt", Some(closed), 0);
        add_account(&v, "open", None, 0, 10_000, "EUR");
        let gone = add_account(&v, "gone", Some(sub), 0, 70_000, "EUR");
        let accounts = v.list_accounts().unwrap();
        assert!(accounts.iter().find(|a| a.id == gone).unwrap().closed);
        assert!(!accounts.iter().find(|a| a.name == "open").unwrap().closed);
        let history = v.balance_history(vec![], 3).unwrap();
        assert_eq!(history.last().unwrap().balance_cents, 10_000);
    }

    fn labels(v: &Vault) -> Vec<String> {
        outline(v).into_iter().map(|(l, _)| l).collect()
    }

    fn invalid<T: std::fmt::Debug>(r: Result<T, CoreError>) -> bool {
        matches!(r, Err(CoreError::InvalidInput { .. }))
    }

    #[test]
    fn create_rejects_empty_and_duplicate_names() {
        let (v, _) = temp_vault();
        let a = v.create_account_group("A".into(), None).unwrap();
        assert!(invalid(v.create_account_group("  ".into(), None)));
        assert!(invalid(v.create_account_group("A".into(), None)));
        assert!(invalid(v.create_account_group(" A ".into(), None)));
        v.create_account_group("A".into(), Some(a)).unwrap();
        let closed = closed_group_id(&v.db().unwrap()).unwrap();
        assert!(invalid(v.create_account_group("Alt".into(), Some(closed))));
        assert!(invalid(v.rename_account_group(a, "".into())));
        v.rename_account_group(a, "Bank".into()).unwrap();
        assert_eq!(labels(&v), vec!["G:Bank", "G:A", "G:Geschlossen"]);
    }

    #[test]
    fn new_groups_go_last_among_siblings() {
        let (v, _) = temp_vault();
        add_account(&v, "x", None, 5, 0, "EUR");
        v.create_account_group("N".into(), None).unwrap();
        assert_eq!(labels(&v), vec!["x", "G:N", "G:Geschlossen"]);
    }

    #[test]
    fn delete_moves_contents_up_in_place() {
        let (v, _) = temp_vault();
        add_group(&v, "A", None, 0);
        let g = add_group(&v, "G", None, 1);
        add_account(&v, "Z", None, 2, 0, "EUR");
        add_account(&v, "g1", Some(g), 0, 0, "EUR");
        let h = add_group(&v, "H", Some(g), 1);
        add_account(&v, "h1", Some(h), 0, 0, "EUR");
        v.db()
            .unwrap()
            .execute("INSERT INTO transactions(account_id, external_id, booking_date, amount_cents) SELECT id, 't', '2026-01-01', 1 FROM accounts", [])
            .unwrap();
        v.delete_account_group(g).unwrap();
        assert_eq!(
            labels(&v),
            vec!["G:A", "g1", "G:H", "h1", "Z", "G:Geschlossen"]
        );
        assert_eq!(count(&v, "SELECT count(*) FROM accounts"), 3);
        assert_eq!(count(&v, "SELECT count(*) FROM transactions"), 3);
    }

    #[test]
    fn delete_renames_on_clash() {
        let (v, _) = temp_vault();
        add_group(&v, "A", None, 0);
        let g = add_group(&v, "G", None, 1);
        add_group(&v, "A", Some(g), 0);
        v.delete_account_group(g).unwrap();
        assert_eq!(labels(&v), vec!["G:A", "G:A 2", "G:Geschlossen"]);
    }

    #[test]
    fn move_group_into_descendant_is_rejected() {
        let (v, _) = temp_vault();
        let a = add_group(&v, "A", None, 0);
        let b = add_group(&v, "B", Some(a), 0);
        let before = outline(&v);
        assert!(invalid(v.move_account_group(a, Some(b), 0)));
        assert!(invalid(v.move_account_group(a, Some(a), 0)));
        assert_eq!(outline(&v), before);
        v.move_account_group(b, None, 0).unwrap();
        assert_eq!(labels(&v), vec!["G:B", "G:A", "G:Geschlossen"]);
    }

    #[test]
    fn move_account_reorders_and_keeps_bank_link() {
        let (v, _) = temp_vault();
        let g = add_group(&v, "G", None, 0);
        add_account(&v, "g1", Some(g), 0, 0, "EUR");
        add_account(&v, "g2", Some(g), 1, 0, "EUR");
        let x = {
            let db = v.db().unwrap();
            db.execute_batch(
                "INSERT INTO bank_connections(id, connector, display_name) VALUES (1, 'comdirect', 'comdirect');
                 INSERT INTO accounts(connection_id, group_id, external_ref, name, balance_cents, sort_order)
                     VALUES (1, NULL, 'DE1', 'x', 4242, 1);",
            )
            .unwrap();
            db.last_insert_rowid()
        };
        v.move_account(x, Some(g), 1).unwrap();
        assert_eq!(labels(&v), vec!["G:G", "g1", "x", "g2", "G:Geschlossen"]);
        assert_eq!(
            count(&v, &format!("SELECT count(*) FROM accounts WHERE id = {x} AND connection_id = 1 AND external_ref = 'DE1' AND balance_cents = 4242")),
            1
        );
        v.move_account(x, None, 99).unwrap();
        assert_eq!(labels(&v), vec!["G:G", "g1", "g2", "x", "G:Geschlossen"]);
    }

    #[test]
    fn closed_group_cannot_be_deleted_or_moved() {
        let (v, _) = temp_vault();
        let a = add_group(&v, "A", None, 0);
        let closed = closed_group_id(&v.db().unwrap()).unwrap();
        assert!(invalid(v.delete_account_group(closed)));
        assert!(invalid(v.move_account_group(closed, Some(a), 0)));
        // Other groups may be moved into it.
        v.move_account_group(a, Some(closed), 0).unwrap();
    }

    #[test]
    fn close_then_reopen_returns_to_bank_group_or_top_level() {
        let (v, _) = temp_vault();
        let bank = {
            let db = v.db().unwrap();
            db.execute_batch(
                "INSERT INTO bank_connections(id, connector, display_name) VALUES (1, 'comdirect', 'comdirect');
                 INSERT INTO account_groups(name, connection_id) VALUES ('comdirect', 1);",
            )
            .unwrap();
            db.last_insert_rowid()
        };
        let linked = {
            let db = v.db().unwrap();
            db.execute(
                "INSERT INTO accounts(connection_id, group_id, external_ref, name) VALUES (1, ?1, 'DE1', 'Giro')",
                [bank],
            )
            .unwrap();
            db.last_insert_rowid()
        };
        let loose = add_account(&v, "Bar", None, 0, 0, "EUR");
        v.close_account(linked).unwrap();
        v.close_account(loose).unwrap();
        assert_eq!(
            labels(&v),
            vec!["G:comdirect", "G:Geschlossen", "Giro", "Bar"]
        );
        assert!(v.list_accounts().unwrap().iter().all(|a| a.closed));
        v.reopen_account(linked).unwrap();
        v.reopen_account(loose).unwrap();
        assert_eq!(
            labels(&v),
            vec!["G:comdirect", "Giro", "Bar", "G:Geschlossen"]
        );
    }
}
