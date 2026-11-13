//! Schema upgrade tests against real vault files.
//!
//! - `fixtures/schema-v{N}.sql`: normalised `sqlite_master` of a fresh vault at
//!   schema N. Written when missing (review it in the diff), compared after.
//!   `schema-v9.sql` was captured from the last probe-based build (schema 8):
//!   the baseline plus repair step must rebuild exactly that.
//! - `fixtures/vault-v{N}.girocrab`: vaults written by schema version N
//!   (`examples/make_fixture_vault.rs`, key = 32 × 0x47). Never edited.

use std::path::{Path, PathBuf};

use girocrab_core::error::CoreError;
use girocrab_core::models::BookingFilter;
use girocrab_core::vault::Vault;
use rusqlite::Connection;

const KEY: [u8; 32] = [0x47; 32];

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

/// Own directory per test, removed on drop.
struct Tmp(PathBuf);

impl Tmp {
    fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir()
            .join("girocrab-tests")
            .join(format!("{tag}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    fn path(&self, name: &str) -> String {
        self.0.join(name).to_string_lossy().into_owned()
    }
}

impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn raw(path: &str, key: &[u8]) -> Connection {
    let c = Connection::open(path).unwrap();
    c.execute_batch(&format!("PRAGMA key = \"x'{}'\";", hex::encode(key)))
        .unwrap();
    c
}

fn user_version(path: &str) -> i64 {
    raw(path, &KEY)
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .unwrap()
}

/// `sqlite_master` with whitespace collapsed, one object per line.
fn schema_dump(path: &str) -> String {
    let c = raw(path, &KEY);
    let mut st = c
        .prepare(
            "SELECT type, name, tbl_name, sql FROM sqlite_master
             WHERE sql IS NOT NULL ORDER BY type, name",
        )
        .unwrap();
    let rows = st
        .query_map([], |r| {
            Ok(format!(
                "{} {} {}: {}",
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?
            ))
        })
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    rows.iter()
        .map(|r| normalize(r))
        .collect::<Vec<_>>()
        .join("\n")
        + "\n"
}

/// Drops `--` comments and layout, so a column added by `ALTER TABLE` (SQLite
/// splices its text into the stored `CREATE TABLE`) compares equal to the
/// same column written inline in the baseline.
fn normalize(sql: &str) -> String {
    let no_comments = sql
        .lines()
        .map(|l| l.split("--").next().unwrap_or(""))
        .collect::<Vec<_>>()
        .join(" ");
    let mut out = no_comments.split_whitespace().collect::<Vec<_>>().join(" ");
    for p in ["(", ")", ","] {
        out = out
            .replace(&format!(" {p}"), p)
            .replace(&format!("{p} "), p);
    }
    out
}

fn fresh_vault(tmp: &Tmp) -> String {
    let path = tmp.path("fresh.girocrab");
    drop(Vault::open(path.clone(), KEY.to_vec()).unwrap());
    path
}

#[test]
fn fresh_vault_matches_golden_schema() {
    let tmp = Tmp::new("golden");
    let fresh = fresh_vault(&tmp);
    let dump = schema_dump(&fresh);
    let golden = fixtures().join(format!("schema-v{}.sql", user_version(&fresh)));
    if !golden.exists() {
        std::fs::write(&golden, &dump).unwrap();
    }
    let expected = std::fs::read_to_string(golden).unwrap();
    assert_eq!(
        dump, expected,
        "fresh vault schema differs from the golden file"
    );
}

/// Columns (sorted by name, with type/NOT NULL/default/pk) and normalised
/// index SQL per table: equal for vaults whose columns were added in a
/// different order.
fn schema_facts(path: &str) -> Vec<String> {
    let c = raw(path, &KEY);
    let tables: Vec<String> = c
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let mut out = Vec::new();
    for t in tables {
        let mut cols: Vec<String> = c
            .prepare("SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info(?1)")
            .unwrap()
            .query_map([&t], |r| {
                Ok(format!(
                    "{t}.{} {} nn={} d={:?} pk={}",
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, i64>(4)?
                ))
            })
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        cols.sort();
        out.extend(cols);
    }
    let idx: Vec<String> = c
        .prepare(
            "SELECT sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name",
        )
        .unwrap()
        .query_map([], |r| r.get::<_, String>(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    out.extend(idx.iter().map(|s| normalize(s)));
    out
}

fn fixture_files() -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(fixtures())
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| {
            let n = p.file_name().unwrap().to_string_lossy();
            n.starts_with("vault-v") && n.ends_with(".girocrab")
        })
        .collect();
    files.sort();
    files
}

fn count(path: &str, sql: &str) -> i64 {
    raw(path, &KEY).query_row(sql, [], |r| r.get(0)).unwrap()
}

#[test]
fn fixture_vaults_open_and_match_a_fresh_vault() {
    let files = fixture_files();
    assert!(!files.is_empty(), "no fixture vaults in tests/fixtures");
    let tmp = Tmp::new("fixtures");
    let fresh = fresh_vault(&tmp);
    let fresh_version = user_version(&fresh);
    for file in files {
        let name = file.file_name().unwrap().to_string_lossy().into_owned();
        let path = tmp.path(&name);
        std::fs::copy(&file, &path).unwrap();
        let bookings = count(
            &path,
            "SELECT count(*) FROM transactions WHERE deleted_ms IS NULL",
        );
        assert!(bookings > 0, "{name}: fixture without bookings");

        let v = Vault::open(path.clone(), KEY.to_vec()).unwrap();
        let page = v.list_transactions(BookingFilter::default()).unwrap();
        assert_eq!(page.total_count as i64, bookings, "{name}: bookings");
        assert!(
            v.list_user_groups()
                .unwrap()
                .iter()
                .any(|g| g.name == "Fixture-Gruppe"),
            "{name}: user group"
        );
        assert!(
            v.list_manual_loans()
                .unwrap()
                .iter()
                .any(|l| l.setup.name == "Fixture-Kredit"),
            "{name}: manual loan"
        );
        assert!(!v.list_rules().unwrap().is_empty(), "{name}: rules");
        drop(v);

        assert_eq!(user_version(&path), fresh_version, "{name}: user_version");
        assert_eq!(schema_dump(&path), schema_dump(&fresh), "{name}: schema");
    }
}

#[test]
fn half_migrated_v8_vault_is_repaired() {
    let tmp = Tmp::new("half-v8");
    let fresh = fresh_vault(&tmp);
    let path = tmp.path("half.girocrab");
    drop(Vault::open(path.clone(), KEY.to_vec()).unwrap());
    // what a probe-based build could leave behind: steps of several features
    // missing, indexes in their old form, `user_version` already 8
    raw(&path, &KEY)
        .execute_batch(
            "DROP INDEX tx_salary_marked;
             ALTER TABLE transactions DROP COLUMN salary_flag;
             DROP INDEX tx_rule;
             CREATE INDEX tx_rule ON transactions(rule_id);
             DROP INDEX categories_unique_name;
             CREATE UNIQUE INDEX categories_unique_name ON categories(IFNULL(parent_id, 0), name);
             ALTER TABLE user_groups DROP COLUMN color_hex;
             ALTER TABLE user_groups DROP COLUMN color_ms;
             ALTER TABLE accounts DROP COLUMN archived_ms;
             ALTER TABLE booking_documents DROP COLUMN exported_at;
             DROP TABLE loan_links;
             DROP TABLE loan_terms;
             DROP TABLE merchant_logo_cache;
             PRAGMA user_version = 8;",
        )
        .unwrap();
    assert_ne!(schema_facts(&path), schema_facts(&fresh));
    drop(Vault::open(path.clone(), KEY.to_vec()).unwrap());
    assert_eq!(user_version(&path), user_version(&fresh));
    assert_eq!(schema_facts(&path), schema_facts(&fresh));
}

fn set_user_version(path: &str, v: i64) {
    raw(path, &KEY)
        .execute_batch(&format!("PRAGMA user_version = {v};"))
        .unwrap();
}

#[test]
fn newer_vault_is_refused_and_left_untouched() {
    let tmp = Tmp::new("newer");
    let path = fresh_vault(&tmp);
    set_user_version(&path, 99);
    let before = std::fs::read(&path).unwrap();
    match Vault::open(path.clone(), KEY.to_vec()) {
        Err(CoreError::SchemaTooNew {
            vault_version: 99,
            app_version,
        }) => assert!(app_version < 99),
        Err(e) => panic!("expected SchemaTooNew, got {e:?}"),
        Ok(_) => panic!("a vault from a newer build must not open"),
    }
    assert_eq!(std::fs::read(&path).unwrap(), before, "file was changed");
    assert_eq!(user_version(&path), 99);
}

#[test]
fn wrong_key_is_still_reported_as_wrong_key() {
    let tmp = Tmp::new("wrong-key");
    let path = fresh_vault(&tmp);
    assert!(matches!(
        Vault::open(path, vec![0x48; 32]),
        Err(CoreError::WrongKey)
    ));
}

#[test]
fn snapshot_merge_refuses_newer_file() {
    let tmp = Tmp::new("merge-newer");
    let local = Vault::open(tmp.path("local.girocrab"), KEY.to_vec()).unwrap();
    local.seed_starter_categories().unwrap();
    let other = tmp.path("other.girocrab");
    {
        let o = Vault::open(other.clone(), KEY.to_vec()).unwrap();
        o.seed_demo_data().unwrap();
    }
    set_user_version(&other, 99);
    let other_before = std::fs::read(&other).unwrap();
    let changes = local.change_count();
    let categories = local.list_categories(None, None).unwrap().len();
    assert!(matches!(
        local.merge_other_vault(other.clone(), KEY.to_vec()),
        Err(CoreError::SchemaTooNew {
            vault_version: 99,
            ..
        })
    ));
    assert!(matches!(
        local.merge_peer_snapshot(other.clone()),
        Err(CoreError::SchemaTooNew { .. })
    ));
    assert_eq!(local.change_count(), changes);
    assert_eq!(local.list_categories(None, None).unwrap().len(), categories);
    assert_eq!(std::fs::read(&other).unwrap(), other_before);
}
