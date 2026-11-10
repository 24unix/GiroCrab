//! Structural, non-sensitive trace of depot/holdings syncs.
//!
//! Appends to `/tmp/girocrab-depot-debug.log`. NEVER pass account numbers, IBANs,
//! WKNs/ISINs, names or amounts here – only step names, counts, codes and versions.

use std::io::Write;

const PATH: &str = "/tmp/girocrab-depot-debug.log";

pub fn log(msg: &str) {
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(PATH)
    {
        let _ = writeln!(f, "{} {msg}", crate::connectors::today());
    }
}
