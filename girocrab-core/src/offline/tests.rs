use std::sync::Arc;

use rusqlite::params;

use super::ManualBookingSetup;
use crate::error::CoreError;
use crate::models::AccountKind;
use crate::vault::Vault;

fn vault(tag: &str) -> Arc<Vault> {
    Vault::open(
        crate::test_support::thread_temp_path(tag)
            .to_string_lossy()
            .into(),
        vec![7u8; 32],
    )
    .unwrap()
}

fn setup(date: &str, cents: i64, who: &str) -> ManualBookingSetup {
    ManualBookingSetup {
        booking_date: date.into(),
        amount_cents: cents,
        counterparty: who.into(),
        purpose: String::new(),
        category_id: None,
        note: String::new(),
    }
}

fn balance(v: &Vault, id: i64) -> i64 {
    v.list_accounts()
        .unwrap()
        .into_iter()
        .find(|a| a.id == id)
        .unwrap()
        .balance_cents
}

fn live_count(v: &Vault, id: i64) -> i64 {
    v.db()
        .unwrap()
        .query_row(
            "SELECT count(*) FROM transactions WHERE account_id = ?1 AND deleted_ms IS NULL",
            [id],
            |r| r.get(0),
        )
        .unwrap()
}

#[test]
fn new_account_starts_with_its_opening_balance() {
    let v = vault("offline-new");
    let id = v
        .create_offline_account("Portemonnaie".into(), AccountKind::Cash, 50_00)
        .unwrap();
    let a = v
        .list_accounts()
        .unwrap()
        .into_iter()
        .find(|a| a.id == id)
        .unwrap();
    assert_eq!(a.name, "Portemonnaie");
    assert_eq!(a.kind, AccountKind::Cash);
    assert_eq!(a.balance_cents, 50_00);
    assert!(a.connection_id.is_none());
    assert!(a.balance_derived);
    assert_eq!(v.list_offline_account_ids().unwrap(), vec![id]);
}

#[test]
fn empty_name_becomes_cash_and_loans_are_refused() {
    let v = vault("offline-name");
    let id = v
        .create_offline_account("  ".into(), AccountKind::Cash, 0)
        .unwrap();
    assert_eq!(v.list_accounts().unwrap()[0].id, id);
    assert_eq!(v.list_accounts().unwrap()[0].name, "Bargeld");
    for kind in [AccountKind::Loan, AccountKind::Brokerage] {
        assert!(matches!(
            v.create_offline_account("X".into(), kind, 0),
            Err(CoreError::InvalidInput { .. })
        ));
    }
}

#[test]
fn bookings_move_the_balance_and_can_be_edited_and_deleted() {
    let v = vault("offline-edit");
    let acc = v
        .create_offline_account("Kasse".into(), AccountKind::Cash, 100_00)
        .unwrap();
    let a = v
        .save_manual_booking(acc, None, setup("2026-11-01", -20_00, "Bäcker"))
        .unwrap();
    let b = v
        .save_manual_booking(acc, None, setup("2026-11-02", 5_00, "Fund"))
        .unwrap();
    assert_eq!(balance(&v, acc), 85_00);

    // edit: amount, date and text
    v.save_manual_booking(acc, Some(a), setup("2026-11-03", -30_00, "Metzger"))
        .unwrap();
    assert_eq!(balance(&v, acc), 75_00);
    let t = v
        .list_transactions(crate::models::BookingFilter {
            account_ids: vec![acc],
            ..Default::default()
        })
        .unwrap()
        .transactions;
    assert!(t
        .iter()
        .any(|x| x.id == a && x.counterparty == "Metzger" && x.booking_date == "2026-11-03"));

    // soft delete: the row stays for the merge, nothing lists or sums it
    v.delete_manual_booking(b).unwrap();
    assert_eq!(balance(&v, acc), 70_00);
    assert_eq!(live_count(&v, acc), 1);
    let stamp: Option<i64> = v
        .db()
        .unwrap()
        .query_row(
            "SELECT deleted_ms FROM transactions WHERE id = ?1",
            [b],
            |r| r.get(0),
        )
        .unwrap();
    assert!(stamp.is_some());
}

#[test]
fn category_is_set_by_hand_and_validated() {
    let v = vault("offline-category");
    let acc = v
        .create_offline_account("Kasse".into(), AccountKind::Cash, 0)
        .unwrap();
    let cat: i64 = {
        let db = v.db().unwrap();
        db.execute("INSERT INTO categories(name) VALUES ('Essen')", [])
            .unwrap();
        db.last_insert_rowid()
    };
    let mut s = setup("2026-11-01", -9_00, "Imbiss");
    s.category_id = Some(cat);
    let id = v.save_manual_booking(acc, None, s.clone()).unwrap();
    let src: String = v
        .db()
        .unwrap()
        .query_row(
            "SELECT category_source FROM transactions WHERE id = ?1",
            [id],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(src, "manual");
    s.category_id = Some(cat + 999);
    assert!(matches!(
        v.save_manual_booking(acc, Some(id), s),
        Err(CoreError::NotFound { .. })
    ));
}

#[test]
fn input_is_validated() {
    let v = vault("offline-validate");
    let acc = v
        .create_offline_account("Kasse".into(), AccountKind::Cash, 0)
        .unwrap();
    for bad in [
        setup("2026-11-01", 0, "x"),
        setup("kein Datum", 1_00, "x"),
        setup("2026-02-30", 1_00, "x"),
    ] {
        assert!(matches!(
            v.save_manual_booking(acc, None, bad),
            Err(CoreError::InvalidInput { .. })
        ));
    }
    assert!(matches!(
        v.save_manual_booking(acc, None, setup("2026-11-01", 1_00, &"x".repeat(501))),
        Err(CoreError::InvalidInput { .. })
    ));
    assert_eq!(live_count(&v, acc), 0);
}

#[test]
fn synced_accounts_stay_read_only() {
    let v = vault("offline-readonly");
    let bank = {
        let db = v.db().unwrap();
        db.execute(
            "INSERT INTO account_groups(name, sf_symbol, sort_order) VALUES ('G', 'tray', 1)",
            [],
        )
        .unwrap();
        db.execute(
            "INSERT INTO bank_connections(connector, display_name, login_name)
             VALUES ('fints:52090000', 'VB', '1234567890')",
            [],
        )
        .unwrap();
        let conn = db.last_insert_rowid();
        db.execute(
            "INSERT INTO accounts(connection_id, group_id, external_ref, name, kind)
             VALUES (?1, (SELECT min(id) FROM account_groups), 'DE1', 'Giro', 'checking')",
            params![conn],
        )
        .unwrap();
        db.last_insert_rowid()
    };
    assert!(matches!(
        v.save_manual_booking(bank, None, setup("2026-11-01", 1_00, "x")),
        Err(CoreError::InvalidInput { .. })
    ));
    assert!(!v.list_offline_account_ids().unwrap().contains(&bank));
    assert!(matches!(
        v.save_manual_booking(9999, None, setup("2026-11-01", 1_00, "x")),
        Err(CoreError::NotFound { .. })
    ));
}

#[test]
fn an_imported_account_keeps_its_balance_when_it_takes_a_booking() {
    let v = vault("offline-imported");
    let acc = {
        let db = v.db().unwrap();
        db.execute(
            "INSERT INTO account_groups(name, sf_symbol, sort_order) VALUES ('G', 'tray', 1)",
            [],
        )
        .unwrap();
        db.execute(
            "INSERT INTO accounts(group_id, external_ref, name, kind, balance_cents)
             VALUES ((SELECT min(id) FROM account_groups), 'csv-1', 'Alt', 'cash', 40_00)",
            [],
        )
        .unwrap();
        db.last_insert_rowid()
    };
    assert_eq!(v.list_offline_account_ids().unwrap(), vec![acc]);
    v.save_manual_booking(acc, None, setup("2026-11-01", -10_00, "Kiosk"))
        .unwrap();
    assert_eq!(balance(&v, acc), 30_00);
}

#[test]
fn mirroring_reverses_the_amount_and_leaves_no_category() {
    let v = vault("offline-mirror");
    let cash = v
        .create_offline_account("Kasse".into(), AccountKind::Cash, 0)
        .unwrap();
    let giro = {
        let db = v.db().unwrap();
        db.execute(
            "INSERT INTO account_groups(name, sf_symbol, sort_order) VALUES ('G', 'tray', 1)",
            [],
        )
        .unwrap();
        db.execute(
            "INSERT INTO accounts(group_id, external_ref, name, kind) VALUES ((SELECT min(id) FROM account_groups), 'g', 'Giro', 'checking')",
            [],
        )
        .unwrap();
        let giro = db.last_insert_rowid();
        db.execute(
            "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, counterparty, category_id, category_source)
             VALUES (?1, 'atm', '2026-11-05', -80_00, 'Geldautomat', NULL, 'none')",
            [giro],
        )
        .unwrap();
        giro
    };
    // the Giro account has no connection either, so it is "offline" by the SQL rule; mirror from it
    let atm: i64 = v
        .db()
        .unwrap()
        .query_row(
            "SELECT id FROM transactions WHERE external_id = 'atm'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let copy = v.mirror_booking_to_offline_account(atm, cash).unwrap();
    assert_eq!(balance(&v, cash), 80_00);
    let (cents, cat): (i64, Option<i64>) = v
        .db()
        .unwrap()
        .query_row(
            "SELECT amount_cents, category_id FROM transactions WHERE id = ?1",
            [copy],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!((cents, cat), (80_00, None));
    // the original is untouched, and a booking cannot be mirrored into its own account
    assert!(matches!(
        v.mirror_booking_to_offline_account(atm, giro),
        Err(CoreError::InvalidInput { .. })
    ));
    assert_eq!(live_count(&v, giro), 1);
}

#[test]
fn a_correction_booking_reaches_the_target_balance() {
    let v = vault("offline-correct");
    let acc = v
        .create_offline_account("Kasse".into(), AccountKind::Cash, 10_00)
        .unwrap();
    assert_eq!(v.correct_offline_balance(acc, 10_00).unwrap(), None);
    let id = v.correct_offline_balance(acc, 25_50).unwrap().unwrap();
    assert_eq!(balance(&v, acc), 25_50);
    let amount: i64 = v
        .db()
        .unwrap()
        .query_row(
            "SELECT amount_cents FROM transactions WHERE id = ?1",
            [id],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(amount, 15_50);
    v.correct_offline_balance(acc, -5_00).unwrap();
    assert_eq!(balance(&v, acc), -5_00);
}
