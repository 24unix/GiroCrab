//! BLZ -> (bank name, FinTS 3.0 PIN/TAN URL) directory (~2,000 German banks:
//! Sparkassen, Volks-/Raiffeisenbanken, Sparda, PSD, Deutsche Bank, HVB, ING, …).
//!
//! The table lives in `data/fints_directory.tsv` (generated from the CC0
//! dataset `moay/fints-institute-db`, see the header there) and is parsed once
//! on first use. Lookups are a binary search over that table – no network and,
//! after the first call, no allocation until a result is returned.

use std::sync::OnceLock;

use super::fints::sepa;
use crate::data_tables::rows;

const FINTS_TSV: &str = include_str!("../../data/fints_directory.tsv");
const BIC_TSV: &str = include_str!("../../data/bic_directory.tsv");

/// (BLZ, bank name, FinTS URL), sorted by BLZ.
type Bank = (&'static str, &'static str, &'static str);

fn banks() -> &'static [Bank] {
    static BANKS: OnceLock<Vec<Bank>> = OnceLock::new();
    BANKS.get_or_init(|| rows(FINTS_TSV).map(|[b, n, u]| (b, n, u)).collect())
}

/// (BLZ, BIC) from the Bundesbank BLZ list, sorted by BLZ.
fn bics() -> &'static [(&'static str, &'static str)] {
    static BICS: OnceLock<Vec<(&str, &str)>> = OnceLock::new();
    BICS.get_or_init(|| rows(BIC_TSV).map(|[b, c]| (b, c)).collect())
}

/// Name and FinTS endpoint of a bank in the built-in directory.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FinTsBankInfo {
    pub blz: String,
    pub name: String,
    pub url: String,
}

fn info(entry: &Bank) -> FinTsBankInfo {
    FinTsBankInfo {
        blz: entry.0.to_string(),
        name: entry.1.to_string(),
        url: entry.2.to_string(),
    }
}

/// Keeps only the digits ("1005 0000" -> "10050000").
fn digits(s: &str) -> String {
    s.chars().filter(|c| c.is_ascii_digit()).collect()
}

fn find(blz: &str) -> Option<&'static Bank> {
    let banks = banks();
    banks
        .binary_search_by(|e| e.0.cmp(blz))
        .ok()
        .map(|i| &banks[i])
}

/// Number of banks in the directory.
pub fn directory_len() -> usize {
    banks().len()
}

/// Directory entry for an exact 8-digit BLZ.
pub fn lookup(blz: &str) -> Option<FinTsBankInfo> {
    let blz = blz.trim();
    if blz.len() != 8 || !blz.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    find(blz).map(info)
}

/// FinTS URL for a BLZ (used as fallback when a connection has no stored URL).
pub fn url_for_blz(blz: &str) -> Option<&'static str> {
    find(blz).map(|e| e.2)
}

/// Lower-cases and folds German umlauts / ß so "Münchner" matches "muenchner".
pub(crate) fn fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars().flat_map(char::to_lowercase) {
        match c {
            'ä' => out.push('a'),
            'ö' => out.push('o'),
            'ü' => out.push('u'),
            'ß' => out.push_str("ss"),
            c if c.is_alphanumeric() => out.push(c),
            _ => out.push(' '),
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Banks whose name contains every word of `query` (case/umlaut-insensitive),
/// or whose BLZ starts with the digits typed. Name matches that start with the
/// query come first. At most `limit` results.
pub fn search(query: &str, limit: usize) -> Vec<FinTsBankInfo> {
    let q = fold(query);
    if q.is_empty() || limit == 0 {
        return vec![];
    }
    let only_digits = q.chars().all(|c| c.is_ascii_digit() || c == ' ');
    if only_digits {
        let d = digits(&q);
        if d.len() < 3 {
            return vec![];
        }
        return banks()
            .iter()
            .filter(|e| e.0.starts_with(&d))
            .take(limit)
            .map(info)
            .collect();
    }
    let words: Vec<&str> = q.split(' ').collect();
    let mut prefix = vec![];
    let mut rest = vec![];
    for e in banks() {
        let name = fold(e.1);
        if words.iter().all(|w| name.contains(w)) {
            if name.starts_with(&q) {
                prefix.push(e);
            } else {
                rest.push(e);
            }
        }
    }
    prefix
        .into_iter()
        .chain(rest)
        .take(limit)
        .map(info)
        .collect()
}

/// The 8-digit BLZ of a German IBAN (`DE kk BBBBBBBB KKKKKKKKKK`, characters
/// 5..12). Spaces and case are ignored; the IBAN checksum must be valid.
pub fn blz_from_german_iban(iban: &str) -> Option<String> {
    let s: String = iban
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>()
        .to_uppercase();
    if s.len() != 22 || !s.starts_with("DE") || !sepa::validate_iban(&s) {
        return None;
    }
    Some(s[4..12].to_string())
}

/// Extracts a BLZ from what the user typed: an 8-digit BLZ (spaces allowed)
/// or a complete German IBAN. Anything else gives `None`.
pub fn blz_from_input(input: &str) -> Option<String> {
    if let Some(b) = blz_from_german_iban(input) {
        return Some(b);
    }
    let t = input.trim();
    let d = digits(t);
    // only digits and spaces – "DE12…" fragments must not be mistaken for a BLZ
    (d.len() == 8 && t.chars().all(|c| c.is_ascii_digit() || c == ' ')).then_some(d)
}

/// Looks a bank up by its 8-digit BLZ (the Swift add-account form calls this
/// while the user types).
#[uniffi::export]
pub fn lookup_fints_bank_by_blz(blz: String) -> Option<FinTsBankInfo> {
    lookup(&digits(&blz))
}

/// BLZ typed as 8 digits or taken from a German IBAN; `None` for other input.
#[uniffi::export]
pub fn blz_from_bank_input(input: String) -> Option<String> {
    blz_from_input(&input)
}

/// Directory lookup straight from what the user typed (BLZ or German IBAN).
#[uniffi::export]
pub fn lookup_fints_bank_by_input(input: String) -> Option<FinTsBankInfo> {
    blz_from_input(&input).and_then(|b| lookup(&b))
}

/// BIC of a German IBAN's bank, from the Bundesbank BLZ list in
/// `data/bic_directory.tsv` ("INGDDEFF"). `None` for non-German or invalid IBANs.
#[uniffi::export]
pub fn bic_for_iban(iban: String) -> Option<String> {
    let blz = blz_from_german_iban(&iban)?;
    let bics = bics();
    bics.binary_search_by(|e| e.0.cmp(blz.as_str()))
        .ok()
        .map(|i| bics[i].1.to_string())
}

#[cfg(test)]
mod tests {
    use super::super::fints_presets::is_valid_fints_url;
    use super::*;
    use crate::data_tables::malformed_rows;

    #[test]
    fn every_data_row_parses() {
        assert_eq!(malformed_rows(BIC_TSV, 2, 2), Vec::<&str>::new());
        assert_eq!(malformed_rows(FINTS_TSV, 3, 3), Vec::<&str>::new());
    }

    #[test]
    fn bic_table_sorted_and_lookup_works() {
        let bics = bics();
        assert!(bics.len() > 3000);
        for w in bics.windows(2) {
            assert!(w[0].0 < w[1].0, "{} !< {}", w[0].0, w[1].0);
        }
        assert_eq!(
            bic_for_iban("DE89 3704 0044 0532 0130 00".into()).as_deref(),
            Some("COBADEFF")
        );
        assert_eq!(bic_for_iban("AT611904300234573201".into()), None);
        assert_eq!(bic_for_iban("".into()), None);
    }

    #[test]
    fn table_is_sorted_unique_and_https() {
        assert!(directory_len() > 1500);
        for w in banks().windows(2) {
            assert!(w[0].0 < w[1].0, "{} !< {}", w[0].0, w[1].0);
        }
        for e in banks() {
            assert_eq!(e.0.len(), 8, "{}", e.0);
            assert!(e.0.bytes().all(|b| b.is_ascii_digit()), "{}", e.0);
            assert!(!e.1.trim().is_empty(), "{}", e.0);
            assert!(is_valid_fints_url(e.2), "{}: {}", e.0, e.2);
            assert!(!e.2.contains('*'), "{}: {}", e.0, e.2);
        }
    }

    #[test]
    fn requested_banks_resolve_to_their_endpoints() {
        const ATRUVIA: &str = "https://fints1.atruvia.de/cgi-bin/hbciservlet";
        let cases = [
            ("50010517", "https://fints.ing.de/fints/"),
            ("43060967", ATRUVIA),
            ("12030000", "https://fints.dkb.de/fints"),
            ("76030080", "https://brokerage-hbci.consorsbank.de/hbci"),
            ("10077777", "https://fints.norisbank.de/"),
            ("66090800", ATRUVIA),
            ("30060601", ATRUVIA),
            ("83094495", ATRUVIA),
            ("10070000", "https://fints.deutsche-bank.de/"),
            ("70020270", "https://hbci.hypovereinsbank.de/hbci/hbci.do"),
            ("12096597", ATRUVIA),
            ("10010010", "https://hbci.postbank.de/banking/hbci.do"),
            ("10050000", "https://banking-be3.s-fints-pt-be.de/fints30"),
        ];
        for (blz, url) in cases {
            let b = lookup(blz).unwrap_or_else(|| panic!("{blz} missing"));
            assert_eq!(b.url, url, "{blz}");
            assert_eq!(b.blz, blz);
        }
        assert_eq!(lookup("50010517").unwrap().name, "ING");
        assert_eq!(url_for_blz("43060967"), Some(ATRUVIA));
    }

    #[test]
    fn unknown_and_malformed_blz() {
        assert_eq!(lookup("00000000"), None);
        assert_eq!(lookup("1234567"), None);
        assert_eq!(lookup("1234567x"), None);
        assert_eq!(lookup(""), None);
        // comdirect has its own connector, not a FinTS entry
        assert_eq!(lookup("20041111"), None);
    }

    #[test]
    fn exported_lookup_ignores_spaces() {
        assert_eq!(
            lookup_fints_bank_by_blz("5001 0517".into()).map(|b| b.name),
            Some("ING".into())
        );
        assert_eq!(lookup_fints_bank_by_blz("abc".into()), None);
    }

    #[test]
    fn iban_to_blz() {
        // public example IBANs
        assert_eq!(
            blz_from_german_iban("DE89 3704 0044 0532 0130 00").as_deref(),
            Some("37040044")
        );
        assert_eq!(
            blz_from_german_iban("de89370400440532013000").as_deref(),
            Some("37040044")
        );
        // bad checksum, wrong country, wrong length
        assert_eq!(blz_from_german_iban("DE88370400440532013000"), None);
        assert_eq!(blz_from_german_iban("AT611904300234573201"), None);
        assert_eq!(blz_from_german_iban("DE8937040044053201300"), None);
        assert_eq!(blz_from_german_iban(""), None);
    }

    #[test]
    fn input_can_be_blz_or_iban() {
        assert_eq!(blz_from_input("50010517").as_deref(), Some("50010517"));
        assert_eq!(blz_from_input(" 5001 0517 ").as_deref(), Some("50010517"));
        assert_eq!(
            blz_from_input("DE89370400440532013000").as_deref(),
            Some("37040044")
        );
        assert_eq!(blz_from_input("5001051"), None);
        assert_eq!(blz_from_input("500105178"), None);
        assert_eq!(blz_from_input("DE89 3704"), None);
        assert_eq!(blz_from_input("ING"), None);
        assert_eq!(
            lookup_fints_bank_by_input("DE89370400440532013000".into()),
            lookup("37040044")
        );
    }

    #[test]
    fn name_search_folds_case_and_umlauts() {
        let r = search("sparkasse", 500);
        assert!(r.len() > 100, "{}", r.len());
        assert!(search("  ", 10).is_empty());
        assert!(search("sparkasse", 0).is_empty());
        assert_eq!(search("sparkasse", 7).len(), 7);
        let ing = search("ING", 20);
        assert!(ing.iter().any(|b| b.blz == "50010517"));
        assert!(search("Sparda Berlin", 5)
            .iter()
            .any(|b| b.blz == "12096597"));
        assert!(search("postbank", 5).iter().all(|b| b.name == "Postbank"));
        assert!(search("apobank", 5).iter().any(|b| b.blz == "30060601"));
        assert!(search("ethik", 5).iter().any(|b| b.blz == "83094495"));
        assert_eq!(
            fold("Münchner Bank-Großkunden"),
            "munchner bank grosskunden"
        );
        // BLZ prefix search needs at least three digits
        assert!(search("50", 5).is_empty());
        assert!(search("50010", 5).iter().any(|b| b.blz == "50010517"));
    }

    #[test]
    fn sparda_and_psd_banks_have_https_endpoints() {
        // PSD and Sparda banks have all migrated to Atruvia (the legacy
        // Sparda-Datenverarbeitung gateway bankingonline.de is gone).
        const ATRUVIA: &str = "https://fints1.atruvia.de/cgi-bin/hbciservlet";
        let psd = search("psd", 200);
        let psd: Vec<_> = psd
            .iter()
            .filter(|b| fold(&b.name).starts_with("psd"))
            .collect();
        assert!(psd.len() >= 10);
        assert!(psd.iter().all(|b| b.url == ATRUVIA));
        let sparda = search("sparda", 200);
        let sparda: Vec<_> = sparda
            .iter()
            .filter(|b| fold(&b.name).starts_with("sparda"))
            .collect();
        assert!(sparda.len() >= 10);
        assert!(sparda.iter().all(|b| is_valid_fints_url(&b.url)));
        assert!(sparda.iter().all(|b| b.url == ATRUVIA));
        assert!(!banks().iter().any(|e| e.2.contains("bankingonline.de")));
    }

    /// All 19 PSD head offices of the Bundesbank Bankleitzahlendatei (names
    /// containing "PSD", main entries) – checked against the file on 2026-11-13.
    /// 75090900 is the VR Bank Niederbayern-Oberpfalz (merged PSD), not a PSD.
    const PSD_BLZ: [&str; 19] = [
        "10090900", "20090900", "21090900", "25090900", "27090900", "29090900", "30060992",
        "37060993", "40090900", "44090920", "50090900", "57090900", "58590900", "59090900",
        "60090900", "66090900", "68090900", "72090900", "76090900",
    ];

    #[test]
    fn every_psd_bank_is_listed_once_and_findable() {
        let mut names = std::collections::HashSet::new();
        for blz in PSD_BLZ {
            let b = lookup(blz).unwrap_or_else(|| panic!("{blz} missing"));
            assert!(b.name.starts_with("PSD Bank"), "{blz}: {}", b.name);
            assert!(names.insert(b.name.clone()), "duplicate name: {}", b.name);
            assert!(search(&b.name, 50).iter().any(|r| r.blz == blz), "{blz}");
            assert!(
                bics().binary_search_by(|e| e.0.cmp(blz)).is_ok(),
                "{blz}: no BIC"
            );
        }
        // no further bank named PSD in the directory
        let psd = search("psd", 200);
        let all: Vec<_> = psd
            .iter()
            .filter(|b| fold(&b.name).starts_with("psd"))
            .collect();
        assert_eq!(all.len(), PSD_BLZ.len());
        assert!(search("psd west", 5).iter().any(|b| b.blz == "37060993"));
        assert!(search("psd stuttgart", 5)
            .iter()
            .any(|b| b.blz == "60090900"));
    }
}
