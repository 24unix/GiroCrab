use std::path::{Path, PathBuf};
use std::sync::Arc;

use rusqlite::Connection;

use crate::error::CoreError;
use crate::vault::{Vault, SCHEMA_VERSION};

const PASSWORD: &str = "Krabbe am Strand 7";

fn temp_path(tag: &str) -> PathBuf {
    std::env::temp_dir().join(format!("girocrab-backup-{tag}-{}.db", uuid::Uuid::new_v4()))
}

fn path(p: &Path) -> String {
    p.to_string_lossy().to_string()
}

/// A vault with demo data (accounts, bookings) under key `fill`.
fn filled(fill: u8) -> (Arc<Vault>, PathBuf) {
    let p = temp_path("src");
    let v = Vault::open(path(&p), vec![fill; 32]).unwrap();
    v.seed_demo_data().unwrap();
    (v, p)
}

fn bookings(v: &Vault) -> i64 {
    v.db()
        .unwrap()
        .query_row("SELECT count(*) FROM transactions", [], |r| r.get(0))
        .unwrap()
}

#[test]
fn restore_brings_back_accounts_and_bookings_under_the_device_key() {
    let (src, _) = filled(1);
    let backup = temp_path("bak");
    src.write_backup(path(&backup), PASSWORD.into()).unwrap();

    // another device: its own key, an empty vault
    let dest_path = temp_path("dest");
    let dest = Vault::open(path(&dest_path), vec![2u8; 32]).unwrap();
    assert_eq!(dest.account_count().unwrap(), 0);
    dest.restore_backup(path(&backup), PASSWORD.into()).unwrap();
    assert_eq!(dest.account_count().unwrap(), src.account_count().unwrap());
    assert_eq!(bookings(&dest), bookings(&src));
    assert!(bookings(&dest) > 0);

    // on disk, under the device key, after reopening
    drop(dest);
    let reopened = Vault::open(path(&dest_path), vec![2u8; 32]).unwrap();
    assert_eq!(
        reopened.account_count().unwrap(),
        src.account_count().unwrap()
    );
}

#[test]
fn restore_replaces_what_the_vault_held() {
    let (src, _) = filled(1);
    let backup = temp_path("bak");
    let empty = Vault::open(path(&temp_path("empty")), vec![3u8; 32]).unwrap();
    empty.write_backup(path(&backup), PASSWORD.into()).unwrap();
    src.restore_backup(path(&backup), PASSWORD.into()).unwrap();
    assert_eq!(src.account_count().unwrap(), 0);
    assert_eq!(bookings(&src), 0);
}

#[test]
fn backup_needs_the_password_not_the_vault_key() {
    let (src, _) = filled(1);
    let backup = temp_path("bak");
    src.write_backup(path(&backup), PASSWORD.into()).unwrap();
    assert!(std::fs::metadata(&backup).unwrap().len() > 0);
    assert!(Vault::open(path(&backup), vec![1u8; 32]).is_err());
}

#[test]
fn wrong_password_is_refused_and_the_vault_stays() {
    let (src, _) = filled(1);
    let backup = temp_path("bak");
    src.write_backup(path(&backup), PASSWORD.into()).unwrap();
    let dest = Vault::open(path(&temp_path("dest")), vec![2u8; 32]).unwrap();
    dest.seed_demo_data().unwrap();
    let before = bookings(&dest);
    let err = dest
        .restore_backup(path(&backup), "falsch".into())
        .unwrap_err();
    assert!(matches!(err, CoreError::InvalidInput { .. }), "{err:?}");
    assert_eq!(bookings(&dest), before);
}

#[test]
fn not_a_backup_is_refused() {
    let junk = temp_path("junk");
    std::fs::write(&junk, b"kein Tresor").unwrap();
    let dest = Vault::open(path(&temp_path("dest")), vec![2u8; 32]).unwrap();
    let err = dest
        .restore_backup(path(&junk), PASSWORD.into())
        .unwrap_err();
    assert!(matches!(err, CoreError::InvalidInput { .. }), "{err:?}");
}

#[test]
fn empty_password_is_refused() {
    let (src, _) = filled(1);
    let err = src
        .write_backup(path(&temp_path("bak")), String::new())
        .unwrap_err();
    assert!(matches!(err, CoreError::InvalidInput { .. }), "{err:?}");
}

#[test]
fn backup_from_a_newer_app_is_refused() {
    let (src, _) = filled(1);
    let backup = temp_path("bak");
    src.write_backup(path(&backup), PASSWORD.into()).unwrap();
    {
        let c = Connection::open(&backup).unwrap();
        c.pragma_update(None, "key", PASSWORD).unwrap();
        c.execute_batch(&format!("PRAGMA user_version = {}", SCHEMA_VERSION + 1))
            .unwrap();
    }
    let dest = Vault::open(path(&temp_path("dest")), vec![2u8; 32]).unwrap();
    let err = dest
        .restore_backup(path(&backup), PASSWORD.into())
        .unwrap_err();
    assert!(matches!(err, CoreError::SchemaTooNew { .. }), "{err:?}");
    assert_eq!(dest.account_count().unwrap(), 0);
}
