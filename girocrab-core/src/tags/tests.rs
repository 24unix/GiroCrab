use std::sync::Arc;

use rusqlite::params;

use crate::models::BookingFilter;
use crate::test_support::TempDir;
use crate::vault::Vault;

const KEY: [u8; 32] = [7u8; 32];

fn open(dir: &TempDir, file: &str) -> Arc<Vault> {
    Vault::open(dir.join(file).to_string_lossy().into(), KEY.to_vec()).unwrap()
}

/// One account `A1` with the bookings `T1`..`Tn` (same on every vault, so a
/// merge matches them by external id).
fn seed(v: &Vault, n: i64) -> Vec<i64> {
    let c = v.db().unwrap();
    c.execute(
        "INSERT OR IGNORE INTO account_groups(name) VALUES ('G')",
        [],
    )
    .unwrap();
    c.execute(
        "INSERT OR IGNORE INTO accounts(group_id, external_ref, name) \
         VALUES ((SELECT id FROM account_groups WHERE name='G'), 'A1', 'Konto')",
        [],
    )
    .unwrap();
    (1..=n)
        .map(|i| {
            c.execute(
                "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, counterparty) \
                 VALUES ((SELECT id FROM accounts LIMIT 1), ?1, ?2, ?3, 'Laden')",
                params![format!("T{i}"), format!("2026-01-{i:02}"), -100 * i],
            )
            .unwrap();
            c.last_insert_rowid()
        })
        .collect()
}

fn id_of(v: &Vault, ext: &str) -> i64 {
    v.db()
        .unwrap()
        .query_row(
            "SELECT id FROM transactions WHERE external_id = ?1",
            [ext],
            |r| r.get(0),
        )
        .unwrap()
}

fn tag_id(v: &Vault, name: &str) -> i64 {
    v.list_tags()
        .unwrap()
        .into_iter()
        .find(|t| t.name == name)
        .unwrap_or_else(|| panic!("no tag {name}"))
        .id
}

/// Tag names of the booking with external id `ext`.
fn names(v: &Vault, ext: &str) -> Vec<String> {
    let id = id_of(v, ext);
    v.list_transactions(BookingFilter::default())
        .unwrap()
        .transactions
        .into_iter()
        .find(|b| b.id == id)
        .unwrap()
        .tags
        .into_iter()
        .map(|t| t.name)
        .collect()
}

fn listed(v: &Vault, filter: BookingFilter) -> Vec<i64> {
    let mut ids: Vec<i64> = v
        .list_transactions(filter)
        .unwrap()
        .transactions
        .iter()
        .map(|b| b.id)
        .collect();
    ids.sort();
    ids
}

fn merge(into: &Vault, from: &Vault) {
    into.merge_other_vault(from.file_path(), KEY.to_vec())
        .unwrap();
}

#[test]
fn migration_adds_tables_and_stamp() {
    let dir = TempDir::new("tags-schema");
    let v = open(&dir, "a.db");
    let db = v.db().unwrap();
    let n: i64 = db
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('tags', 'transaction_tags')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(n, 2);
    let stamp: i64 = db
        .query_row(
            "SELECT count(*) FROM pragma_table_info('transactions') WHERE name = 'tags_ms'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(stamp, 1);
    // idempotent: running the step again changes nothing
    super::tags_tables(&db).unwrap();
}

#[test]
fn create_returns_the_existing_tag_of_a_name() {
    let dir = TempDir::new("tags-create");
    let v = open(&dir, "a.db");
    let a = v
        .create_tag("  Urlaub   2026 ".into(), "#ff8800".into())
        .unwrap();
    assert_eq!(
        (a.name.as_str(), a.color_hex.as_str()),
        ("Urlaub 2026", "#FF8800")
    );
    let b = v.create_tag("urlaub 2026".into(), String::new()).unwrap();
    assert_eq!(a.id, b.id);
    assert_eq!(v.list_tags().unwrap().len(), 1);
    assert!(v.create_tag("   ".into(), String::new()).is_err());
    assert!(v.create_tag("x".repeat(65), String::new()).is_err());
    assert!(v.create_tag("Steuer".into(), "rot".into()).is_err());
}

#[test]
fn rename_refuses_a_taken_name() {
    let dir = TempDir::new("tags-rename");
    let v = open(&dir, "a.db");
    let a = v.create_tag("Sohn".into(), String::new()).unwrap();
    v.create_tag("Tochter".into(), String::new()).unwrap();
    assert!(v.rename_tag(a.id, "tochter".into()).is_err());
    // a change of case of its own name is fine
    assert_eq!(v.rename_tag(a.id, "SOHN".into()).unwrap().name, "SOHN");
}

#[test]
fn bookings_carry_and_filter_by_tags() {
    let dir = TempDir::new("tags-filter");
    let v = open(&dir, "a.db");
    let ids = seed(&v, 3);
    let trip = v.create_tag("Urlaub".into(), String::new()).unwrap().id;
    let tax = v.create_tag("Steuer".into(), String::new()).unwrap().id;
    v.set_booking_tags(ids[0], vec![trip, tax, trip]).unwrap();
    v.set_booking_tags(ids[1], vec![trip]).unwrap();
    assert_eq!(names(&v, "T1"), ["Urlaub", "Steuer"]);
    assert!(names(&v, "T3").is_empty());

    let only = |tag_ids: Vec<i64>| BookingFilter {
        tag_ids,
        ..Default::default()
    };
    assert_eq!(listed(&v, only(vec![trip])), [ids[0], ids[1]]);
    // several tags: every one of them (AND)
    assert_eq!(listed(&v, only(vec![trip, tax])), [ids[0]]);
    let untagged = BookingFilter {
        untagged_only: true,
        ..Default::default()
    };
    assert_eq!(listed(&v, untagged.clone()), [ids[2]]);
    assert_eq!(v.count_transactions(only(vec![trip])).unwrap(), 2);

    // counts per tag skip deleted bookings
    crate::sync_merge::soft_delete_booking(&v.db().unwrap(), ids[1]).unwrap();
    let counts: Vec<(String, u32)> = v
        .list_tags()
        .unwrap()
        .into_iter()
        .map(|t| (t.name, t.booking_count))
        .collect();
    assert_eq!(
        counts,
        [("Urlaub".to_string(), 1), ("Steuer".to_string(), 1)]
    );

    // clearing the set
    v.set_booking_tags(ids[0], vec![]).unwrap();
    assert_eq!(listed(&v, untagged), [ids[0], ids[2]]);
    assert!(v.set_booking_tags(ids[0], vec![999]).is_err());
}

#[test]
fn large_and_small_pages_load_the_same_tags() {
    let dir = TempDir::new("tags-large");
    let v = open(&dir, "a.db");
    let ids = seed(&v, 600);
    let a = v.create_tag("Firma".into(), String::new()).unwrap().id;
    let b = v.create_tag("Sohn".into(), String::new()).unwrap().id;
    v.set_booking_tags(ids[0], vec![b, a]).unwrap();
    v.set_booking_tags(ids[599], vec![b]).unwrap();
    let db = v.db().unwrap();
    let names = |m: &std::collections::HashMap<i64, Vec<super::BookingTag>>, id: i64| {
        m.get(&id)
            .map(|t| t.iter().map(|t| t.name.clone()).collect::<Vec<_>>())
            .unwrap_or_default()
    };
    // more than 500 ids: one pass over the links, filtered to the page
    let large = super::tags_for_bookings(&db, &ids[..599]).unwrap();
    assert_eq!(large.len(), 1);
    assert_eq!(names(&large, ids[0]), ["Firma", "Sohn"]);
    let small = super::tags_for_bookings(&db, &[ids[0], ids[599]]).unwrap();
    assert_eq!(names(&small, ids[0]), ["Firma", "Sohn"]);
    assert_eq!(names(&small, ids[599]), ["Sohn"]);
    assert!(super::tags_for_bookings(&db, &[]).unwrap().is_empty());
}

#[test]
fn multi_selection_reports_what_changed() {
    let dir = TempDir::new("tags-multi");
    let v = open(&dir, "a.db");
    let ids = seed(&v, 3);
    let t = v.create_tag("Familie".into(), String::new()).unwrap().id;
    v.set_booking_tags(ids[0], vec![t]).unwrap();
    let added = v.add_tag_to_bookings(ids.clone(), t).unwrap();
    assert_eq!(added, [ids[1], ids[2]]);
    let stamps: i64 = v
        .db()
        .unwrap()
        .query_row(
            "SELECT count(*) FROM transactions WHERE tags_ms > 0",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(stamps, 3);
    let removed = v.remove_tag_from_bookings(vec![ids[1], 999], t).unwrap();
    assert_eq!(removed, [ids[1]]);
    assert_eq!(v.list_tags().unwrap()[0].booking_count, 2);
}

#[test]
fn delete_and_merge_move_the_links() {
    let dir = TempDir::new("tags-delete");
    let v = open(&dir, "a.db");
    let ids = seed(&v, 3);
    let a = v.create_tag("Frau".into(), String::new()).unwrap().id;
    let b = v.create_tag("Ehefrau".into(), String::new()).unwrap().id;
    let c = v.create_tag("Corsa".into(), String::new()).unwrap().id;
    v.set_booking_tags(ids[0], vec![a, b]).unwrap();
    v.set_booking_tags(ids[1], vec![b, c]).unwrap();

    v.merge_tag_into(b, a).unwrap();
    assert_eq!(names(&v, "T1"), ["Frau"]);
    assert_eq!(names(&v, "T2"), ["Frau", "Corsa"]);
    assert!(v.merge_tag_into(a, a).is_err());

    v.delete_tag(c).unwrap();
    assert_eq!(names(&v, "T2"), ["Frau"]);
    assert_eq!(v.list_tags().unwrap().len(), 1);
    // a name used before gets a new tag, never the tombstone back
    let again = v.create_tag("Corsa".into(), String::new()).unwrap();
    assert_ne!(again.id, c);
    assert_eq!(again.booking_count, 0);
}

#[test]
fn csv_export_lists_tags_guarded() {
    let dir = TempDir::new("tags-csv");
    let v = open(&dir, "a.db");
    let ids = seed(&v, 1);
    let t = v.create_tag("=Steuer".into(), String::new()).unwrap().id;
    let u = v.create_tag("Urlaub".into(), String::new()).unwrap().id;
    v.set_booking_tags(ids[0], vec![t, u]).unwrap();
    let csv = v.export_bookings_csv(BookingFilter::default()).unwrap();
    assert!(csv.contains(";Währung;Tags\r\n"), "{csv}");
    assert!(csv.contains(";EUR;'=Steuer, Urlaub\r\n"), "{csv}");
}

#[test]
fn merge_brings_tags_and_tag_sets_over() {
    let dir = TempDir::new("tags-merge");
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    seed(&a, 2);
    seed(&b, 2);
    let trip = b.create_tag("Urlaub".into(), "#00AA00".into()).unwrap().id;
    b.set_booking_tags(id_of(&b, "T1"), vec![trip]).unwrap();

    merge(&a, &b);
    assert_eq!(names(&a, "T1"), ["Urlaub"]);
    assert_eq!(a.list_tags().unwrap()[0].color_hex, "#00AA00");
    // again: nothing changes
    let st = a.merge_other_vault(b.file_path(), KEY.to_vec()).unwrap();
    assert_eq!(st.bookings_updated, 0);
}

#[test]
fn same_name_on_two_devices_is_one_tag() {
    let dir = TempDir::new("tags-twins");
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    seed(&a, 2);
    seed(&b, 2);
    let ta = a.create_tag("Sohn".into(), String::new()).unwrap().id;
    a.set_booking_tags(id_of(&a, "T1"), vec![ta]).unwrap();
    let tb = b.create_tag("sohn".into(), String::new()).unwrap().id;
    b.set_booking_tags(id_of(&b, "T2"), vec![tb]).unwrap();

    merge(&a, &b);
    merge(&b, &a);
    for v in [&a, &b] {
        assert_eq!(v.list_tags().unwrap().len(), 1);
        assert_eq!(names(v, "T1").len(), 1);
        assert_eq!(names(v, "T2").len(), 1);
    }
}

#[test]
fn renamed_and_recreated_names_combine() {
    // a renames "Auto" to "Golf"; b creates a new "Golf" (another uuid)
    let dir = TempDir::new("tags-collide");
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    seed(&a, 2);
    seed(&b, 2);
    let car = a.create_tag("Auto".into(), String::new()).unwrap().id;
    a.set_booking_tags(id_of(&a, "T1"), vec![car]).unwrap();
    merge(&b, &a);
    a.rename_tag(car, "Golf".into()).unwrap();
    let golf = b.create_tag("Golf".into(), String::new()).unwrap().id;
    b.set_booking_tags(id_of(&b, "T2"), vec![golf]).unwrap();

    merge(&a, &b);
    merge(&b, &a);
    for v in [&a, &b] {
        let tags = v.list_tags().unwrap();
        assert_eq!(tags.len(), 1, "{tags:?}");
        assert_eq!(tags[0].name, "Golf");
        assert_eq!(names(v, "T1"), ["Golf"]);
        assert_eq!(names(v, "T2"), ["Golf"]);
    }
}

#[test]
fn newest_tag_set_wins_and_deletions_stay() {
    let dir = TempDir::new("tags-conflict");
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    seed(&a, 1);
    seed(&b, 1);
    let x = a.create_tag("Firma".into(), String::new()).unwrap().id;
    let y = a.create_tag("Privat".into(), String::new()).unwrap().id;
    a.set_booking_tags(id_of(&a, "T1"), vec![x]).unwrap();
    merge(&b, &a);

    // b edits later than a: b's set wins on both sides
    a.set_booking_tags(id_of(&a, "T1"), vec![x, y]).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(5));
    let by = tag_id(&b, "Privat");
    b.set_booking_tags(id_of(&b, "T1"), vec![by]).unwrap();
    merge(&a, &b);
    merge(&b, &a);
    assert_eq!(names(&a, "T1"), ["Privat"]);
    assert_eq!(names(&b, "T1"), ["Privat"]);

    // a deletes "Privat"; an older copy on b does not bring it back
    a.delete_tag(y).unwrap();
    merge(&a, &b);
    merge(&b, &a);
    for v in [&a, &b] {
        assert_eq!(
            v.list_tags()
                .unwrap()
                .into_iter()
                .map(|t| t.name)
                .collect::<Vec<_>>(),
            ["Firma"]
        );
        assert!(names(v, "T1").is_empty());
    }
}

#[test]
fn merged_tag_follows_on_the_other_device() {
    let dir = TempDir::new("tags-merged");
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    seed(&a, 2);
    seed(&b, 2);
    let wife = a.create_tag("Frau".into(), String::new()).unwrap().id;
    let spouse = a.create_tag("Ehefrau".into(), String::new()).unwrap().id;
    a.set_booking_tags(id_of(&a, "T1"), vec![spouse]).unwrap();
    merge(&b, &a);
    // b tags T2 with "Ehefrau" while a merges "Ehefrau" into "Frau"
    let b_spouse = tag_id(&b, "Ehefrau");
    b.set_booking_tags(id_of(&b, "T2"), vec![b_spouse]).unwrap();
    a.merge_tag_into(spouse, wife).unwrap();

    merge(&a, &b);
    merge(&b, &a);
    for v in [&a, &b] {
        assert_eq!(names(v, "T1"), ["Frau"]);
        assert_eq!(names(v, "T2"), ["Frau"]);
        assert_eq!(v.list_tags().unwrap().len(), 1);
    }
}

/// Front ends without UniFFI (Linux) send filters as JSON that predate the
/// tag fields; they must still decode.
#[cfg(feature = "serde")]
#[test]
fn filter_json_without_tag_fields_decodes() {
    let f: BookingFilter = serde_json::from_str(
        r#"{"account_ids":[1],"category_id":null,"include_subcategories":true,
            "uncategorized_only":false,"search":null,"date_from":null,"date_to":null,
            "limit":0,"offset":0,"scope":"All","merchant_key":null,"direction":"All",
            "checked":null,"whole_days":false}"#,
    )
    .unwrap();
    assert!(f.tag_ids.is_empty() && !f.untagged_only);
}
