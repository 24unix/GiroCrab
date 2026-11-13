//! Resolves every "counterparty<TAB>purpose" line of the file in argv[1] and prints
//! "counterparty | purpose -> merchant name (key)". Diff the output before/after a matcher change.
fn main() {
    let path = std::env::args().nth(1).expect("corpus file");
    for line in std::fs::read_to_string(path).unwrap().lines() {
        let (cp, pu) = line.split_once('\t').unwrap_or((line, ""));
        let m = girocrab_core::merchants::resolve_merchant(cp.to_string(), pu.to_string());
        println!("{cp} | {pu} -> {} ({})", m.name, m.key);
    }
}
