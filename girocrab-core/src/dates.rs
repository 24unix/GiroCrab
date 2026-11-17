//! Date and time helpers. The vault stores dates as `YYYY-MM-DD` text and
//! change stamps (`created_ms`, `updated_ms`, `deleted_ms`) as Unix
//! milliseconds.

use std::sync::LazyLock;

use chrono::NaiveDate;
use regex::Regex;

/// The current time as a change stamp: Unix milliseconds, UTC.
pub(crate) fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

/// `d` as stored: `YYYY-MM-DD`.
pub(crate) fn iso(d: NaiveDate) -> String {
    d.format("%Y-%m-%d").to_string()
}

/// The `YYYY-MM-DD` at the start of `s`; a time after it is ignored.
pub(crate) fn parse_iso(s: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(s.get(..10).unwrap_or(s), "%Y-%m-%d").ok()
}

/// `YYYY-MM-DD` or `DD.MM.YYYY`, blanks around it ignored.
pub(crate) fn parse_de_or_iso(s: &str) -> Option<NaiveDate> {
    let s = s.trim();
    NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .or_else(|_| NaiveDate::parse_from_str(s, "%d.%m.%Y"))
        .ok()
}

/// The first `D.M.YYYY` anywhere in `s` that is a real day ("31.02.2025" is
/// skipped). Digits glued to it ("112.03.2025") don't count as one.
pub(crate) fn find_de_date(s: &str) -> Option<NaiveDate> {
    static DE_DATE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b").unwrap());
    DE_DATE.captures_iter(s).find_map(|c| {
        NaiveDate::from_ymd_opt(c[3].parse().ok()?, c[2].parse().ok()?, c[1].parse().ok()?)
    })
}

/// Month names and abbreviations (German, English), lower case.
const MONTHS: [&[&str]; 12] = [
    &["januar", "jänner", "january", "jän", "jan"],
    &["februar", "february", "febr", "feb"],
    &["märz", "maerz", "marz", "march", "mär", "mrz", "mar"],
    &["april", "apr"],
    &["mai", "may"],
    &["juni", "june", "jun"],
    &["juli", "july", "jul"],
    &["august", "aug"],
    &["september", "sept", "sep"],
    &["oktober", "october", "okt", "oct"],
    &["november", "nov"],
    &["dezember", "december", "dez", "dec"],
];

/// 1–12 for a German or English month name or abbreviation, in any case and
/// with or without a trailing dot. Only whole names count, so "Maintal" or
/// "Junior" is no month.
pub(crate) fn month_from_name(s: &str) -> Option<u32> {
    let s = s.trim().trim_end_matches('.').to_lowercase();
    MONTHS
        .iter()
        .position(|names| names.contains(&s.as_str()))
        .map(|i| i as u32 + 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(y: i32, m: u32, d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, d).unwrap()
    }

    #[test]
    fn iso_round_trip() {
        assert_eq!(iso(day(2025, 3, 2)), "2025-03-02");
        assert_eq!(parse_iso("2025-03-02"), Some(day(2025, 3, 2)));
        assert_eq!(parse_iso("2025-03-02T10:00:00Z"), Some(day(2025, 3, 2)));
        assert_eq!(parse_iso("2025-02-30"), None);
        assert_eq!(parse_iso("02.03.2025"), None);
        assert_eq!(parse_iso(""), None);
    }

    #[test]
    fn german_or_iso() {
        assert_eq!(parse_de_or_iso(" 2025-03-02 "), Some(day(2025, 3, 2)));
        assert_eq!(parse_de_or_iso("02.03.2025"), Some(day(2025, 3, 2)));
        assert_eq!(parse_de_or_iso("31.02.2025"), None);
        assert_eq!(parse_de_or_iso("März 2025"), None);
    }

    #[test]
    fn german_date_in_text() {
        assert_eq!(find_de_date("am 1.2.2026."), Some(day(2026, 2, 1)));
        assert_eq!(find_de_date("31.02.2026"), None);
        assert_eq!(
            find_de_date("Formular 10.20.2024, Stand 01.03.2025"),
            Some(day(2025, 3, 1))
        );
        assert_eq!(find_de_date("Bestellung 112.03.2025"), None);
        assert_eq!(find_de_date("2025-03-02"), None);
    }

    #[test]
    fn month_names() {
        assert_eq!(month_from_name("März"), Some(3));
        assert_eq!(month_from_name("Mär."), Some(3));
        assert_eq!(month_from_name("SEPT"), Some(9));
        assert_eq!(month_from_name("Febr."), Some(2));
        assert_eq!(month_from_name("Jän."), Some(1));
        assert_eq!(month_from_name("Marz"), Some(3));
        assert_eq!(month_from_name("may"), Some(5));
        for word in ["marketing", "Maintal", "Augen", "Junior", "decimal", ""] {
            assert_eq!(month_from_name(word), None, "{word}");
        }
    }
}
