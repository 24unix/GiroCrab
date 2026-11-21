//! NaturalSearchParser.swift › literalSearchTerm (54f83952): what the core searches for when the
//! user types into the search field. German plurals are cut back to their stem ("kredite" →
//! "kredit") and a booking compound with a plain booking noun searches its stem
//! ("amazonbestellungen" → "amazon"), so the substring search also finds the singular. The field
//! keeps showing what was typed (`AppModel.currentFilter`).

/// Booking nouns that only say "a booking of …": the stem may replace the word in the text search.
const STRONG_BOOKING_SUFFIXES: [&str; 10] = [
    "transaktionen",
    "transaktion",
    "bestellungen",
    "bestellung",
    "zahlungen",
    "zahlung",
    "buchungen",
    "buchung",
    "umsaetze",
    "umsatz",
];
/// Nouns with meaning of their own (Nebenkosten ≠ neben): their stem only serves to match a category.
const WEAK_BOOKING_SUFFIXES: [&str; 15] = [
    "rechnungen",
    "rechnung",
    "einnahmen",
    "einnahme",
    "gebuehren",
    "gebuehr",
    "beitraege",
    "beitrag",
    "ausgaben",
    "ausgabe",
    "kosten",
    "raten",
    "rate",
    "abos",
    "abo",
];
/// Fugen-s only after endings where German regularly inserts it (versicherungs-, gesundheits-).
const FUGEN_S_ENDINGS: [&str; 6] = ["ungs", "heits", "keits", "schafts", "ions", "taets"];

/// `wordForms`: the word itself first, then shorter stems, longest first. Only letters-only words
/// of at least 6 characters are shortened, so "miete" and "kredit" stay as they are and IBANs,
/// amounts and years are never touched. Every form is a prefix of the word.
fn word_forms(word: &str) -> Vec<String> {
    let mut forms = vec![word.to_string()];
    let chars: Vec<char> = word.chars().collect();
    if chars.len() < 6 || !chars.iter().all(|c| c.is_alphabetic()) {
        return forms;
    }
    let lower = word.to_lowercase();
    let drop = |n: usize| chars[..chars.len() - n].iter().collect::<String>();
    if lower.ends_with("en") {
        forms.push(drop(1)); // mieten → miete
        forms.push(drop(2)); // versicherungen → versicherung
    } else if lower.ends_with('e') || lower.ends_with('s') {
        forms.push(drop(1)); // kredite → kredit, depots → depot
    }
    forms
}

/// `stemPlural`: the shortest form of `word`.
fn stem_plural(word: &str) -> String {
    word_forms(word).pop().unwrap_or_else(|| word.to_string())
}

/// `fold`: lowercased, umlauts spelled out (ä→ae, ß→ss), other diacritics dropped.
fn fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.to_lowercase().chars() {
        match c {
            'ä' => out.push_str("ae"),
            'ö' => out.push_str("oe"),
            'ü' => out.push_str("ue"),
            'ß' => out.push_str("ss"),
            'à' | 'á' | 'â' | 'ã' | 'å' | 'ā' => out.push('a'),
            'ç' | 'ć' | 'č' => out.push('c'),
            'è' | 'é' | 'ê' | 'ë' | 'ē' => out.push('e'),
            'ì' | 'í' | 'î' | 'ï' => out.push('i'),
            'ñ' | 'ń' => out.push('n'),
            'ò' | 'ó' | 'ô' | 'õ' => out.push('o'),
            'ù' | 'ú' | 'û' => out.push('u'),
            'ý' | 'ÿ' => out.push('y'),
            'š' => out.push('s'),
            'ž' => out.push('z'),
            other => out.push(other),
        }
    }
    out
}

/// `splitBookingCompound`: `mietzahlungen` → ("miet", strong); `versicherungsbeitraege` →
/// ("versicherung", weak); None without a booking suffix or when the stem would be shorter than
/// 3 letters.
fn split_booking_compound(word: &str) -> Option<(String, bool)> {
    let w = fold(word);
    let mut strong: Vec<&str> = STRONG_BOOKING_SUFFIXES.to_vec();
    let mut weak: Vec<&str> = WEAK_BOOKING_SUFFIXES.to_vec();
    // longest first, like the Swift lists
    strong.sort_by_key(|s| std::cmp::Reverse(s.len()));
    weak.sort_by_key(|s| std::cmp::Reverse(s.len()));
    for (list, is_strong) in [(strong, true), (weak, false)] {
        for suffix in list {
            if !w.ends_with(suffix) || w == suffix {
                continue;
            }
            let mut stem = w[..w.len() - suffix.len()].to_string();
            if FUGEN_S_ENDINGS.iter().any(|e| stem.ends_with(e)) {
                stem.pop();
            }
            if stem.chars().count() < 3 || !stem.chars().all(|c| c.is_alphabetic()) {
                continue;
            }
            return Some((stem, is_strong));
        }
    }
    None
}

/// `literalSearchTerm`: every word of the typed text cut back to its stem. The core searches each
/// whitespace-separated word on its own, so each stem is still a substring of what the word matched.
pub fn literal_search_term(text: &str) -> String {
    if text.trim().is_empty() {
        return text.to_string();
    }
    text.split_whitespace()
        .map(|word| match split_booking_compound(word) {
            Some((stem, true)) => stem,
            _ => stem_plural(word),
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The cases of NaturalSearchParserTests / the Mac's literal search.
    #[test]
    fn plurals_and_booking_compounds() {
        assert_eq!(literal_search_term("kredite"), "kredit");
        assert_eq!(literal_search_term("Mieten"), "Miet", "case kept");
        assert_eq!(literal_search_term("kredite sparkasse"), "kredit sparkass");
        assert_eq!(literal_search_term("miete 2024"), "miete 2024");
        assert_eq!(literal_search_term("mieten"), "miet");
        assert_eq!(literal_search_term("versicherungen"), "versicherung");
        assert_eq!(literal_search_term("depots"), "depot");
        // short words, numbers, IBANs and amounts stay as typed
        assert_eq!(literal_search_term("miete"), "miete");
        assert_eq!(literal_search_term("kredit"), "kredit");
        assert_eq!(
            literal_search_term("DE89370400440532013000"),
            "DE89370400440532013000"
        );
        assert_eq!(literal_search_term("12,50"), "12,50");
        assert_eq!(literal_search_term("2026"), "2026");
        // strong booking compounds search their stem, weak ones only lose the plural
        assert_eq!(literal_search_term("amazonbestellungen"), "amazon");
        assert_eq!(literal_search_term("mietzahlungen"), "miet");
        assert_eq!(
            literal_search_term("versicherungszahlungen"),
            "versicherung"
        );
        assert_eq!(literal_search_term("nebenkosten"), "nebenkost");
        // the booking noun alone is no compound
        assert_eq!(literal_search_term("zahlungen"), "zahlung");
        // each word on its own, surrounding blanks dropped
        assert_eq!(literal_search_term("  alle kredite "), "alle kredit");
        assert_eq!(literal_search_term(""), "");
        assert_eq!(literal_search_term("   "), "   ");
    }

    #[test]
    fn fold_spells_out_umlauts() {
        assert_eq!(fold("Gebühren"), "gebuehren");
        assert_eq!(fold("Straße"), "strasse");
        assert_eq!(fold("Café"), "cafe");
    }
}
