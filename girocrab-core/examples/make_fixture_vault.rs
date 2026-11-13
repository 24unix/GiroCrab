//! Writes a fixture vault for the schema upgrade tests
//! (`girocrab-core/tests/schema_fixtures.rs`): demo data (connections,
//! accounts, categories, rules, bookings), a user group and a manual loan, so
//! every table that matters has rows.
//!
//! Usage: cargo run -q -p girocrab-core --example make_fixture_vault
//!
//! The file is named after the schema version it ends up with
//! (`tests/fixtures/vault-v{N}.girocrab`, key = 32 × 0x47). Run it once after
//! every schema bump and commit the new file. Never regenerate or edit an
//! existing fixture: each one stands for vaults written by that version.
use girocrab_core::loans::LoanSetup;
use girocrab_core::vault::Vault;
use rusqlite::Connection;

const KEY: [u8; 32] = [0x47; 32];

fn main() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    std::fs::create_dir_all(&dir).unwrap();
    let tmp = dir.join("vault-new.girocrab");
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", tmp.display()));
    }
    let path = tmp.to_string_lossy().to_string();
    {
        let v = Vault::open(path.clone(), KEY.to_vec()).unwrap();
        assert!(v.seed_demo_data().unwrap() > 0, "demo data not seeded");
        v.create_user_group("Fixture-Gruppe".into(), "folder".into())
            .unwrap();
        v.create_manual_loan(LoanSetup {
            name: "Fixture-Kredit".into(),
            original_cents: Some(1_000_000),
            anchor_date: "2025-01-01".into(),
            anchor_balance_cents: 800_000,
            interest_rate_ppm: Some(39_900),
            match_expr: String::new(),
        })
        .unwrap();
    }
    // Compact, leave WAL mode (no -wal/-shm files) and read the version.
    let conn = Connection::open(&tmp).unwrap();
    conn.execute_batch(&format!("PRAGMA key = \"x'{}'\";", hex::encode(KEY)))
        .unwrap();
    conn.execute_batch("PRAGMA journal_mode = DELETE; VACUUM;")
        .unwrap();
    let version: i64 = conn
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap();
    drop(conn);
    let dest = dir.join(format!("vault-v{version}.girocrab"));
    if dest.exists() {
        let _ = std::fs::remove_file(&tmp);
        panic!("{} exists – fixtures are never regenerated", dest.display());
    }
    std::fs::rename(&tmp, &dest).unwrap();
    println!("{}", dest.display());
}
