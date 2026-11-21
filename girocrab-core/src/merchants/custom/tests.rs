use std::sync::Arc;

use rusqlite::params;

use crate::merchants::{FlowKind, MerchantRules};
use crate::models::{Booking, BookingFilter};
use crate::test_support::TempDir;
use crate::vault::Vault;

const KEY: [u8; 32] = [7u8; 32];
const SHOP_IBAN: &str = "DE12500105170648489890";

fn open(dir: &TempDir, file: &str) -> Arc<Vault> {
    Vault::open(dir.join(file).to_string_lossy().into(), KEY.to_vec()).unwrap()
}

/// A booking on the one account (created on first use).
fn book(v: &Vault, counterparty: &str, purpose: &str, iban: &str, date: &str, cents: i64) -> i64 {
    let c = v.db().unwrap();
    c.execute(
        "INSERT OR IGNORE INTO account_groups(name) VALUES ('G')",
        [],
    )
    .unwrap();
    // once: without a connection the unique index lets `INSERT OR IGNORE` add it again
    c.execute(
        "INSERT INTO accounts(group_id, external_ref, name) \
         SELECT (SELECT id FROM account_groups WHERE name='G'), 'A1', 'Konto' \
          WHERE NOT EXISTS (SELECT 1 FROM accounts WHERE external_ref = 'A1')",
        [],
    )
    .unwrap();
    c.execute(
        "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, counterparty, purpose, counterparty_iban) \
         VALUES ((SELECT id FROM accounts WHERE external_ref = 'A1'), lower(hex(randomblob(8))), ?1, ?2, ?3, ?4, ?5)",
        params![date, cents, counterparty, purpose, iban],
    )
    .unwrap();
    c.last_insert_rowid()
}

fn booking(v: &Vault, id: i64) -> Booking {
    v.list_transactions(BookingFilter::default())
        .unwrap()
        .transactions
        .into_iter()
        .find(|b| b.id == id)
        .unwrap()
}

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| w.to_string()).collect()
}

fn create(v: &Vault, name: &str, needles: &[&str], based_on: Option<&str>) -> String {
    v.save_custom_merchant(
        None,
        name.into(),
        strings(needles),
        based_on.map(Into::into),
    )
    .unwrap()
    .uuid
}

fn count(v: &Vault, sql: &str) -> i64 {
    v.db().unwrap().query_row(sql, [], |r| r.get(0)).unwrap()
}

#[test]
fn a_new_vault_uses_the_shared_bundled_rules() {
    let dir = TempDir::new("merchant-custom-new");
    let v = open(&dir, "v.db");
    let r = v.merchant_recognition().unwrap();
    assert!(r.enabled);
    assert!(r.custom.is_empty());
    assert_eq!(r.builtin.len(), crate::merchants::dictionary_size());
    assert!(r.builtin.iter().all(|m| m.enabled));
    let rewe = r.builtin.iter().find(|m| m.key == "rewe").unwrap();
    assert_eq!(rewe.needles, ["rewe"]);
    assert_eq!(rewe.merchant.name, "REWE");
    // needles shown without the padding of short brand words (" dm ")
    assert!(
        r.builtin
            .iter()
            .flat_map(|m| &m.needles)
            .all(|n| n.trim() == n)
    );
    let rules = v.merchant_rules(&v.db().unwrap()).unwrap();
    assert!(Arc::ptr_eq(&rules, MerchantRules::builtin()));
}

#[test]
fn saving_cleans_and_checks_the_input() {
    let dir = TempDir::new("merchant-custom-save");
    let v = open(&dir, "v.db");
    let m = v
        .save_custom_merchant(
            None,
            "  Mein   Laden ".into(),
            strings(&["  Muster GmbH ", "MUSTER*Shop", "", "--", "muster"]),
            None,
        )
        .unwrap();
    assert_eq!(m.name, "Mein Laden");
    assert_eq!(m.needles, ["muster", "muster shop"]);
    assert_eq!(m.based_on, "");
    assert_eq!(m.merchant.key, format!("u:{}", m.uuid));
    assert_eq!(m.merchant.name, "Mein Laden");
    let bad = |name: &str, needles: &[&str], based_on: Option<&str>| {
        v.save_custom_merchant(
            None,
            name.into(),
            strings(needles),
            based_on.map(Into::into),
        )
        .is_err()
    };
    assert!(bad(" ", &["muster"], None), "name missing");
    assert!(bad(&"x".repeat(81), &["muster"], None), "name too long");
    assert!(bad("Laden", &[], None), "no search word");
    assert!(bad("Laden", &["- / *"], None), "no letter or digit");
    assert!(
        bad("Laden", &["a", "- b -"], None),
        "no word of two letters"
    );
    assert!(
        bad("Laden", &[&"m".repeat(61)], None),
        "search word too long"
    );
    assert!(
        bad("Laden", &["muster"], Some("gibt-es-nicht")),
        "unknown original"
    );
    assert!(
        v.save_custom_merchant(
            Some("gibt-es-nicht".into()),
            "Laden".into(),
            strings(&["x1"]),
            None
        )
        .is_err()
    );
    assert!(
        v.set_builtin_merchant_enabled("gibt-es-nicht".into(), false)
            .is_err()
    );
    assert!(
        v.set_builtin_merchant_enabled(String::new(), false)
            .is_err()
    );
    assert_eq!(count(&v, "SELECT count(*) FROM custom_merchants"), 1);
}

#[test]
fn unchanged_saves_and_switches_write_nothing() {
    let dir = TempDir::new("merchant-custom-noop");
    let v = open(&dir, "v.db");
    let before = v.change_count();
    v.set_merchant_recognition_enabled(true).unwrap();
    v.set_builtin_merchant_enabled("rewe".into(), true).unwrap();
    assert_eq!(v.change_count(), before, "a switch never touched is on");
    let uuid = create(&v, "Laden", &["muster"], None);
    let before = v.change_count();
    v.save_custom_merchant(
        Some(uuid.clone()),
        " Laden ".into(),
        strings(&["MUSTER"]),
        None,
    )
    .unwrap();
    v.set_builtin_merchant_enabled("rewe".into(), true).unwrap();
    assert_eq!(v.change_count(), before);
    v.delete_custom_merchant(uuid.clone()).unwrap();
    let before = v.change_count();
    v.delete_custom_merchant(uuid.clone()).unwrap();
    assert_eq!(v.change_count(), before, "deleting twice");
    assert!(
        v.save_custom_merchant(Some(uuid), "Laden".into(), strings(&["muster"]), None)
            .is_err(),
        "a deleted merchant cannot be edited"
    );
}

#[test]
fn own_merchants_rename_bookings_but_keep_flow_and_series() {
    let dir = TempDir::new("merchant-custom-list");
    let v = open(&dir, "v.db");
    let etf = book(
        &v,
        "MSCI World USD (Acc)",
        "Kauf",
        "",
        "2026-10-02",
        -100_00,
    );
    let shop = book(
        &v,
        "REWE Markt GmbH",
        "Einkauf",
        SHOP_IBAN,
        "2026-10-03",
        -25_00,
    );
    let (etf_before, shop_before) = (booking(&v, etf), booking(&v, shop));
    assert_eq!(etf_before.merchant.key, "etf-core-msci-world");
    assert_eq!(etf_before.flow, FlowKind::Investment);

    let custom = v
        .save_custom_merchant(
            None,
            "MSCI World (anderer Anbieter)".into(),
            strings(&["MSCI World USD"]),
            None,
        )
        .unwrap();
    v.set_builtin_merchant_enabled("etf-core-msci-world".into(), false)
        .unwrap();
    let copy = create(&v, "Supermarkt um die Ecke", &["rewe markt"], Some("rewe"));

    let etf_now = booking(&v, etf);
    assert_eq!(etf_now.merchant.key, custom.merchant.key);
    assert_eq!(etf_now.merchant_name, "MSCI World (anderer Anbieter)");
    assert_eq!(
        etf_now.flow,
        FlowKind::Investment,
        "the flow reads the bundled kind"
    );
    assert_eq!(etf_now.recurrence_key, etf_before.recurrence_key);
    let shop_now = booking(&v, shop);
    assert_eq!(shop_now.merchant.key, format!("u:{copy}"));
    assert_eq!(shop_now.merchant_name, "Supermarkt um die Ecke");
    assert_eq!(shop_now.merchant_hex_color, shop_before.merchant_hex_color);
    assert_eq!(shop_now.merchant_svg_path, shop_before.merchant_svg_path);
    assert_eq!(shop_now.flow, shop_before.flow);
    assert_eq!(shop_now.recurrence_key, shop_before.recurrence_key);
    assert!(
        shop_now.recurrence_key.ends_with("|m:rewe"),
        "{}",
        shop_now.recurrence_key
    );

    // the merchant filter and history follow the shown merchant
    let filtered = v
        .list_transactions(BookingFilter {
            merchant_key: Some(shop_now.merchant.key.clone()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(
        filtered
            .transactions
            .iter()
            .map(|b| b.id)
            .collect::<Vec<_>>(),
        [shop]
    );
    let history = v
        .merchant_history(shop_now.merchant.key.clone(), shop_now.account_id)
        .unwrap();
    assert_eq!(history.all.count, 1);
    assert_eq!(history.all.name, "Supermarkt um die Ecke");

    // the copy replaces the original without touching its switch; editing renames,
    // deleting brings the original back
    let r = v.merchant_recognition().unwrap();
    let rewe = r.builtin.iter().find(|m| m.key == "rewe").unwrap();
    assert!(rewe.replaced && rewe.enabled);
    assert_eq!(
        count(&v, "SELECT count(*) FROM merchant_switches"),
        1,
        "only the ETF"
    );
    v.save_custom_merchant(
        Some(copy.clone()),
        "Eckladen".into(),
        strings(&["rewe"]),
        None,
    )
    .unwrap();
    assert_eq!(booking(&v, shop).merchant_name, "Eckladen");
    v.delete_custom_merchant(copy).unwrap();
    let r = v.merchant_recognition().unwrap();
    let rewe = r.builtin.iter().find(|m| m.key == "rewe").unwrap();
    assert!(!rewe.replaced && rewe.enabled);
    assert_eq!(r.custom.len(), 1);
    assert_eq!(booking(&v, shop).merchant.key, "rewe");
}

#[test]
fn a_copy_replaces_its_original_only_while_it_lives() {
    let dir = TempDir::new("merchant-custom-copies");
    let v = open(&dir, "v.db");
    let shop = book(&v, "REWE Markt GmbH", "", "", "2026-10-03", -25_00);
    let replaced = |v: &Vault| {
        let r = v.merchant_recognition().unwrap();
        let rewe = r.builtin.into_iter().find(|m| m.key == "rewe").unwrap();
        (rewe.replaced, rewe.enabled)
    };
    let a = create(&v, "Markt A", &["rewe a"], Some("rewe"));
    let b = create(&v, "Markt B", &["rewe b"], Some("rewe"));
    v.delete_custom_merchant(a).unwrap();
    assert_eq!(replaced(&v), (true, true), "one copy is left");
    assert_ne!(booking(&v, shop).merchant.key, "rewe");
    // a switch the user set stays when the last copy goes
    v.set_builtin_merchant_enabled("rewe".into(), false)
        .unwrap();
    v.delete_custom_merchant(b).unwrap();
    assert_eq!(replaced(&v), (false, false));
    assert_ne!(booking(&v, shop).merchant.key, "rewe");
    v.set_builtin_merchant_enabled("rewe".into(), true).unwrap();
    assert_eq!(booking(&v, shop).merchant.key, "rewe");
}

#[test]
fn a_copy_and_its_deletion_on_two_devices_end_up_consistent() {
    // #1373 review: device a deletes the last copy while b, not yet merged, makes a new
    // one; whatever the order, the live copy replaces the original on both
    let dir = TempDir::new("merchant-custom-copy-merge");
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    let old = create(&a, "Alt", &["rewe alt"], Some("rewe"));
    b.merge_other_vault(dir.join("a.db").to_string_lossy().into(), KEY.to_vec())
        .unwrap();
    a.delete_custom_merchant(old).unwrap();
    create(&b, "Neu", &["rewe neu"], Some("rewe"));
    for (into, from) in [(&a, "b.db"), (&b, "a.db")] {
        into.merge_other_vault(dir.join(from).to_string_lossy().into(), KEY.to_vec())
            .unwrap();
    }
    for v in [&a, &b] {
        let r = v.merchant_recognition().unwrap();
        assert_eq!(
            r.custom.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(),
            ["Neu"]
        );
        let rewe = r.builtin.iter().find(|m| m.key == "rewe").unwrap();
        assert!(rewe.replaced && rewe.enabled);
    }
}

#[test]
fn switches_for_merchants_the_table_lacks_change_nothing() {
    let dir = TempDir::new("merchant-custom-orphan");
    let v = open(&dir, "v.db");
    v.db()
        .unwrap()
        .execute(
            "INSERT INTO merchant_switches(merchant_key, enabled, changed_ms) VALUES ('gibt-es-nicht', 0, 1)",
            [],
        )
        .unwrap();
    let rules = v.merchant_rules(&v.db().unwrap()).unwrap();
    assert!(Arc::ptr_eq(&rules, MerchantRules::builtin()));
}

#[test]
fn recognition_off_keeps_the_savings_plans_apart() {
    // two ETFs bought through one broker, named in the purpose: with the recognition
    // off both show the broker, but they stay two plans (#1373 review)
    let dir = TempDir::new("merchant-custom-plans");
    let v = open(&dir, "v.db");
    let today = crate::dates::today();
    for days in [5, 35] {
        let date = (today - crate::dates::days(days)).to_string();
        book(
            &v,
            "Muster Broker",
            "Sparplan Core MSCI World",
            "",
            &date,
            -100_00,
        );
        book(&v, "Muster Broker", "Sparplan Bitcoin", "", &date, -25_00);
    }
    let plans = |v: &Vault| {
        let mut p: Vec<(String, i64)> = v
            .investment_dashboard(6)
            .unwrap()
            .plans
            .into_iter()
            .map(|p| (p.merchant.key, p.monthly_cents))
            .collect();
        p.sort();
        p
    };
    let on = plans(&v);
    assert_eq!(on.len(), 2, "{on:?}");
    v.set_merchant_recognition_enabled(false).unwrap();
    assert_eq!(plans(&v), on);
}

#[test]
fn recognition_off_shows_counterparties_without_logos() {
    let dir = TempDir::new("merchant-custom-off");
    let v = open(&dir, "v.db");
    let shop = book(
        &v,
        "REWE Markt GmbH",
        "Einkauf",
        SHOP_IBAN,
        "2026-10-03",
        -25_00,
    );
    let firm = book(
        &v,
        "Muster Handwerk GmbH",
        "Rechnung 12",
        "",
        "2026-10-04",
        -80_00,
    );
    let before = booking(&v, shop);
    v.set_merchant_domain(before.merchant.key.clone(), Some("example.org".into()))
        .unwrap();
    assert_eq!(
        booking(&v, shop).merchant_domain.as_deref(),
        Some("example.org")
    );

    assert!(v.merchant_recognition_enabled().unwrap());
    v.set_merchant_recognition_enabled(false).unwrap();
    assert!(!v.merchant_recognition().unwrap().enabled);
    assert!(!v.merchant_recognition_enabled().unwrap());
    let off = booking(&v, shop);
    assert_eq!(off.merchant_name, "REWE Markt");
    assert!(off.merchant.key.starts_with("x:"));
    assert_eq!(
        off.merchant_domain, None,
        "no logo, not even a manual domain"
    );
    assert_eq!(off.merchant_svg_path, None);
    assert!(off.merchant.domain_candidates.is_empty());
    assert_eq!(off.flow, before.flow);
    assert_eq!(off.recurrence_key, before.recurrence_key);
    assert!(booking(&v, firm).merchant.domain_candidates.is_empty());

    v.set_merchant_recognition_enabled(true).unwrap();
    let on = booking(&v, shop);
    assert_eq!(on.merchant.key, "rewe");
    assert_eq!(on.merchant_domain.as_deref(), Some("example.org"));
}

#[test]
fn the_merge_joins_switches_and_own_merchants() {
    let dir = TempDir::new("merchant-custom-merge");
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    let both = create(&a, "Laden", &["muster"], None);
    // the same merchant reaches the other device, as through an earlier merge
    b.merge_other_vault(dir.join("a.db").to_string_lossy().into(), KEY.to_vec())
        .unwrap();
    assert_eq!(b.merchant_recognition().unwrap().custom.len(), 1);

    // a: renames it later, switches REWE off; b: deletes nothing yet, adds its own
    std::thread::sleep(std::time::Duration::from_millis(5));
    a.save_custom_merchant(
        Some(both.clone()),
        "Laden neu".into(),
        strings(&["muster"]),
        None,
    )
    .unwrap();
    a.set_builtin_merchant_enabled("rewe".into(), false)
        .unwrap();
    let only_b = create(&b, "Nur auf B", &["bbb"], None);
    b.set_merchant_recognition_enabled(false).unwrap();

    for (into, from) in [(&a, "b.db"), (&b, "a.db")] {
        into.merge_other_vault(dir.join(from).to_string_lossy().into(), KEY.to_vec())
            .unwrap();
    }
    let (ra, rb) = (
        a.merchant_recognition().unwrap(),
        b.merchant_recognition().unwrap(),
    );
    assert_eq!(ra, rb);
    assert!(!ra.enabled);
    assert!(!ra.builtin.iter().find(|m| m.key == "rewe").unwrap().enabled);
    let names: Vec<_> = ra.custom.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, ["Laden neu", "Nur auf B"]);

    // a deletion stays, even against a later edit on the other device
    b.delete_custom_merchant(only_b.clone()).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(5));
    a.save_custom_merchant(Some(only_b), "Doch wieder".into(), strings(&["bbb"]), None)
        .unwrap();
    for (into, from) in [(&a, "b.db"), (&b, "a.db")] {
        into.merge_other_vault(dir.join(from).to_string_lossy().into(), KEY.to_vec())
            .unwrap();
    }
    let (ra, rb) = (
        a.merchant_recognition().unwrap(),
        b.merchant_recognition().unwrap(),
    );
    assert_eq!(ra, rb);
    assert_eq!(ra.custom.len(), 1);
    // a merge that brings nothing new writes nothing
    let before = a.change_count();
    let stats = a
        .merge_other_vault(dir.join("b.db").to_string_lossy().into(), KEY.to_vec())
        .unwrap();
    assert_eq!(stats.changes, 0);
    assert_eq!(a.change_count(), before);
}

#[test]
fn equal_switch_stamps_end_switched_off_in_both_merge_orders() {
    let dir = TempDir::new("merchant-custom-tie");
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    for (v, enabled) in [(&a, 1), (&b, 0)] {
        v.db()
            .unwrap()
            .execute(
                "INSERT INTO merchant_switches(merchant_key, enabled, changed_ms) VALUES ('rewe', ?1, 42)",
                [enabled],
            )
            .unwrap();
    }
    for (into, from) in [(&a, "b.db"), (&b, "a.db")] {
        into.merge_other_vault(dir.join(from).to_string_lossy().into(), KEY.to_vec())
            .unwrap();
    }
    for v in [&a, &b] {
        let r = v.merchant_recognition().unwrap();
        assert!(!r.builtin.iter().find(|m| m.key == "rewe").unwrap().enabled);
    }
}

#[test]
fn a_merged_change_reaches_the_booking_list() {
    let dir = TempDir::new("merchant-custom-merge-list");
    let a = open(&dir, "a.db");
    let b = open(&dir, "b.db");
    let shop = book(&a, "REWE Markt GmbH", "Einkauf", "", "2026-10-03", -25_00);
    assert_eq!(booking(&a, shop).merchant.key, "rewe");
    create(&b, "Eckladen", &["rewe"], None);
    a.merge_other_vault(dir.join("b.db").to_string_lossy().into(), KEY.to_vec())
        .unwrap();
    assert_eq!(booking(&a, shop).merchant_name, "Eckladen");
}

#[test]
fn rules_are_kept_while_the_tables_stay_the_same() {
    let dir = TempDir::new("merchant-custom-keep");
    let v = open(&dir, "v.db");
    create(&v, "Laden", &["muster"], None);
    let first = v.merchant_rules(&v.db().unwrap()).unwrap();
    book(&v, "Muster", "", "", "2026-10-01", -1_00);
    let again = v.merchant_rules(&v.db().unwrap()).unwrap();
    assert!(
        Arc::ptr_eq(&first, &again),
        "another write keeps the rules and their cache"
    );
    v.set_builtin_merchant_enabled("rewe".into(), false)
        .unwrap();
    let changed = v.merchant_rules(&v.db().unwrap()).unwrap();
    assert!(!Arc::ptr_eq(&first, &changed));
    assert!(changed.settings().disabled.contains("rewe"));
}

#[test]
fn the_search_finds_the_shown_merchant_name() {
    let dir = TempDir::new("merchant-custom-search");
    let v = open(&dir, "v.db");
    let shop = book(&v, "REWE Markt GmbH", "Einkauf", "", "2026-10-03", -25_00);
    let amzn = book(
        &v,
        "AMZN Mktp DE",
        "Bestellung 302",
        "",
        "2026-10-04",
        -19_99,
    );
    let rent = book(
        &v,
        "Hausverwaltung Muster",
        "Oktober",
        "",
        "2026-10-01",
        -800_00,
    );
    let found = |q: &str| -> Vec<i64> {
        let filter = BookingFilter {
            search: Some(q.into()),
            ..Default::default()
        };
        let mut ids: Vec<i64> = v
            .list_transactions(filter)
            .unwrap()
            .transactions
            .iter()
            .map(|b| b.id)
            .collect();
        ids.sort();
        ids
    };
    // a bundled name that no booking text contains
    assert_eq!(found("amazon"), [amzn]);
    create(&v, "Supermarkt Ecke", &["rewe markt"], Some("rewe"));
    assert_eq!(found("Supermarkt Ecke"), [shop]);
    assert_eq!(found("ecke supermarkt"), [shop], "every word, in any order");
    assert!(found("ecke hausverwaltung").is_empty());
    assert_eq!(found("REWE"), [shop], "the texts still count");
    // a search that no merchant name contains does not finish every booking
    book(&v, "Muster", "", "", "2026-10-05", -1_00);
    assert_eq!(found("hausverwaltung"), [rent]);
    assert!(v.cached_booking_classes(&v.db().unwrap()).is_none());
    // recognition off: the shown names are the counterparties
    v.set_merchant_recognition_enabled(false).unwrap();
    assert!(found("amazon").is_empty());
}

#[test]
fn two_merchants_made_in_one_millisecond_keep_their_order() {
    let dir = TempDir::new("merchant-custom-order");
    let v = open(&dir, "v.db");
    let shop = book(&v, "Muster Laden", "", "", "2026-10-03", -5_00);
    for name in ["Erster", "Zweiter", "Dritter"] {
        create(&v, name, &["muster"], None);
    }
    let created: Vec<i64> = v
        .db()
        .unwrap()
        .prepare("SELECT created_ms FROM custom_merchants ORDER BY created_ms")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert!(created.windows(2).all(|w| w[0] < w[1]), "{created:?}");
    assert_eq!(
        booking(&v, shop).merchant_name,
        "Erster",
        "a tie goes to the older"
    );
}

#[test]
fn receipts_match_by_the_bundled_name_not_an_own_one() {
    let dir = TempDir::new("merchant-custom-receipt");
    let v = open(&dir, "v.db");
    let shop = book(&v, "REWE Markt GmbH", "Einkauf", "", "2026-10-03", -25_00);
    create(&v, "Eckladen", &["rewe markt"], Some("rewe"));
    let best = |text: &str| {
        let candidates = v.bookings_for_matching(text).unwrap();
        crate::documents::best_match(&candidates, text).map(|(b, score)| (b.id, score))
    };
    // the receipt names the brand: name and date are enough, as before the rename
    assert_eq!(best("REWE Markt Datum 03.10.2026"), Some((shop, 6)));
    // the name the user gave the booking is on no receipt and links nothing
    assert_eq!(best("Eckladen Datum 03.10.2026"), None);
}
