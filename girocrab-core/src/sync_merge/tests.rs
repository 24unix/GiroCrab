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

fn cat_stamps(v: &Vault, id: i64) -> Vec<i64> {
    let db = v.db().unwrap();
    db.query_row(
        "SELECT name_ms, parent_ms, symbol_ms, color_ms, budget_ms, order_ms FROM categories WHERE id = ?1",
        [id],
        |r| (0..6).map(|i| r.get(i)).collect::<Result<Vec<i64>, _>>(),
    )
    .unwrap()
}

fn plain_rule(category_id: i64, pattern: &str) -> crate::models::Rule {
    crate::models::Rule {
        id: 0,
        name: "r".into(),
        category_id,
        field: crate::models::RuleField::Any,
        match_kind: crate::models::MatchKind::Keyword,
        pattern: pattern.into(),
        case_sensitive: false,
        min_amount_cents: None,
        max_amount_cents: None,
        account_id: None,
        priority: 10,
        enabled: true,
        match_count: 0,
    }
}

#[test]
fn rename_stamps_name_only() {
    let v = open(&temp_dir("rename"), "a.db");
    let id = v
        .create_category("Food".into(), None, "tag".into(), "#111111".into())
        .unwrap();
    // seeded stamps are 0 for a category without user edits
    v.db().unwrap().execute("UPDATE categories SET name_ms=0, parent_ms=0, symbol_ms=0, color_ms=0, budget_ms=0, order_ms=0", []).unwrap();
    v.update_category(id, "Essen".into(), None, "tag".into(), "#111111".into())
        .unwrap();
    let s = cat_stamps(&v, id);
    assert!(s[0] > 0, "{s:?}");
    assert_eq!(&s[1..], &[0, 0, 0, 0, 0]);
    // unchanged save stamps nothing more
    let before = s[0];
    v.update_category(id, "Essen".into(), None, "tag".into(), "#111111".into())
        .unwrap();
    assert_eq!(cat_stamps(&v, id)[0], before);
    // colour change stamps colour only
    v.update_category(id, "Essen".into(), None, "tag".into(), "#222222".into())
        .unwrap();
    let s = cat_stamps(&v, id);
    assert!(s[3] > 0);
    assert_eq!((s[1], s[2], s[4], s[5]), (0, 0, 0, 0));
}

#[test]
fn budget_stamps_budget_only() {
    let v = open(&temp_dir("budget"), "a.db");
    let id = v
        .create_category("Food".into(), None, "tag".into(), "#111111".into())
        .unwrap();
    v.db().unwrap().execute("UPDATE categories SET name_ms=0, parent_ms=0, symbol_ms=0, color_ms=0, budget_ms=0, order_ms=0", []).unwrap();
    v.set_category_budget(id, Some(5000)).unwrap();
    let s = cat_stamps(&v, id);
    assert!(s[4] > 0, "{s:?}");
    assert_eq!((s[0], s[1], s[2], s[3], s[5]), (0, 0, 0, 0, 0));
    // clearing is an edit too
    v.db()
        .unwrap()
        .execute("UPDATE categories SET budget_ms = 1", [])
        .unwrap();
    v.set_category_budget(id, None).unwrap();
    assert!(cat_stamps(&v, id)[4] > 1);
}

#[test]
fn deleting_a_category_soft_deletes_it_its_children_and_rules() {
    let v = open(&temp_dir("catdel"), "a.db");
    let parent = v
        .create_category("Home".into(), None, "tag".into(), "#111111".into())
        .unwrap();
    let child = v
        .create_category("Power".into(), Some(parent), "tag".into(), "#111111".into())
        .unwrap();
    let other = v
        .create_category("Other".into(), None, "tag".into(), "#111111".into())
        .unwrap();
    let rule = v.save_rule(plain_rule(child, "stadtwerke")).unwrap();
    let keep_rule = v.save_rule(plain_rule(other, "lidl")).unwrap();
    {
        let db = v.db().unwrap();
        db.execute_batch(
            "INSERT INTO account_groups(id, name) VALUES (1, 'G');
             INSERT INTO accounts(id, group_id, external_ref, name) VALUES (1, 1, 'DE1', 'A');",
        )
        .unwrap();
        for (i, c) in [("e1", child), ("e2", other)] {
            db.execute(
                "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, category_id, category_source, category_ms)
                 VALUES (1, ?1, '2026-01-01', -5, ?2, 'manual', 77)",
                params![i, c],
            )
            .unwrap();
        }
        db.execute(
            "INSERT INTO transaction_splits(id, transaction_id, category_id, amount_cents) VALUES (1, 2, ?1, -3)",
            [child],
        )
        .unwrap();
        db.execute(
            "INSERT INTO transaction_splits(id, transaction_id, category_id, amount_cents) VALUES (2, 2, ?1, -2)",
            [other],
        )
        .unwrap();
    }
    v.delete_category(parent).unwrap();
    let db = v.db().unwrap();
    let del = |t: &str, id: i64| -> Option<i64> {
        db.query_row(
            &format!("SELECT deleted_ms FROM {t} WHERE id = ?1"),
            [id],
            |r| r.get(0),
        )
        .unwrap()
    };
    assert!(del("categories", parent).unwrap() > 0);
    assert!(del("categories", child).unwrap() > 0);
    assert!(del("categories", other).is_none());
    assert!(del("rules", rule).unwrap() > 0);
    assert!(del("rules", keep_rule).is_none());
    let (cat, src, ms): (Option<i64>, String, i64) = db
        .query_row("SELECT category_id, category_source, category_ms FROM transactions WHERE external_id='e1'", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap();
    assert_eq!((cat, src.as_str(), ms), (None, "none", 77));
    let (cat, src): (Option<i64>, String) = db
        .query_row(
            "SELECT category_id, category_source FROM transactions WHERE external_id='e2'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!((cat, src.as_str()), (Some(other), "manual"));
    let split_cat = |id: i64| -> Option<i64> {
        db.query_row(
            "SELECT category_id FROM transaction_splits WHERE id = ?1",
            [id],
            |r| r.get(0),
        )
        .unwrap()
    };
    // the split row stays, uncategorised; the unrelated split is untouched
    assert_eq!(split_cat(1), None);
    assert_eq!(split_cat(2), Some(other));
    drop(db);
    let ids: Vec<i64> = v
        .list_categories(None, None)
        .unwrap()
        .iter()
        .map(|c| c.id)
        .collect();
    assert_eq!(ids, vec![other]);
    let rules: Vec<i64> = v.list_rules().unwrap().iter().map(|r| r.id).collect();
    assert_eq!(rules, vec![keep_rule]);
}

#[test]
fn save_rule_stamps_and_keeps_uuid_on_edit() {
    let v = open(&temp_dir("rule"), "a.db");
    let cat = v
        .create_category("Food".into(), None, "tag".into(), "#111111".into())
        .unwrap();
    let id = v.save_rule(plain_rule(cat, "lidl")).unwrap();
    let get = |v: &Vault| -> (String, i64) {
        v.db()
            .unwrap()
            .query_row(
                "SELECT uuid, updated_ms FROM rules WHERE id = ?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap()
    };
    let (uuid, ms) = get(&v);
    assert!(ms > 0);
    v.db()
        .unwrap()
        .execute("UPDATE rules SET updated_ms = 1", [])
        .unwrap();
    let mut r = plain_rule(cat, "lidl");
    r.id = id;
    r.pattern = "edeka".into();
    v.save_rule(r).unwrap();
    let (uuid2, ms2) = get(&v);
    assert_eq!(uuid, uuid2);
    assert!(ms2 > 1);
    // same content as a deleted rule: random uuid, content uuid stays taken
    v.delete_rule(id).unwrap();
    let (_, del_ms): (String, i64) = v
        .db()
        .unwrap()
        .query_row(
            "SELECT uuid, deleted_ms FROM rules WHERE id = ?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert!(del_ms > 0);
    assert!(v.list_rules().unwrap().is_empty());
    let id2 = v.save_rule(plain_rule(cat, "lidl")).unwrap();
    let u2: String = v
        .db()
        .unwrap()
        .query_row("SELECT uuid FROM rules WHERE id = ?1", [id2], |r| r.get(0))
        .unwrap();
    assert_ne!(u2, uuid);
}

fn n(v: &Vault, sql: &str) -> i64 {
    v.db()
        .unwrap()
        .query_row(sql, [], |r| r.get::<_, i64>(0))
        .unwrap()
}

/// One connection `c` with two accounts and one booking each, plus an unrelated
/// loose account with a booking. Returns (connection, account 1, account 2, loose).
fn bank_fixture(v: &Vault) -> (i64, i64, i64, i64) {
    let db = v.db().unwrap();
    db.execute_batch("INSERT INTO account_groups(id, name) VALUES (1, 'G');")
        .unwrap();
    db.execute(
        "INSERT INTO bank_connections(connector, display_name, login_name, bank_code)
         VALUES ('fints:12345678', 'Bank', 'me', '12345678')",
        [],
    )
    .unwrap();
    let c = db.last_insert_rowid();
    let mut ids = Vec::new();
    for (conn, ext) in [(Some(c), "A1"), (Some(c), "A2"), (None, "loose")] {
        db.execute(
            "INSERT INTO accounts(connection_id, group_id, external_ref, name) VALUES (?1, 1, ?2, ?2)",
            params![conn, ext],
        )
        .unwrap();
        let a = db.last_insert_rowid();
        db.execute(
            "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents)
             VALUES (?1, 'e1', '2026-01-01', -5)",
            [a],
        )
        .unwrap();
        ids.push(a);
    }
    (c, ids[0], ids[1], ids[2])
}

#[test]
fn deleting_connection_soft_deletes_it_accounts_and_bookings() {
    let v = open(&temp_dir("conndel"), "a.db");
    let (c, a1, _, loose) = bank_fixture(&v);
    v.delete_bank_connection(c).unwrap();
    assert_eq!(n(&v, "SELECT count(*) FROM bank_connections"), 1);
    assert_eq!(
        n(
            &v,
            "SELECT count(*) FROM bank_connections WHERE deleted_ms > 0"
        ),
        1
    );
    assert_eq!(n(&v, "SELECT count(*) FROM accounts"), 3);
    assert_eq!(
        n(&v, "SELECT count(*) FROM accounts WHERE deleted_ms > 0"),
        2
    );
    assert_eq!(n(&v, "SELECT count(*) FROM transactions"), 3);
    assert_eq!(
        n(&v, "SELECT count(*) FROM transactions WHERE deleted_ms > 0"),
        2
    );
    assert_eq!(
        n(
            &v,
            &format!("SELECT count(*) FROM transactions WHERE account_id = {loose} AND deleted_ms IS NULL")
        ),
        1
    );
    // the accounts keep their connection, so their sync keys stay stable
    assert_eq!(
        n(
            &v,
            &format!("SELECT connection_id FROM accounts WHERE id = {a1}")
        ),
        c
    );
}

#[test]
fn deleting_account_soft_deletes_it_and_its_bookings() {
    let v = open(&temp_dir("accdel"), "a.db");
    let (c, a1, a2, _) = bank_fixture(&v);
    v.set_account_archived(a1, true).unwrap();
    v.delete_account(a1).unwrap();
    assert_eq!(n(&v, "SELECT count(*) FROM accounts"), 3);
    assert_eq!(
        n(
            &v,
            &format!(
                "SELECT count(*) FROM transactions WHERE account_id = {a1} AND deleted_ms > 0"
            )
        ),
        1
    );
    assert_eq!(
        n(
            &v,
            "SELECT count(*) FROM bank_connections WHERE deleted_ms IS NULL"
        ),
        1
    );
    // the last account of a connection takes the connection along
    v.set_account_archived(a2, true).unwrap();
    v.delete_account(a2).unwrap();
    assert_eq!(
        n(
            &v,
            &format!("SELECT deleted_ms > 0 FROM bank_connections WHERE id = {c}")
        ),
        1
    );
}

#[test]
fn readding_connection_revives_it_with_new_created_ms() {
    let v = open(&temp_dir("revive"), "a.db");
    let id = v
        .add_bank_connection(ConnectorKind::Comdirect, String::new(), "Login".into())
        .unwrap();
    assert!(n(&v, "SELECT created_ms FROM bank_connections") > 1);
    v.db()
        .unwrap()
        .execute("UPDATE bank_connections SET created_ms = 1", [])
        .unwrap();
    v.delete_bank_connection(id).unwrap();
    let again = v
        .add_bank_connection(ConnectorKind::Comdirect, String::new(), "login".into())
        .unwrap();
    assert_eq!(again, id);
    assert_eq!(n(&v, "SELECT count(*) FROM bank_connections"), 1);
    assert_eq!(
        n(
            &v,
            "SELECT count(*) FROM bank_connections WHERE deleted_ms IS NULL"
        ),
        1
    );
    assert!(n(&v, "SELECT created_ms FROM bank_connections") > 1);
}

fn remote_account(ext: &str) -> crate::connectors::RemoteAccount {
    crate::connectors::RemoteAccount {
        external_ref: ext.into(),
        name: "Giro".into(),
        owner: String::new(),
        iban: String::new(),
        account_number: String::new(),
        currency: "EUR".into(),
        kind: crate::models::AccountKind::Checking,
        balance_cents: 0,
        balance_date: "2026-11-10".into(),
    }
}

fn remote_tx(ext: &str, id: &str) -> crate::connectors::RemoteTransaction {
    crate::connectors::RemoteTransaction {
        account_ref: ext.into(),
        external_id: id.into(),
        booking_date: "2026-11-10".into(),
        value_date: "2026-11-10".into(),
        amount_cents: -500,
        currency: "EUR".into(),
        counterparty: "Shop".into(),
        purpose: "Kauf".into(),
        ..Default::default()
    }
}

#[test]
fn fetch_does_not_resurrect_deleted_booking() {
    let v = open(&temp_dir("noresurrect"), "a.db");
    let c = v
        .add_bank_connection(ConnectorKind::Comdirect, String::new(), "login".into())
        .unwrap();
    let fetch = |ids: &[&str]| crate::connectors::FetchResult {
        accounts: vec![remote_account("DE1")],
        transactions: ids.iter().map(|i| remote_tx("DE1", i)).collect(),
        adjust_balances: true,
        ..Default::default()
    };
    crate::connectors::store_fetch(&v, ConnectorKind::Comdirect, c, fetch(&["b1", "b2"])).unwrap();
    assert_eq!(n(&v, "SELECT created_ms > 1 FROM accounts"), 1);
    v.db()
        .unwrap()
        .execute(
            "UPDATE transactions SET deleted_ms = 5 WHERE external_id = 'b1'",
            [],
        )
        .unwrap();
    let before = n(&v, "SELECT balance_cents FROM accounts");
    let s = crate::connectors::store_fetch(&v, ConnectorKind::Comdirect, c, fetch(&["b1", "b2"]))
        .unwrap();
    assert_eq!(s.transactions_imported, 0);
    assert_eq!(n(&v, "SELECT count(*) FROM transactions"), 2);
    assert_eq!(
        n(
            &v,
            "SELECT deleted_ms FROM transactions WHERE external_id = 'b1'"
        ),
        5
    );
    assert_eq!(n(&v, "SELECT balance_cents FROM accounts"), before);
}

#[test]
fn fetch_revives_a_deleted_account_it_delivers() {
    let v = open(&temp_dir("accrevive"), "a.db");
    let c = v
        .add_bank_connection(ConnectorKind::Comdirect, String::new(), "login".into())
        .unwrap();
    let fetch = || crate::connectors::FetchResult {
        accounts: vec![remote_account("DE1")],
        ..Default::default()
    };
    crate::connectors::store_fetch(&v, ConnectorKind::Comdirect, c, fetch()).unwrap();
    v.db()
        .unwrap()
        .execute("UPDATE accounts SET created_ms = 1, deleted_ms = 2", [])
        .unwrap();
    crate::connectors::store_fetch(&v, ConnectorKind::Comdirect, c, fetch()).unwrap();
    assert_eq!(n(&v, "SELECT count(*) FROM accounts"), 1);
    assert_eq!(
        n(&v, "SELECT count(*) FROM accounts WHERE deleted_ms IS NULL"),
        1
    );
    assert!(n(&v, "SELECT created_ms FROM accounts") > 2);
}

#[test]
fn pending_booking_removed_by_fetch_is_soft_deleted() {
    let v = open(&temp_dir("pending"), "a.db");
    let c = v
        .add_bank_connection(ConnectorKind::Comdirect, String::new(), "login".into())
        .unwrap();
    let fetch = |txs: Vec<crate::connectors::RemoteTransaction>| crate::connectors::FetchResult {
        accounts: vec![remote_account("DE1")],
        transactions: txs,
        hold_prefix: Some("hold-".into()),
        ..Default::default()
    };
    crate::connectors::store_fetch(
        &v,
        ConnectorKind::Comdirect,
        c,
        fetch(vec![remote_tx("DE1", "hold-1")]),
    )
    .unwrap();
    // an optimistic transfer booking older than 14 days
    v.db()
        .unwrap()
        .execute(
            "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, imported_unix)
             VALUES ((SELECT id FROM accounts), 'pending-e2e', '2026-01-01', -9, 1)",
            [],
        )
        .unwrap();
    crate::connectors::store_fetch(&v, ConnectorKind::Comdirect, c, fetch(vec![])).unwrap();
    assert_eq!(n(&v, "SELECT count(*) FROM transactions"), 2);
    assert_eq!(
        n(&v, "SELECT count(*) FROM transactions WHERE deleted_ms > 0"),
        2
    );
}

#[test]
fn twin_merge_soft_deletes_the_bank_copy() {
    let v = open(&temp_dir("twin"), "a.db");
    let csv = "Datum;Name;Verwendungszweck;Betrag;Kategorie;Notiz\n10.05.2026;REWE Markt;Einkauf;-12,50;;\n";
    let acc = v
        .import_moneymoney_data(csv.as_bytes().to_vec(), "t.csv".into(), None, true, true)
        .unwrap()
        .account_id;
    let db = v.db().unwrap();
    db.execute(
        "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, counterparty, purpose)
         VALUES (?1, 'f1', '2026-05-10', -1250, 'REWE', 'Einkauf')",
        [acc],
    )
    .unwrap();
    let bank_id = db.last_insert_rowid();
    assert!(crate::connectors::moneymoney_import::merge_synced_twin(
        &db,
        acc,
        "f1",
        "2026-05-10",
        -1250,
        "",
        "REWE",
        "Einkauf"
    )
    .unwrap());
    let deleted: Option<i64> = db
        .query_row(
            "SELECT deleted_ms FROM transactions WHERE id = ?1",
            [bank_id],
            |r| r.get(0),
        )
        .unwrap();
    assert!(deleted.unwrap() > 0);
    // the import row carries the bank's id and stays live
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM transactions WHERE external_id = 'f1' AND deleted_ms IS NULL",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        1
    );
}

#[test]
fn revive_brings_back_cascade_bookings_but_not_individually_deleted_ones() {
    let v = open(&temp_dir("cascade"), "a.db");
    let c = v
        .add_bank_connection(ConnectorKind::Comdirect, String::new(), "login".into())
        .unwrap();
    let fetch = || crate::connectors::FetchResult {
        accounts: vec![remote_account("DE1")],
        transactions: ["b1", "b2", "b3"]
            .iter()
            .map(|i| remote_tx("DE1", i))
            .collect(),
        ..Default::default()
    };
    crate::connectors::store_fetch(&v, ConnectorKind::Comdirect, c, fetch()).unwrap();
    let live = |v: &Vault| {
        let mut ids = uuids(
            v,
            "SELECT external_id FROM transactions WHERE deleted_ms IS NULL ORDER BY 1",
        );
        ids.sort();
        ids
    };
    v.db()
        .unwrap()
        .execute(
            "UPDATE transactions SET deleted_ms = 5 WHERE external_id = 'b1'",
            [],
        )
        .unwrap();
    // connection delete + re-add + fetch
    v.delete_bank_connection(c).unwrap();
    assert!(live(&v).is_empty());
    let again = v
        .add_bank_connection(ConnectorKind::Comdirect, String::new(), "login".into())
        .unwrap();
    assert_eq!(again, c);
    assert!(live(&v).is_empty(), "bookings wait for the account");
    crate::connectors::store_fetch(&v, ConnectorKind::Comdirect, c, fetch()).unwrap();
    assert_eq!(live(&v), vec!["b2", "b3"]);
    // account delete + fetch
    let acc = n(&v, "SELECT id FROM accounts");
    v.set_account_archived(acc, true).unwrap();
    v.delete_account(acc).unwrap();
    assert!(live(&v).is_empty());
    crate::connectors::store_fetch(&v, ConnectorKind::Comdirect, c, fetch()).unwrap();
    assert_eq!(live(&v), vec!["b2", "b3"]);
    assert_eq!(
        n(
            &v,
            "SELECT deleted_ms FROM transactions WHERE external_id = 'b1'"
        ),
        5
    );
}

/// The demo vault plus what the demo lacks (bookings on the Tagesgeld,
/// a holding, splits, documents, budgets, an IBAN for transfer suggestions),
/// before anything is deleted.
fn soft_delete_world(v: &Vault) {
    v.seed_demo_data().unwrap();
    let db = v.db().unwrap();
    let id = |sql: &str| -> i64 { db.query_row(sql, [], |r| r.get(0)).unwrap() };
    let tagesgeld = id("SELECT id FROM accounts WHERE external_ref = 'demo-tagesgeld'");
    let depot = id("SELECT id FROM accounts WHERE external_ref = 'demo-depot'");
    let today = chrono::Local::now().date_naive();
    for (i, (ago, cents, cp, iban, purpose)) in [
        (70, 1250, "Musterbank", "", "Zinsgutschrift"),
        (40, 1250, "Musterbank", "", "Zinsgutschrift"),
        (10, 1250, "Musterbank", "", "Zinsgutschrift"),
        (
            15,
            -20000,
            "Max Muster",
            "DE02120300000000202051",
            "Umbuchung",
        ),
        (
            5,
            380000,
            "TechNova GmbH",
            "DE75512108001245126199",
            "Gehalt Bonus",
        ),
    ]
    .into_iter()
    .enumerate()
    {
        let date = (today - chrono::Duration::days(ago))
            .format("%Y-%m-%d")
            .to_string();
        db.execute(
            "INSERT INTO transactions(account_id, external_id, booking_date, value_date, amount_cents,
                                      counterparty, counterparty_iban, purpose, booking_text)
             VALUES (?1, ?2, ?3, ?3, ?4, ?5, ?6, ?7, 'GUTSCHRIFT')",
            params![tagesgeld, format!("tg-{i}"), date, cents, cp, iban, purpose],
        )
        .unwrap();
    }
    for acc in [tagesgeld, depot] {
        db.execute(
            "INSERT INTO holdings(account_id, isin, name, quantity, current_price_cents, value_cents)
             VALUES (?1, 'IE00B4L5Y983', 'MSCI World', 10, 9000, 90000)",
            [acc],
        )
        .unwrap();
    }
    db.execute(
        "UPDATE transactions SET counterparty_iban = 'DE89370400440532013000'
         WHERE counterparty = 'Autobank AG'",
        [],
    )
    .unwrap();
    // the tax refund on the giro counts as salary only through the Tagesgeld
    // booking marked as salary (same payer IBAN)
    db.execute(
        "UPDATE transactions SET counterparty_iban = 'DE75512108001245126199'
         WHERE counterparty = 'Finanzamt Musterstadt'",
        [],
    )
    .unwrap();
    let bonus = id("SELECT id FROM transactions WHERE external_id = 'tg-4'");
    let autobank = id("SELECT max(id) FROM transactions WHERE counterparty = 'Autobank AG'");
    let rewe = id("SELECT min(id) FROM transactions WHERE counterparty = 'REWE Markt GmbH'");
    let interest = id("SELECT min(id) FROM transactions WHERE external_id = 'tg-0'");
    let lebensmittel = id("SELECT id FROM categories WHERE name = 'Lebensmittel'");
    let supermarkt = id("SELECT id FROM categories WHERE name = 'Supermarkt'");
    let wohnen = id("SELECT id FROM categories WHERE name = 'Wohnen & Energie'");
    drop(db);
    v.set_booking_salary_flag(bonus, Some(true)).unwrap();
    v.set_category_budget(lebensmittel, Some(400_00)).unwrap();
    v.set_category_budget(supermarkt, Some(250_00)).unwrap();
    v.set_category_budget(wohnen, Some(1500_00)).unwrap();
    let split = |cat: Option<i64>, cents: i64| crate::models::TransactionSplitInput {
        category_id: cat,
        amount_cents: cents,
        note: "Teil".into(),
    };
    v.set_transaction_splits(
        autobank,
        vec![split(Some(wohnen), -20000), split(None, -8900)],
    )
    .unwrap();
    v.set_transaction_splits(
        rewe,
        vec![split(Some(supermarkt), -3000), split(Some(wohnen), -1782)],
    )
    .unwrap();
    v.set_transaction_splits(interest, vec![split(Some(wohnen), 1000), split(None, 250)])
        .unwrap();
    let pdf = |s: &str| crate::documents::simple_pdf(&[s.to_string()]);
    v.attach_document_to_booking(autobank, "autobank.pdf".into(), pdf("Autobank Rate"))
        .unwrap();
    v.attach_document_to_booking(interest, "zinsen.pdf".into(), pdf("Zinsen"))
        .unwrap();
    v.attach_document_to_account(
        tagesgeld,
        "Kontoauszug".into(),
        "auszug.pdf".into(),
        pdf("Kontoauszug Tagesgeld"),
        "kontoauszug".into(),
    )
    .unwrap();
}

/// Deletes one booking (the newer Autobank rate), one connection (the Amex
/// with the Visa account and its bookings), two accounts (the Tagesgeld with
/// bookings, a holding, splits and documents; the manual car loan), one
/// category tree (Lebensmittel with its subcategories and rules) and one rule.
fn soft_delete_items(v: &Vault) {
    let id = |sql: &str| -> i64 { v.db().unwrap().query_row(sql, [], |r| r.get(0)).unwrap() };
    let autobank = id("SELECT max(id) FROM transactions WHERE counterparty = 'Autobank AG'");
    soft_delete_booking(&v.db().unwrap(), autobank).unwrap();
    v.delete_bank_connection(id(&format!(
        "SELECT id FROM bank_connections WHERE connector = '{}'",
        ConnectorKind::AmericanExpress.as_str()
    )))
    .unwrap();
    for r in ["demo-tagesgeld", "demo-autokredit"] {
        let a = id(&format!(
            "SELECT id FROM accounts WHERE external_ref = '{r}' OR (name = 'Autokredit' AND '{r}' = 'demo-autokredit')"
        ));
        v.set_account_archived(a, true).unwrap();
        v.delete_account(a).unwrap();
    }
    v.delete_category(id("SELECT id FROM categories WHERE name = 'Lebensmittel'"))
        .unwrap();
    v.delete_rule(id(
        "SELECT r.id FROM rules r JOIN categories c ON c.id = r.category_id
         WHERE c.name = 'Internet & Telefon' ORDER BY r.id LIMIT 1",
    ))
    .unwrap();
}

/// Collects differences between the vault with soft-deleted rows and the one
/// where those rows never existed.
struct Mismatches(Vec<String>);

impl Mismatches {
    fn cmp<T: std::fmt::Debug>(&mut self, api: &str, a: T, b: T) {
        let (a, b) = (format!("{a:?}"), format!("{b:?}"));
        if a != b {
            // show the neighbourhood of the first difference
            let at = a.bytes().zip(b.bytes()).take_while(|(x, y)| x == y).count();
            let cut = |s: &str| {
                let start = s.floor_char_boundary(at.saturating_sub(200));
                let end = s.floor_char_boundary((at + 200).min(s.len()));
                s[start..end].to_string()
            };
            self.0
                .push(format!("{api}:\n  soft: {}\n  gone: {}", cut(&a), cut(&b)));
        }
    }
}

fn files_under(dir: &std::path::Path) -> Vec<String> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                stack.push(p);
            } else {
                out.push(p.strip_prefix(dir).unwrap().to_string_lossy().into_owned());
            }
        }
    }
    out.sort();
    out
}

/// A vault with soft-deleted rows (`soft_delete_items`) answers every public
/// read API exactly like a copy where those rows were removed for good (the
/// old hard delete with its foreign-key cascades). APIs covered, each called
/// with every account / booking / connection / category / document id that
/// existed before the deletions where it takes one:
///
/// - vault: `list_bank_connections`, `list_accounts`, `list_account_groups`,
///   `list_holdings`, `balance_history`, `list_categories` (all time and a
///   date range), `list_transactions` (all, per account, per category with and
///   without subcategories, uncategorised, search, everyday/investment scope,
///   merchant), `list_rules`, `preview_rule`, `apply_rules` (count and the
///   bookings afterwards), `list_settings`, `export_bookings_csv`, `is_empty`
///   and `account_count` (also on a vault whose only rows are deleted)
/// - connections: `connection_status`
/// - planning: `list_category_budget_progress` (this and last month),
///   `list_transaction_splits`, `cashflow_by_period` (month, quarter, year),
///   `list_transfer_templates`
/// - recurring / salary: `list_recurring`, `recurring_month`,
///   `list_ignored_recurring`, `salary_cycle`
/// - loans: `list_manual_loans`, `preview_manual_loan`, `list_loan_links`
/// - insights: `merchant_stats` (every merchant key), `investment_dashboard`
/// - user groups: `list_user_groups`
/// - documents: `list_documents_for_booking`, `list_all_documents` (all, per
///   account, unlinked, search), `get_document_bytes`, `export_all_documents`,
///   `mirror_new_documents`, `auto_match_document` (text that fits the deleted
///   booking best)
/// - transfers / statements: `suggest_recipients`, `auto_statements_enabled`
/// - imports: `preview_moneymoney_import` (rows unrelated to the deleted
///   bookings; rows that hit a deleted booking are kept from resurrecting it on
///   purpose, see Task 4)
///
/// Not compared: `preview_moneymoney_database` (its read of "no bookings yet"
/// is covered by `moneymoney_db::tests::deleted_bookings_do_not_count_as_existing`),
/// `preview_portal_capture` (only dedup by key, which must see deleted rows),
/// the placement written by `move_account_to_group` (see
/// `moving_an_account_ignores_deleted_neighbours`), and the APIs that only
/// write or return no stored data (setters, imports, settings getters,
/// catalogues, parsers, connector sessions, logos).
#[test]
fn soft_deleted_rows_appear_in_no_public_api() {
    use crate::models::{BookingFilter, BookingScope, PeriodGranularity};
    use chrono::Datelike;
    let dir = temp_dir("invisible");
    let a = open(&dir, "soft.db");
    soft_delete_world(&a);
    a.checkpoint().unwrap();
    std::fs::copy(dir.join("soft.db"), dir.join("gone.db")).unwrap();
    let b = open(&dir, "gone.db");

    // every id that existed before the deletions
    let all = |sql: &str| -> Vec<i64> {
        let db = a.db().unwrap();
        let mut st = db.prepare(sql).unwrap();
        st.query_map([], |r| r.get(0))
            .unwrap()
            .map(|r| r.unwrap())
            .collect()
    };
    let accounts = all("SELECT id FROM accounts ORDER BY id");
    let bookings = all("SELECT id FROM transactions ORDER BY id");
    let connections = all("SELECT id FROM bank_connections ORDER BY id");
    let categories = all("SELECT id FROM categories ORDER BY id");
    let documents = all("SELECT id FROM booking_documents ORDER BY id");
    let merchant_keys: Vec<String> = {
        let mut k: Vec<String> = a
            .list_transactions(BookingFilter::default())
            .unwrap()
            .transactions
            .into_iter()
            .map(|t| t.merchant.key)
            .collect();
        k.sort();
        k.dedup();
        k
    };

    soft_delete_items(&a);
    soft_delete_items(&b);
    b.db()
        .unwrap()
        .execute_batch(
            "DELETE FROM transactions WHERE deleted_ms IS NOT NULL;
             DELETE FROM rules WHERE deleted_ms IS NOT NULL;
             DELETE FROM accounts WHERE deleted_ms IS NOT NULL;
             DELETE FROM bank_connections WHERE deleted_ms IS NOT NULL;
             DELETE FROM categories WHERE deleted_ms IS NOT NULL;",
        )
        .unwrap();
    assert!(n(&a, "SELECT count(*) FROM transactions WHERE deleted_ms > 0") > 10);

    let mut m = Mismatches(Vec::new());
    macro_rules! both {
        ($label:expr, |$v:ident| $call:expr) => {{
            let r_a = {
                let $v = &a;
                $call
            };
            let r_b = {
                let $v = &b;
                $call
            };
            m.cmp(&$label, r_a, r_b);
        }};
    }

    both!("list_bank_connections", |v| v.list_bank_connections());
    both!("list_accounts", |v| v.list_accounts());
    both!("list_account_groups", |v| v.list_account_groups());
    both!("list_user_groups", |v| v.list_user_groups());
    both!("account_count", |v| v.account_count());
    both!("is_empty", |v| v.is_empty());
    both!("list_rules", |v| v.list_rules());
    both!("list_settings", |v| v.list_settings());
    both!("list_categories", |v| v.list_categories(None, None));
    let today = chrono::Local::now().date_naive();
    let ago = |d: i64| {
        (today - chrono::Duration::days(d))
            .format("%Y-%m-%d")
            .to_string()
    };
    both!("list_categories(range)", |v| v
        .list_categories(Some(ago(40)), Some(ago(0))));
    both!("balance_history(all)", |v| v.balance_history(vec![], 120));
    both!("list_manual_loans", |v| v.list_manual_loans());
    both!("list_loan_links", |v| v.list_loan_links());
    both!("list_transfer_templates", |v| v.list_transfer_templates());
    both!("investment_dashboard", |v| v.investment_dashboard(6));
    both!("list_recurring(all)", |v| v.list_recurring(vec![]));
    both!("list_ignored_recurring", |v| v
        .list_ignored_recurring(vec![]));
    both!("salary_cycle(all)", |v| v.salary_cycle(vec![]));
    for (y, mo) in [
        (today.year(), today.month()),
        if today.month() == 1 {
            (today.year() - 1, 12)
        } else {
            (today.year(), today.month() - 1)
        },
    ] {
        both!(format!("list_category_budget_progress({y}-{mo})"), |v| v
            .list_category_budget_progress(y, mo));
        both!(format!("recurring_month({y}-{mo})"), |v| v.recurring_month(
            vec![],
            y,
            mo
        ));
    }
    for g in [
        PeriodGranularity::Month,
        PeriodGranularity::Quarter,
        PeriodGranularity::Year,
    ] {
        both!(format!("cashflow_by_period({g:?})"), |v| v
            .cashflow_by_period(g, 6));
    }
    both!("suggest_recipients", |v| v
        .suggest_recipients(String::new(), 20));
    both!("suggest_recipients(query)", |v| v
        .suggest_recipients("Autobank".into(), 20));

    for &id in &accounts {
        both!(format!("list_holdings({id})"), |v| v.list_holdings(id));
        both!(format!("balance_history({id})"), |v| v
            .balance_history(vec![id], 120));
        both!(format!("list_recurring({id})"), |v| v
            .list_recurring(vec![id]));
        both!(format!("salary_cycle({id})"), |v| v.salary_cycle(vec![id]));
        both!(format!("auto_statements_enabled({id})"), |v| v
            .auto_statements_enabled(id));
        both!(format!("list_transactions(account {id})"), |v| v
            .list_transactions(BookingFilter {
                account_ids: vec![id],
                ..Default::default()
            }));
        both!(format!("list_all_documents(account {id})"), |v| v
            .list_all_documents(crate::documents::DocumentFilter {
                account_id: Some(id),
                doc_type: None,
                search: None,
                unlinked_only: false,
            }));
        both!(format!("preview_manual_loan({id})"), |v| v
            .preview_manual_loan(
                Some(id),
                crate::loans::LoanSetup {
                    name: "Autokredit".into(),
                    original_cents: Some(15_000_00),
                    anchor_date: ago(60),
                    anchor_balance_cents: 9_400_00,
                    interest_rate_ppm: Some(49_900),
                    match_expr: "Autobank".into(),
                },
                12
            ));
    }
    for &id in &bookings {
        both!(format!("list_transaction_splits({id})"), |v| v
            .list_transaction_splits(id));
        both!(format!("list_documents_for_booking({id})"), |v| v
            .list_documents_for_booking(id));
    }
    for &id in &connections {
        both!(format!("connection_status({id})"), |v| v
            .connection_status(id));
    }
    for &id in &categories {
        for sub in [false, true] {
            both!(
                format!("list_transactions(category {id}, sub {sub})"),
                |v| v.list_transactions(BookingFilter {
                    category_id: Some(id),
                    include_subcategories: sub,
                    ..Default::default()
                })
            );
        }
    }
    for &id in &documents {
        both!(format!("get_document_bytes({id})"), |v| v
            .get_document_bytes(id));
    }
    for key in &merchant_keys {
        both!(format!("merchant_stats({key})"), |v| v
            .merchant_stats(key.clone()));
        both!(format!("list_transactions(merchant {key})"), |v| v
            .list_transactions(BookingFilter {
                merchant_key: Some(key.clone()),
                ..Default::default()
            }));
    }
    let filters = [
        BookingFilter::default(),
        BookingFilter {
            uncategorized_only: true,
            ..Default::default()
        },
        BookingFilter {
            search: Some("Autobank".into()),
            ..Default::default()
        },
        BookingFilter {
            search: Some("Musterbank".into()),
            ..Default::default()
        },
        BookingFilter {
            scope: BookingScope::Everyday,
            date_from: Some(ago(30)),
            ..Default::default()
        },
        BookingFilter {
            scope: BookingScope::Investments,
            ..Default::default()
        },
    ];
    for (i, f) in filters.iter().enumerate() {
        both!(format!("list_transactions(filter {i})"), |v| v
            .list_transactions(f.clone()));
        both!(format!("export_bookings_csv(filter {i})"), |v| v
            .export_bookings_csv(f.clone()));
    }
    for (i, f) in [
        crate::documents::DocumentFilter {
            account_id: None,
            doc_type: None,
            search: None,
            unlinked_only: false,
        },
        crate::documents::DocumentFilter {
            account_id: None,
            doc_type: None,
            search: None,
            unlinked_only: true,
        },
        crate::documents::DocumentFilter {
            account_id: None,
            doc_type: None,
            search: Some("Tagesgeld".into()),
            unlinked_only: false,
        },
    ]
    .into_iter()
    .enumerate()
    {
        both!(format!("list_all_documents(filter {i})"), |v| v
            .list_all_documents(f.clone()));
    }
    let any_rule = |pattern: &str| crate::models::Rule {
        id: 0,
        name: "x".into(),
        category_id: n(&b, "SELECT min(id) FROM categories"),
        field: crate::models::RuleField::Any,
        match_kind: crate::models::MatchKind::Keyword,
        pattern: pattern.into(),
        case_sensitive: false,
        min_amount_cents: None,
        max_amount_cents: None,
        account_id: None,
        priority: 100,
        enabled: true,
        match_count: 0,
    };
    for p in ["Autobank", "Musterbank", "a"] {
        both!(format!("preview_rule({p})"), |v| v
            .preview_rule(any_rule(p), 500));
    }
    let mm = "\"Datum\";\"Wertstellung\";\"Kategorie\";\"Name\";\"Verwendungszweck\";\"Konto\";\"Bank\";\"Betrag\";\"Währung\";\"Notiz\"\n\
\"15.03.2012\";\"15.03.2012\";\"Haushalt\\Supermarkt\";\"REWE Markt\";\"Einkauf\";\"\";\"\";\"-12,34\";\"EUR\";\"\"\n";
    let giro = n(
        &b,
        "SELECT id FROM accounts WHERE external_ref = 'demo-giro'",
    );
    for target in [None, Some(giro)] {
        both!(format!("preview_moneymoney_import({target:?})"), |v| v
            .preview_moneymoney_import(
                mm.as_bytes().to_vec(),
                "x.csv".into(),
                target
            ));
    }
    both!("auto_match_document", |v| v.auto_match_document(
        "autobank.pdf".into(),
        Vec::new(),
        Some(format!(
            "Autobank AG Rate Kreditvertrag 289,00 EUR {}",
            ago(24)
        ))
    ));
    for (api, run) in [("export_all_documents", 0), ("mirror_new_documents", 1)] {
        let out = |tag: &str| {
            let d = dir.join(format!("{api}-{tag}"));
            std::fs::create_dir_all(&d).unwrap();
            d
        };
        let (da, db) = (out("soft"), out("gone"));
        let call = |v: &Vault, d: &std::path::Path| {
            let d = d.to_string_lossy().into_owned();
            if run == 0 {
                v.export_all_documents(d)
            } else {
                v.mirror_new_documents(d)
            }
        };
        m.cmp(api, call(&a, &da), call(&b, &db));
        m.cmp(&format!("{api} files"), files_under(&da), files_under(&db));
    }
    // apply last: it writes
    both!("apply_rules", |v| v.apply_rules(false));
    both!("list_transactions after apply_rules", |v| v
        .list_transactions(BookingFilter::default()));

    // a vault whose only rows are deleted is empty
    let e = open(&dir, "empty.db");
    let cat = e
        .create_category("X".into(), None, String::new(), String::new())
        .unwrap();
    let conn = e
        .add_bank_connection(ConnectorKind::Comdirect, String::new(), "login".into())
        .unwrap();
    e.db()
        .unwrap()
        .execute_batch(&format!(
            "INSERT INTO account_groups(id, name) VALUES (1, 'G');
             INSERT INTO accounts(connection_id, group_id, external_ref, name) VALUES ({conn}, 1, 'A', 'A');"
        ))
        .unwrap();
    e.delete_category(cat).unwrap();
    e.delete_bank_connection(conn).unwrap();
    m.cmp("is_empty(only deleted rows)", e.is_empty(), Ok(true));
    m.cmp("account_count(only deleted rows)", e.account_count(), Ok(0));

    assert!(
        m.0.is_empty(),
        "{} APIs show soft-deleted rows:\n{}",
        m.0.len(),
        m.0.join("\n")
    );
}

/// The drop index of a move counts the accounts the user sees, so a deleted
/// account in the target group must not shift it.
#[test]
fn moving_an_account_ignores_deleted_neighbours() {
    let v = open(&temp_dir("moveidx"), "a.db");
    let (_, a1, a2, loose) = bank_fixture(&v);
    let g = v.create_user_group("G".into(), "folder".into()).unwrap();
    v.move_account_to_group(a1, Some(g.clone()), None).unwrap();
    v.move_account_to_group(a2, Some(g.clone()), None).unwrap();
    v.set_account_archived(a1, true).unwrap();
    v.delete_account(a1).unwrap();
    // visible group: [a2]; index 1 = after a2
    v.move_account_to_group(loose, Some(g.clone()), Some(1))
        .unwrap();
    let group = v
        .list_user_groups()
        .unwrap()
        .into_iter()
        .find(|x| x.uuid == g)
        .unwrap();
    let ids: Vec<i64> = group.accounts.iter().map(|a| a.id).collect();
    assert_eq!(ids, [a2, loose]);
}
