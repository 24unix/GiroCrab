use std::sync::Arc;

use crate::connectors::*;
use crate::models::{AccountKind, ConnectorKind};
use crate::vault::Vault;

fn tx(date: &str, cents: i64, who: &str) -> RemoteTransaction {
    RemoteTransaction {
        account_ref: "ACC".into(),
        booking_date: date.into(),
        value_date: date.into(),
        amount_cents: cents,
        currency: "EUR".into(),
        counterparty: who.into(),
        purpose: "Einkauf".into(),
        ..Default::default()
    }
}

#[test]
fn fnv_matches_reference_values() {
    assert_eq!(fnv1a64(""), 0xcbf2_9ce4_8422_2325);
    assert_eq!(fnv1a64("a"), 0xaf63_dc4c_8601_ec8c);
    let id = tx("2026-11-01", -350, "Bäckerei").content_id(0);
    assert!(is_content_id(&id, CONTENT_ID_PREFIX), "{id}");
}

#[test]
fn ids_count_per_content_not_per_position() {
    let coffee = tx("2026-11-05", -350, "Café");
    let rent = tx("2026-11-01", -90_000, "Vermieter");
    let ids = |list: &[&RemoteTransaction]| {
        let mut c = ContentIds::default();
        list.iter().map(|t| c.next(t)).collect::<Vec<_>>()
    };
    // two identical coffees on one day stay two ids
    let a = ids(&[&coffee, &coffee, &rent]);
    assert_ne!(a[0], a[1]);
    // a moved window / new booking in front changes nothing
    let new = tx("2026-11-10", -1_000, "Kiosk");
    let b = ids(&[&new, &rent, &coffee, &coffee]);
    assert_eq!((&b[2], &b[3], &b[1]), (&a[0], &a[1], &a[2]));
}

#[test]
fn since_is_per_account_with_a_common_floor() {
    let d = |s: &str| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap();
    let newest = vec![
        ("A".to_string(), Some("2026-11-01".to_string())),
        ("B".to_string(), Some("2026-10-01".to_string())), // lagging behind
        ("C".to_string(), None),                           // no bookings (depot)
    ];
    let (since, per) = since_window(d("2026-11-12"), 90, &newest);
    assert_eq!(per["A"], "2026-10-22");
    assert_eq!(per["B"], "2026-09-21");
    assert_eq!(per["C"], "2026-08-14");
    // connectors fetching everything at once start at the earliest account
    assert_eq!(since, "2026-09-21");
    // whole connection not synced for long: older than `days` is kept
    let (since, per) = since_window(
        d("2026-11-12"),
        90,
        &[("A".to_string(), Some("2026-01-01".to_string()))],
    );
    assert_eq!(
        (since.as_str(), per["A"].as_str()),
        ("2025-12-22", "2025-12-22")
    );
    let (since, _) = since_window(d("2026-11-12"), 90, &[]);
    assert_eq!(since, "2026-08-14");
}

fn setup() -> (Arc<Vault>, i64) {
    let p_dir = crate::test_support::TempDir::new("girocrab-cid");
    let p = p_dir.join("v.db");
    let v = Vault::open(p.to_string_lossy().to_string(), vec![5u8; 32]).unwrap();
    let conn = v
        .add_bank_connection(ConnectorKind::Comdirect, String::new(), "login".into())
        .unwrap();
    (v, conn)
}

fn fetch(txs: Vec<RemoteTransaction>) -> FetchResult {
    FetchResult {
        accounts: vec![RemoteAccount {
            external_ref: "ACC".into(),
            name: "Giro".into(),
            owner: String::new(),
            iban: String::new(),
            account_number: String::new(),
            currency: "EUR".into(),
            kind: AccountKind::Checking,
            balance_cents: 0,
            balance_date: "2026-11-10".into(),
        }],
        transactions: txs,
        ..Default::default()
    }
}

fn ext_ids(v: &Vault) -> Vec<String> {
    let db = v.db().unwrap();
    let mut st = db
        .prepare("SELECT external_id FROM transactions ORDER BY id")
        .unwrap();
    st.query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

#[test]
fn legacy_content_ids_are_adopted_not_duplicated() {
    let (v, conn) = setup();
    let coffee = tx("2026-11-05", -350, "Café");
    // stored by an older version: two identical coffees, DefaultHasher ids
    let mut old = vec![coffee.clone(), coffee.clone()];
    old[0].external_id = "h0123456789abcdef".into();
    old[1].external_id = "hfedcba9876543210".into();
    store_fetch(&v, ConnectorKind::Comdirect, conn, fetch(old)).unwrap();
    // same bookings with the new FNV ids
    let mut ids = ContentIds::default();
    let mut new = vec![coffee.clone(), coffee.clone()];
    for t in &mut new {
        t.external_id = ids.next(t);
    }
    let s = store_fetch(&v, ConnectorKind::Comdirect, conn, fetch(new.clone())).unwrap();
    assert_eq!(s.transactions_imported, 0);
    let stored = ext_ids(&v);
    assert_eq!(stored.len(), 2);
    assert!(stored.contains(&new[0].external_id) && stored.contains(&new[1].external_id));
    // and a third, genuinely new identical coffee is still imported
    let mut ids = ContentIds::default();
    let mut three = vec![coffee.clone(), coffee.clone(), coffee];
    for t in &mut three {
        t.external_id = ids.next(t);
    }
    let s = store_fetch(&v, ConnectorKind::Comdirect, conn, fetch(three)).unwrap();
    assert_eq!(s.transactions_imported, 1);
    assert_eq!(ext_ids(&v).len(), 3);
}

#[test]
fn empty_external_ids_do_not_collapse() {
    let (v, conn) = setup();
    let coffee = tx("2026-11-05", -350, "Café");
    let txs = vec![coffee.clone(), coffee, tx("2026-11-06", -500, "Kiosk")];
    store_fetch(&v, ConnectorKind::Comdirect, conn, fetch(txs.clone())).unwrap();
    let ids = ext_ids(&v);
    assert_eq!(ids.len(), 3);
    assert!(ids.iter().all(|i| is_content_id(i, CONTENT_ID_PREFIX)));
    // deterministic: the next sync adds nothing
    let s = store_fetch(&v, ConnectorKind::Comdirect, conn, fetch(txs)).unwrap();
    assert_eq!(s.transactions_imported, 0);
}
