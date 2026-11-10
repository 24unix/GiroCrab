//! User-defined account groups: a tree of groups and accounts in the sidebar,
//! plus one built-in "Closed" group for accounts no longer in use.

use rusqlite::{Connection, OptionalExtension};

use crate::error::CoreResult;

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
}
