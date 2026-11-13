use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use rusqlite::params;

use crate::models::AccountKind;
use crate::vault::Vault;

fn temp_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "gc-groups-{tag}-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn open(dir: &std::path::Path, file: &str) -> Arc<Vault> {
    Vault::open(dir.join(file).to_string_lossy().into(), vec![7u8; 32]).unwrap()
}

/// Same bank login + accounts in a vault: (Giro, Depot, Visa) with balances.
fn seed(v: &Vault) -> Vec<i64> {
    let db = v.db().unwrap();
    db.execute(
        "INSERT INTO bank_connections(connector, display_name, login_name) VALUES ('fints:12345678', 'Bank', 'me')",
        [],
    )
    .unwrap();
    let con = db.last_insert_rowid();
    db.execute("INSERT INTO account_groups(name) VALUES ('G')", [])
        .unwrap();
    let g = db.last_insert_rowid();
    let mut ids = vec![];
    for (ext, name, kind, bal) in [
        ("A1", "Giro", "checking", 100_00),
        ("A2", "Depot", "brokerage", 5_000_00),
        ("A3", "Visa", "credit_card", -50_00),
    ] {
        db.execute(
            "INSERT INTO accounts(connection_id, group_id, external_ref, name, kind, balance_cents) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![con, g, ext, name, kind, bal],
        )
        .unwrap();
        ids.push(db.last_insert_rowid());
    }
    ids
}

fn tick() {
    std::thread::sleep(Duration::from_millis(3));
}

fn names(v: &Vault) -> Vec<(String, Vec<String>)> {
    v.list_user_groups()
        .unwrap()
        .into_iter()
        .map(|g| (g.name, g.accounts.into_iter().map(|a| a.name).collect()))
        .collect()
}

fn s(v: &[&str]) -> Vec<String> {
    v.iter().map(|x| x.to_string()).collect()
}

#[test]
fn create_rename_delete() {
    let dir = temp_dir("crud");
    let v = open(&dir, "a.db");
    let ids = seed(&v);

    // nothing grouped yet: only "Ohne Gruppe", sorted by kind (Giro, Visa, Depot)
    let gs = v.list_user_groups().unwrap();
    assert_eq!(gs.len(), 1);
    assert!(gs[0].is_ungrouped && gs[0].uuid.is_empty());
    assert_eq!(names(&v)[0].1, s(&["Giro", "Visa", "Depot"]));

    let privat = v
        .create_user_group(" Privat ".into(), "person".into())
        .unwrap();
    assert!(
        v.create_user_group("privat".into(), "person".into())
            .is_err(),
        "names are unique, ignoring case"
    );
    assert!(v.create_user_group("  ".into(), "person".into()).is_err());
    let firma = v
        .create_user_group("Firma".into(), "briefcase".into())
        .unwrap();

    // empty user groups are listed (drop targets)
    assert_eq!(
        names(&v),
        vec![
            ("Privat".into(), vec![]),
            ("Firma".into(), vec![]),
            ("Ohne Gruppe".into(), s(&["Giro", "Visa", "Depot"]))
        ]
    );

    v.move_account_to_group(ids[0], Some(privat.clone()), None)
        .unwrap();
    v.move_account_to_group(ids[1], Some(privat.clone()), Some(0))
        .unwrap();
    v.move_account_to_group(ids[2], Some(firma.clone()), None)
        .unwrap();
    let gs = v.list_user_groups().unwrap();
    assert_eq!(
        gs.len(),
        2,
        "no 'Ohne Gruppe' when every account is grouped"
    );
    assert_eq!(
        names(&v)[0].1,
        s(&["Depot", "Giro"]),
        "index 0 puts Depot first"
    );
    assert_eq!(gs[0].balance_cents, 5_100_00);
    assert_eq!(gs[0].sf_symbol, "person");

    v.update_user_group(firma.clone(), "Geschäft".into(), "building.2".into(), true)
        .unwrap();
    assert!(v
        .update_user_group(firma.clone(), "PRIVAT".into(), "x".into(), true)
        .is_err());
    assert!(v
        .update_user_group("nope".into(), "X".into(), "x".into(), true)
        .is_err());

    v.reorder_user_groups(vec![firma.clone(), privat.clone()])
        .unwrap();
    v.reorder_accounts_in_group(Some(privat.clone()), vec![ids[0], ids[1], ids[2]])
        .unwrap();
    assert_eq!(
        names(&v),
        vec![
            ("Geschäft".into(), s(&["Visa"])),
            ("Privat".into(), s(&["Giro", "Depot"]))
        ]
    );

    // deleting keeps the accounts, they go to "Ohne Gruppe"
    v.delete_user_group(privat.clone()).unwrap();
    assert!(
        v.move_account_to_group(ids[0], Some(privat), None).is_err(),
        "deleted group"
    );
    assert_eq!(
        names(&v),
        vec![
            ("Geschäft".into(), s(&["Visa"])),
            ("Ohne Gruppe".into(), s(&["Giro", "Depot"]))
        ]
    );
    assert_eq!(v.list_accounts().unwrap().len(), 3);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn excluded_group_leaves_the_total() {
    let dir = temp_dir("total");
    let v = open(&dir, "a.db");
    let ids = seed(&v);
    let firma = v
        .create_user_group("Firma".into(), "briefcase".into())
        .unwrap();
    v.move_account_to_group(ids[1], Some(firma.clone()), None)
        .unwrap();
    let total = |v: &Vault| {
        v.balance_history(vec![], 1)
            .unwrap()
            .last()
            .unwrap()
            .balance_cents
    };
    assert_eq!(total(&v), 5_050_00);

    v.update_user_group(firma.clone(), "Firma".into(), "briefcase".into(), false)
        .unwrap();
    let accs = v.list_accounts().unwrap();
    assert!(!accs.iter().find(|a| a.id == ids[1]).unwrap().in_total);
    assert!(accs.iter().find(|a| a.id == ids[0]).unwrap().in_total);
    assert_eq!(total(&v), 50_00, "Depot excluded from the overall total");
    // explicitly selected accounts are still summed
    let one = v.balance_history(vec![ids[1]], 1).unwrap();
    assert_eq!(one.last().unwrap().balance_cents, 5_000_00);
    assert!(!v.list_user_groups().unwrap()[0].include_in_total);
    let _ = std::fs::remove_dir_all(dir);
}

/// GiroCrab/GiroCrab#208: an "Alle" group holding everything, with an "Alt"
/// subgroup of old accounts. Archived accounts and subgroups taken out of
/// the total must not count in the group sums.
#[test]
fn group_sums_skip_archived_accounts_and_excluded_subgroups() {
    let dir = temp_dir("sums208");
    let v = open(&dir, "a.db");
    let ids = seed(&v); // Giro 100, Depot 5000, Visa -50
    let alle = v.create_user_group("Alle".into(), "folder".into()).unwrap();
    let alt = v
        .create_user_group("Alt".into(), "archivebox".into())
        .unwrap();
    v.set_user_group_parent(alt.clone(), Some(alle.clone()))
        .unwrap();
    v.move_account_to_group(ids[0], Some(alle.clone()), None)
        .unwrap();
    v.move_account_to_group(ids[1], Some(alle.clone()), None)
        .unwrap();
    v.move_account_to_group(ids[2], Some(alt.clone()), None)
        .unwrap();
    let sums = |v: &Vault| -> HashMap<String, i64> {
        v.list_user_groups()
            .unwrap()
            .into_iter()
            .map(|g| (g.name, g.balance_cents))
            .collect()
    };
    let kind_sum = |v: &Vault| -> i64 {
        v.list_account_groups()
            .unwrap()
            .iter()
            .map(|g| g.balance_cents)
            .sum()
    };
    assert_eq!(sums(&v)["Alle"], 5_050_00);
    assert_eq!(sums(&v)["Alt"], -50_00);
    assert_eq!(kind_sum(&v), 5_050_00);

    // archiving the Visa: it stays in "Alt", but no sum counts it any more
    v.set_account_archived(ids[2], true).unwrap();
    let s = sums(&v);
    assert_eq!(s["Alt"], 0);
    assert_eq!(s["Alle"], 5_100_00);
    assert_eq!(kind_sum(&v), 5_100_00);
    let alt_group = v
        .list_user_groups()
        .unwrap()
        .into_iter()
        .find(|g| g.name == "Alt")
        .unwrap();
    assert_eq!(alt_group.accounts.len(), 1, "archived account still listed");
    v.set_account_archived(ids[2], false).unwrap();

    // "Alt" out of the total: keeps its own sum, "Alle" no longer adds it
    v.update_user_group(alt.clone(), "Alt".into(), "archivebox".into(), false)
        .unwrap();
    let s = sums(&v);
    assert_eq!(s["Alt"], -50_00);
    assert_eq!(s["Alle"], 5_100_00);

    // the parent out of the total too: its own sum still shows everything
    // inside it, apart from the subgroup excluded on its own
    v.update_user_group(alle.clone(), "Alle".into(), "folder".into(), false)
        .unwrap();
    assert_eq!(sums(&v)["Alle"], 5_100_00);
    v.update_user_group(alt.clone(), "Alt".into(), "archivebox".into(), true)
        .unwrap();
    assert_eq!(
        sums(&v)["Alle"],
        5_050_00,
        "subgroup only inherits the exclusion"
    );
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn new_bank_account_joins_its_siblings_group() {
    let dir = temp_dir("place");
    let v = open(&dir, "a.db");
    let ids = seed(&v);
    let mama = v.create_user_group("Mama".into(), "person".into()).unwrap();
    v.move_account_to_group(ids[0], Some(mama.clone()), None)
        .unwrap();
    v.move_account_to_group(ids[1], Some(mama.clone()), None)
        .unwrap();
    let db = v.db().unwrap();
    db.execute(
        "INSERT INTO accounts(connection_id, group_id, external_ref, name) SELECT connection_id, group_id, 'A4', 'Neu' FROM accounts WHERE id = ?1",
        [ids[0]],
    )
    .unwrap();
    let new = db.last_insert_rowid();
    super::place_new_account(&db, new).unwrap();
    let (uuid, ms): (Option<String>, i64) = db
        .query_row(
            "SELECT user_group_uuid, placement_ms FROM accounts WHERE id = ?1",
            [new],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(uuid.as_deref(), Some(mama.as_str()));
    assert_eq!(
        ms, 0,
        "automatic placement never beats a user choice on sync"
    );

    // other login without grouped accounts → stays ungrouped
    db.execute("INSERT INTO accounts(group_id, external_ref, name) SELECT group_id, 'X', 'Bar' FROM accounts LIMIT 1", []).unwrap();
    let other = db.last_insert_rowid();
    super::place_new_account(&db, other).unwrap();
    let uuid: Option<String> = db
        .query_row(
            "SELECT user_group_uuid FROM accounts WHERE id = ?1",
            [other],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(uuid, None);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn merge_newest_edit_wins_and_deletions_stick() {
    let dir = temp_dir("merge");
    let key = vec![7u8; 32];
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    let ia = seed(&a);
    let ib = seed(&b);

    // A creates a group and moves Giro into it → B gets both
    let privat = a
        .create_user_group("Privat".into(), "person".into())
        .unwrap();
    a.move_account_to_group(ia[0], Some(privat.clone()), None)
        .unwrap();
    tick();
    let st = b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    assert!(st.groups_updated >= 2);
    assert_eq!(names(&b)[0], ("Privat".into(), s(&["Giro"])));

    // concurrent edits: B renames the group, A moves Visa in and renames an account
    b.update_user_group(privat.clone(), "Familie".into(), "person.2".into(), true)
        .unwrap();
    tick();
    a.move_account_to_group(ia[2], Some(privat.clone()), None)
        .unwrap();
    a.rename_account(ia[1], "Mein Depot".into()).unwrap();
    tick();
    b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    a.merge_other_vault(b.file_path(), key.clone()).unwrap();
    for v in [&a, &b] {
        assert_eq!(
            names(v),
            vec![
                ("Familie".into(), s(&["Giro", "Visa"])),
                ("Ohne Gruppe".into(), s(&["Mein Depot"]))
            ]
        );
    }
    // an older rename doesn't overwrite a newer one
    let depot_b = ib[1];
    b.rename_account(depot_b, "Depot B".into()).unwrap();
    tick();
    a.rename_account(ia[1], "Depot A".into()).unwrap();
    b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    a.merge_other_vault(b.file_path(), key.clone()).unwrap();
    for v in [&a, &b] {
        assert!(v
            .list_accounts()
            .unwrap()
            .iter()
            .any(|x| x.name == "Depot A"));
    }

    // A deletes the group; B (which still has it) must not bring it back
    tick();
    a.delete_user_group(privat.clone()).unwrap();
    a.merge_other_vault(b.file_path(), key.clone()).unwrap();
    assert!(a.list_user_groups().unwrap().iter().all(|g| g.is_ungrouped));
    b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    for v in [&a, &b] {
        let gs = v.list_user_groups().unwrap();
        assert_eq!(gs.len(), 1);
        assert!(gs[0].is_ungrouped);
        assert_eq!(gs[0].accounts.len(), 3);
    }
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn merge_brings_new_accounts_with_their_group() {
    let dir = temp_dir("merge-new");
    let key = vec![7u8; 32];
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    let ia = seed(&a);
    let g = a
        .create_user_group("Kinder".into(), "figure.and.child.holdinghands".into())
        .unwrap();
    a.move_account_to_group(ia[2], Some(g.clone()), None)
        .unwrap();
    let st = b.merge_other_vault(a.file_path(), key).unwrap();
    assert_eq!(st.accounts_added, 3);
    assert_eq!(names(&b)[0], ("Kinder".into(), s(&["Visa"])));
    let _ = std::fs::remove_dir_all(dir);
}

fn colors(v: &Vault) -> Vec<(String, String)> {
    let mut c: Vec<_> = v
        .list_accounts()
        .unwrap()
        .into_iter()
        .map(|a| (a.name, a.color_hex))
        .collect();
    c.sort();
    c
}

#[test]
fn account_colors_default_stable_and_sync() {
    let dir = temp_dir("colors");
    let key = vec![7u8; 32];
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    let bar = |v: &Vault| {
        let db = v.db().unwrap();
        db.execute(
            "INSERT OR IGNORE INTO account_groups(name) VALUES ('H')",
            [],
        )
        .unwrap();
        db.execute(
            "INSERT INTO accounts(group_id, external_ref, name) \
             VALUES ((SELECT id FROM account_groups WHERE name = 'H'), 'unrelated', 'Bar')",
            [],
        )
        .unwrap();
    };
    // the same accounts, created in a different order → different local ids
    let ia = seed(&a);
    bar(&a);
    bar(&b);
    seed(&b);

    // same default colours on both devices, distinct, nothing stored
    let ca = colors(&a);
    assert_eq!(ca, colors(&b));
    let distinct: std::collections::HashSet<_> = ca.iter().map(|(_, c)| c.clone()).collect();
    assert_eq!(
        distinct.len(),
        ca.len(),
        "no two accounts share a default colour"
    );
    assert!(
        ca.iter()
            .all(|(_, c)| super::ACCOUNT_COLOR_PALETTE[..super::DISTINCT].contains(&c.as_str())),
        "a few accounts only get the clearly distinct hues"
    );
    assert!(ca
        .iter()
        .all(|(_, c)| super::ACCOUNT_COLOR_PALETTE.contains(&c.as_str())));
    let stored: i64 = a
        .db()
        .unwrap()
        .query_row(
            "SELECT count(*) FROM accounts WHERE color_hex IS NOT NULL",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(stored, 0);

    // a user choice syncs both ways; the newer one wins
    assert!(a.set_account_color(ia[0], Some("blue".into())).is_err());
    assert!(a.set_account_color(999, Some("#123456".into())).is_err());
    a.set_account_color(ia[0], Some("#abcdef".into())).unwrap();
    tick();
    b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    let giro = |v: &Vault| {
        v.list_accounts()
            .unwrap()
            .into_iter()
            .find(|x| x.name == "Giro")
            .unwrap()
            .color_hex
    };
    assert_eq!(giro(&b), "#ABCDEF");
    let gb = b
        .list_accounts()
        .unwrap()
        .into_iter()
        .find(|x| x.name == "Giro")
        .unwrap()
        .id;
    b.set_account_color(gb, None).unwrap();
    tick();
    a.merge_other_vault(b.file_path(), key.clone()).unwrap();
    assert_eq!(
        giro(&a),
        ca.iter().find(|(n, _)| n == "Giro").unwrap().1,
        "reset to default syncs too"
    );
    assert_eq!(super::account_color_palette().len(), 12);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn group_color_syncs_newer_wins_and_resets() {
    let dir = temp_dir("groupcolor");
    let key = vec![7u8; 32];
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    seed(&a);
    seed(&b);
    let g = a
        .create_user_group("Privat".into(), "person".into())
        .unwrap();
    let color = |v: &Vault| {
        v.list_user_groups()
            .unwrap()
            .into_iter()
            .find(|x| x.uuid == g)
            .unwrap()
            .color_hex
    };
    assert_eq!(color(&a), "", "no colour until one is chosen");
    assert!(a
        .set_user_group_color(g.clone(), Some("blue".into()))
        .is_err());
    assert!(a
        .set_user_group_color("nope".into(), Some("#123456".into()))
        .is_err());
    a.set_user_group_color(g.clone(), Some("#abcdef".into()))
        .unwrap();
    assert_eq!(color(&a), "#ABCDEF");
    tick();
    b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    assert_eq!(color(&b), "#ABCDEF");
    // a newer choice on the other device wins, also back to none
    b.set_user_group_color(g.clone(), None).unwrap();
    tick();
    a.merge_other_vault(b.file_path(), key.clone()).unwrap();
    assert_eq!(color(&a), "");
    let ungrouped = a
        .list_user_groups()
        .unwrap()
        .into_iter()
        .find(|x| x.is_ungrouped);
    assert!(ungrouped.is_none_or(|u| u.color_hex.is_empty()));
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn account_symbol_choice_syncs_newer_wins() {
    let dir = temp_dir("symbols");
    let key = vec![7u8; 32];
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    let ia = seed(&a);
    seed(&b);
    let giro = |v: &Vault| {
        v.list_accounts()
            .unwrap()
            .into_iter()
            .find(|x| x.name == "Giro")
            .unwrap()
    };
    assert!(a.set_account_symbol(ia[0], " ".into()).is_err());
    assert!(a.set_account_symbol(999, "house".into()).is_err());
    a.set_account_symbol(ia[0], "house".into()).unwrap();
    assert_eq!(giro(&a).sf_symbol, "house");
    tick();
    b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    assert_eq!(giro(&b).sf_symbol, "house");
    // a later choice on the other device wins back
    let gb = giro(&b).id;
    b.set_account_symbol(gb, "briefcase".into()).unwrap();
    tick();
    a.merge_other_vault(b.file_path(), key.clone()).unwrap();
    assert_eq!(giro(&a).sf_symbol, "briefcase");
    // merging the older state again changes nothing
    b.merge_other_vault(a.file_path(), key).unwrap();
    assert_eq!(giro(&b).sf_symbol, "briefcase");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn account_symbol_reset_returns_to_kind_symbol_and_syncs() {
    // #169 on top of #183: the choice lives in `sf_symbol` + `symbol_ms`
    let dir = temp_dir("symbol-reset");
    let key = vec![7u8; 32];
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    let ia = seed(&a);
    seed(&b);
    let giro = |v: &Vault| {
        v.list_accounts()
            .unwrap()
            .into_iter()
            .find(|x| x.name == "Giro")
            .unwrap()
    };
    assert!(a.reset_account_symbol(999).is_err());
    a.set_account_symbol(ia[0], "car".into()).unwrap();
    tick();
    b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    assert_eq!(giro(&b).sf_symbol, "car");
    // back to the kind's symbol on B – and A follows
    let gb = giro(&b).id;
    b.reset_account_symbol(gb).unwrap();
    assert_eq!(giro(&b).sf_symbol, AccountKind::Checking.sf_symbol());
    tick();
    a.merge_other_vault(b.file_path(), key).unwrap();
    assert_eq!(giro(&a).sf_symbol, AccountKind::Checking.sf_symbol());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn default_colors_distinct_up_to_twelve_and_respect_choices() {
    let dir = temp_dir("colors12");
    let v = open(&dir, "a.db");
    let ids = seed(&v);
    let add = |n: usize| {
        let db = v.db().unwrap();
        for i in 0..n {
            db.execute(
                "INSERT INTO accounts(group_id, external_ref, name) VALUES (1, ?1, ?1)",
                [format!("X{i}-{}", uuid::Uuid::new_v4())],
            )
            .unwrap();
        }
    };
    let counts = |v: &Vault| {
        let mut m: HashMap<String, usize> = HashMap::new();
        for a in v.list_accounts().unwrap() {
            *m.entry(a.color_hex).or_default() += 1;
        }
        m
    };
    // a chosen colour is reserved: no default account gets it
    v.set_account_color(ids[0], Some(super::ACCOUNT_COLOR_PALETTE[3].into()))
        .unwrap();
    add(9); // 12 accounts
    let c = counts(&v);
    assert_eq!(c.len(), 12, "12 accounts → 12 different colours");
    assert_eq!(c[super::ACCOUNT_COLOR_PALETTE[3]], 1);
    add(1); // 13th account: colours repeat as evenly as possible
    let c = counts(&v);
    assert_eq!(c.len(), 12);
    assert_eq!(c.values().max(), Some(&2));
    let _ = std::fs::remove_dir_all(dir);
}

/// Creates a group and gives it a fixed uuid, so a test knows which one
/// survives when two same-name groups are combined (the lower uuid).
fn group_with_uuid(v: &Vault, name: &str, uuid: &str) -> String {
    let made = v.create_user_group(name.into(), "folder".into()).unwrap();
    v.db()
        .unwrap()
        .execute(
            "UPDATE user_groups SET uuid = ?2 WHERE uuid = ?1",
            params![made, uuid],
        )
        .unwrap();
    uuid.to_string()
}

fn live_groups(v: &Vault) -> Vec<(String, String)> {
    v.list_user_groups()
        .unwrap()
        .into_iter()
        .filter(|g| !g.is_ungrouped)
        .map(|g| (g.uuid, g.name))
        .collect()
}

#[test]
fn same_name_groups_combine_on_sync() {
    let dir = temp_dir("samename");
    let key = vec![7u8; 32];
    let (a, b, c) = (open(&dir, "a.db"), open(&dir, "b.db"), open(&dir, "c.db"));
    let (ia, ib, ic) = (seed(&a), seed(&b), seed(&c));
    let keep = "00000000-0000-4000-8000-000000000000";
    let lose = "ffffffff-ffff-4fff-8fff-ffffffffffff";

    // both devices create "Privat" independently (different case even)
    group_with_uuid(&a, "Privat", keep);
    a.move_account_to_group(ia[0], Some(keep.into()), None)
        .unwrap();
    tick();
    group_with_uuid(&b, "privat", lose);
    b.update_user_group(lose.into(), "privat".into(), "person".into(), false)
        .unwrap();
    b.move_account_to_group(ib[2], Some(lose.into()), None)
        .unwrap();
    // C only knows B's group so far and puts Depot into it
    c.merge_other_vault(b.file_path(), key.clone()).unwrap();
    tick();
    c.move_account_to_group(ic[1], Some(lose.into()), None)
        .unwrap();
    tick();

    // A ← B, B ← A: one group, same uuid, newest settings, both accounts
    a.merge_other_vault(b.file_path(), key.clone()).unwrap();
    b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    for v in [&a, &b] {
        assert_eq!(live_groups(v), vec![(keep.into(), "privat".into())]);
        let g = &v.list_user_groups().unwrap()[0];
        assert_eq!(g.sf_symbol, "person");
        assert!(!g.include_in_total);
        let mut accs: Vec<_> = g.accounts.iter().map(|x| x.name.clone()).collect();
        accs.sort();
        assert_eq!(accs, s(&["Giro", "Visa"]));
    }
    assert_eq!(synced_state(&a), synced_state(&b));
    // C hasn't seen the combination yet: its later placement into the old
    // group follows the pointer instead of dropping to "Ohne Gruppe"
    c.merge_other_vault(a.file_path(), key.clone()).unwrap();
    a.merge_other_vault(c.file_path(), key.clone()).unwrap();
    for v in [&a, &c] {
        assert_eq!(live_groups(v), vec![(keep.into(), "privat".into())]);
        assert_eq!(v.list_user_groups().unwrap()[0].accounts.len(), 3);
    }
    // the group is no longer stuck: saving it (same name) works, and so does
    // a case-only rename
    a.update_user_group(keep.into(), "privat".into(), "house".into(), true)
        .unwrap();
    a.update_user_group(keep.into(), "Privat".into(), "house".into(), true)
        .unwrap();
    assert_eq!(live_groups(&a), vec![(keep.into(), "Privat".into())]);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn deleted_group_stays_deleted_after_later_rename() {
    let dir = temp_dir("delwins");
    let key = vec![7u8; 32];
    let (a, b) = (open(&dir, "a.db"), open(&dir, "b.db"));
    let (ia, ib) = (seed(&a), seed(&b));
    let g = a.create_user_group("Haus".into(), "house".into()).unwrap();
    a.move_account_to_group(ia[0], Some(g.clone()), None)
        .unwrap();
    b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    tick();

    a.delete_user_group(g.clone()).unwrap();
    tick();
    // B, not synced yet, renames the group and moves another account in
    b.update_user_group(g.clone(), "Wohnung".into(), "house".into(), true)
        .unwrap();
    b.move_account_to_group(ib[1], Some(g.clone()), None)
        .unwrap();
    tick();

    a.merge_other_vault(b.file_path(), key.clone()).unwrap();
    b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    assert_eq!(synced_state(&a), synced_state(&b));
    for v in [&a, &b] {
        let gs = v.list_user_groups().unwrap();
        assert_eq!(gs.len(), 1, "deleted group came back");
        assert!(gs[0].is_ungrouped);
        assert_eq!(gs[0].accounts.len(), 3);
    }
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn user_merges_groups_and_other_devices_follow() {
    let dir = temp_dir("usermerge");
    let key = vec![7u8; 32];
    let (a, b) = (open(&dir, "a.db"), open(&dir, "b.db"));
    let ia = seed(&a);
    seed(&b);
    let privat = a
        .create_user_group("Privat".into(), "person".into())
        .unwrap();
    let familie = a
        .create_user_group("Familie".into(), "person.2".into())
        .unwrap();
    a.move_account_to_group(ia[0], Some(privat.clone()), None)
        .unwrap();
    a.move_account_to_group(ia[1], Some(familie.clone()), None)
        .unwrap();
    a.move_account_to_group(ia[2], Some(familie.clone()), None)
        .unwrap();
    b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    tick();

    a.merge_user_groups(familie.clone(), privat.clone())
        .unwrap();
    assert_eq!(
        names(&a),
        vec![("Privat".into(), s(&["Giro", "Depot", "Visa"]))]
    );
    b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    a.merge_other_vault(b.file_path(), key.clone()).unwrap();
    for v in [&a, &b] {
        assert_eq!(
            names(v),
            vec![("Privat".into(), s(&["Giro", "Depot", "Visa"]))]
        );
    }
    assert!(a.merge_user_groups(familie, privat).is_err());
    let _ = std::fs::remove_dir_all(dir);
}

fn user_version(v: &Vault) -> i64 {
    v.db()
        .unwrap()
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap()
}

fn columns(v: &Vault, table: &str) -> Vec<String> {
    let db = v.db().unwrap();
    let mut st = db
        .prepare("SELECT name FROM pragma_table_info(?1)")
        .unwrap();
    st.query_map([table], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn total(v: &Vault) -> i64 {
    v.balance_history(vec![], 1)
        .unwrap()
        .last()
        .unwrap()
        .balance_cents
}

/// Takes the v7 additions out again, leaving the schema a v6 build (GiroCrab
/// ≤ 0.5.x, `main` before this PR) writes: no `user_groups` table, none of
/// the new `accounts` columns, `user_version` 6.
fn downgrade_to_v6(v: &Vault) {
    let db = v.db().unwrap();
    db.execute_batch("DROP TABLE user_groups; DROP TABLE sync_log;")
        .unwrap();
    for (col, _) in super::ACCOUNT_COLUMNS {
        db.execute_batch(&format!("ALTER TABLE accounts DROP COLUMN {col};"))
            .unwrap();
    }
    db.execute_batch("PRAGMA user_version = 6;").unwrap();
}

/// (a) A vault written by a v6 build is migrated in place when the new build
/// opens it: nothing is lost, all accounts land in "Ohne Gruppe" and count
/// towards the total, and opening it again changes nothing.
#[test]
fn v6_vault_is_migrated_by_this_build() {
    let dir = temp_dir("v6");
    let v = open(&dir, "vault.db");
    let ids = seed(&v);
    downgrade_to_v6(&v);
    assert_eq!(user_version(&v), 6);
    assert!(!columns(&v, "accounts").contains(&"user_group_uuid".to_string()));
    assert!(columns(&v, "user_groups").is_empty());
    // what a v6 build shows as the total: all accounts
    let before: i64 = v
        .db()
        .unwrap()
        .query_row("SELECT sum(balance_cents) FROM accounts", [], |r| r.get(0))
        .unwrap();
    drop(v);

    for round in 0..2 {
        let v = open(&dir, "vault.db");
        assert_eq!(
            user_version(&v),
            crate::vault::SCHEMA_VERSION,
            "round {round}"
        );
        let cols = columns(&v, "accounts");
        for (col, _) in super::ACCOUNT_COLUMNS {
            assert!(cols.contains(&col.to_string()), "accounts.{col}");
        }
        assert!(columns(&v, "user_groups").contains(&"merged_into".to_string()));
        assert_eq!(total(&v), before, "visible total unchanged");
        let accs = v.list_accounts().unwrap();
        assert_eq!(accs.len(), 3);
        assert!(accs.iter().all(|a| a.in_total && !a.color_hex.is_empty()));
        if round == 0 {
            assert!(accs.iter().all(|a| a.user_group_uuid.is_none()));
            assert_eq!(
                names(&v),
                vec![("Ohne Gruppe".into(), s(&["Giro", "Visa", "Depot"]))]
            );
            // usable right away
            let g = v
                .create_user_group("Privat".into(), "person".into())
                .unwrap();
            v.move_account_to_group(ids[0], Some(g), None).unwrap();
        } else {
            // opening again changes nothing
            assert_eq!(names(&v)[0], ("Privat".into(), s(&["Giro"])));
        }
    }
    let _ = std::fs::remove_dir_all(dir);
}

/// (c) A v7 vault opened and written by a v6 build, then opened by this build
/// again. A v6 build never lowers `user_version` (it only migrates when the
/// version is below 6) and writes accounts with explicit column lists, so the
/// v7 columns keep their values or defaults. Simulated here with the
/// statements a v6 build runs: a rename (`rename_account` without `name_ms`)
/// and a new account from a bank sync (no group placement).
#[test]
fn v7_vault_survives_a_round_trip_through_a_v6_build() {
    let dir = temp_dir("roundtrip");
    let v = open(&dir, "vault.db");
    let ids = seed(&v);
    let firma = v
        .create_user_group("Firma".into(), "briefcase".into())
        .unwrap();
    v.move_account_to_group(ids[0], Some(firma.clone()), None)
        .unwrap();
    v.update_user_group(firma.clone(), "Firma".into(), "briefcase".into(), false)
        .unwrap();
    v.set_account_color(ids[0], Some("#DC2626".into())).unwrap();
    drop(v);

    // --- the v6 build ---
    {
        let v = open(&dir, "vault.db");
        let db = v.db().unwrap();
        db.execute(
            "UPDATE accounts SET name = 'Geschäftskonto' WHERE id = ?1",
            [ids[0]],
        )
        .unwrap();
        db.execute(
            "INSERT INTO accounts(connection_id, group_id, external_ref, name, kind, balance_cents)
             SELECT connection_id, group_id, 'A4', 'Tagesgeld', 'savings', 1000_00 FROM accounts WHERE id = ?1",
            [ids[0]],
        )
        .unwrap();
    }

    // --- back in this build ---
    let v = open(&dir, "vault.db");
    assert_eq!(user_version(&v), crate::vault::SCHEMA_VERSION);
    let gs = v.list_user_groups().unwrap();
    assert_eq!(gs[0].uuid, firma);
    assert!(!gs[0].include_in_total);
    let mut listed = names(&v);
    listed[1].1.sort();
    assert_eq!(
        listed,
        vec![
            ("Firma".into(), s(&["Geschäftskonto"])),
            ("Ohne Gruppe".into(), s(&["Depot", "Tagesgeld", "Visa"]))
        ]
    );
    let accs = v.list_accounts().unwrap();
    let giro = accs.iter().find(|a| a.id == ids[0]).unwrap();
    assert_eq!(giro.color_hex, "#DC2626");
    // the account the v6 build added counts towards the total; Firma doesn't
    assert_eq!(total(&v), 5_000_00 - 50_00 + 1000_00);
    let _ = std::fs::remove_dir_all(dir);
}

/// Known limit, pinned: a rename made by a v6 build carries no `name_ms`, so
/// an older but stamped rename from a v7 device wins the next merge.
#[test]
fn v6_rename_loses_against_a_stamped_rename_on_merge() {
    let dir = temp_dir("v6rename");
    let key = vec![7u8; 32];
    let (a, b) = (open(&dir, "a.db"), open(&dir, "b.db"));
    let ia = seed(&a);
    let ib = seed(&b);
    b.rename_account(ib[0], "Giro (B)".into()).unwrap();
    tick();
    // later, a v6 build renames the same account on A without a stamp
    a.db()
        .unwrap()
        .execute(
            "UPDATE accounts SET name = 'Giro (A, v6)' WHERE id = ?1",
            [ia[0]],
        )
        .unwrap();
    a.merge_other_vault(b.file_path(), key).unwrap();
    let name = |v: &Vault, id: i64| {
        v.list_accounts()
            .unwrap()
            .into_iter()
            .find(|x| x.id == id)
            .unwrap()
            .name
    };
    assert_eq!(name(&a, ia[0]), "Giro (B)");
    let _ = std::fs::remove_dir_all(dir);
}

/// Everything that syncs, keyed by synced identities only: both devices
/// must end up byte-for-byte equal here after merging both ways.
#[allow(clippy::type_complexity)]
fn synced_state(
    v: &Vault,
) -> (
    Vec<(
        String,
        String,
        String,
        i64,
        i64,
        Option<i64>,
        Option<String>,
    )>,
    Vec<(String, Option<String>, i64, i64, String)>,
) {
    let db = v.db().unwrap();
    let groups = db
        .prepare(
            "SELECT uuid, name, sf_symbol, include_in_total, sort_order, deleted_ms, merged_into
             FROM user_groups ORDER BY uuid",
        )
        .unwrap()
        .query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
                r.get(6)?,
            ))
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let accounts = db
        .prepare(
            "SELECT external_ref, user_group_uuid, user_sort_order, placement_ms, name
             FROM accounts ORDER BY external_ref",
        )
        .unwrap()
        .query_map([], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    (groups, accounts)
}

fn sync_both_ways(a: &Vault, b: &Vault) {
    let key = vec![7u8; 32];
    a.merge_other_vault(b.file_path(), key.clone()).unwrap();
    b.merge_other_vault(a.file_path(), key).unwrap();
}

/// Review point 3: edits of different fields on two devices both survive.
#[test]
fn concurrent_edits_of_different_fields_both_survive() {
    let dir = temp_dir("fields");
    let (a, b) = (open(&dir, "a.db"), open(&dir, "b.db"));
    seed(&a);
    seed(&b);
    let g = a
        .create_user_group("Privat".into(), "folder".into())
        .unwrap();
    let h = a
        .create_user_group("Firma".into(), "folder".into())
        .unwrap();
    sync_both_ways(&a, &b);
    tick();
    // A renames and reorders; later B changes symbol and total flag
    a.update_user_group(g.clone(), "Familie".into(), "folder".into(), true)
        .unwrap();
    a.reorder_user_groups(vec![h.clone(), g.clone()]).unwrap();
    tick();
    b.update_user_group(g.clone(), "Privat".into(), "house".into(), false)
        .unwrap();
    tick();
    sync_both_ways(&a, &b);
    for v in [&a, &b] {
        let gs = live_groups(v);
        assert_eq!(
            gs,
            vec![(h.clone(), "Firma".into()), (g.clone(), "Familie".into())]
        );
        let fam = v
            .list_user_groups()
            .unwrap()
            .into_iter()
            .find(|x| x.uuid == g)
            .unwrap();
        assert_eq!(fam.sf_symbol, "house");
        assert!(!fam.include_in_total);
    }
    assert_eq!(synced_state(&a), synced_state(&b));
    let _ = std::fs::remove_dir_all(dir);
}

/// Review point 4: sort positions that collide after a merge still give
/// the same order on every device (no local ids in the tie-break).
#[test]
fn order_inside_a_group_is_the_same_on_every_device() {
    let dir = temp_dir("order");
    let (a, b) = (open(&dir, "a.db"), open(&dir, "b.db"));
    let ia = seed(&a);
    let ib = seed(&b);
    // Giro and Visa of the same kind, and B's local ids in the other order
    for v in [&a, &b] {
        v.db()
            .unwrap()
            .execute(
                "UPDATE accounts SET kind = 'checking' WHERE external_ref = 'A3'",
                [],
            )
            .unwrap();
    }
    b.db()
        .unwrap()
        .execute(
            "UPDATE accounts SET id = id + 100 WHERE external_ref = 'A1'",
            [],
        )
        .unwrap();
    let ib = [ib[0] + 100, ib[1], ib[2]];
    let g = a.create_user_group("Alle".into(), "folder".into()).unwrap();
    sync_both_ways(&a, &b);
    // each device puts a different account of that kind first → both at 0
    a.move_account_to_group(ia[0], Some(g.clone()), Some(0))
        .unwrap();
    b.move_account_to_group(ib[2], Some(g.clone()), Some(0))
        .unwrap();
    sync_both_ways(&a, &b);
    let ga = names(&a);
    assert_eq!(ga[0].1.len(), 2, "both accounts in the group");
    assert_eq!(ga, names(&b));
    assert_eq!(synced_state(&a), synced_state(&b));
    let _ = std::fs::remove_dir_all(dir);
}

/// (name, depth, sum, own accounts) of all named groups, in list order.
fn tree(v: &Vault) -> Vec<(String, u32, i64, Vec<String>)> {
    v.list_user_groups()
        .unwrap()
        .into_iter()
        .filter(|g| !g.is_ungrouped)
        .map(|g| {
            (
                g.name,
                g.depth,
                g.balance_cents,
                g.accounts.into_iter().map(|a| a.name).collect(),
            )
        })
        .collect()
}

fn group(v: &Vault, name: &str) -> crate::models::UserGroup {
    v.list_user_groups()
        .unwrap()
        .into_iter()
        .find(|g| g.name == name)
        .unwrap()
}

#[test]
fn subgroups_nest_sum_up_and_inherit_the_total_switch() {
    let dir = temp_dir("nest");
    let v = open(&dir, "a.db");
    let ids = seed(&v);
    let new = |n: &str| v.create_user_group(n.into(), "folder".into()).unwrap();
    let (immo, nsu, hn, privat) = (
        new("Immobilien"),
        new("ETW Neckarsulm"),
        new("ETW Heilbronn"),
        new("Privat"),
    );
    v.set_user_group_parent(nsu.clone(), Some(immo.clone()))
        .unwrap();
    v.set_user_group_parent(hn.clone(), Some(immo.clone()))
        .unwrap();
    v.move_account_to_group(ids[0], Some(nsu.clone()), None)
        .unwrap();
    v.move_account_to_group(ids[1], Some(hn.clone()), None)
        .unwrap();
    v.move_account_to_group(ids[2], Some(immo.clone()), None)
        .unwrap();
    assert_eq!(
        tree(&v),
        vec![
            ("Immobilien".into(), 0, 5_050_00, s(&["Visa"])),
            ("ETW Neckarsulm".into(), 1, 100_00, s(&["Giro"])),
            ("ETW Heilbronn".into(), 1, 5_000_00, s(&["Depot"])),
            ("Privat".into(), 0, 0, vec![]),
        ]
    );
    assert_eq!(group(&v, "ETW Heilbronn").parent_uuid, Some(immo.clone()));

    // not into itself or its own subgroups; unknown groups are rejected
    assert!(v
        .set_user_group_parent(immo.clone(), Some(immo.clone()))
        .is_err());
    assert!(v
        .set_user_group_parent(immo.clone(), Some(nsu.clone()))
        .is_err());
    assert!(v
        .set_user_group_parent(immo.clone(), Some("nope".into()))
        .is_err());
    // deeper nesting, and back to the top level
    v.set_user_group_parent(immo.clone(), Some(privat.clone()))
        .unwrap();
    assert_eq!(
        tree(&v)
            .iter()
            .map(|g| (g.0.as_str(), g.1, g.2))
            .collect::<Vec<_>>(),
        vec![
            ("Privat", 0, 5_050_00),
            ("Immobilien", 1, 5_050_00),
            ("ETW Neckarsulm", 2, 100_00),
            ("ETW Heilbronn", 2, 5_000_00),
        ]
    );
    v.set_user_group_parent(immo.clone(), None).unwrap();

    // excluding the parent excludes the accounts of its subgroups too
    v.update_user_group(immo.clone(), "Immobilien".into(), "house".into(), false)
        .unwrap();
    assert!(v.list_accounts().unwrap().iter().all(|a| !a.in_total));
    let hn_group = group(&v, "ETW Heilbronn");
    assert!(hn_group.include_in_total && !hn_group.in_total);
    assert_eq!(
        v.balance_history(vec![], 1)
            .unwrap()
            .last()
            .unwrap()
            .balance_cents,
        0
    );
    v.update_user_group(immo.clone(), "Immobilien".into(), "house".into(), true)
        .unwrap();

    // deleting a subgroup moves its accounts up into the parent …
    v.delete_user_group(nsu).unwrap();
    assert_eq!(
        tree(&v)[0],
        ("Immobilien".into(), 0, 5_050_00, s(&["Visa", "Giro"]))
    );
    // … and deleting the parent moves its subgroups up, its accounts to "Ohne Gruppe"
    v.delete_user_group(immo).unwrap();
    assert_eq!(
        names(&v),
        vec![
            ("ETW Heilbronn".to_string(), s(&["Depot"])),
            ("Privat".to_string(), vec![]),
            ("Ohne Gruppe".to_string(), s(&["Visa", "Giro"])),
        ]
    );
    assert_eq!(group(&v, "ETW Heilbronn").depth, 0);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn nesting_syncs_and_survives_conflicts() {
    let dir = temp_dir("nest-sync");
    let (a, b) = (open(&dir, "a.db"), open(&dir, "b.db"));
    let (ia, _) = (seed(&a), seed(&b));
    let new = |n: &str| a.create_user_group(n.into(), "folder".into()).unwrap();
    let (x, y, z) = (new("X"), new("Y"), new("Z"));
    a.move_account_to_group(ia[0], Some(y.clone()), None)
        .unwrap();
    a.set_user_group_parent(y.clone(), Some(x.clone())).unwrap();
    tick();
    sync_both_ways(&a, &b);
    let shape = |v: &Vault| {
        tree(v)
            .into_iter()
            .map(|g| (g.0, g.1, g.2))
            .collect::<Vec<_>>()
    };
    let nested = vec![
        ("X".to_string(), 0, 100_00),
        ("Y".to_string(), 1, 100_00),
        ("Z".to_string(), 0, 0),
    ];
    assert_eq!(shape(&a), nested);
    assert_eq!(shape(&b), nested);

    // both devices nest two groups into each other: no loop, same tree on both
    a.set_user_group_parent(z.clone(), Some(y.clone())).unwrap();
    tick();
    b.set_user_group_parent(x.clone(), Some(z.clone())).unwrap();
    tick();
    sync_both_ways(&a, &b);
    assert_eq!(shape(&a), shape(&b));
    assert_eq!(shape(&a).len(), 3, "every group is still listed");
    assert!(shape(&a).iter().any(|g| g.1 == 0));

    // a parent deleted on one device: its subgroups move up on the other
    b.set_user_group_parent(x.clone(), None).unwrap();
    b.set_user_group_parent(z.clone(), None).unwrap();
    tick();
    sync_both_ways(&a, &b);
    assert_eq!(shape(&a), nested);
    // (B still has Y inside X when A deletes X)
    a.delete_user_group(x).unwrap();
    tick();
    sync_both_ways(&a, &b);
    let flat = vec![("Y".to_string(), 0, 100_00), ("Z".to_string(), 0, 0)];
    assert_eq!(shape(&a), flat);
    assert_eq!(shape(&b), flat);

    // combining groups takes the subgroups along
    a.set_user_group_parent(y.clone(), Some(z.clone())).unwrap();
    let w = a.create_user_group("W".into(), "folder".into()).unwrap();
    a.merge_user_groups(z, w).unwrap();
    tick();
    sync_both_ways(&a, &b);
    let merged = vec![("W".to_string(), 0, 100_00), ("Y".to_string(), 1, 100_00)];
    assert_eq!(shape(&a), merged);
    assert_eq!(shape(&b), merged);
    let _ = std::fs::remove_dir_all(dir);
}

fn archived(v: &Vault, name: &str) -> Option<i64> {
    v.list_accounts()
        .unwrap()
        .into_iter()
        .find(|a| a.name == name)
        .unwrap()
        .archived_unix
}

#[test]
fn archived_account_keeps_group_and_history_but_leaves_total_and_rules() {
    let dir = temp_dir("archive");
    let v = open(&dir, "a.db");
    let ids = seed(&v);
    let umzug = v
        .create_user_group("Depotumzug".into(), "folder".into())
        .unwrap();
    v.move_account_to_group(ids[1], Some(umzug.clone()), None)
        .unwrap();
    {
        let db = v.db().unwrap();
        for (acc, ext) in [(ids[0], "g1"), (ids[1], "d1")] {
            db.execute(
                "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, counterparty)
                 VALUES (?1, ?2, date('now', '-1 day'), -10_00, 'Bäckerei Krume')",
                params![acc, ext],
            )
            .unwrap();
        }
        db.execute("INSERT INTO categories(name) VALUES ('Essen')", [])
            .unwrap();
    }
    let total = |v: &Vault| {
        v.balance_history(vec![], 1)
            .unwrap()
            .last()
            .unwrap()
            .balance_cents
    };
    assert_eq!(total(&v), 5_050_00);
    assert!(v.set_account_archived(999, true).is_err());

    v.set_account_archived(ids[1], true).unwrap();
    let depot = v
        .list_accounts()
        .unwrap()
        .into_iter()
        .find(|a| a.id == ids[1])
        .unwrap();
    let since = depot.archived_unix.expect("archived");
    assert!(!depot.in_total);
    assert_eq!(depot.transaction_count, 1, "bookings kept");
    assert_eq!(
        total(&v),
        50_00,
        "archived account leaves the overall total"
    );
    // still a member of its group, but no longer in its sum (GiroCrab/GiroCrab#208);
    // an explicit selection keeps its history
    let groups = v.list_user_groups().unwrap();
    let g = groups.iter().find(|g| g.uuid == umzug).unwrap();
    assert_eq!(g.accounts.len(), 1);
    assert_eq!(g.balance_cents, 0);
    let hist = v.balance_history(vec![ids[1]], 3).unwrap();
    assert_eq!(hist.last().unwrap().balance_cents, 5_000_00);
    assert_eq!(hist.first().unwrap().balance_cents, 5_010_00);
    // archiving again keeps the date
    tick();
    v.set_account_archived(ids[1], true).unwrap();
    assert_eq!(archived(&v, "Depot"), Some(since));

    // rules only touch bookings of active accounts
    let cat: i64 = v
        .db()
        .unwrap()
        .query_row("SELECT id FROM categories WHERE name = 'Essen'", [], |r| {
            r.get(0)
        })
        .unwrap();
    v.db()
        .unwrap()
        .execute(
            "INSERT INTO rules(name, category_id, pattern) VALUES ('Bäcker', ?1, 'krume')",
            [cat],
        )
        .unwrap();
    assert_eq!(v.apply_rules(false).unwrap(), 1);
    let cats = |v: &Vault| -> Vec<(String, Option<i64>)> {
        let db = v.db().unwrap();
        let mut st = db
            .prepare("SELECT external_id, category_id FROM transactions ORDER BY external_id")
            .unwrap();
        let rows = st
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        rows
    };
    assert_eq!(
        cats(&v),
        vec![("d1".into(), None), ("g1".into(), Some(cat))]
    );

    // reactivated: back in the total, rules apply again
    v.set_account_archived(ids[1], false).unwrap();
    assert_eq!(archived(&v, "Depot"), None);
    assert_eq!(total(&v), 5_050_00);
    assert_eq!(v.apply_rules(false).unwrap(), 1);
    assert_eq!(cats(&v)[0].1, Some(cat));
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn archived_state_syncs_and_newest_change_wins() {
    let dir = temp_dir("archive-sync");
    let (a, b) = (open(&dir, "a.db"), open(&dir, "b.db"));
    let key = vec![7u8; 32];
    let (ia, _) = (seed(&a), seed(&b));
    a.set_account_archived(ia[0], true).unwrap();
    tick();
    b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    assert_eq!(archived(&b, "Giro"), archived(&a, "Giro"));
    assert!(archived(&b, "Giro").is_some());
    assert_eq!(archived(&b, "Visa"), None);

    // reactivated on B later: wins on A, and an old archive never comes back
    let gb = b
        .list_accounts()
        .unwrap()
        .into_iter()
        .find(|x| x.name == "Giro")
        .unwrap()
        .id;
    b.set_account_archived(gb, false).unwrap();
    tick();
    a.merge_other_vault(b.file_path(), key.clone()).unwrap();
    assert_eq!(archived(&a, "Giro"), None);
    b.merge_other_vault(a.file_path(), key.clone()).unwrap();
    assert_eq!(archived(&b, "Giro"), None);

    // an account new to the other device arrives archived
    let c = open(&dir, "c.db");
    a.set_account_archived(ia[2], true).unwrap();
    c.merge_other_vault(a.file_path(), key).unwrap();
    assert!(archived(&c, "Visa").is_some());
    assert_eq!(archived(&c, "Giro"), None);
    let _ = std::fs::remove_dir_all(dir);
}
