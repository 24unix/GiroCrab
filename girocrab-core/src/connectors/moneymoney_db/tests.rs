//! Tests with fake MoneyMoney databases (real column layout, invented data,
//! SQLCipher-encrypted with a test password).

use super::*;
use crate::models::{BookingFilter, CategorySource, MatchKind};
use std::path::PathBuf;
use std::sync::Arc;

const PW: &str = "Test-Passwort 'mit' Anführungszeichen";

/// The relevant MoneyMoney tables with their real columns.
const SCHEMA: &str = r#"
CREATE TABLE account_groups (rowid INTEGER PRIMARY KEY, name TEXT, perspective TEXT, group_key INTEGER, sort INTEGER, icon TEXT, expanded INTEGER, sidebar INTEGER, userdata BLOB);
CREATE TABLE accounts (rowid INTEGER PRIMARY KEY, bank_key INTEGER, account TEXT, subaccount TEXT, bankcode TEXT, portfolio INTEGER, iban TEXT, bic TEXT, currency TEXT, name TEXT, owner TEXT, kind INTEGER, type INTEGER, sort INTEGER, icon TEXT, balances BLOB, pending_balances BLOB, overdraft_limit REAL, available_funds REAL, initial_balance REAL, cub INTEGER, cub_tsp INTEGER, recipient_key INTEGER, refresh_tsp INTEGER, balance_tsp INTEGER, transaction_tsp INTEGER, payment_tsp INTEGER, error_tsp INTEGER, cancel_tsp INTEGER, statements INTEGER, refresh_actions INTEGER, refresh INTEGER, userdata BLOB, cred TEXT, transientdata BLOB, perspective TEXT, group_key INTEGER, error TEXT, web_ops BLOB);
CREATE TABLE balances (account_key INTEGER, currency TEXT, timestamp INTEGER, initial_balance REAL, PRIMARY KEY (account_key, currency, timestamp DESC));
CREATE TABLE banks (rowid INTEGER PRIMARY KEY, country TEXT, bankcode TEXT, username TEXT, customer TEXT, credential TEXT, name TEXT, server TEXT, protocol REAL, tanmethod TEXT, tanmedium TEXT, systemid TEXT, tanmethods TEXT, bpd BLOB, upd BLOB, spa INTEGER, spa_tsp INTEGER, local_storage TEXT, pubkey BLOB, privkey BLOB, userdata BLOB);
CREATE TABLE categories (rowid INTEGER PRIMARY KEY, name TEXT, type INTEGER, perspective TEXT, group_key INTEGER, sort INTEGER, color TEXT, rules TEXT, apply_to_account TEXT, currency TEXT, is_valid_sum INTEGER, userdata BLOB);
CREATE TABLE category_groups (rowid INTEGER PRIMARY KEY, name TEXT, perspective TEXT, group_key INTEGER, sort INTEGER, color TEXT, expanded INTEGER, currency TEXT, userdata BLOB);
CREATE TABLE pins (bank_key INTEGER PRIMARY KEY, pin TEXT);
CREATE TABLE recipients (local_account_key INTEGER, name TEXT, owner TEXT, account TEXT, subaccount TEXT, bankcode TEXT, iban TEXT, bic TEXT, type INTEGER);
CREATE TABLE securities (rowid INTEGER PRIMARY KEY, account_key INTEGER, ident TEXT, isin TEXT, wpn TEXT, symbol TEXT, quantity REAL, quantity_cur TEXT, amount REAL, amount_cur TEXT, ocmt REAL, ocmt_cur TEXT, purchase REAL, purchase_cur TEXT, price REAL, price_cur TEXT, exch REAL, trade_date INTEGER, trade_tsp INTEGER, purchase_tsp INTEGER, market TEXT, comment TEXT, userdata BLOB, visited INTEGER, deleted INTEGER, asset_class INTEGER);
CREATE TABLE statements (rowid INTEGER PRIMARY KEY, account_key INTEGER, name TEXT, directory TEXT, filename TEXT, created_tsp INTEGER, fetched_tsp INTEGER, orderid INTEGER, userorder INTEGER, imported INTEGER, visited INTEGER, deleted INTEGER, number TEXT, year TEXT, identifier BLOB, digest TEXT);
CREATE TABLE transactions (rowid INTEGER PRIMARY KEY, local_account_key INTEGER, account TEXT, bankcode TEXT, amount REAL, currency TEXT, timestamp INTEGER, value_timestamp INTEGER, pn TEXT, eref TEXT, mref TEXT, kref TEXT, cred TEXT, dept TEXT, rtcd TEXT, rtrn TEXT, ocmt REAL, ocmt_cur TEXT, chgs REAL, chgs_cur TEXT, coam REAL, coam_cur TEXT, oamt REAL, oamt_cur TEXT, exch REAL, abwe TEXT, abwa TEXT, seq TEXT, comment TEXT, attachment TEXT, booked INTEGER, nopretty INTEGER, unformatted_type TEXT, unformatted_name TEXT, unformatted_purpose TEXT, identifier TEXT, name TEXT, a1490107618 TEXT, visited INTEGER, checkmark INTEGER, splitted INTEGER, split_key INTEGER, reverse_key INTEGER, category_key INTEGER);
"#;

// Invented data only (public example IBANs, fictional names).
const DATA: &str = r#"
INSERT INTO banks (rowid, country, bankcode, username, customer, credential, name, systemid, local_storage) VALUES
  (1, 'DE', '20041111', '1234567', '1234567', 'GEHEIM-1', 'comdirect', 'SYS', 'LS'),
  (2, 'DE', '52090000', 'VRNK4711', 'VRNK4711', 'GEHEIM-2', 'Volksbank Kassel Göttingen', 'SYS', 'LS'),
  (3, 'DE', '12345678', 'max.m', '', 'GEHEIM-3', 'Sparkasse Musterstadt', 'SYS', 'LS');
INSERT INTO pins (bank_key, pin) VALUES (1, '11111'), (2, '22222'), (3, '33333');
INSERT INTO account_groups (rowid, name, group_key, sort) VALUES (1, 'Privat', 0, 1);
INSERT INTO accounts (rowid, bank_key, account, bankcode, portfolio, iban, currency, name, owner, kind, type, sort, initial_balance, group_key, cred) VALUES
  (1, 1, '0532013000', '20041111', 0, 'DE89 3704 0044 0532 0130 00', 'EUR', 'Girokonto', 'Max Mustermann', 0, 0, 1, 50.0, 1, 'GEHEIM'),
  (2, 1, '4711', '20041111', 0, '', 'EUR', 'Visa-Karte', 'Max Mustermann', 0, 3, 2, 0, 1, 'GEHEIM'),
  (3, 1, '9999', '20041111', 1, '', 'EUR', 'Depot', 'Max Mustermann', 0, 7, 3, 0, 0, 'GEHEIM'),
  (4, 3, '1000', '12345678', 0, '', 'USD', 'Dollar-Konto', 'Max Mustermann', 0, 0, 4, 10.5, 0, 'GEHEIM');
INSERT INTO balances (account_key, currency, timestamp, initial_balance) VALUES
  (1, 'EUR', 1104580800, 80.0),
  (1, 'EUR', 1577880000, 100.0);
INSERT INTO category_groups (rowid, name, group_key, sort) VALUES
  (1, 'Haushalt', 0, 1), (2, 'Wohnen', 0, 2), (3, 'Nebenkosten', 2, 1);
INSERT INTO categories (rowid, name, type, group_key, sort) VALUES
  (1, '', 0, 0, 0),
  (2, 'Supermarkt', 1, 1, 1),
  (3, 'Gehalt', 1, 0, 2),
  (4, 'Strom', 1, 3, 1),
  (5, 'Steuern / Büro', 1, 0, 3);
INSERT INTO transactions (rowid, local_account_key, account, bankcode, amount, currency, timestamp, value_timestamp, pn, eref, mref, cred, comment, booked, unformatted_type, unformatted_purpose, name, checkmark, splitted, split_key, category_key) VALUES
  (1, 1, 'DE02120300000000202051', 'BYLADEM1001', 2500.0, 'EUR', 1104580800, 1104580800, 'X', '', '', '', 'erstes Gehalt', 1, 'GUTSCHRIFT', 'Gehalt Januar', 'Arbeitgeber GmbH', 1, 0, 1, 3),
  (2, 1, 'DE02100100100006820101', 'PBNKDEFFXXX', -45.67, 'EUR', 1772712000, 1772712000, '', 'E2E-1', 'MANDAT-1', 'DE98ZZZ09999999999', '', 1, 'LASTSCHRIFT', 'Einkauf Filiale 12', 'REWE Markt', 0, 0, 2, 2),
  (3, 1, '12345', '10010010', -12.3, 'EUR', 1772798400, 0, '', '', '', '', '', 1, 'KARTENZAHLUNG', 'Brötchen', 'Bäckerei Schmidt', 0, 0, 3, 1),
  (4, 1, '', '', -9.99, 'EUR', 1772971200, 0, '', '', '', '', '', 0, 'VORMERKUNG', 'Vorgemerkt', 'Streaming AG', 0, 0, 4, 1),
  (5, 1, '', '', -100.0, 'EUR', 1772884800, 0, '', '', '', '', '', 1, 'KARTENZAHLUNG', 'Einkauf', 'Kaufhaus Muster', 0, 1, 5, 1),
  (6, 1, '', '', -60.0, 'EUR', 1772884800, 0, '', '', '', '', '', 1, 'KARTENZAHLUNG', 'Einkauf Lebensmittel', 'Kaufhaus Muster', 0, 0, 5, 2),
  (7, 1, '', '', -40.0, 'EUR', 1772884800, 0, '', '', '', '', '', 1, 'KARTENZAHLUNG', 'Einkauf Lampe', 'Kaufhaus Muster', 0, 0, 5, 4),
  (8, 2, '', '', -19.99, 'EUR', 1709208000, 0, '', '', '', '', 'Abo kündigen', 1, 'KARTENZAHLUNG', 'Monatsabo', 'Streaming AG', 0, 0, 8, 5),
  (9, 4, '', '', 25.255, 'USD', 1772712000, 0, '', '', '', '', '', 1, 'GUTSCHRIFT', 'Dividende', 'Muster Inc', 0, 0, 9, 1);
INSERT INTO recipients (local_account_key, name, iban) VALUES (1, 'Erika Mustermann', 'DE02120300000000202051');
-- Depot: balance only in the displayed-balance blob, positions in securities (one sold)
UPDATE accounts SET balances = CAST('12:12345.670000,3:EUR,' AS BLOB), balance_tsp = 1772884800 WHERE rowid = 3;
INSERT INTO securities (rowid, account_key, ident, isin, wpn, quantity, amount, amount_cur, purchase, price, trade_date, deleted) VALUES
  (1, 3, 'Muster World ETF', 'IE00B4L5Y983', 'A0RPWH', 12.5, 1000.0, 'EUR', 70.0, 80.0, 1772884800, 0),
  (2, 3, 'Liquidität', '', '', NULL, 345.67, 'EUR', NULL, NULL, 1772884800, 0),
  (3, 3, 'Verkauft AG', 'DE0000000001', '', 1, 1, 'EUR', 1, 1, 1772884800, 1);
"#;

fn temp(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("girocrab-mmdb-{name}-{}", uuid::Uuid::new_v4()))
}

fn fake_db_with(compat3: bool, extra: &str) -> String {
    let path = temp("src.sqlite");
    let c = Connection::open(&path).unwrap();
    c.execute_batch(&format!("PRAGMA key = '{}';", PW.replace('\'', "''")))
        .unwrap();
    if compat3 {
        c.execute_batch("PRAGMA cipher_compatibility = 3;").unwrap();
    }
    c.execute_batch(SCHEMA).unwrap();
    c.execute_batch(DATA).unwrap();
    c.execute_batch(extra).unwrap();
    path.to_string_lossy().to_string()
}

fn fake_db_unencrypted() -> String {
    let path = temp("plain-src.sqlite");
    let c = Connection::open(&path).unwrap();
    c.execute_batch(SCHEMA).unwrap();
    c.execute_batch(DATA).unwrap();
    path.to_string_lossy().to_string()
}

fn fake_db() -> String {
    fake_db_with(false, "")
}

fn vault() -> Arc<Vault> {
    Vault::open(
        temp("vault.db").to_string_lossy().to_string(),
        vec![7u8; 32],
    )
    .unwrap()
}

/// Options as the UI would send them: every account, suggested kind and target.
fn options_from(
    p: &MoneyMoneyDbPreview,
    connections: bool,
    pins: bool,
) -> MoneyMoneyDbImportOptions {
    MoneyMoneyDbImportOptions {
        accounts: p
            .accounts
            .iter()
            .map(|a| MoneyMoneyDbAccountChoice {
                mm_id: a.mm_id,
                import: true,
                kind: a.suggested_kind,
                target_account_id: a.existing_account_id,
            })
            .collect(),
        import_categories: true,
        import_notes: true,
        create_connections: connections,
        import_pins: pins,
        import_groups: true,
        import_statements: true,
        statements_dir: None,
    }
}

fn bookings(v: &Vault, account_id: i64) -> Vec<crate::models::Booking> {
    v.list_transactions(BookingFilter {
        account_ids: vec![account_id],
        ..Default::default()
    })
    .unwrap()
    .transactions
}

fn account_by_name(v: &Vault, name: &str) -> crate::models::Account {
    v.list_accounts()
        .unwrap()
        .into_iter()
        .find(|a| a.name == name)
        .unwrap()
}

#[test]
fn amount_and_date_conversion_edge_cases() {
    assert_eq!(real_to_cents(1234.56), Some(123_456));
    assert_eq!(real_to_cents(-45.67), Some(-4567));
    assert_eq!(real_to_cents(0.285), Some(29)); // (0.285 * 100.0).round() would give 28
    assert_eq!(real_to_cents(-0.285), Some(-29));
    assert_eq!(real_to_cents(0.1 + 0.2), Some(30));
    assert_eq!(real_to_cents(-0.004), Some(0));
    assert_eq!(real_to_cents(-0.005), Some(-1));
    assert_eq!(real_to_cents(1e-9), Some(0));
    assert_eq!(real_to_cents(99_999_999.99), Some(9_999_999_999));
    assert_eq!(real_to_cents(f64::NAN), None);
    assert_eq!(real_to_cents(f64::INFINITY), None);
    assert_eq!(unix_to_date(1104580800).as_deref(), Some("2005-01-01"));
    assert_eq!(unix_to_date(1709208000).as_deref(), Some("2024-02-29"));
    // 12:00 UTC is the convention; the whole UTC day maps to the same date
    assert_eq!(
        unix_to_date(1104580800 - 12 * 3600).as_deref(),
        Some("2005-01-01")
    );
    assert_eq!(
        unix_to_date(1104580800 + 12 * 3600 - 1).as_deref(),
        Some("2005-01-01")
    );
    assert_eq!(unix_to_date(0).as_deref(), Some("1970-01-01"));
}

#[test]
fn wrong_password_and_missing_file() {
    let path = fake_db();
    let v = vault();
    let err = v
        .preview_moneymoney_database(path.clone(), "falsch".into(), None)
        .unwrap_err();
    assert!(matches!(err, CoreError::Authentication { .. }));
    assert!(err.to_string().contains("Falsches Passwort"));
    assert!(!err.to_string().contains("falsch\""));
    let err = v
        .preview_moneymoney_database(path, String::new(), None)
        .unwrap_err();
    assert!(matches!(err, CoreError::Authentication { .. }));
    let err = v
        .preview_moneymoney_database("/nonexistent/MoneyMoney.sqlite".into(), PW.into(), None)
        .unwrap_err();
    assert!(matches!(err, CoreError::NotFound { .. }));
    // an unencrypted SQLite file that is not MoneyMoney's
    let plain = temp("plain.sqlite");
    Connection::open(&plain)
        .unwrap()
        .execute_batch("CREATE TABLE x (a);")
        .unwrap();
    let err = v
        .preview_moneymoney_database(plain.to_string_lossy().to_string(), PW.into(), None)
        .unwrap_err();
    assert!(matches!(err, CoreError::Authentication { .. }));
}

#[test]
fn unencrypted_database_opens_with_empty_password() {
    let path = fake_db_unencrypted();
    let v = vault();
    let p = v
        .preview_moneymoney_database(path.clone(), String::new(), None)
        .unwrap();
    assert_eq!(p.accounts.len(), 4);
    // an encrypted file must not open without a password
    let enc = fake_db();
    assert!(v
        .preview_moneymoney_database(enc, String::new(), None)
        .is_err());
}

#[test]
fn older_cipher_compatibility_3_opens() {
    let path = fake_db_with(true, "");
    let p = vault()
        .preview_moneymoney_database(path, PW.into(), None)
        .unwrap();
    assert_eq!(p.accounts.len(), 4);
}

#[test]
fn source_file_bytes_unchanged_after_preview_and_import() {
    let path = fake_db();
    let before = std::fs::read(&path).unwrap();
    let modified = std::fs::metadata(&path).unwrap().modified().unwrap();
    let v = vault();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path.clone(), PW.into(), options_from(&p, true, true))
        .unwrap();
    v.import_moneymoney_database(path.clone(), PW.into(), options_from(&p, true, true))
        .unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), before);
    assert_eq!(
        std::fs::metadata(&path).unwrap().modified().unwrap(),
        modified
    );
    // and the connection really is read-only
    let c = open_source(&path, &SecretString::new(PW.into())).unwrap();
    assert!(c.execute("DELETE FROM pins", []).is_err());
}

#[test]
fn preview_lists_accounts_banks_categories_and_totals() {
    let v = vault();
    let p = v
        .preview_moneymoney_database(fake_db(), PW.into(), None)
        .unwrap();
    let giro = p.accounts.iter().find(|a| a.mm_id == 1).unwrap();
    assert_eq!(giro.iban, "DE89370400440532013000");
    assert_eq!(giro.group_name, "Privat");
    assert_eq!(giro.bank_name, "comdirect");
    assert_eq!(giro.suggested_kind, AccountKind::Checking);
    // 5 = salary, REWE, bakery, 2 split parts (parent + pending not counted)
    assert_eq!((giro.booking_count, giro.pending_count), (5, 1));
    assert_eq!(giro.first_date.as_deref(), Some("2005-01-01"));
    assert_eq!(giro.last_date.as_deref(), Some("2026-03-07"));
    // newest `balances` row (100,00) + booked bookings (parent, not parts)
    assert_eq!(
        giro.computed_balance_cents,
        10_000 + 250_000 - 4567 - 1230 - 10_000
    );
    assert!(giro.balance_source.contains("Saldenverlauf"));
    let kind = |id: i64| {
        p.accounts
            .iter()
            .find(|a| a.mm_id == id)
            .unwrap()
            .suggested_kind
    };
    assert_eq!(kind(2), AccountKind::CreditCard);
    assert_eq!(kind(3), AccountKind::Brokerage);
    let usd = p.accounts.iter().find(|a| a.mm_id == 4).unwrap();
    assert_eq!(usd.currency, "USD");
    // accounts.initial_balance (10,50) + 25,255 → 25,26
    assert_eq!(usd.computed_balance_cents, 1050 + 2526);
    assert_eq!(
        p.category_paths,
        vec![
            "Gehalt",
            "Steuern / Büro",
            "Haushalt › Supermarkt",
            "Wohnen › Nebenkosten › Strom"
        ]
    );
    assert_eq!(
        (p.total_bookings, p.pending_bookings, p.split_parts),
        (7, 1, 2)
    );
    assert_eq!(p.notes_count, 2);
    assert_eq!(p.date_range_start.as_deref(), Some("2005-01-01"));
    let bank = |id: i64| p.banks.iter().find(|b| b.mm_id == id).unwrap();
    assert_eq!(bank(1).connector, Some(ConnectorKind::Comdirect));
    assert_eq!(bank(1).login_name, "1234567");
    assert_eq!(
        bank(2).connector,
        Some(ConnectorKind::VolksbankKasselGoettingen)
    );
    assert_eq!(bank(3).connector, None);
    assert!(bank(1).has_saved_pin);
    assert_eq!(bank(1).account_count, 3);
    // the preview never stores anything
    assert!(v.list_accounts().unwrap().is_empty());
    assert!(v.list_bank_connections().unwrap().is_empty());
}

#[test]
fn import_categories_splits_pending_notes_and_balance() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let r = v
        .import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!((r.accounts_created, r.accounts_merged), (4, 0));
    assert_eq!(
        (r.bookings_new, r.bookings_duplicates, r.pending_skipped),
        (7, 0, 1)
    );
    assert_eq!(r.notes_imported, 2);
    // Haushalt, Supermarkt, Gehalt, Wohnen, Nebenkosten, Strom, Steuern / Büro
    assert_eq!(r.categories_created, 7);
    assert_eq!(r.connections_created, 0);

    let giro = account_by_name(&v, "Girokonto");
    assert_eq!(giro.iban, "DE89370400440532013000");
    assert_eq!(giro.bank_name, "comdirect");
    assert_eq!(giro.balance_cents, 10_000 + 250_000 - 4567 - 1230 - 10_000);
    assert_eq!(giro.balance_date, "2026-03-07");
    let bs = bookings(&v, giro.id);
    assert_eq!(bs.len(), 5);
    let find = |name: &str, cents: i64| {
        bs.iter()
            .find(|b| b.counterparty == name && b.amount_cents == cents)
            .unwrap_or_else(|| panic!("{name} {cents}"))
    };
    // grouped category path
    let rewe = find("REWE Markt", -4567);
    assert_eq!(rewe.category_path, "Haushalt › Supermarkt");
    assert_eq!(rewe.counterparty_iban, "DE02100100100006820101");
    assert_eq!(rewe.booking_text, "LASTSCHRIFT");
    assert!(rewe.purpose.starts_with("Einkauf Filiale 12"));
    assert!(rewe.purpose.contains("MREF: MANDAT-1"));
    assert!(rewe.purpose.contains("CRED: DE98ZZZ09999999999"));
    assert!(rewe.purpose.contains("EREF: E2E-1"));
    assert_eq!(rewe.booking_date, "2026-03-05");
    // uncategorised in MoneyMoney → no MoneyMoney category
    let bakery = find("Bäckerei Schmidt", -1230);
    assert_ne!(bakery.category_source, CategorySource::Manual);
    assert_eq!(bakery.counterparty_iban, ""); // "12345" is no IBAN
    assert_eq!(bakery.value_date, "");
    // note
    let salary = find("Arbeitgeber GmbH", 250_000);
    assert_eq!(salary.note, "erstes Gehalt");
    assert_eq!(salary.category_path, "Gehalt");
    assert_eq!(salary.booking_date, "2005-01-01");
    // splits: parts with own categories, parent not imported
    assert_eq!(
        find("Kaufhaus Muster", -6000).category_path,
        "Haushalt › Supermarkt"
    );
    assert_eq!(
        find("Kaufhaus Muster", -4000).category_path,
        "Wohnen › Nebenkosten › Strom"
    );
    assert!(!bs.iter().any(|b| b.amount_cents == -10_000));
    // pending not imported
    assert!(!bs.iter().any(|b| b.counterparty == "Streaming AG"));

    // category name containing " / " stays one category
    let visa = account_by_name(&v, "Visa-Karte");
    assert_eq!(visa.kind, AccountKind::CreditCard);
    let vb = bookings(&v, visa.id);
    assert_eq!(vb[0].category_path, "Steuern / Büro");
    assert_eq!(vb[0].note, "Abo kündigen");
    let groups = v.list_account_groups().unwrap();
    assert!(groups
        .iter()
        .any(|g| g.name == "Kreditkarten" && g.accounts.iter().any(|a| a.id == visa.id)));
    assert!(groups
        .iter()
        .any(|g| g.name == "Depots & ETFs" && g.accounts.iter().any(|a| a.name == "Depot")));
    let usd = account_by_name(&v, "Dollar-Konto");
    assert_eq!(usd.currency, "USD");
    assert_eq!(bookings(&v, usd.id)[0].amount_cents, 2526);
}

#[test]
fn reimport_is_idempotent() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let first = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, true, true))
        .unwrap();
    let count = |v: &Vault| {
        let db = v.db().unwrap();
        let q = |sql: &str| db.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap();
        (
            q("SELECT count(*) FROM accounts"),
            q("SELECT count(*) FROM transactions"),
            q("SELECT count(*) FROM categories"),
            q("SELECT count(*) FROM bank_connections"),
            q("SELECT count(*) FROM settings WHERE key LIKE 'pin.conn.%'"),
        )
    };
    let after_first = count(&v);
    // second run with the options a fresh preview suggests …
    let p2 = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    assert!(p2.accounts.iter().all(|a| a.existing_account_id.is_some()));
    assert!(p2.banks[..2]
        .iter()
        .all(|b| b.existing_connection_id.is_some()));
    let second = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p2, true, true))
        .unwrap();
    // … and a third one that still says "new account" everywhere
    let third = v
        .import_moneymoney_database(path, PW.into(), options_from(&p, true, true))
        .unwrap();
    for r in [&second, &third] {
        assert_eq!((r.accounts_created, r.accounts_merged), (0, 4));
        assert_eq!(
            (r.bookings_new, r.bookings_duplicates),
            (0, first.bookings_new)
        );
        assert_eq!((r.categories_created, r.connections_created), (0, 0));
        assert_eq!((r.connections_existing, r.pins_stored), (2, 0));
    }
    assert_eq!(count(&v), after_first);
    assert_eq!(
        account_by_name(&v, "Girokonto").balance_cents,
        10_000 + 250_000 - 4567 - 1230 - 10_000
    );
}

#[test]
fn iban_match_merges_into_existing_synced_account() {
    let v = vault();
    let conn_id = v
        .add_bank_connection(
            ConnectorKind::Comdirect,
            "comdirect".into(),
            "1234567".into(),
        )
        .unwrap();
    let existing = {
        let db = v.db().unwrap();
        let gid = Vault::ensure_group(&db, "Giro & Tagesgeld", "building.columns", 1).unwrap();
        db.execute(
            "INSERT INTO accounts(connection_id, group_id, external_ref, name, iban, currency, kind, balance_cents)
             VALUES (?1, ?2, 'abc-123', 'Mein Giro', 'DE89 3704 0044 0532 0130 00', 'EUR', 'checking', 123456)",
            params![conn_id, gid],
        )
        .unwrap();
        let id = db.last_insert_rowid();
        // already fetched by the bank: the REWE booking without category
        db.execute(
            "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, counterparty, counterparty_iban, purpose)
             VALUES (?1, 'bank-1', '2026-03-05', -4567, 'REWE Markt', 'DE02100100100006820101', 'Einkauf Filiale 12')",
            [id],
        )
        .unwrap();
        id
    };
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let giro = p.accounts.iter().find(|a| a.mm_id == 1).unwrap();
    assert_eq!(giro.existing_account_id, Some(existing));
    assert_eq!(giro.existing_account_name.as_deref(), Some("Mein Giro"));
    assert_eq!(p.banks[0].existing_connection_id, Some(conn_id));
    let mut o = options_from(&p, true, false);
    o.accounts.retain(|c| c.mm_id == 1);
    let r = v.import_moneymoney_database(path, PW.into(), o).unwrap();
    assert_eq!((r.accounts_created, r.accounts_merged), (0, 1));
    assert_eq!(
        (r.bookings_new, r.bookings_duplicates, r.bookings_enriched),
        (4, 1, 1)
    );
    assert_eq!((r.connections_created, r.connections_existing), (1, 1));
    let acc = v
        .list_accounts()
        .unwrap()
        .into_iter()
        .find(|a| a.id == existing)
        .unwrap();
    // the bank's balance stays authoritative for synced accounts
    assert_eq!(acc.balance_cents, 123_456);
    assert_eq!(acc.name, "Mein Giro");
    let bs = bookings(&v, existing);
    assert_eq!(bs.len(), 5);
    let rewe = bs.iter().find(|b| b.counterparty == "REWE Markt").unwrap();
    assert_eq!(rewe.category_path, "Haushalt › Supermarkt");
    assert_eq!(v.list_accounts().unwrap().len(), 1);
}

#[test]
fn first_bank_sync_adopts_imported_account_by_iban() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, true, false))
        .unwrap();
    let giro = account_by_name(&v, "Girokonto");
    let conn_id = v.list_bank_connections().unwrap()[0].id;
    let db = v.db().unwrap();
    assert_eq!(
        adopt_account(&db, conn_id, "remote-1", "", AccountKind::Checking).unwrap(),
        None
    );
    let adopted = adopt_account(
        &db,
        conn_id,
        "remote-1",
        "DE89 3704 0044 0532 0130 00",
        AccountKind::Checking,
    )
    .unwrap();
    assert_eq!(adopted, Some(giro.id));
    let (c, e): (Option<i64>, String) = db
        .query_row(
            "SELECT connection_id, external_ref FROM accounts WHERE id = ?1",
            [giro.id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!((c, e.as_str()), (Some(conn_id), "remote-1"));
    // only once
    assert_eq!(
        adopt_account(
            &db,
            conn_id,
            "remote-2",
            "DE89370400440532013000",
            AccountKind::Checking
        )
        .unwrap(),
        None
    );
}

#[test]
fn connections_for_supported_banks_only_and_pins_on_request() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    // without import_pins: connections, but no PIN
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, true, false))
        .unwrap();
    assert_eq!(
        (
            r.connections_created,
            r.banks_skipped_unsupported,
            r.pins_stored
        ),
        (2, 1, 0)
    );
    let conns = v.list_bank_connections().unwrap();
    assert_eq!(conns.len(), 2);
    let comdirect = conns
        .iter()
        .find(|c| c.connector == ConnectorKind::Comdirect)
        .unwrap();
    assert_eq!(comdirect.login_name, "1234567");
    let vb = conns
        .iter()
        .find(|c| c.connector == ConnectorKind::VolksbankKasselGoettingen)
        .unwrap();
    assert_eq!(vb.login_name, "VRNK4711");
    for c in &conns {
        assert!(!v.connection_status(c.id).unwrap().has_pin);
    }
    // with import_pins: stored for the supported banks only
    let r = v
        .import_moneymoney_database(path, PW.into(), options_from(&p, true, true))
        .unwrap();
    assert_eq!((r.connections_created, r.pins_stored), (0, 2));
    let db = v.db().unwrap();
    let pin = |id: i64| -> String {
        db.query_row(
            "SELECT value FROM settings WHERE key = ?1 AND is_secret = 1",
            [crate::connections::pin_key(id)],
            |r| r.get(0),
        )
        .unwrap()
    };
    assert_eq!(pin(comdirect.id), "11111");
    assert_eq!(pin(vb.id), "22222");
    let n: i64 = db
        .query_row(
            "SELECT count(*) FROM settings WHERE value = '33333'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(n, 0);
}

/// Replaces the secret columns of `banks`, `accounts` and `pins.pin` by views
/// whose secret columns raise an error when evaluated. The importer must still
/// work – proving it never reads them (and `pins.pin` only on request).
const TRAP: &str = r#"
ALTER TABLE banks RENAME TO banks_data;
CREATE VIEW banks AS SELECT rowid, country, bankcode, username, customer, json('x') AS credential, name, server,
  protocol, tanmethod, tanmedium, json('x') AS systemid, tanmethods, json('x') AS bpd, json('x') AS upd, spa, spa_tsp,
  json('x') AS local_storage, json('x') AS pubkey, json('x') AS privkey, json('x') AS userdata FROM banks_data;
ALTER TABLE accounts RENAME TO accounts_data;
CREATE VIEW accounts AS SELECT rowid, bank_key, account, subaccount, bankcode, portfolio, iban, bic, currency, name,
  owner, kind, type, sort, icon, balances, pending_balances, overdraft_limit, available_funds, initial_balance, cub,
  cub_tsp, recipient_key, refresh_tsp, balance_tsp, transaction_tsp, payment_tsp, error_tsp, cancel_tsp, statements,
  refresh_actions, refresh, json('x') AS userdata, json('x') AS cred, json('x') AS transientdata, perspective,
  group_key, error, json('x') AS web_ops FROM accounts_data;
ALTER TABLE pins RENAME TO pins_data;
CREATE VIEW pins AS SELECT bank_key, json('x') AS pin FROM pins_data;
"#;

#[test]
fn secret_columns_and_pins_are_never_read_unless_requested() {
    let path = fake_db_with(false, TRAP);
    // positive control: evaluating a trapped column fails
    let c = open_source(&path, &SecretString::new(PW.into())).unwrap();
    assert!(c
        .query_row("SELECT pin FROM pins LIMIT 1", [], |r| r
            .get::<_, String>(0))
        .is_err());
    assert!(c
        .query_row("SELECT credential FROM banks LIMIT 1", [], |r| r
            .get::<_, String>(0))
        .is_err());
    drop(c);
    let v = vault();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    assert!(p.banks[0].has_saved_pin);
    // connections without PINs, and PINs requested without connections: pin column untouched
    v.import_moneymoney_database(path.clone(), PW.into(), options_from(&p, true, false))
        .unwrap();
    v.import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, true))
        .unwrap();
    // only now the (trapped) pin column is read
    assert!(v
        .import_moneymoney_database(path, PW.into(), options_from(&p, true, true))
        .is_err());
}

#[test]
fn kind_override_on_reimport() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let mut o = options_from(&p, false, false);
    for c in &mut o.accounts {
        c.import = c.mm_id == 2;
        c.kind = AccountKind::Checking;
    }
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), o.clone())
        .unwrap();
    assert_eq!((r.accounts_created, r.bookings_new), (1, 1));
    assert_eq!(
        account_by_name(&v, "Visa-Karte").kind,
        AccountKind::Checking
    );
    // changing the kind on a later run re-files the importer's own account
    o.accounts
        .iter_mut()
        .for_each(|c| c.kind = AccountKind::CreditCard);
    v.import_moneymoney_database(path, PW.into(), o).unwrap();
    assert_eq!(
        account_by_name(&v, "Visa-Karte").kind,
        AccountKind::CreditCard
    );
    assert_eq!(v.list_accounts().unwrap().len(), 1);
}

#[test]
fn imported_accounts_are_linked_to_their_bank_login() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, true, false))
        .unwrap();
    let comdirect = v.list_bank_connections().unwrap()[0].id;
    for name in ["Girokonto", "Visa-Karte", "Depot"] {
        assert_eq!(
            account_by_name(&v, name).connection_id,
            Some(comdirect),
            "{name}"
        );
    }
    // unsupported bank: no login, account stays on its own
    assert_eq!(account_by_name(&v, "Dollar-Konto").connection_id, None);
}

#[test]
fn accounts_stay_unlinked_without_bank_logins() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    assert!(v
        .list_accounts()
        .unwrap()
        .iter()
        .all(|a| a.connection_id.is_none()));
}

#[test]
fn first_bank_sync_adopts_imported_card_without_iban_by_kind() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, true, false))
        .unwrap();
    let visa = account_by_name(&v, "Visa-Karte");
    let conn_id = v.list_bank_connections().unwrap()[0].id;
    let db = v.db().unwrap();
    // a fetched account with an IBAN never takes over an account by kind
    assert_eq!(
        adopt_account(
            &db,
            conn_id,
            "card-x",
            "DE02120300000000202051",
            AccountKind::CreditCard
        )
        .unwrap(),
        None
    );
    assert_eq!(
        adopt_account(&db, conn_id, "card-1", "", AccountKind::CreditCard).unwrap(),
        Some(visa.id)
    );
    // only once, and never for another login
    assert_eq!(
        adopt_account(&db, conn_id, "card-2", "", AccountKind::CreditCard).unwrap(),
        None
    );
    assert_eq!(
        adopt_account(&db, conn_id + 1, "dep-1", "", AccountKind::Brokerage).unwrap(),
        None
    );
}

#[test]
fn starter_categories_are_replaced_in_an_empty_vault() {
    let v = vault();
    assert!(v.seed_starter_categories().unwrap() > 0);
    assert!(!v.list_rules().unwrap().is_empty());
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    assert!(p.replaces_starter_categories);
    v.import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    let mut names: Vec<String> = v
        .list_categories(None, None)
        .unwrap()
        .into_iter()
        .map(|c| c.name)
        .collect();
    names.sort();
    assert_eq!(
        names,
        [
            "Gehalt",
            "Haushalt",
            "Nebenkosten",
            "Steuern / Büro",
            "Strom",
            "Supermarkt",
            "Wohnen"
        ]
    );
    assert!(v.list_rules().unwrap().is_empty());
}

#[test]
fn starter_categories_stay_when_the_vault_has_bookings() {
    let v = vault();
    let starter = v.seed_starter_categories().unwrap() as usize;
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    // second run: the vault now has bookings, nothing is replaced
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    assert!(!p.replaces_starter_categories);
    let before = v.list_categories(None, None).unwrap().len();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(v.list_categories(None, None).unwrap().len(), before);

    let v = vault();
    v.seed_starter_categories().unwrap();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    // categories not wanted: the starter set stays
    let mut o = options_from(&p, false, false);
    o.import_categories = false;
    v.import_moneymoney_database(path, PW.into(), o).unwrap();
    assert_eq!(v.list_categories(None, None).unwrap().len(), starter);
}

#[test]
fn directory_banks_map_to_fints_keys() {
    // (bank code, name) -> stored connector key
    for (code, name, key) in [
        ("50010517", "ING", "fints:50010517"),
        ("43060967", "GLS Gemeinschaftsbank", "fints:43060967"),
        ("12030000", "DKB", "fints:12030000"),
        ("76030080", "Consorsbank", "fints:76030080"),
        ("10077777", "Norisbank", "fints:10077777"),
        ("66090800", "BBBank", "fints:66090800"),
        ("30060601", "apoBank", "fints:30060601"),
        ("83094495", "EthikBank", "fints:83094495"),
        ("10050000", "Berliner Sparkasse", "fints:10050000"),
        ("10070000", "Deutsche Bank", "fints:10070000"),
        ("70020270", "HypoVereinsbank", "fints:70020270"),
        ("1005 0000", "Berliner Sparkasse", "fints:10050000"),
    ] {
        let (kind, k) = connector_key_for(code, name).unwrap_or_else(|| panic!("{code}"));
        assert_eq!(kind, ConnectorKind::FinTsGeneric, "{code}");
        assert_eq!(k, key);
    }
    // dedicated connectors keep precedence over the directory
    assert_eq!(
        connector_key_for("20041111", "comdirect").unwrap().0,
        ConnectorKind::Comdirect
    );
    assert_eq!(
        connector_key_for("52090000", "Volksbank Kassel Göttingen")
            .unwrap()
            .1,
        "fints:52090000"
    );
    // unknown German bank code stays unsupported
    assert!(connector_key_for("12345678", "Sparkasse Musterstadt").is_none());
}

#[test]
fn generic_enable_banking_connection_is_stored_once() {
    let v = vault();
    let a = v
        .add_enable_banking_connection("N26".into(), "de".into(), "".into(), "".into())
        .unwrap();
    let b = v
        .add_enable_banking_connection("N26".into(), "DE".into(), "N26".into(), "".into())
        .unwrap();
    assert_eq!(a, b);
    assert!(v
        .add_enable_banking_connection("".into(), "DE".into(), "".into(), "".into())
        .is_err());
    assert!(v
        .add_enable_banking_connection("N26".into(), "DEU".into(), "".into(), "".into())
        .is_err());
    let c = v.list_bank_connections().unwrap();
    assert_eq!(c.len(), 1);
    assert_eq!(c[0].connector, ConnectorKind::EnableBanking);
    assert_eq!(c[0].display_name, "N26");
}

fn sha256(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect()
}

fn pdf(text: &str) -> Vec<u8> {
    format!("%PDF-1.4\n{text}\n%%EOF").into_bytes()
}

/// A MoneyMoney database listing four documents (and a deleted one) the way
/// MoneyMoney does: bank folder, file name, date, upper-case SHA-256.
fn statements_db() -> String {
    let (a, b, c, d) = (pdf("A"), pdf("B"), pdf("C"), pdf("D"));
    fake_db_with(
        false,
        &format!(
            "INSERT INTO statements (rowid, account_key, name, directory, filename, created_tsp, deleted, digest) VALUES
               (1, 1, 'Girokonto', 'Musterbank', 'Kontoauszug_2026_001.pdf', 1767225600, 0, '{}'),
               (2, 1, 'Girokonto', 'Musterbank', 'Steuerbescheinigung_2025.pdf', 1767312000, 0, '{}'),
               (3, 1, 'Girokonto', 'Musterbank', 'Kreditkartenabrechnung_2026_01.pdf', 1767398400, 0, '{}'),
               (4, 1, 'Girokonto', 'Musterbank', 'Geloescht.pdf', 1767398400, 1, ''),
               (5, 2, 'Visa-Karte', 'Musterbank', 'Vertragsinformationen.pdf', 1767484800, 0, '{}');",
            sha256(&a),
            sha256(&b),
            sha256(&c),
            sha256(&d)
        ),
    )
}

fn docs(v: &Vault) -> Vec<(String, String, String, String)> {
    let mut out: Vec<_> = v
        .list_all_documents(crate::documents::DocumentFilter::default())
        .unwrap()
        .into_iter()
        .map(|d| (d.file_name, d.doc_type, d.doc_date, d.title))
        .collect();
    out.sort();
    out
}

#[test]
fn statements_are_imported_from_the_moneymoney_folder() {
    // <folder>/Database/MoneyMoney.sqlite + <folder>/Statements/<bank>/<file>
    let folder = temp("mm-folder");
    let bank = folder.join("Statements").join("Musterbank");
    std::fs::create_dir_all(&bank).unwrap();
    std::fs::create_dir_all(folder.join("Database")).unwrap();
    std::fs::rename(
        statements_db(),
        folder.join("Database").join("MoneyMoney.sqlite"),
    )
    .unwrap();
    std::fs::write(bank.join("Kontoauszug_2026_001.pdf"), pdf("A")).unwrap();
    // B is missing, C has other content than the database says, D is fine
    std::fs::write(bank.join("Kreditkartenabrechnung_2026_01.pdf"), pdf("X")).unwrap();
    std::fs::write(bank.join("Vertragsinformationen.pdf"), pdf("D")).unwrap();
    std::fs::write(bank.join("Fremd.pdf"), pdf("F")).unwrap();
    let path = folder.to_string_lossy().to_string();

    let v = vault();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    assert!(p.database_path.ends_with("MoneyMoney.sqlite"));
    assert!(p.statements_dir.as_deref().unwrap().ends_with("Statements"));
    assert_eq!((p.statement_count, p.statements_found), (4, 3));
    assert_eq!(p.statements_bytes, 3 * pdf("A").len() as u64);
    let giro = p.accounts.iter().find(|a| a.name == "Girokonto").unwrap();
    assert_eq!(giro.statement_count, 3, "the deleted one is not counted");

    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(
        (
            r.documents_imported,
            r.documents_missing,
            r.documents_mismatched,
            r.documents_unlisted
        ),
        (2, 1, 1, 1)
    );
    assert_eq!(
        docs(&v),
        vec![
            (
                "Kontoauszug_2026_001.pdf".to_string(),
                "kontoauszug".to_string(),
                "2026-01-01".to_string(),
                "Kontoauszug 2026 001".to_string()
            ),
            (
                "Vertragsinformationen.pdf".to_string(),
                "postbox".to_string(),
                "2026-01-04".to_string(),
                "Vertragsinformationen".to_string()
            ),
        ]
    );
    // linked to their accounts
    let giro_id = account_by_name(&v, "Girokonto").id;
    let of_giro = v
        .list_all_documents(crate::documents::DocumentFilter {
            account_id: Some(giro_id),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(of_giro.len(), 1);

    // again: nothing twice; and without the option nothing at all
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!((r.documents_imported, r.documents_existing), (0, 2));
    let mut off = options_from(&p, false, false);
    off.import_statements = false;
    let r = v.import_moneymoney_database(path, PW.into(), off).unwrap();
    assert_eq!(
        (
            r.documents_imported,
            r.documents_existing,
            r.documents_missing
        ),
        (0, 0, 0)
    );
    assert_eq!(docs(&v).len(), 2);
    let _ = std::fs::remove_dir_all(folder);
}

#[test]
fn statements_of_a_backup_come_from_a_separately_saved_folder() {
    // a single database file somewhere: documents are listed, but no files
    let path = statements_db();
    let v = vault();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    assert_eq!(
        (
            p.statement_count,
            p.statements_found,
            p.statements_dir.clone()
        ),
        (4, 0, None)
    );
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!((r.documents_imported, r.documents_missing), (0, 4));

    // later, with a manual backup of the PDFs: A renamed in a subfolder (found
    // by checksum), B by its name without the bank folder, C and D not saved
    let saved = temp("mm-saved");
    std::fs::create_dir_all(saved.join("alt")).unwrap();
    std::fs::write(saved.join("alt").join("scan 1.PDF"), pdf("A")).unwrap();
    std::fs::write(saved.join("Steuerbescheinigung_2025.pdf"), pdf("B")).unwrap();
    std::fs::write(saved.join("notiz.txt"), b"kein PDF").unwrap();
    let dir = saved.to_string_lossy().to_string();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), Some(dir.clone()))
        .unwrap();
    assert_eq!((p.statement_count, p.statements_found), (4, 2));
    let mut options = options_from(&p, false, false);
    options.statements_dir = Some(dir);
    let r = v
        .import_moneymoney_database(path, PW.into(), options)
        .unwrap();
    assert_eq!(
        (
            r.documents_imported,
            r.documents_missing,
            r.documents_mismatched,
            r.documents_unlisted
        ),
        (2, 2, 0, 0)
    );
    let d = docs(&v);
    assert_eq!(d.len(), 2);
    // the original file name and date come from the database
    assert_eq!(d[0].0, "Kontoauszug_2026_001.pdf");
    assert_eq!(
        (d[1].0.as_str(), d[1].1.as_str(), d[1].2.as_str()),
        ("Steuerbescheinigung_2025.pdf", "steuer", "2026-01-02")
    );
    let _ = std::fs::remove_dir_all(saved);
}

#[test]
fn brand_banks_with_pseudo_bank_code_map_to_their_connector() {
    assert_eq!(
        connector_for("10012345", "Trade Republic"),
        Some(ConnectorKind::TradeRepublic)
    );
    assert_eq!(connector_for("", "PayPal"), Some(ConnectorKind::PayPal));
    assert_eq!(connector_for("12345678", "Sparkasse Musterstadt"), None);
    assert_eq!(
        connector_for("20041111", "comdirect"),
        Some(ConnectorKind::Comdirect)
    );
}

#[test]
fn depot_balance_from_shown_balance_and_holdings() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let depot = p.accounts.iter().find(|a| a.name == "Depot").unwrap();
    assert!(depot.is_portfolio);
    assert_eq!(depot.computed_balance_cents, 1_234_567);
    assert!(
        depot.balance_source.contains("MoneyMoney"),
        "{}",
        depot.balance_source
    );
    assert_eq!(depot.holding_count, 2, "sold position skipped");
    // accounts without the blob keep the derived balance
    let giro = p.accounts.iter().find(|a| a.name == "Girokonto").unwrap();
    assert!(giro.balance_source.contains("Saldenverlauf"));

    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(r.holdings_imported, 2);
    let acc = account_by_name(&v, "Depot");
    assert_eq!(acc.balance_cents, 1_234_567);
    assert_eq!(acc.balance_date, "2026-03-07");
    let h = v.list_holdings(acc.id).unwrap();
    assert_eq!(h.len(), 2);
    let etf = h.iter().find(|x| x.isin == "IE00B4L5Y983").unwrap();
    assert_eq!(
        (
            etf.name.as_str(),
            etf.wkn.as_str(),
            etf.quantity,
            etf.current_price_cents,
            etf.purchase_price_cents,
            etf.value_cents
        ),
        ("Muster World ETF", "A0RPWH", 12.5, 8000, 7000, 100_000)
    );
    let cash = h.iter().find(|x| x.name == "Liquidität").unwrap();
    assert_eq!((cash.quantity, cash.value_cents), (0.0, 34_567));

    // second run replaces instead of duplicating
    let p2 = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let r2 = v
        .import_moneymoney_database(path, PW.into(), options_from(&p2, false, false))
        .unwrap();
    assert_eq!(r2.holdings_imported, 2);
    assert_eq!(v.list_holdings(acc.id).unwrap().len(), 2);
}

#[test]
fn balances_blob_parsing() {
    assert_eq!(
        parse_balances_blob(Value::Text("11:4094.320000,3:EUR,".into())),
        Some((409_432, "EUR".into()))
    );
    assert_eq!(
        parse_balances_blob(Value::Blob(b"11:-671.230000,3:EUR,".to_vec())),
        Some((-67_123, "EUR".into()))
    );
    assert_eq!(parse_balances_blob(Value::Text(String::new())), None);
    assert_eq!(parse_balances_blob(Value::Null), None);
}

#[test]
fn reimport_of_emptied_depot_removes_stale_holdings() {
    let v = vault();
    let p = v
        .preview_moneymoney_database(fake_db(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(fake_db(), PW.into(), options_from(&p, false, false))
        .unwrap();
    let depot = account_by_name(&v, "Depot");
    assert_eq!(v.list_holdings(depot.id).unwrap().len(), 2);

    // MoneyMoney later: all positions sold, balance down to the cash remainder
    let sold = fake_db_with(
        false,
        "UPDATE securities SET deleted = 1 WHERE account_key = 3;
         UPDATE accounts SET balances = CAST('6:0.010000,3:EUR,' AS BLOB) WHERE rowid = 3;",
    );
    let p2 = v
        .preview_moneymoney_database(sold.clone(), PW.into(), None)
        .unwrap();
    let d2 = p2.accounts.iter().find(|a| a.name == "Depot").unwrap();
    assert_eq!(d2.holding_count, 0);
    assert_eq!(
        d2.existing_account_id,
        Some(depot.id),
        "recognised by external ref"
    );
    let r = v
        .import_moneymoney_database(sold, PW.into(), options_from(&p2, false, false))
        .unwrap();
    assert_eq!(r.holdings_imported, 0);
    assert!(
        v.list_holdings(depot.id).unwrap().is_empty(),
        "stale positions removed"
    );
    assert_eq!(account_by_name(&v, "Depot").balance_cents, 1);
}

#[test]
fn shown_balance_also_wins_for_checking_accounts() {
    // MoneyMoney's displayed balance is authoritative for every account type:
    // it is what the user sees in MoneyMoney, independent of how far back the
    // booking history goes. The derived balance (initial balance + bookings)
    // remains the fallback for databases without the blob.
    let v = vault();
    let path = fake_db_with(
        false,
        "UPDATE accounts SET balances = CAST('10:1234.560000,3:EUR,' AS BLOB), balance_tsp = 1772971200 WHERE rowid = 1;",
    );
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let giro = p.accounts.iter().find(|a| a.name == "Girokonto").unwrap();
    assert_eq!(giro.computed_balance_cents, 123_456);
    assert!(
        giro.balance_source.contains("Saldo laut MoneyMoney"),
        "{}",
        giro.balance_source
    );
    // other accounts (no blob) keep the derived value and its source text
    let visa = p.accounts.iter().find(|a| a.name == "Visa-Karte").unwrap();
    assert!(
        visa.balance_source.contains("Umsätze"),
        "{}",
        visa.balance_source
    );

    v.import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    let acc = account_by_name(&v, "Girokonto");
    assert_eq!(acc.balance_cents, 123_456);
    // balance date = max(newest booking, balance timestamp)
    assert_eq!(acc.balance_date, "2026-03-08");
}

#[test]
fn import_takes_over_moneymoney_groups() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(r.groups_created, 1);
    let gs = v.list_user_groups().unwrap();
    let privat = gs
        .iter()
        .find(|g| g.name == "Privat")
        .expect("group 'Privat'");
    let mut n: Vec<_> = privat.accounts.iter().map(|a| a.name.as_str()).collect();
    n.sort();
    assert_eq!(n, ["Girokonto", "Visa-Karte"]);
    assert!(
        gs.iter().any(|g| g.is_ungrouped),
        "accounts without MoneyMoney group stay ungrouped"
    );
    // idempotent: no second group, a user move is kept on re-import
    let giro = privat
        .accounts
        .iter()
        .find(|a| a.name == "Girokonto")
        .unwrap()
        .id;
    v.move_account_to_group(giro, None, None).unwrap();
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(r.groups_created, 0);
    let gs = v.list_user_groups().unwrap();
    assert!(gs
        .iter()
        .find(|g| g.is_ungrouped)
        .unwrap()
        .accounts
        .iter()
        .any(|a| a.id == giro));
}

#[test]
fn import_takes_over_nested_groups_in_moneymoney_order() {
    let v = vault();
    // "Immobilien" (before "Privat") with two subgroups, listed Heilbronn before Neckarsulm
    let path = fake_db_with(
        false,
        "INSERT INTO account_groups (rowid, name, group_key, sort) VALUES
           (2, 'Immobilien', 0, 0), (3, 'ETW Neckarsulm', 2, 2), (4, 'ETW Heilbronn', 2, 1);
         UPDATE accounts SET group_key = 3 WHERE rowid = 3;
         UPDATE accounts SET group_key = 4 WHERE rowid = 4;",
    );
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let shown = |name: &str| {
        p.accounts
            .iter()
            .find(|a| a.name == name)
            .unwrap()
            .group_name
            .clone()
    };
    assert_eq!(shown("Depot"), "Immobilien › ETW Neckarsulm");
    assert_eq!(shown("Girokonto"), "Privat");
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(r.groups_created, 4);
    let tree = |v: &Vault| -> Vec<(String, u32, Vec<String>)> {
        v.list_user_groups()
            .unwrap()
            .into_iter()
            .map(|g| {
                let mut names: Vec<String> = g.accounts.into_iter().map(|a| a.name).collect();
                names.sort();
                (g.name, g.depth, names)
            })
            .collect()
    };
    let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    assert_eq!(
        tree(&v),
        vec![
            ("Immobilien".to_string(), 0, vec![]),
            ("ETW Heilbronn".to_string(), 1, s(&["Dollar-Konto"])),
            ("ETW Neckarsulm".to_string(), 1, s(&["Depot"])),
            ("Privat".to_string(), 0, s(&["Girokonto", "Visa-Karte"])),
        ]
    );
    // the parent's sum covers its subgroups
    let groups = v.list_user_groups().unwrap();
    assert_eq!(
        groups[0].balance_cents,
        groups[1].balance_cents + groups[2].balance_cents
    );

    // re-import: nothing new, and a group the user moved stays where it is
    let heilbronn = groups[1].uuid.clone();
    v.set_user_group_parent(heilbronn, None).unwrap();
    let r = v
        .import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(r.groups_created, 0);
    let after = tree(&v);
    assert_eq!(after.iter().find(|g| g.0 == "ETW Heilbronn").unwrap().1, 0);
    assert_eq!(after.iter().find(|g| g.0 == "ETW Neckarsulm").unwrap().1, 1);
}

#[test]
fn imports_category_rules() {
    let v = vault();
    let path = fake_db_with(
        false,
        "UPDATE categories SET rules = 'name:REWE OR name:EDEKA' WHERE rowid = 2;
         UPDATE categories SET rules = '(Gehalt' WHERE rowid = 3;
         UPDATE categories SET rules = 'purpose:Strom* AND amount<0' WHERE rowid = 4;
         UPDATE categories SET rules = 'name:Finanzamt', apply_to_account = '1' WHERE rowid = 5;
         INSERT INTO categories (rowid, name, type, group_key, sort, rules) VALUES
           (6, 'Spenden', 1, 0, 4, 'reference:X'),
           (7, 'Sonstiges', 1, 0, 5, '   ');",
    );
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!((r.rules_created, r.rules_disabled), (5, 3));

    let rules = v.list_rules().unwrap();
    let by_name = |n: &str| rules.iter().find(|r| r.name == n).unwrap().clone();
    let supermarkt = by_name("Supermarkt");
    assert_eq!(supermarkt.match_kind, MatchKind::Expression);
    assert_eq!(supermarkt.pattern, "name:REWE OR name:EDEKA");
    assert!(supermarkt.enabled);
    assert!(supermarkt.priority >= 1000);
    assert!(by_name("Strom").enabled);
    assert!(
        by_name("Strom").priority > supermarkt.priority,
        "MoneyMoney order"
    );
    assert!(!by_name("Gehalt").enabled, "broken syntax");
    assert!(
        !by_name("Steuern / Büro (nur für bestimmte Konten)").enabled,
        "account restriction is named in the rule"
    );
    assert!(!by_name("Spenden").enabled, "unsupported field");
    assert!(
        rules.iter().all(|r| r.name != "Sonstiges"),
        "blank rule skipped"
    );

    let again = v
        .import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!((again.rules_created, again.rules_disabled), (0, 0));
    assert_eq!(v.list_rules().unwrap().len(), rules.len());
}

/// Records every progress report; cancels after `cancel_after` of them.
struct Recorder {
    seen: std::sync::Mutex<Vec<MoneyMoneyDbImportProgress>>,
    cancel_after: Option<usize>,
}

impl MoneyMoneyImportObserver for Recorder {
    fn progress(&self, progress: MoneyMoneyDbImportProgress) -> bool {
        let mut seen = self.seen.lock().unwrap();
        seen.push(progress);
        self.cancel_after.is_none_or(|n| seen.len() < n)
    }
}

#[test]
fn import_reports_progress_and_can_be_cancelled() {
    let folder = temp("mm-progress");
    let bank = folder.join("Statements").join("Musterbank");
    std::fs::create_dir_all(&bank).unwrap();
    std::fs::create_dir_all(folder.join("Database")).unwrap();
    std::fs::rename(
        statements_db(),
        folder.join("Database").join("MoneyMoney.sqlite"),
    )
    .unwrap();
    std::fs::write(bank.join("Kontoauszug_2026_001.pdf"), pdf("A")).unwrap();
    let path = folder.to_string_lossy().to_string();
    let v = vault();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();

    // cancelled in the middle: an error, and nothing at all is stored
    let stop = Arc::new(Recorder {
        seen: Default::default(),
        cancel_after: Some(4),
    });
    let r = v.import_moneymoney_database_with_progress(
        path.clone(),
        PW.into(),
        options_from(&p, true, false),
        stop.clone(),
    );
    assert!(matches!(r, Err(CoreError::InvalidInput { .. })));
    assert_eq!(stop.seen.lock().unwrap().len(), 4);
    assert!(v.list_accounts().unwrap().is_empty());
    assert!(v.list_bank_connections().unwrap().is_empty());
    assert!(docs(&v).is_empty());

    // a full run: from "reading" over every account to the end
    let all = Arc::new(Recorder {
        seen: Default::default(),
        cancel_after: None,
    });
    let r = v
        .import_moneymoney_database_with_progress(
            path,
            PW.into(),
            options_from(&p, false, false),
            all.clone(),
        )
        .unwrap();
    assert_eq!(r.documents_imported, 1);
    let seen = all.seen.lock().unwrap();
    let (first, last) = (seen.first().unwrap(), seen.last().unwrap());
    assert_eq!((first.account_index, first.account_count), (0, 0));
    let n = p.accounts.len() as u32;
    assert_eq!((last.account_index, last.account_count), (n + 1, n));
    assert_eq!(last.fraction, 1.0);
    assert_eq!(last.bookings_done, last.bookings_total);
    assert_eq!((last.documents_done, last.documents_total), (4, 4));
    assert!(last.account_name.is_empty());
    assert!(seen
        .windows(2)
        .all(|w| w[0].fraction <= w[1].fraction && w[0].account_index <= w[1].account_index));
    assert!(seen.iter().any(|s| s.account_name == "Girokonto"));
    let _ = std::fs::remove_dir_all(folder);
}

/// The "already imported?" lookup runs once per document: it must use the
/// index on `source_url`, not scan the table (and with it every stored PDF).
#[test]
fn document_lookup_uses_the_source_index() {
    let v = vault();
    let db = v.db().unwrap();
    let plan: Vec<String> = db
        .prepare(&format!("EXPLAIN QUERY PLAN {DOCUMENT_EXISTS_SQL}"))
        .unwrap()
        .query_map(["moneymoney:1:abc"], |r| r.get::<_, String>(3))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let plan = plan.join(" | ");
    assert!(plan.contains("booking_documents_source"), "{plan}");
    assert!(!plan.contains("SCAN booking_documents"), "{plan}");
}
