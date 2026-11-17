//! IBAN helpers (ISO 13616): normalising and strict Mod-97 validation.

/// IBAN length per country (SEPA area + common neighbours).
const IBAN_LENGTHS: &[(&str, usize)] = &[
    ("AD", 24),
    ("AT", 20),
    ("BE", 16),
    ("BG", 22),
    ("CH", 21),
    ("CY", 28),
    ("CZ", 24),
    ("DE", 22),
    ("DK", 18),
    ("EE", 20),
    ("ES", 24),
    ("FI", 18),
    ("FR", 27),
    ("GB", 22),
    ("GI", 23),
    ("GR", 27),
    ("HR", 21),
    ("HU", 28),
    ("IE", 22),
    ("IS", 26),
    ("IT", 27),
    ("LI", 21),
    ("LT", 20),
    ("LU", 20),
    ("LV", 21),
    ("MC", 27),
    ("MT", 31),
    ("NL", 18),
    ("NO", 15),
    ("PL", 28),
    ("PT", 25),
    ("RO", 24),
    ("SE", 24),
    ("SI", 19),
    ("SK", 24),
    ("SM", 27),
    ("VA", 22),
];

/// IBAN length of `country` (two upper-case letters), if known.
pub fn iban_length(country: &str) -> Option<usize> {
    IBAN_LENGTHS
        .iter()
        .find(|(c, _)| *c == country)
        .map(|(_, len)| *len)
}

/// Removes whitespace and upper-cases ASCII letters: the form IBANs (and
/// BICs) are stored, compared and sent in.
pub fn normalize_iban(iban: &str) -> String {
    let mut s: String = iban.chars().filter(|c| !c.is_whitespace()).collect();
    s.make_ascii_uppercase();
    s
}

/// Strict IBAN check: characters, country prefix, length, Mod-97 checksum.
pub fn validate_iban(iban: &str) -> bool {
    let s = normalize_iban(iban);
    if s.len() < 15 || s.len() > 34 || !s.chars().all(|c| c.is_ascii_alphanumeric()) {
        return false;
    }
    let b = s.as_bytes();
    if !(b[0].is_ascii_uppercase()
        && b[1].is_ascii_uppercase()
        && b[2].is_ascii_digit()
        && b[3].is_ascii_digit())
    {
        return false;
    }
    if iban_length(&s[..2]) != Some(s.len()) {
        return false;
    }
    // Move the first four characters to the end.
    mod97(s[4..].chars().chain(s[..4].chars())) == 1
}

/// ISO 7064 MOD 97-10 remainder of alphanumerics, letters A=10 … Z=35
/// (IBAN, creditor ID, ISO 11649 creditor reference: valid when it is 1).
pub(crate) fn mod97(chars: impl Iterator<Item = char>) -> u32 {
    chars.fold(0, |rem, c| {
        let v = c.to_digit(36).unwrap_or(0);
        if v >= 10 {
            (rem * 100 + v) % 97
        } else {
            (rem * 10 + v) % 97
        }
    })
}

/// ISO 20022 IBAN2007Identifier: `[A-Z]{2}[0-9]{2}[a-zA-Z0-9]{1,30}`. Shape
/// only, no checksum: see [`validate_iban`] for that.
pub fn has_iban_shape(s: &str) -> bool {
    let b = s.as_bytes();
    (5..=34).contains(&b.len())
        && b[..2].iter().all(u8::is_ascii_uppercase)
        && b[2..4].iter().all(u8::is_ascii_digit)
        && b[4..].iter().all(u8::is_ascii_alphanumeric)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_strips_blanks_and_upper_cases() {
        assert_eq!(
            normalize_iban(" de89 3704\u{00A0}0044 0532 0130 00\n"),
            "DE89370400440532013000"
        );
        // only ASCII is upper-cased: "ß" must not grow into "SS"
        assert_eq!(normalize_iban("deß1"), "DEß1");
    }

    #[test]
    fn valid_ibans() {
        assert!(validate_iban("DE89370400440532013000"));
        assert!(validate_iban("DE89 3704 0044 0532 0130 00"));
        assert!(validate_iban("  de89370400440532013000 "));
        assert!(validate_iban("GB82 WEST 1234 5698 7654 32"));
        assert!(validate_iban("AT611904300234573201"));
    }

    #[test]
    fn invalid_ibans() {
        assert!(!validate_iban("DE89370400440532013001")); // checksum
        assert!(!validate_iban("DE8937040044053201300")); // too short for DE
        assert!(!validate_iban("XX89370400440532013000")); // unknown country
        assert!(!validate_iban("DE89-3704-0044-0532-0130-00")); // bad characters
        assert!(!validate_iban(""));
        assert!(!validate_iban("1234"));
    }
}
