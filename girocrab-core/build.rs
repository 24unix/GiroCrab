//! Embeds GiroCrab's own FinTS product registration at build time.
//!
//! The value comes from the environment variable `GIROCRAB_FINTS_PRODUCT_ID`
//! (set by `scripts/notarize.sh` for Beta/Stable builds) and never from a file
//! in the repository. Without it the build still works: the generated table is
//! empty and the app asks for the user's own registration, as before.
//!
//! The bytes are XOR-masked so the ID does not show up in `strings` output.
//! This is obfuscation only: whatever a binary sends to a bank can be read out
//! of it. The value is never printed by this script.
use std::{env, fs, path::PathBuf};

const MASK: &[u8] = b"girocrab-fints-product-id-mask";

fn main() {
    println!("cargo:rerun-if-env-changed=GIROCRAB_FINTS_PRODUCT_ID");
    println!("cargo:rerun-if-changed=build.rs");
    let raw = env::var("GIROCRAB_FINTS_PRODUCT_ID").unwrap_or_default();
    let raw = raw.trim();
    let masked: Vec<String> = raw
        .bytes()
        .enumerate()
        .map(|(i, b)| (b ^ MASK[i % MASK.len()] ^ (i as u8)).to_string())
        .collect();
    let src = format!(
        "pub(crate) const BUILTIN_MASKED: &[u8] = &[{}];\n",
        masked.join(", ")
    );
    let out = PathBuf::from(env::var("OUT_DIR").unwrap()).join("builtin_product_id.rs");
    fs::write(out, src).unwrap();
}
