use std::sync::Arc;

use rusqlite::{params, Connection};

use super::*;
use crate::vault::Vault;

fn temp_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "gc-sync-{tag}-{}-{}",
        std::process::id(),
        Uuid::new_v4()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn open(dir: &std::path::Path, file: &str) -> Arc<Vault> {
    Vault::open(dir.join(file).to_string_lossy().into(), vec![7u8; 32]).unwrap()
}

fn uuids(v: &Vault, sql: &str) -> Vec<String> {
    let db = v.db().unwrap();
    let mut st = db.prepare(sql).unwrap();
    st.query_map([], |r| r.get::<_, String>(0))
        .unwrap()
        .map(|r| r.unwrap())
        .collect()
}

#[test]
fn migration_is_idempotent() {
    let dir = temp_dir("idem");
    let v = open(&dir, "a.db");
    v.seed_starter_categories().unwrap();
    let before = uuids(&v, "SELECT uuid FROM categories ORDER BY id");
    {
        let db = v.db().unwrap();
        migrate(&db).unwrap();
        migrate(&db).unwrap();
    }
    assert_eq!(before, uuids(&v, "SELECT uuid FROM categories ORDER BY id"));
    drop(v);
    let v = open(&dir, "a.db");
    assert_eq!(before, uuids(&v, "SELECT uuid FROM categories ORDER BY id"));
}

#[test]
fn same_category_path_gets_same_uuid_on_two_vaults() {
    let dir = temp_dir("path");
    let (a, b) = (open(&dir, "a.db"), open(&dir, "b.db"));
    a.seed_starter_categories().unwrap();
    b.seed_starter_categories().unwrap();
    let sql = "SELECT c.uuid FROM categories c ORDER BY c.name, c.id";
    let ua = uuids(&a, sql);
    assert!(!ua.is_empty());
    assert_eq!(ua, uuids(&b, sql));
    let distinct: std::collections::HashSet<_> = ua.iter().collect();
    assert_eq!(distinct.len(), ua.len());
    assert_eq!(
        category_uuid_for_path(&[" Lebensmittel ", "SUPERMARKT"]),
        category_uuid_for_path(&["lebensmittel", "supermarkt"])
    );
    assert_ne!(
        category_uuid_for_path(&["a", "b"]),
        category_uuid_for_path(&["a b"])
    );
}

#[test]
fn rule_uuid_depends_on_content_only() {
    let u = |p: &str, cs: bool, acc: Option<&str>| {
        rule_uuid_for_content("any", "keyword", p, cs, Some(1), None, acc, "cat")
    };
    assert_eq!(u("x", false, None), u("x", false, None));
    assert_ne!(u("x", false, None), u("y", false, None));
    assert_ne!(u("x", false, None), u("x", true, None));
    assert_ne!(u("x", false, None), u("x", false, Some("k|1")));
    assert_ne!(
        rule_uuid_for_content("any", "keyword", "x", false, Some(1), None, None, "c1"),
        rule_uuid_for_content("any", "keyword", "x", false, Some(1), None, None, "c2")
    );
}

#[test]
fn v7_vault_upgrades_and_keeps_rows() {
    let dir = temp_dir("v7");
    let path = dir.join("old.db").to_string_lossy().to_string();
    {
        let conn = Connection::open(&path).unwrap();
        Vault::apply_key(&conn, &[7u8; 32]).unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        conn.execute_batch(crate::vault::SCHEMA).unwrap();
        crate::user_groups::migrate(&conn).unwrap();
        conn.execute_batch(
            "INSERT INTO account_groups(id, name) VALUES (1, 'G');
             INSERT INTO accounts(id, group_id, external_ref, name) VALUES (1, 1, 'DE1', 'Giro');
             INSERT INTO categories(id, name) VALUES (1, 'Food');
             INSERT INTO rules(name, category_id, pattern) VALUES ('r', 1, 'lidl');
             INSERT INTO transactions(account_id, external_id, booking_date, amount_cents)
                 VALUES (1, 'e1', '2026-01-01', -100);
             PRAGMA user_version = 7;",
        )
        .unwrap();
    }
    let v = Vault::open(path, vec![7u8; 32]).unwrap();
    let db = v.db().unwrap();
    let version: i64 = db
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    assert_eq!(version, 8);
    let n = |sql: &str| db.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap();
    assert_eq!(
        n("SELECT count(*) FROM categories WHERE uuid IS NOT NULL"),
        1
    );
    assert_eq!(n("SELECT count(*) FROM rules WHERE uuid IS NOT NULL"), 1);
    assert_eq!(
        n("SELECT count(*) FROM transactions WHERE deleted_ms IS NULL"),
        1
    );
    assert_eq!(n("SELECT count(*) FROM accounts"), 1);
}

#[test]
fn sync_keys_are_stable() {
    let dir = temp_dir("keys");
    let (a, b) = (open(&dir, "a.db"), open(&dir, "b.db"));
    let seed = |v: &Vault, pad: i64| {
        let db = v.db().unwrap();
        db.execute_batch("INSERT INTO account_groups(id, name) VALUES (1, 'G');")
            .unwrap();
        for i in 0..pad {
            db.execute(
                "INSERT INTO bank_connections(connector, display_name, login_name) VALUES ('paypal', 'x', ?1)",
                [format!("pad{i}")],
            )
            .unwrap();
        }
        db.execute(
            "INSERT INTO bank_connections(connector, display_name, login_name, bank_code)
             VALUES ('traderepublic', 'TR', '+49 151 234567', '')",
            [],
        )
        .unwrap();
        let c = db.last_insert_rowid();
        db.execute(
            "INSERT INTO accounts(connection_id, group_id, external_ref, name) VALUES (?1, 1, 'DE9', 'A')",
            [c],
        )
        .unwrap();
        let acc = db.last_insert_rowid();
        db.execute(
            "INSERT INTO accounts(group_id, external_ref, name) VALUES (1, 'loose', 'L')",
            [],
        )
        .unwrap();
        let loose = db.last_insert_rowid();
        db.execute(
            "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents) VALUES (?1, 'e1', '2026-01-01', 5)",
            params![acc],
        )
        .unwrap();
        let t = db.last_insert_rowid();
        (
            connection_key(&db, c).unwrap(),
            account_key(&db, acc).unwrap(),
            account_key(&db, loose).unwrap(),
            booking_key(&db, t).unwrap(),
        )
    };
    let ka = seed(&a, 0);
    let kb = seed(&b, 3);
    assert_eq!(ka, kb);
    assert_eq!(ka.2, "|loose");
    assert!(ka.3.ends_with("|DE9|e1"));
    assert!(ka.0.starts_with("traderepublic|+"));
    // identical content converges even with different local ids
    let (c, d) = (open(&dir, "c.db"), open(&dir, "d.db"));
    seed(&c, 0);
    seed(&d, 0);
    assert_converged(&c, &d);
    assert_ne!(synced_state(&a), synced_state(&b));
}

#[test]
fn deleted_category_name_can_be_reused() {
    let dir = temp_dir("reuse");
    let v = open(&dir, "a.db");
    let db = v.db().unwrap();
    db.execute("INSERT INTO categories(name) VALUES ('Food')", [])
        .unwrap();
    assert!(db
        .execute("INSERT INTO categories(name) VALUES ('Food')", [])
        .is_err());
    db.execute(
        "UPDATE categories SET deleted_ms = 1 WHERE name = 'Food'",
        [],
    )
    .unwrap();
    db.execute("INSERT INTO categories(name) VALUES ('Food')", [])
        .unwrap();
    fill_missing_uuids(&db).unwrap();
    let u: Vec<String> = db
        .prepare("SELECT uuid FROM categories ORDER BY id")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    assert_eq!(u.len(), 2);
    // the deleted row keeps the path uuid, the new one gets a random one
    assert_eq!(u[0], category_uuid_for_path(&["Food"]));
    assert_ne!(u[0], u[1]);
}

/// Two vaults built the same way, with a category, a booking and its stamps.
fn identical_pair(dir: &std::path::Path) -> (Arc<Vault>, Arc<Vault>) {
    let pair = (open(dir, "p1.db"), open(dir, "p2.db"));
    for v in [&pair.0, &pair.1] {
        let db = v.db().unwrap();
        db.execute_batch(
            "INSERT INTO account_groups(id, name) VALUES (1, 'G');
             INSERT INTO accounts(id, group_id, external_ref, name) VALUES (1, 1, 'DE1', 'A');
             INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, note_ms)
                 VALUES (1, 'e1', '2026-01-01', 5, 10);
             INSERT INTO categories(name) VALUES ('Food');",
        )
        .unwrap();
        fill_missing_uuids(&db).unwrap();
    }
    pair
}

#[test]
fn assert_converged_accepts_identical_vaults() {
    let dir = temp_dir("conv-ok");
    let (a, b) = identical_pair(&dir);
    assert_converged(&a, &b);
}

#[test]
fn assert_converged_panics_on_one_differing_stamp() {
    let dir = temp_dir("conv-stamp");
    let (a, b) = identical_pair(&dir);
    b.db()
        .unwrap()
        .execute("UPDATE transactions SET note_ms = 11", [])
        .unwrap();
    assert!(std::panic::catch_unwind(|| assert_converged(&a, &b)).is_err());
}

#[test]
fn assert_converged_panics_on_one_differing_deletion() {
    let dir = temp_dir("conv-del");
    let (a, b) = identical_pair(&dir);
    b.db()
        .unwrap()
        .execute("UPDATE categories SET deleted_ms = 5", [])
        .unwrap();
    assert!(std::panic::catch_unwind(|| assert_converged(&a, &b)).is_err());
}
