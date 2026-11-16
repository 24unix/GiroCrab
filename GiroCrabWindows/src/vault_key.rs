//! VaultKeyManager for Windows: the SQLCipher master key lives in the Windows Credential
//! Manager (`keyring`, `windows-native`). On other platforms (development, `cargo check`,
//! tests) a process-local store stands in, so the crate builds everywhere.

#[cfg(windows)]
const SERVICE: &str = "de.girocrab.vault";
#[cfg(windows)]
const ACCOUNT: &str = "sqlcipher-master-key";
const DEV_KEY: [u8; 32] = [0x42; 32];

#[cfg_attr(not(test), allow(dead_code))]
pub struct Unlocked {
    pub key: zeroize::Zeroizing<Vec<u8>>,
    pub created: bool,
}

fn env_flag(name: &str) -> bool {
    std::env::var(name).is_ok_and(|v| ["1", "true", "yes"].contains(&v.to_lowercase().as_str()))
}

/// `GIROCRAB_DEMO_SEED=1|true|yes`: start with the demo vault.
pub fn demo_seed_requested() -> bool {
    env_flag("GIROCRAB_DEMO_SEED")
}

/// Demo mode and `GIROCRAB_NO_KEYCHAIN=1` use a fixed throw-away key; the store is never touched.
pub fn bypassed() -> bool {
    env_flag("GIROCRAB_NO_KEYCHAIN") || demo_seed_requested()
}

#[cfg(windows)]
mod store {
    use keyring::{Entry, Error};

    fn entry() -> Result<Entry, String> {
        Entry::new(super::SERVICE, super::ACCOUNT)
            .map_err(|e| format!("Anmeldeinformationsverwaltung: {e}"))
    }
    pub fn get() -> Result<Option<Vec<u8>>, String> {
        match entry()?.get_secret() {
            Ok(k) => Ok(Some(k)),
            Err(Error::NoEntry) => Ok(None),
            Err(e) => Err(format!("Anmeldeinformationsverwaltung: {e}")),
        }
    }
    pub fn set(key: &[u8]) -> Result<(), String> {
        entry()?
            .set_secret(key)
            .map_err(|e| format!("Anmeldeinformationsverwaltung: {e}"))
    }
}

#[cfg(not(windows))]
mod store {
    use std::sync::Mutex;
    static KEY: Mutex<Option<Vec<u8>>> = Mutex::new(None);
    pub fn get() -> Result<Option<Vec<u8>>, String> {
        Ok(KEY.lock().unwrap_or_else(|e| e.into_inner()).clone())
    }
    pub fn set(key: &[u8]) -> Result<(), String> {
        *KEY.lock().unwrap_or_else(|e| e.into_inner()) = Some(key.to_vec());
        Ok(())
    }
}

/// Reads the key; creates and stores a new one only when `allow_create` (no vault file yet).
/// A missing key for an existing vault is an error, never a fresh key that would shadow the real one.
pub fn unlock(allow_create: bool) -> Result<Unlocked, String> {
    if bypassed() {
        return Ok(Unlocked {
            key: zeroize::Zeroizing::new(DEV_KEY.to_vec()),
            created: false,
        });
    }
    match store::get()? {
        Some(k) if k.len() == 32 => Ok(Unlocked {
            key: zeroize::Zeroizing::new(k),
            created: false,
        }),
        Some(_) => Err("Der Tresor-Schlüssel ist beschädigt (erwartet 32 Byte).".into()),
        None if allow_create => {
            let key = zeroize::Zeroizing::new(girocrab_core::generate_master_key());
            store::set(&key)?;
            Ok(Unlocked { key, created: true })
        }
        None => Err(
            "Der Schlüssel für den vorhandenen Tresor fehlt in der Anmeldeinformationsverwaltung. \
                      Es wurde kein neuer Schlüssel angelegt."
                .into(),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn creates_once_then_reads_back() {
        std::env::remove_var("GIROCRAB_DEMO_SEED");
        std::env::remove_var("GIROCRAB_NO_KEYCHAIN");
        if cfg!(windows) {
            return; // would touch the real Credential Manager
        }
        assert!(unlock(false).is_err());
        let first = unlock(true).unwrap();
        assert!(first.created);
        let again = unlock(false).unwrap();
        assert_eq!(*first.key, *again.key);
    }
}
