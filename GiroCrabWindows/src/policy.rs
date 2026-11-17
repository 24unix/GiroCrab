//! BankingPolicy for Windows (MVP): evaluates the signed `banking-policy.json` bundled at build
//! time for distribution `windows` (docs/banking-policy.md) and hands the result to the core
//! (`banking_gate`). The file can only restrict. A bundle whose signature does not verify blocks
//! all banks (fail closed). Online refresh (as on Linux/macOS) is not part of the MVP.

use base64::Engine as _;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::Deserialize;

pub const DISTRIBUTION: &str = "windows";
/// `BankingPolicy.publicKeys` (raw 32-byte Ed25519 keys, base64).
const PUBLIC_KEYS: &[&str] = &["sy8puSCv1QXXl0hU5cYaPaaShIltXDIXiKLRXLuNW+A="];
const BUNDLED_JSON: &[u8] = include_bytes!("../../policy/banking-policy.json");
const BUNDLED_SIG: &[u8] = include_bytes!("../../policy/banking-policy.json.sig");

#[derive(Debug, Deserialize)]
struct Rule {
    distribution: Vec<String>,
    channels: Option<Vec<String>>,
    #[serde(rename = "minimumVersion")]
    minimum_version: String,
    connectors: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
struct Document {
    schema: i64,
    rules: Vec<Rule>,
}

#[derive(Debug, PartialEq, Eq, Default)]
pub struct Block {
    pub all: bool,
    pub connector_ids: Vec<String>,
}

impl Block {
    pub fn is_blocked(&self) -> bool {
        self.all || !self.connector_ids.is_empty()
    }
}

pub(crate) fn verify(json: &[u8], sig: &[u8]) -> bool {
    let Ok(sig) = <[u8; 64]>::try_from(sig) else {
        return false;
    };
    let sig = Signature::from_bytes(&sig);
    PUBLIC_KEYS
        .iter()
        .filter_map(|k| base64::engine::general_purpose::STANDARD.decode(k).ok())
        .filter_map(|b| <[u8; 32]>::try_from(b.as_slice()).ok())
        .filter_map(|b| VerifyingKey::from_bytes(&b).ok())
        .any(|k| k.verify(json, &sig).is_ok())
}

/// Numeric dotted comparison; anything after the first `-` is ignored.
pub(crate) fn version_lt(a: &str, b: &str) -> bool {
    let parts = |s: &str| -> Vec<u64> {
        s.split('-')
            .next()
            .unwrap_or("")
            .split('.')
            .map(|p| {
                p.chars()
                    .take_while(char::is_ascii_digit)
                    .collect::<String>()
                    .parse()
                    .unwrap_or(0)
            })
            .collect()
    };
    let (mut pa, mut pb) = (parts(a), parts(b));
    let n = pa.len().max(pb.len());
    pa.resize(n, 0);
    pb.resize(n, 0);
    pa < pb
}

fn channel(version: &str) -> &'static str {
    if version.contains('-') || version.split('.').count() >= 4 {
        "nightly"
    } else {
        "stable"
    }
}

/// Block for `version` according to a signed document; `None` = document invalid.
fn evaluate(json: &[u8], sig: &[u8], version: &str) -> Option<Block> {
    if !verify(json, sig) {
        return None;
    }
    let doc: Document = serde_json::from_slice(json)
        .ok()
        .filter(|d: &Document| d.schema == 1)?;
    let mut block = Block::default();
    for r in doc.rules.iter().filter(|r| {
        r.distribution.iter().any(|d| d == DISTRIBUTION)
            && r.channels
                .as_ref()
                .is_none_or(|c| c.iter().any(|c| c == channel(version)))
            && version_lt(version, &r.minimum_version)
    }) {
        match r.connectors.as_ref().filter(|c| !c.is_empty()) {
            None => block.all = true,
            Some(ids) => block.connector_ids.extend(ids.iter().cloned()),
        }
    }
    Some(block)
}

/// Evaluates the bundled policy and applies it to the core's process-wide banking gate.
pub fn apply(version: &str) -> Block {
    let block = evaluate(BUNDLED_JSON, BUNDLED_SIG, version).unwrap_or(Block {
        all: true,
        connector_ids: vec![],
    });
    if block.is_blocked() {
        girocrab_core::banking_gate::set_banking_block(
            block.all,
            block.connector_ids.clone(),
            "Diese Version darf wegen einer Sicherheitssperre keine Bank abrufen. \
             Bitte aktualisieren Sie GiroCrab."
                .into(),
        );
    } else {
        girocrab_core::banking_gate::clear_banking_block();
    }
    block
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_policy_verifies_and_does_not_block_current_version() {
        let b = evaluate(BUNDLED_JSON, BUNDLED_SIG, env!("CARGO_PKG_VERSION"));
        assert_eq!(b, Some(Block::default()));
    }

    #[test]
    fn tampered_policy_fails_closed() {
        assert_eq!(
            evaluate(b"{\"schema\":1,\"rules\":[]}", BUNDLED_SIG, "1.0.0"),
            None
        );
    }

    #[test]
    fn version_order() {
        assert!(version_lt("0.7.2", "0.7.10"));
        assert!(!version_lt("0.7.5", "0.7.5"));
        assert!(version_lt("0.7", "0.7.1"));
    }
}
