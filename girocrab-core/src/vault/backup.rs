//! „Tresor sichern / wiederherstellen“: a password-protected copy of the vault
//! that opens on any device, also without this device's keychain.
//!
//! The backup is an ordinary SQLCipher database keyed with the password
//! (SQLCipher derives the key with PBKDF2), so no extra crypto is needed.

use std::time::Duration;

use rusqlite::backup::Backup;
use rusqlite::{params, Connection};
use zeroize::Zeroizing;

use super::Vault;
use crate::error::{CoreError, CoreResult};
use crate::i18n::tr;

fn not_a_backup() -> CoreError {
    CoreError::InvalidInput {
        message: tr("Falsches Passwort oder keine GiroCrab-Sicherung.").into(),
    }
}

fn remove_with_sidecars(path: &str) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let _ = std::fs::remove_file(format!("{path}{suffix}"));
    }
}

#[uniffi::export]
impl Vault {
    /// Writes a consistent copy of this vault to `dest_path` (replacing it),
    /// encrypted with `password` instead of the device key.
    pub fn write_backup(&self, dest_path: String, password: String) -> CoreResult<()> {
        let password = Zeroizing::new(password);
        if password.is_empty() {
            return Err(CoreError::InvalidInput {
                message: tr("Bitte ein Passwort für die Sicherung angeben.").into(),
            });
        }
        self.export_to(&dest_path, &password)
    }

    /// Replaces this vault's contents with the backup at `backup_path`
    /// (written by [`Vault::write_backup`], opened with `password`). The data
    /// stays under this device's key; an older backup is migrated, one from a
    /// newer app is refused. Nothing changes if the backup cannot be read.
    pub fn restore_backup(&self, backup_path: String, password: String) -> CoreResult<()> {
        let password = Zeroizing::new(password);
        let staging = format!("{}.restore", self.path);
        remove_with_sidecars(&staging);
        let res = self.restore_via(&staging, &backup_path, &password);
        remove_with_sidecars(&staging);
        res
    }
}

impl Vault {
    /// Copies the backup into `staging` under the device key, then over the
    /// open vault (SQLite backup API, same key on both sides).
    fn restore_via(&self, staging: &str, backup_path: &str, password: &str) -> CoreResult<()> {
        let tmp = Connection::open(staging)?;
        Self::apply_key(&tmp, &self.kept_key()?)?;
        // wrong password or no database: the attach or the first read fails
        tmp.execute(
            "ATTACH DATABASE ?1 AS bak KEY ?2",
            params![backup_path, password],
        )
        .map_err(|_| not_a_backup())?;
        let tables: Vec<String> = tmp
            .prepare("SELECT name FROM bak.sqlite_master WHERE type = 'table'")
            .and_then(|mut s| s.query_map([], |r| r.get(0))?.collect())
            .map_err(|_| not_a_backup())?;
        if !["accounts", "transactions"]
            .iter()
            .all(|t| tables.iter().any(|n| n == t))
        {
            return Err(not_a_backup());
        }
        let version: i64 = tmp.query_row("PRAGMA bak.user_version", [], |r| r.get(0))?;
        if version > super::SCHEMA_VERSION {
            return Err(CoreError::SchemaTooNew {
                vault_version: version,
                app_version: super::SCHEMA_VERSION,
            });
        }
        tmp.query_row("SELECT sqlcipher_export('main', 'bak')", [], |_| Ok(()))?;
        tmp.execute_batch(&format!("PRAGMA main.user_version = {version}"))?;
        tmp.execute_batch("DETACH DATABASE bak")?;

        let mut main = self.db()?;
        Backup::new(&tmp, &mut main)?.run_to_completion(256, Duration::ZERO, None)?;
        Self::migrate(&mut main)?;
        Self::repair(&main);
        Ok(())
    }
}

#[cfg(test)]
mod tests;
