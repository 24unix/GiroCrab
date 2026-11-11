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

const STAMP_COLS: [&str; 5] = [
    "category_ms",
    "note_ms",
    "checked_ms",
    "text_ms",
    "splits_ms",
];

fn stamps(v: &Vault) -> Vec<i64> {
    let db = v.db().unwrap();
    STAMP_COLS
        .iter()
        .map(|c| {
            db.query_row(
                &format!("SELECT {c} FROM transactions WHERE id = 1"),
                [],
                |r| r.get(0),
            )
            .unwrap()
        })
        .collect()
}

fn stamp_vault(tag: &str) -> Arc<Vault> {
    let v = open(&temp_dir(tag), "s.db");
    v.db()
        .unwrap()
        .execute_batch(
            "INSERT INTO account_groups(id, name) VALUES (1, 'G');
             INSERT INTO accounts(id, group_id, external_ref, name) VALUES (1, 1, 'DE1', 'A');
             INSERT INTO transactions(id, account_id, external_id, booking_date, amount_cents, counterparty)
                 VALUES (1, 1, 'e1', '2026-01-01', 5, 'Shop');",
        )
        .unwrap();
    v
}

#[test]
fn editing_a_booking_stamps_only_that_field() {
    let v = stamp_vault("stamp-fields");
    assert_eq!(stamps(&v), vec![0; 5]);
    let cat = v
        .create_category("Food".into(), None, String::new(), String::new())
        .unwrap();
    // (edit, index of the one stamp that must move)
    type Edit = Box<dyn Fn(&Vault)>;
    let edits: Vec<(usize, Edit)> = vec![
        (
            0,
            Box::new(move |v| v.set_transaction_category(1, Some(cat)).unwrap()),
        ),
        (
            1,
            Box::new(|v| v.update_transaction_note(1, "n".into()).unwrap()),
        ),
        (2, Box::new(|v| v.set_transaction_checked(1, true).unwrap())),
        (
            3,
            Box::new(|v| {
                v.update_transaction_text(1, "X".into(), "Y".into())
                    .unwrap()
            }),
        ),
        (
            4,
            Box::new(move |v| {
                v.set_transaction_splits(
                    1,
                    vec![
                        crate::models::TransactionSplitInput {
                            category_id: Some(cat),
                            amount_cents: 3,
                            note: String::new(),
                        },
                        crate::models::TransactionSplitInput {
                            category_id: None,
                            amount_cents: 2,
                            note: String::new(),
                        },
                    ],
                )
                .unwrap()
            }),
        ),
    ];
    for (idx, edit) in edits {
        let before = stamps(&v);
        edit(&v);
        let after = stamps(&v);
        for i in 0..5 {
            if i == idx {
                assert!(
                    after[i] > 0 && after[i] >= before[i],
                    "{} not stamped",
                    STAMP_COLS[i]
                );
            } else {
                assert_eq!(after[i], before[i], "{} must not move", STAMP_COLS[i]);
            }
        }
    }
}

#[test]
fn rule_assignment_does_not_stamp() {
    let v = stamp_vault("stamp-rule");
    let cat = v
        .create_category("Food".into(), None, String::new(), String::new())
        .unwrap();
    v.save_rule(crate::models::Rule {
        id: 0,
        name: "shop".into(),
        category_id: cat,
        field: crate::models::RuleField::Counterparty,
        match_kind: crate::models::MatchKind::Keyword,
        pattern: "Shop".into(),
        case_sensitive: false,
        min_amount_cents: None,
        max_amount_cents: None,
        account_id: None,
        priority: 0,
        enabled: true,
        match_count: 0,
    })
    .unwrap();
    v.apply_rules(false).unwrap();
    let src: String = v
        .db()
        .unwrap()
        .query_row(
            "SELECT category_source FROM transactions WHERE id = 1",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(src, "rule");
    assert_eq!(stamps(&v), vec![0; 5]);
}

#[test]
fn manual_clear_stamps_and_lets_rules_refill() {
    let v = stamp_vault("stamp-clear");
    let cat = v
        .create_category("Food".into(), None, String::new(), String::new())
        .unwrap();
    v.save_rule(crate::models::Rule {
        id: 0,
        name: "shop".into(),
        category_id: cat,
        field: crate::models::RuleField::Counterparty,
        match_kind: crate::models::MatchKind::Keyword,
        pattern: "Shop".into(),
        case_sensitive: false,
        min_amount_cents: None,
        max_amount_cents: None,
        account_id: None,
        priority: 0,
        enabled: true,
        match_count: 0,
    })
    .unwrap();
    v.set_transaction_category(1, None).unwrap();
    let ms = stamps(&v)[0];
    assert!(ms > 0);
    let row = |v: &Vault| -> (Option<i64>, String) {
        v.db()
            .unwrap()
            .query_row(
                "SELECT category_id, category_source FROM transactions WHERE id = 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap()
    };
    assert_eq!(row(&v), (None, "none".to_string()));
    v.apply_rules(true).unwrap();
    assert_eq!(row(&v), (Some(cat), "rule".to_string()));
    assert_eq!(stamps(&v)[0], ms);
}
