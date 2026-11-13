//! Which FinTS product registration goes to the bank.
//!
//! Two sources exist:
//! * **builtin** – GiroCrab's own registration with the Deutsche
//!   Kreditwirtschaft, embedded only by the release build script (see
//!   `build.rs`); absent in developer and fork builds.
//! * **own** – the user's own registration (setting `fints.product_id`). It is
//!   never deleted when the user switches to the built-in one.
//!
//! The choice is stored in `fints.product_id_mode` (`builtin`, `own` or empty =
//! not decided yet). The ID itself must never reach logs, errors or the UI.

/// Setting key of the user's choice.
pub const MODE_KEY: &str = "fints.product_id_mode";
/// Setting key of the user's own registration.
pub const OWN_KEY: &str = "fints.product_id";

include!(concat!(env!("OUT_DIR"), "/builtin_product_id.rs"));

const MASK: &[u8] = b"girocrab-fints-product-id-mask";

/// Which registration is (or would be) used.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Builtin,
    Own,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Builtin => "builtin",
            Source::Own => "own",
        }
    }
}

/// The embedded ID, if this build carries one.
pub(crate) fn builtin() -> Option<String> {
    if BUILTIN_MASKED.is_empty() {
        return None;
    }
    let bytes: Vec<u8> = BUILTIN_MASKED
        .iter()
        .enumerate()
        .map(|(i, b)| b ^ MASK[i % MASK.len()] ^ (i as u8))
        .collect();
    String::from_utf8(bytes).ok().filter(|s| !s.is_empty())
}

/// True when this build carries GiroCrab's own registration.
pub fn builtin_available() -> bool {
    !BUILTIN_MASKED.is_empty()
}

/// Normalises the stored mode; anything unknown counts as "not decided".
pub fn normalize_mode(mode: &str) -> &'static str {
    match mode.trim() {
        "builtin" => "builtin",
        "own" => "own",
        _ => "",
    }
}

fn pick(mode: &str, own: &str, builtin: Option<String>) -> Option<(Source, String)> {
    let own = own.trim();
    let own = (!own.is_empty()).then(|| (Source::Own, own.to_string()));
    let builtin = builtin.map(|b| (Source::Builtin, b));
    match normalize_mode(mode) {
        "own" => own,
        "builtin" => builtin.or(own),
        // Not decided yet: existing users keep working with what they have.
        _ => own.or(builtin),
    }
}

/// Developer override: `GIROCRAB_FINTS_PRODUCT_ID_OVERRIDE` at run time acts as
/// the user's own ID and forces mode `own`. Debug builds only, so a release
/// can never be redirected by the environment.
fn dev_override() -> Option<String> {
    if !cfg!(debug_assertions) {
        return None;
    }
    std::env::var("GIROCRAB_FINTS_PRODUCT_ID_OVERRIDE")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

/// Resolves the registration to send: user's choice first, then what exists.
pub fn resolve(mode: &str, own: &str) -> Option<(Source, String)> {
    if let Some(v) = dev_override() {
        return Some((Source::Own, v));
    }
    pick(mode, own, builtin())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b() -> Option<String> {
        Some("BUILTIN".into())
    }

    #[test]
    fn builtin_mode_prefers_builtin_but_falls_back_to_own() {
        assert_eq!(pick("builtin", "OWN", b()).unwrap().0, Source::Builtin);
        assert_eq!(pick("builtin", "OWN", None).unwrap().0, Source::Own);
    }

    #[test]
    fn own_mode_never_uses_builtin() {
        assert_eq!(pick("own", "OWN", b()).unwrap().1, "OWN");
        assert!(pick("own", "  ", b()).is_none());
    }

    #[test]
    fn undecided_keeps_existing_own_id_working() {
        assert_eq!(pick("", "OWN", b()).unwrap().0, Source::Own);
        assert_eq!(pick("", "", b()).unwrap().0, Source::Builtin);
        assert_eq!(pick("garbage", "", b()).unwrap().0, Source::Builtin);
        assert!(pick("", "", None).is_none());
    }

    #[test]
    fn vault_keeps_own_id_when_switching_mode() {
        use crate::Vault;
        let dir = crate::test_support::TempDir::new("girocrab-pid");
        let v = Vault::open(
            dir.join("v.db").to_string_lossy().to_string(),
            vec![7u8; 32],
        )
        .unwrap();
        assert_eq!(v.fints_product_id_mode().unwrap(), "");
        let none = if builtin_available() { "builtin" } else { "" };
        assert_eq!(v.fints_product_id_source().unwrap(), none);
        v.set_setting(OWN_KEY.into(), "OWNID".into()).unwrap();
        assert_eq!(v.fints_product_id_source().unwrap(), "own");
        v.set_fints_product_id_mode("builtin".into()).unwrap();
        assert_eq!(v.fints_product_id_mode().unwrap(), "builtin");
        // Own ID survives the switch; without an embedded ID it stays the fallback.
        assert_eq!(
            v.get_setting(OWN_KEY.into()).unwrap().as_deref(),
            Some("OWNID")
        );
        let expect = if builtin_available() {
            "builtin"
        } else {
            "own"
        };
        assert_eq!(v.fints_product_id_source().unwrap(), expect);
        v.set_fints_product_id_mode("nonsense".into()).unwrap();
        assert_eq!(v.fints_product_id_mode().unwrap(), "");
    }

    #[test]
    fn unmasking_round_trips() {
        let plain = b"ABC123-xyz";
        let masked: Vec<u8> = plain
            .iter()
            .enumerate()
            .map(|(i, b)| b ^ MASK[i % MASK.len()] ^ (i as u8))
            .collect();
        let back: Vec<u8> = masked
            .iter()
            .enumerate()
            .map(|(i, b)| b ^ MASK[i % MASK.len()] ^ (i as u8))
            .collect();
        assert_eq!(back, plain);
    }
}
