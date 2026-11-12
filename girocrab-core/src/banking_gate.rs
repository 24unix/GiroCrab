//! Process-wide banking block (security lock for outdated app versions).
//!
//! The app evaluates the signed `banking-policy.json` (see
//! `GiroCrabUI/BankingPolicy.swift`) and hands the result to the core with
//! [`set_banking_block`]. Every entry point that contacts a bank or adds a bank
//! login then checks [`check_connector`]. This is a second line of defence
//! behind the checks in the app model: a UI path that was overlooked still
//! cannot reach the bank.
//!
//! The block is deliberately *process-wide*, not stored in a `Vault`: locking
//! and reopening the vault must not lift it.
//!
//! Connector IDs follow the connection keys of `ConnectorKind::as_str`. An ID
//! matches a key if it is equal or the key starts with `<ID>:` – `fints`
//! matches every FinTS bank (`fints:<BLZ>`), `fints:50050201` only 1822direkt,
//! `enablebanking` also `enablebanking:amex`.

use std::sync::RwLock;

use crate::error::{CoreError, CoreResult};

#[derive(Debug, Clone, Default)]
struct BlockState {
    all: bool,
    connector_ids: Vec<String>,
    message: String,
}

static BLOCK: RwLock<Option<BlockState>> = RwLock::new(None);

/// True if the policy connector ID `id` covers the connection key `key`.
pub fn connector_id_matches(id: &str, key: &str) -> bool {
    let id = id.trim();
    !id.is_empty()
        && (key == id || key.strip_prefix(id).is_some_and(|rest| rest.starts_with(':')))
}

/// Sets the banking block. `all = true` blocks every connector, otherwise
/// only those matched by `connector_ids`. `message` is the localised text the
/// app shows (the same as in its banner). An empty block (`all = false`, no
/// IDs) is the same as [`clear_banking_block`].
#[uniffi::export]
pub fn set_banking_block(all: bool, connector_ids: Vec<String>, message: String) {
    let ids: Vec<String> = connector_ids
        .into_iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    let state = if all || !ids.is_empty() {
        Some(BlockState {
            all,
            connector_ids: ids,
            message,
        })
    } else {
        None
    };
    *BLOCK.write().unwrap_or_else(|e| e.into_inner()) = state;
}

/// Lifts the banking block.
#[uniffi::export]
pub fn clear_banking_block() {
    *BLOCK.write().unwrap_or_else(|e| e.into_inner()) = None;
}

/// Connector key of a connector kind (`ConnectorKind::as_str`), e.g. for a
/// login that is about to be added.
#[uniffi::export]
pub fn connector_kind_key(kind: crate::models::ConnectorKind) -> String {
    kind.as_str().to_string()
}

/// True if the connection key `key` (e.g. `fints:50050201`) is blocked.
#[uniffi::export]
pub fn is_banking_blocked(key: String) -> bool {
    check_connector(&key).is_err()
}

impl BlockState {
    fn blocks(&self, key: &str) -> bool {
        self.all || self.connector_ids.iter().any(|id| connector_id_matches(id, key))
    }
}

/// Fails with [`CoreError::BankingBlocked`] if `key` is blocked.
pub(crate) fn check_connector(key: &str) -> CoreResult<()> {
    let guard = BLOCK.read().unwrap_or_else(|e| e.into_inner());
    match guard.as_ref() {
        Some(s) if s.blocks(key) => Err(CoreError::BankingBlocked {
            message: s.message.clone(),
        }),
        _ => Ok(()),
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::sync::Mutex;

    /// The block is global and other core tests sync demo banks in parallel.
    /// Tests that set it therefore only use IDs no real connector has
    /// (`zz-test…`) and hold this lock, and never block "all".
    pub(crate) static SERIAL: Mutex<()> = Mutex::new(());

    #[test]
    fn id_matching_uses_prefix_with_colon() {
        assert!(connector_id_matches("fints", "fints"));
        assert!(connector_id_matches("fints", "fints:50050201"));
        assert!(connector_id_matches("fints:50050201", "fints:50050201"));
        assert!(!connector_id_matches("fints:50050201", "fints:52090000"));
        assert!(connector_id_matches("enablebanking", "enablebanking:amex"));
        assert!(!connector_id_matches("bunq", "bunqx"));
        assert!(!connector_id_matches("fin", "fints"));
        assert!(!connector_id_matches("", "fints"));
        assert!(connector_id_matches(" bunq ", "bunq"));
    }

    #[test]
    fn all_blocks_every_key() {
        let s = BlockState {
            all: true,
            connector_ids: vec![],
            message: String::new(),
        };
        assert!(s.blocks("comdirect") && s.blocks("fints:50050201") && s.blocks(""));
        let s = BlockState {
            all: false,
            connector_ids: vec!["fints".into()],
            message: String::new(),
        };
        assert!(s.blocks("fints:52090000") && !s.blocks("comdirect"));
    }

    #[test]
    fn set_check_and_clear() {
        let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        assert!(check_connector("zz-test:1").is_ok());

        set_banking_block(false, vec!["zz-test".into()], "gesperrt".into());
        match check_connector("zz-test:1") {
            Err(CoreError::BankingBlocked { message }) => assert_eq!(message, "gesperrt"),
            other => panic!("expected BankingBlocked, got {other:?}"),
        }
        assert_eq!(
            CoreError::BankingBlocked {
                message: "gesperrt".into()
            }
            .to_string(),
            "gesperrt"
        );
        assert!(check_connector("comdirect").is_ok());
        assert!(is_banking_blocked("zz-test".into()));

        // An empty block lifts it.
        set_banking_block(false, vec!["  ".into()], "x".into());
        assert!(check_connector("zz-test:1").is_ok());

        set_banking_block(false, vec!["zz-test".into()], "gesperrt".into());
        clear_banking_block();
        assert!(check_connector("zz-test:1").is_ok());
    }
}
