//! VaultKeyManager.swift for Linux: the SQLCipher master key lives in the
//! Secret Service (KWallet / GNOME Keyring) instead of the Apple Keychain.
//! Unlocking the keyring (the wallet password prompt) takes the place of
//! Touch ID / Face ID.

use base64::Engine as _;
use keyring::{Entry, Error as KeyringError};

const SERVICE: &str = "de.girocrab.vault";
const ACCOUNT: &str = "sqlcipher-master-key";

fn env_flag(name: &str) -> bool {
    std::env::var(name).is_ok_and(|v| ["1", "true", "yes"].contains(&v.to_lowercase().as_str()))
}

/// Developer switch (`GIROCRAB_NO_KEYCHAIN=1`, also with `GIROCRAB_DEMO_SEED`):
/// fixed throw-away key and a separate vault file, the keyring is never touched.
pub fn keychain_bypassed() -> bool {
    env_flag("GIROCRAB_NO_KEYCHAIN") || env_flag("GIROCRAB_DEMO_SEED")
}

/// `GIROCRAB_DEMO_SEED=1|true|yes` (LaunchOptions.swift): start with the demo vault, like `--demo-seed`.
pub fn demo_seed_requested() -> bool {
    env_flag("GIROCRAB_DEMO_SEED")
}

const DEV_KEY: [u8; 32] = [0x42; 32];

pub struct Unlocked {
    pub key: zeroize::Zeroizing<Vec<u8>>,
    pub created: bool,
}

fn entry() -> Result<Entry, String> {
    Entry::new(SERVICE, ACCOUNT).map_err(describe)
}

fn describe(e: KeyringError) -> String {
    match e {
        KeyringError::NoStorageAccess(inner) => crate::i18n::tr(
            "Kein Zugriff auf den Schlüsselbund (KWallet / GNOME Schlüsselbund): %1. \
             Ist der Schlüsselbund entsperrt und der Secret-Service-Dienst aktiv?",
        )
        .replace("%1", &inner.to_string()),
        KeyringError::PlatformFailure(inner) => {
            crate::i18n::tr("Schlüsselbund-Fehler: %1").replace("%1", &inner.to_string())
        }
        other => crate::i18n::tr("Schlüsselbund-Fehler: %1").replace("%1", &other.to_string()),
    }
}

/// `VaultKeyManager.unlock(allowCreate:)`: reads the key; creates and stores a
/// new one only when `allow_create` (no vault file yet). A missing key for an
/// existing vault is an error, never a fresh key that would shadow the real one.
pub fn unlock(allow_create: bool) -> Result<Unlocked, String> {
    if keychain_bypassed() {
        return Ok(Unlocked {
            key: zeroize::Zeroizing::new(DEV_KEY.to_vec()),
            created: false,
        });
    }
    let e = entry()?;
    match e.get_secret() {
        Ok(k) if k.len() == 32 => Ok(Unlocked { key: zeroize::Zeroizing::new(k), created: false }),
        Ok(_) => Err(crate::i18n::tr(
            "Der Tresor-Schlüssel im Schlüsselbund ist beschädigt (erwartet 32 Byte).",
        )),
        Err(KeyringError::NoEntry) if allow_create => {
            let key = zeroize::Zeroizing::new(girocrab_core::generate_master_key());
            e.set_secret(&key).map_err(describe)?;
            Ok(Unlocked { key, created: true })
        }
        Err(KeyringError::NoEntry) => Err(
            "Der Schlüssel für den vorhandenen Tresor fehlt im Schlüsselbund. Es wurde kein neuer Schlüssel angelegt. \
             Stellen Sie den Schlüssel unter Einstellungen › Sicherheit wieder her (Base64 oder Hex)."
                .into(),
        ),
        Err(e) => Err(describe(e)),
    }
}

/// `exportKeyBase64()`: for the backup of the key (Einstellungen › Sicherheit).
pub fn export_base64() -> Result<String, String> {
    let u = unlock(false)?;
    Ok(base64::engine::general_purpose::STANDARD.encode(&*u.key))
}

/// `VaultKeyManager.parseKey`: Base64 or 64 hex digits, 32 bytes.
pub fn parse_key(text: &str) -> Result<zeroize::Zeroizing<Vec<u8>>, String> {
    let t = text.trim();
    let b64 = base64::engine::general_purpose::STANDARD
        .decode(t)
        .ok()
        .filter(|k| k.len() == 32);
    let key = b64.or_else(|| (t.len() == 64).then(|| hex_decode(t)).flatten());
    key.map(zeroize::Zeroizing::new)
        .ok_or_else(|| crate::i18n::tr("Ungültiger Schlüssel (erwartet 32 Byte, Base64 oder Hex)."))
}

fn hex_decode(t: &str) -> Option<Vec<u8>> {
    (0..t.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(t.get(i..i + 2)?, 16).ok())
        .collect()
}

/// Stores `key` (after the vault was rekeyed to it).
pub fn store(key: &[u8]) -> Result<(), String> {
    if keychain_bypassed() {
        return Ok(());
    }
    entry()?.set_secret(key).map_err(describe)
}

/// Round trip through the real Secret Service with a throw-away entry
/// (`cargo test -- --ignored secret_service_round_trip`; needs a session keyring).
#[cfg(test)]
#[test]
#[ignore]
fn secret_service_round_trip() {
    let e = Entry::new("de.girocrab.selftest", "roundtrip").unwrap();
    e.set_secret(&[7u8; 32]).unwrap();
    assert_eq!(e.get_secret().unwrap(), vec![7u8; 32]);
    e.delete_credential().unwrap();
    assert!(matches!(e.get_secret(), Err(KeyringError::NoEntry)));
}
