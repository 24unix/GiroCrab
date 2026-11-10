//! User-defined account groups: a tree of groups and accounts in the sidebar,
//! plus one built-in "Closed" group for accounts no longer in use.

use std::collections::HashMap;

use rusqlite::{Connection, OptionalExtension};

use crate::error::{CoreError, CoreResult};
use crate::i18n::display_name;
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
}
