//! Händler-Erkennung ("Merchant Resolver").
//!
//! Turns noisy German bank strings ("REWE SAGT DANKE 4711", "PayPal *Spotify",
//! "AMZN Mktp DE*AB12CD", "Core MSCI World USD (Acc)") into a clean merchant:
//! display name, domain, monogram, a subtle brand colour and an SF Symbol.
//!
//!  * Tier 1 – offline: the bundled table below (supermarkets, insurers,
//!    mobility, streaming, shops, banks, ETF issuers, ETFs with ISIN/WKN).
//!  * Tier 2 – optional online favicon cache (see `Vault::fetch_logo`), only
//!    when the user enables it in Settings; bytes are cached in SQLCipher.
//!  * Tier 3 – the UI falls back to the category's SF Symbol.
//!
//! The module also classifies every booking into a `FlowKind`, so ETF savings
//! plans, Saveback and Round up never count as consumption ("Konsumausgaben").
//!
//! The user can switch the recognition off, switch off single bundled merchants
//! and add own ones (#1373, Einstellungen › Händler): [`MerchantRules`] applies
//! that per vault, `custom` stores and syncs it.

pub mod custom;

use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use crate::models::AccountKind;

/// Entries kept by the merchant cache of [`MerchantRules::resolve`].
const RESOLVE_CACHE_MAX: usize = 200_000;

/// Counterparty → purpose → merchant, see [`MerchantRules::resolve`]. Nested
/// so a lookup borrows both texts instead of building an owned key per booking.
#[derive(Default)]
struct ResolveCache {
    len: usize,
    by_counterparty: HashMap<String, HashMap<String, Resolved>>,
}

/// A remembered merchant: the one shown and the bundled table's.
#[derive(Clone)]
struct Resolved {
    info: Arc<MerchantInfo>,
    bundled: BundledMerchant,
}

/// What the bundled table alone says about a booking, whatever the user changed
/// (#1373). The analysis reads it: the flow (an ETF purchase stays an investment),
/// the recurring series and the category suggestions. The user's changes rename
/// bookings; they don't move them between "Konsum" and "Investition" or split the
/// series of a subscription.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BundledMerchant {
    pub(crate) key: Arc<str>,
    pub(crate) kind: MerchantKind,
}

/// Forgets every merchant the bundled rules remembered. Its keys are booking texts
/// in plain text, so the last vault to close calls this (#267); the own rules of a
/// vault (and their cache) go with the vault.
pub(crate) fn clear_resolve_cache() {
    MerchantRules::builtin().clear_cache();
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum MerchantKind {
    Supermarket,
    Butcher,
    FoodRescue,
    Restaurant,
    Delivery,
    Drugstore,
    Insurance,
    Mobility,
    Fuel,
    Streaming,
    Telecom,
    Utilities,
    OnlineShop,
    Electronics,
    Games,
    Fitness,
    Travel,
    PaymentService,
    Bank,
    Broker,
    EtfIssuer,
    Etf,
    Crypto,
    Stock,
    Unknown,
}

/// What a booking means for the household budget.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum FlowKind {
    /// Everyday spending (Konsum) – the only kind counted as "Konsumausgaben".
    Consumption,
    Income,
    /// ETF / crypto / stock savings plans and purchases.
    Investment,
    /// Trade Republic Saveback and Round up.
    Perk,
    /// Between own accounts, card settlements, top-ups.
    Transfer,
    /// Loan instalments / repayments (Darlehen).
    Loan,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct MerchantInfo {
    /// Stable key ("rewe", "ishares-core-msci-world", "x:muster-gmbh").
    pub key: String,
    pub name: String,
    /// Domain for the optional favicon cache ("" if unknown).
    pub domain: String,
    /// One or two letters for the squircle signet.
    pub monogram: String,
    /// Subtle brand colour, e.g. "#0050AA".
    pub color_hex: String,
    /// SF Symbol hint ("" = use the category symbol).
    pub sf_symbol: String,
    pub kind: MerchantKind,
    /// From the bundled table (Tier 1)?
    pub known: bool,
    pub isin: String,
    pub wkn: String,
    /// "ETF", "Krypto", "Aktie" or "".
    pub asset_class: String,
    /// simple-icons SVG path (24×24 viewBox), "" if the brand has none.
    pub svg_path: String,
    /// simple-icons slug ("lidl", "deutschebahn" …), "" if none.
    pub icon_slug: String,
    /// Domains to try for the favicon, best first ("enbw.de", "enbw.com").
    pub domain_candidates: Vec<String>,
    /// "dictionary" | "company" (legal suffix) | "override" | "person" | "" (none)
    pub domain_source: String,
    /// Looks like a private person ("Laura Schneider"): no logo, initials circle.
    pub is_person: bool,
}

/// Merchant key -> simple-icons slug (CC0 brand icon dataset, simpleicons-rs).
fn simple_icon_slug(key: &str) -> Option<&'static str> {
    Some(match key {
        "rewe" => "rewe",
        "edeka" => "edeka",
        "lidl" => "lidl",
        "aldi-sued" => "aldisud",
        "aldi-nord" => "aldinord",
        "kaufland" => "kaufland",
        "penny" => "penny",
        "metro" => "metro",
        "dm" => "dm",
        "rossmann" => "rossmann",
        "barmenia" => "barmenia",
        "amazon" => "amazon",
        "paypal" => "paypal",
        "netflix" => "netflix",
        "spotify" => "spotify",
        "apple" => "apple",
        "deutsche-bahn" => "deutschebahn",
        "shell" => "shell",
        "aral" => "aral",
        "crypto-bitcoin" => "bitcoin",
        "crypto-ethereum" => "ethereum",
        "vodafone" => "vodafone",
        "ebay" => "ebay",
        "zalando" => "zalando",
        "ikea" => "ikea",
        "mediamarkt" => "mediamarkt",
        "steam" => "steam",
        "nintendo" => "nintendo",
        "lufthansa" => "lufthansa",
        "american-express" => "americanexpress",
        "sparkasse" => "sparkasse",
        "disney-plus" => "disneyplus",
        "audible" => "audible",
        "uber" => "uber",
        "airbnb" => "airbnb",
        "booking-com" => "bookingdotcom",
        "eurowings" => "eurowings",
        "esso" => "esso",
        "klarna" => "klarna",
        "o2" => "o2",
        _ => return None,
    })
}

/// Looks up a simple-icons brand: (slug, hex colour, SVG path).
pub fn simple_icon(key: &str) -> Option<(&'static str, String, String)> {
    simple_icon_named(key, "")
}

/// Curated slug first; otherwise the merchant key itself, but only if the
/// icon's title starts with the brand name (avoids wrong look-alikes).
pub fn simple_icon_named(key: &str, name: &str) -> Option<(&'static str, String, String)> {
    let icon = match simple_icon_slug(key) {
        Some(slug) => simpleicons_rs::slug(slug)?,
        None => {
            let guess: String = key.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
            let icon = simpleicons_rs::slug(&guess)?;
            let first = name.split_whitespace().next().unwrap_or("").to_lowercase();
            if first.len() < 3 || !icon.title.to_lowercase().starts_with(&first) {
                return None;
            }
            icon
        }
    };
    let svg = icon.svg;
    let start = svg.find(" d=\"")? + 4;
    let end = svg[start..].find('"')? + start;
    Some((
        icon.slug,
        format!("#{}", icon.hex),
        svg[start..end].to_string(),
    ))
}

struct Entry {
    key: &'static str,
    name: &'static str,
    /// Lower-case needles matched against the normalised text.
    needles: Vec<&'static str>,
    domain: &'static str,
    color: &'static str,
    symbol: &'static str,
    kind: MerchantKind,
    isin: &'static str,
    wkn: &'static str,
}

use MerchantKind as K;

const MERCHANTS_TSV: &str = include_str!("../data/merchants.tsv");

impl MerchantKind {
    /// Variant by its Rust name, as written in `data/merchants.tsv`.
    fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "Supermarket" => K::Supermarket,
            "Butcher" => K::Butcher,
            "FoodRescue" => K::FoodRescue,
            "Restaurant" => K::Restaurant,
            "Delivery" => K::Delivery,
            "Drugstore" => K::Drugstore,
            "Insurance" => K::Insurance,
            "Mobility" => K::Mobility,
            "Fuel" => K::Fuel,
            "Streaming" => K::Streaming,
            "Telecom" => K::Telecom,
            "Utilities" => K::Utilities,
            "OnlineShop" => K::OnlineShop,
            "Electronics" => K::Electronics,
            "Games" => K::Games,
            "Fitness" => K::Fitness,
            "Travel" => K::Travel,
            "PaymentService" => K::PaymentService,
            "Bank" => K::Bank,
            "Broker" => K::Broker,
            "EtfIssuer" => K::EtfIssuer,
            "Etf" => K::Etf,
            "Crypto" => K::Crypto,
            "Stock" => K::Stock,
            "Unknown" => K::Unknown,
            _ => return None,
        })
    }
}

/// Stage A: the curated dictionary from `data/merchants.tsv` (~270 brands),
/// in match order – priority list, main table, German dictionary.
fn entries() -> &'static [Entry] {
    static ENTRIES: OnceLock<Vec<Entry>> = OnceLock::new();
    ENTRIES.get_or_init(|| {
        crate::data_tables::rows(MERCHANTS_TSV)
            .filter_map(
                |[key, name, needles, kind, symbol, color, domain, isin, wkn]| {
                    let needles: Vec<_> = needles.split('|').filter(|n| !n.is_empty()).collect();
                    // `resolve` looks behind `needles[0]` of payment processors
                    if needles.is_empty() {
                        return None;
                    }
                    Some(Entry {
                        key,
                        name,
                        needles,
                        domain,
                        color,
                        symbol,
                        kind: MerchantKind::from_name(kind)?,
                        isin,
                        wkn,
                    })
                },
            )
            .collect()
    })
}

/// Calm palette for unknown merchants (deterministic by name).
const FALLBACK_COLORS: [&str; 8] = [
    "#5B6B7F", "#6B7A5B", "#7F5B6B", "#5B7F7A", "#7A6B5B", "#5E5B7F", "#7F735B", "#5B7F62",
];

pub struct MerchantResolver;

/// Lower-case, collapse separators, drop noise words and long digit runs.
pub fn normalise(s: &str) -> String {
    normalise_text(s, Some(5))
}

/// Legal forms and noise dropped from the texts before matching.
const NOISE: &[&str] = &[
    " sagt danke",
    " gmbh & co. kg",
    " gmbh & co kg",
    " gmbh",
    " se ",
    " ag ",
    " eg ",
    " kg ",
    " s.a.r.l.",
    " s.a.",
    " e.v.",
];

/// [`normalise`] for the user's own search words and the texts they are compared
/// with (#1373): a digit run stays whole (the reference "123456" must not match
/// "123459"), and spaces are collapsed again after the legal forms are dropped
/// ("Muster GmbH Shop" matches "muster shop"). The bundled table keeps `normalise`,
/// so its keys for the analysis do not move.
pub(crate) fn normalise_words(s: &str) -> String {
    let text = normalise_text(s, None);
    let words: Vec<&str> = text.split(' ').filter(|w| !w.is_empty()).collect();
    format!(" {} ", words.join(" "))
}

/// Lower case, separators as spaces, runs of spaces collapsed, digit runs cut after
/// `max_digits`, noise words dropped; padded with a space on both sides.
fn normalise_text(s: &str, max_digits: Option<usize>) -> String {
    let lower = s.to_lowercase();
    let mut out = String::with_capacity(lower.len() + 2);
    out.push(' ');
    let mut digits = 0;
    for ch in lower.chars() {
        let c = match ch {
            '*' | '/' | '_' | ',' | ';' | '|' | '\t' | '\n' => ' ',
            c => c,
        };
        if c.is_ascii_digit() {
            digits += 1;
        } else {
            digits = 0;
        }
        if max_digits.is_some_and(|max| digits > max) {
            continue;
        }
        if c == ' ' && out.ends_with(' ') {
            continue;
        }
        out.push(c);
    }
    let mut s = out;
    for noise in NOISE {
        // `replace` allocates even without a match; most texts contain none.
        if s.contains(noise) {
            s = s.replace(noise, " ");
        }
    }
    if !s.ends_with(' ') {
        s.push(' ');
    }
    s
}

/// Words that mark a booking as a securities transaction.
const SECURITIES_HINTS: &[&str] = &[
    "wp-abrechnung",
    "wp abrechnung",
    "wertpapier",
    "sparplan",
    "aktie",
    "dividende",
    "depot",
    "isin",
    "wkn",
    "kauf order",
    "verkauf order",
];

/// A company name can also be a surname ("Max Bayer", "Anna Siemens"). A
/// stock entry only counts when the booking carries securities evidence:
/// its ISIN/WKN, a securities keyword, or the needle followed by a legal form
/// ("Bayer AG").
fn stock_confirmed(e: &Entry, text: &str, ctx: &str) -> bool {
    securities_hint(e, ctx)
        || e.needles.iter().any(|n| {
            text.find(n.trim())
                .is_some_and(|p| legal_form_at(text, p + n.trim().len()))
        })
}

/// ISIN/WKN of the entry or a securities keyword anywhere in the booking.
fn securities_hint(e: &Entry, ctx: &str) -> bool {
    (!e.isin.is_empty() && ctx.contains(&e.isin.to_lowercase()))
        || (!e.wkn.is_empty() && ctx.contains(&e.wkn.to_lowercase()))
        || contains_any(ctx, SECURITIES_HINTS)
}

/// A legal form of a listed company ("AG", "Inc") right after `text[end..]`.
fn legal_form_at(text: &str, end: usize) -> bool {
    let word: String = text[end..]
        .trim_start()
        .chars()
        .take_while(|c| c.is_alphanumeric() || *c == '.')
        .collect();
    matches!(
        word.trim_end_matches('.'),
        "ag" | "se" | "kgaa" | "inc" | "corp" | "plc"
    )
}

/// True when `needle` occurs in `text` at the start of a word. "Bausparkasse"
/// must not match the needle "sparkasse"; "telekoms" still matches "telekom"
/// (the right edge stays open for plurals and genitives).
fn needle_in(text: &str, needle: &str) -> bool {
    text.match_indices(needle).any(|(i, _)| {
        needle.starts_with(|c: char| !c.is_alphanumeric())
            || text[..i]
                .chars()
                .next_back()
                .is_none_or(|c| !c.is_alphanumeric())
    })
}

/// Sub-brands that the counterparty only shows under the parent company's legal
/// entity ("Fraenk - eine Marke der Telekom Deutschland GmbH"). When the
/// counterparty or purpose names the sub-brand, it wins over the parent.
const SUB_BRANDS: &[(&str, &[&str])] = &[("telekom", &["fraenk", "congstar"])];

/// Entries that stand for a whole group of independent banks (#1365). The booking
/// keeps the group's logo, colour and key, but shows the bank's own name from the
/// counterparty ("Volksbank Mittelhessen", "Stadtsparkasse München").
const GROUP_BRANDS: &[&str] = &["volksbank", "sparkasse"];

/// `entry` named after the member bank in `counterparty`; `None` for other entries
/// or when the counterparty leaves no usable name.
fn group_member(entry: &Entry, counterparty: &str) -> Option<MerchantInfo> {
    if !GROUP_BRANDS.contains(&entry.key) {
        return None;
    }
    // "VOLKSBANK MITTELHESSEN EG": `clean_name` only knows the mixed-case " eG".
    let cp = counterparty.trim();
    let cp = match cp.rsplit_once(' ') {
        Some((head, last)) if last.eq_ignore_ascii_case("eg") => head,
        _ => cp,
    };
    let name = clean_name(cp);
    if name.is_empty() || name.chars().count() > 40 {
        return None;
    }
    let mut info = to_info(entry);
    info.monogram = monogram(&name);
    info.name = name;
    Some(info)
}

/// [`needle_in`] for a search word the user typed (#1373): every position where it
/// stands as a whole word in `text`, so "dm" does not catch "Dmitri" and a copy of
/// "TIER" (bundled as `" tier "`) not "Tierarzt". An edge of the word that is no letter
/// or digit ("(acc)") needs no boundary there. Overlapping occurrences count ("ab-ab"
/// in "xab-ab-ab": the first fails, the second matches). Texts and words come from
/// [`normalise_words`].
fn word_starts<'a>(text: &'a str, needle: &'a str) -> impl Iterator<Item = usize> + 'a {
    let open_start = needle.starts_with(|c: char| !c.is_alphanumeric());
    let open_end = needle.ends_with(|c: char| !c.is_alphanumeric());
    // an empty word would "match" everywhere (stored words never are, see `clean_needles`)
    let mut from = if needle.is_empty() { text.len() + 1 } else { 0 };
    std::iter::from_fn(move || {
        while let Some(p) = text.get(from..)?.find(needle) {
            let i = from + p;
            from = i + text[i..].chars().next().map_or(1, char::len_utf8);
            let start_ok = open_start
                || text[..i]
                    .chars()
                    .next_back()
                    .is_none_or(|c| !c.is_alphanumeric());
            let end_ok = open_end
                || text[i + needle.len()..]
                    .chars()
                    .next()
                    .is_none_or(|c| !c.is_alphanumeric());
            if start_ok && end_ok {
                return Some(i);
            }
        }
        None
    })
}

fn entry_by_key(key: &str) -> Option<&'static Entry> {
    entries().iter().find(|e| e.key == key)
}

/// Every domain of the curated dictionary (whitelist for the logo cache).
pub fn known_brand_domains() -> Vec<&'static str> {
    entries()
        .iter()
        .map(|e| e.domain)
        .filter(|d| !d.is_empty())
        .collect()
}

const LEGAL_SUFFIXES: &[&str] = &[
    "gmbh", "ag", "se", "kg", "ohg", "e.v", "ev", "ug", "ltd", "inc", "s.a", "sa", "s.a.r.l",
    "sarl", "kgaa", "mbh", "gbr", "llc", "plc", "b.v", "bv", "eg", "co.kg", "gmbh&co", "corp",
    "limited",
];

/// "Mustermann Bau GmbH", "Hilfswerk e.V.", "Foo S.a.r.l." -> true
pub fn has_legal_suffix(raw: &str) -> bool {
    raw.split(|c: char| c.is_whitespace() || c == ',' || c == '(' || c == ')')
        .map(|t| {
            t.trim_matches(|c: char| c == '.' || c == ',' || c == ';')
                .to_lowercase()
        })
        .any(|t| LEGAL_SUFFIXES.contains(&t.as_str()))
}

/// Words that make a two-word name a business, not a person.
const BUSINESS_WORDS: &[&str] = &[
    "bäckerei",
    "baeckerei",
    "metzgerei",
    "café",
    "cafe",
    "hotel",
    "restaurant",
    "apotheke",
    "praxis",
    "markt",
    "shop",
    "store",
    "service",
    "technik",
    "verlag",
    "kanzlei",
    "studio",
    "salon",
    "friseur",
    "gärtnerei",
    "werkstatt",
    "pizzeria",
    "trattoria",
    "bistro",
    "imbiss",
    "kiosk",
    "stiftung",
    "verein",
    "schule",
    "kita",
    "klinik",
    "zentrum",
    "center",
    "haus",
    "gasthof",
    "bank",
    "versicherung",
    "werke",
    "energie",
    "konto",
    "finanzamt",
    "kasse",
    "zahnarzt",
    "tierarzt",
    "arzt",
    "tankstelle",
    "station",
    "bar",
    "pub",
    "grill",
    "laden",
    "handel",
    "vertrieb",
    "agentur",
    "consulting",
    "immobilien",
    "hausverwaltung",
    "transport",
    "logistik",
    "reisen",
    "tours",
    "druck",
    "optik",
    "akustik",
    "fahrschule",
    "autohaus",
    "garage",
    "lounge",
];

/// Two or three capitalised words, no digits, no business word, no legal
/// suffix: "Laura Schneider", "Hannah Berger", "Dr. Anna von Berg".
pub fn looks_like_person(raw: &str) -> bool {
    let tokens: Vec<&str> = raw
        .split_whitespace()
        .filter(|t| {
            !matches!(
                t.to_lowercase().as_str(),
                "dr." | "dr" | "prof." | "prof" | "herr" | "frau"
            )
        })
        .collect();
    let particles = ["von", "van", "de", "zu", "der", "den", "di", "da", "le"];
    let names: Vec<&str> = tokens
        .iter()
        .copied()
        .filter(|t| {
            !particles.contains(&t.to_lowercase().as_str())
                || t.chars().next().map(|c| c.is_uppercase()).unwrap_or(false)
        })
        .collect();
    if !(2..=3).contains(&names.len()) || has_legal_suffix(raw) {
        return false;
    }
    names.iter().all(|t| {
        let mut chars = t.chars();
        let first_upper = chars
            .next()
            .map(|c| c.is_alphabetic() && c.is_uppercase())
            .unwrap_or(false);
        let rest_ok = t
            .chars()
            .skip(1)
            .all(|c| c.is_lowercase() || c == '-' || c == '\'');
        let lower = t.to_lowercase();
        let business = BUSINESS_WORDS
            .iter()
            .any(|w| lower == *w || (w.len() >= 4 && lower.ends_with(w)));
        first_upper && rest_ok && t.chars().filter(|c| c.is_alphabetic()).count() >= 2 && !business
    })
}

/// "Laura Schneider" -> "LS"
pub fn person_initials(raw: &str) -> String {
    let words: Vec<&str> = raw
        .split_whitespace()
        .filter(|t| {
            t.chars().next().map(|c| c.is_uppercase()).unwrap_or(false) && !t.ends_with('.')
        })
        .collect();
    match (words.first(), words.last()) {
        (Some(a), Some(b)) if words.len() > 1 => {
            format!("{}{}", a.chars().next().unwrap(), b.chars().next().unwrap()).to_uppercase()
        }
        (Some(a), _) => a.chars().take(2).collect::<String>().to_uppercase(),
        _ => "?".into(),
    }
}

/// Number of curated merchants.
pub fn dictionary_size() -> usize {
    entries().len()
}

const PAYMENT_PREFIXES: &[&str] = &[
    "paypal",
    "pp",
    "visa",
    "sumup",
    "sq",
    "ec",
    "lastschrift",
    "kartenzahlung",
    "zettle",
    "izettle",
    "girocard",
    "mastercard",
    "maestro",
    "vpay",
    "sepa",
    "überweisung",
    "ueberweisung",
    "gutschrift",
    "debitk",
    "kauf",
    "einkauf",
    "zahlung",
    "bei",
];
const GENERIC_WORDS: &[&str] = &[
    "eigenes",
    "eigene",
    "konto",
    "der",
    "die",
    "das",
    "und",
    "the",
    "bäckerei",
    "baeckerei",
    "metzgerei",
    "restaurant",
    "cafe",
    "café",
    "hotel",
    "apotheke",
    "praxis",
    "dr",
    "gasthaus",
    "gaststätte",
    "pizzeria",
    "trattoria",
    "kiosk",
    "shop",
    "store",
    "markt",
    "autohaus",
    "friseur",
    "salon",
    "stadt",
    "gemeinde",
    "verein",
    "firma",
    "zahnarzt",
    "tankstelle",
    "station",
    "geldautomat",
    "bargeld",
    "zinsen",
    "rechnung",
    "miete",
    "lohn",
    "gehalt",
    "hausverwaltung",
    "energie",
    "service",
    "services",
    "deutschland",
    "germany",
    "europe",
    "online",
    "gmbh",
    "ag",
    "se",
    "kg",
    "ohg",
    "co",
    "sagt",
    "danke",
    "filiale",
];
const FIRST_NAMES: &[&str] = &[
    "alex",
    "andreas",
    "anna",
    "anne",
    "christian",
    "daniel",
    "david",
    "eva",
    "felix",
    "florian",
    "frank",
    "hans",
    "jan",
    "jana",
    "jens",
    "johannes",
    "jonas",
    "julia",
    "katharina",
    "lara",
    "laura",
    "lea",
    "lena",
    "lisa",
    "lukas",
    "maria",
    "markus",
    "martin",
    "max",
    "michael",
    "nina",
    "paul",
    "peter",
    "sabine",
    "sandra",
    "sarah",
    "sebastian",
    "simon",
    "sophie",
    "stefan",
    "stephan",
    "susanne",
    "thomas",
    "tim",
    "tobias",
    "ute",
    "wolfgang",
];

fn transliterate(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            'ä' => out.push_str("ae"),
            'ö' => out.push_str("oe"),
            'ü' => out.push_str("ue"),
            'ß' => out.push_str("ss"),
            c => out.push(c),
        }
    }
    out
}

/// Stage B: guesses brand domains for an unknown counterparty
/// ("SumUp *Blumenhaus Schmidt" -> ["blumenhaus.de", "blumenhaus.com"]).
pub fn heuristic_domains(counterparty: &str) -> Vec<String> {
    let norm = normalise(counterparty);
    let tokens: Vec<String> = norm
        .split_whitespace()
        .map(|t| {
            t.trim_matches(|c: char| !c.is_alphanumeric() && c != '&' && c != '+')
                .to_string()
        })
        .filter(|t| !t.is_empty())
        .collect();
    // private persons ("Markus Schneider") get no domain
    if tokens.len() == 2 && FIRST_NAMES.contains(&tokens[0].as_str()) {
        return vec![];
    }
    let significant: Vec<String> = tokens
        .iter()
        .skip_while(|t| PAYMENT_PREFIXES.contains(&t.as_str()))
        .filter(|t| {
            let t = t.as_str();
            !GENERIC_WORDS.contains(&t)
                && t.chars().filter(|c| c.is_alphanumeric()).count() >= 3
                && !t.chars().all(|c| c.is_ascii_digit())
        })
        .map(|t| {
            transliterate(t)
                .chars()
                .filter(|c| c.is_ascii_alphanumeric())
                .collect::<String>()
        })
        .filter(|s| s.len() >= 3)
        .take(2)
        .collect();
    let Some(brand) = significant.first() else {
        return vec![];
    };
    let mut out = Vec::new();
    // Distinctive two-word names of local businesses first ("Schwarzer Bock" -> schwarzerbock.de)
    if significant.len() == 2 && tokens.len() <= 4 {
        let joined = format!("{}{}", significant[0], significant[1]);
        out.push(format!("{joined}.de"));
        out.push(format!("{joined}.com"));
    }
    out.push(format!("{brand}.de"));
    out.push(format!("{brand}.com"));
    out
}

fn to_info(e: &Entry) -> MerchantInfo {
    let icon = simple_icon_named(e.key, e.name);
    MerchantInfo {
        domain_candidates: if e.domain.is_empty() {
            vec![]
        } else {
            vec![e.domain.to_string()]
        },
        domain_source: if e.domain.is_empty() {
            String::new()
        } else {
            "dictionary".into()
        },
        is_person: false,
        svg_path: icon.as_ref().map(|i| i.2.clone()).unwrap_or_default(),
        icon_slug: icon.as_ref().map(|i| i.0.to_string()).unwrap_or_default(),
        key: e.key.to_string(),
        name: e.name.to_string(),
        domain: e.domain.to_string(),
        monogram: match e.key {
            "dm" => "dm".to_string(),
            "1822direkt" => "18".to_string(),
            "o2" => "O2".to_string(),
            "ing" => "ING".to_string(),
            "trade-republic" => "TR".to_string(),
            "deutsche-bahn" => "DB".to_string(),
            "huk" => "HUK".to_string(),
            _ => monogram(e.name),
        },
        color_hex: e.color.to_string(),
        sf_symbol: e.symbol.to_string(),
        kind: e.kind,
        known: true,
        isin: e.isin.to_string(),
        wkn: e.wkn.to_string(),
        asset_class: crate::i18n::tr(match e.kind {
            K::Etf => "ETF",
            K::Crypto => "Krypto",
            K::Stock => "Aktie",
            _ => "",
        })
        .to_string(),
    }
}

pub fn monogram(name: &str) -> String {
    let words: Vec<&str> = name
        .split(|c: char| c.is_whitespace() || c == '-' || c == '&' || c == '.')
        .filter(|w| {
            w.chars()
                .next()
                .map(|c| c.is_alphanumeric())
                .unwrap_or(false)
        })
        .collect();
    let mut m: String = words
        .iter()
        .take(2)
        .filter_map(|w| w.chars().next())
        .collect::<String>()
        .to_uppercase();
    if m.is_empty() {
        m = "?".into();
    }
    if words.len() == 1 {
        // "Lidl" -> "L", "REWE" -> "R"; keep two letters for short brand words like "dm"
        m = words[0].chars().take(1).collect::<String>().to_uppercase();
    }
    m
}

/// Acronyms that stay upper-case when `clean_name` title-cases a shouting name
/// ("VR BANK NORD" -> "VR Bank Nord", #1410).
const KEEP_UPPER: &[&str] = &["VR"];

/// Removes legal forms and trailing noise for display ("Muster GmbH & Co. KG" -> "Muster").
pub fn clean_name(s: &str) -> String {
    let mut t = s.trim().to_string();
    for suffix in [
        " GmbH & Co. KG",
        " GmbH & Co KG",
        " GmbH",
        " AG",
        " SE",
        " eG",
        " KG",
        " S.a.r.l. et Cie S.C.A",
        " S.a.r.l.",
        " S.A.",
        " e.V.",
        " sagt Danke",
        " SAGT DANKE",
    ] {
        // Whole words only: " SE" must not cut "SPARKASSE SEELAND" (#1410). A suffix
        // ending in a dot is its own boundary (" S.A." also cuts "S.A.R.L.").
        let ends_word = suffix.ends_with(char::is_alphanumeric);
        if let Some((p, _)) = t.match_indices(suffix).find(|(p, _)| {
            !ends_word
                || t[p + suffix.len()..]
                    .chars()
                    .next()
                    .is_none_or(|c| !c.is_alphanumeric())
        }) {
            t.truncate(p);
        }
    }
    let t = t
        .trim_matches(|c: char| c == ',' || c == '.' || c.is_whitespace())
        .to_string();
    // Title-case shouting names ("MUSTERMANN BAU" -> "Mustermann Bau")
    if t.len() > 4
        && t.chars()
            .filter(|c| c.is_alphabetic())
            .all(|c| c.is_uppercase())
    {
        t.split(' ')
            .map(|w| {
                w.split('-')
                    .map(|part| {
                        if KEEP_UPPER.contains(&part) {
                            return part.to_string();
                        }
                        let mut cs = part.chars();
                        match cs.next() {
                            Some(f) => {
                                f.to_uppercase().collect::<String>() + &cs.as_str().to_lowercase()
                            }
                            None => String::new(),
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("-")
            })
            .collect::<Vec<_>>()
            .join(" ")
    } else {
        t
    }
}

/// Shop name after a processor's `*` ("PayPal *Haendler Gmbh 1234567890" ->
/// "Haendler Gmbh"), without trailing reference numbers; `None` if nothing is left.
fn behind_processor(counterparty: &str) -> Option<String> {
    let (_, shop) = counterparty.split_once('*')?;
    let mut words: Vec<&str> = shop.split_whitespace().collect();
    while words
        .last()
        .is_some_and(|w| w.len() >= 5 && w.chars().all(|c| c.is_ascii_digit()))
    {
        words.pop();
    }
    let shop = words.join(" ");
    shop.chars().any(char::is_alphabetic).then_some(shop)
}

impl MerchantResolver {
    /// Resolves the merchant of a booking from counterparty and purpose with the
    /// bundled table alone, without the user's changes of a vault (see
    /// [`MerchantRules`]). Remembered like [`MerchantRules::resolve`].
    pub fn resolve(counterparty: &str, purpose: &str) -> MerchantInfo {
        MerchantRules::builtin().resolve(counterparty, purpose)
    }

    /// Empty merchant for a booking that is enriched right afterwards.
    pub fn placeholder() -> MerchantInfo {
        static EMPTY: OnceLock<MerchantInfo> = OnceLock::new();
        EMPTY.get_or_init(|| Self::resolve_uncached("", "")).clone()
    }

    fn resolve_uncached(counterparty: &str, purpose: &str) -> MerchantInfo {
        MerchantRules::builtin().resolve_uncached(counterparty, purpose)
    }
}

/// What the user changed about the merchant recognition (#1373), as the vault
/// stores it (see [`custom`]). Equal settings give equal merchants.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MerchantSettings {
    /// Master switch. Off, every booking shows its cleaned counterparty (else the
    /// start of its purpose) without a brand or logo; its signet keeps the calm
    /// fallback colour of every merchant the table does not know.
    pub(crate) enabled: bool,
    /// Keys of bundled merchants the user switched off.
    pub(crate) disabled: BTreeSet<String>,
    /// The user's own merchants, oldest first.
    pub(crate) custom: Vec<CustomSpec>,
}

impl Default for MerchantSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            disabled: BTreeSet::new(),
            custom: Vec::new(),
        }
    }
}

/// One own merchant as stored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CustomSpec {
    pub(crate) uuid: String,
    pub(crate) name: String,
    /// Normalised search words (`custom::clean_needles`).
    pub(crate) needles: Vec<String>,
    /// Key of the bundled merchant it was copied from, "" for none.
    pub(crate) based_on: String,
}

/// Merchant key of an own merchant: stays the same across renames and devices.
pub(crate) fn custom_key(uuid: &str) -> String {
    format!("u:{uuid}")
}

/// An own merchant, ready for matching.
struct CustomEntry {
    key: String,
    name: String,
    needles: Vec<String>,
    /// The bundled merchant it was copied from ("Bearbeiten" of a bundled one):
    /// logo, colour, kind and the securities check come from there.
    base: Option<&'static Entry>,
}

impl CustomEntry {
    fn kind(&self) -> MerchantKind {
        self.base.map_or(K::Unknown, |e| e.kind)
    }

    /// Its longest search word (of at least `min_len` characters) in `text`, `None` if
    /// none matches. A copy of a stock entry keeps the bundled securities check, so a
    /// surname ("Max Bayer") does not turn into the share: a securities hint, or a legal
    /// form right after a whole-word match. `text` and `ctx` come from [`normalise_words`].
    fn matched_in(&self, text: &str, ctx: &str, min_len: usize) -> Option<&str> {
        let stock = self.base.filter(|e| e.kind == K::Stock);
        let listed = stock.is_some_and(|e| securities_hint(e, ctx));
        self.needles
            .iter()
            .filter(|n| n.chars().count() >= min_len)
            .filter(|n| {
                let mut at = word_starts(text, n);
                if stock.is_none() || listed {
                    at.next().is_some()
                } else {
                    at.any(|i| legal_form_at(text, i + n.len()))
                }
            })
            .max_by_key(|n| n.chars().count())
            .map(String::as_str)
    }

    /// Length of [`matched_in`](Self::matched_in), the measure among own merchants.
    fn longest_in(&self, text: &str, ctx: &str, min_len: usize) -> Option<usize> {
        self.matched_in(text, ctx, min_len)
            .map(|n| n.chars().count())
    }

    fn info(&self) -> MerchantInfo {
        let mut info = match self.base {
            Some(e) => to_info(e),
            None => MerchantInfo {
                key: String::new(),
                name: String::new(),
                domain: String::new(),
                monogram: String::new(),
                color_hex: fallback_color(&self.name).to_string(),
                sf_symbol: String::new(),
                kind: K::Unknown,
                known: false,
                isin: String::new(),
                wkn: String::new(),
                asset_class: String::new(),
                svg_path: String::new(),
                icon_slug: String::new(),
                domain_candidates: vec![],
                domain_source: String::new(),
                is_person: false,
            },
        };
        // a renamed copy gets the initials of its new name, an unchanged one keeps
        // the bundled monogram ("dm", "ING")
        if info.name != self.name {
            info.monogram = monogram(&self.name);
        }
        info.key = self.key.clone();
        info.name = self.name.clone();
        // A name the user typed, not a bundled brand: covered in bug report pictures,
        // and a rule made from such a booking takes its pattern from the counterparty.
        info.known = false;
        info
    }
}

/// The merchant recognition of one vault: the bundled table with the user's changes
/// (#1373) and a cache of the merchants it resolved.
///
/// The vault builds it from its tables (`Vault::merchant_rules`) and keeps it while
/// they stay the same, so a change, a merge or a restore starts a fresh cache.
pub(crate) struct MerchantRules {
    settings: MerchantSettings,
    /// No user changes: the shared [`MerchantRules::builtin`].
    bundled: bool,
    /// Own merchants, oldest first (a tie goes to the older one).
    custom: Vec<CustomEntry>,
    cache: Mutex<ResolveCache>,
}

impl MerchantRules {
    /// The bundled table without user changes. Every vault without changes shares it
    /// (and its cache).
    pub(crate) fn builtin() -> &'static Arc<MerchantRules> {
        static BUILTIN: OnceLock<Arc<MerchantRules>> = OnceLock::new();
        BUILTIN.get_or_init(|| Arc::new(Self::new(MerchantSettings::default())))
    }

    /// The rules for `settings`: the shared bundled ones when nothing is changed.
    pub(crate) fn for_settings(settings: MerchantSettings) -> Arc<MerchantRules> {
        if settings == MerchantSettings::default() {
            Self::builtin().clone()
        } else {
            Arc::new(Self::new(settings))
        }
    }

    fn new(settings: MerchantSettings) -> Self {
        let custom = settings
            .custom
            .iter()
            .map(|c| CustomEntry {
                key: custom_key(&c.uuid),
                name: c.name.clone(),
                needles: c.needles.clone(),
                base: entry_by_key(&c.based_on),
            })
            .collect();
        Self {
            bundled: settings == MerchantSettings::default(),
            settings,
            custom,
            cache: Mutex::default(),
        }
    }

    pub(crate) fn settings(&self) -> &MerchantSettings {
        &self.settings
    }

    /// The master switch.
    pub(crate) fn enabled(&self) -> bool {
        self.settings.enabled
    }

    /// Whether the name of an own merchant or of a bundled one in use contains `term`
    /// (lower case): the shown names that may be in no booking text (search, #1373).
    pub(crate) fn names_contain(&self, term: &str) -> bool {
        self.settings.enabled
            && (self
                .custom
                .iter()
                .any(|c| c.name.to_lowercase().contains(term))
                || entries().iter().any(|e| {
                    !self.settings.disabled.contains(e.key) && e.name.to_lowercase().contains(term)
                }))
    }

    fn clear_cache(&self) {
        *self.cache.lock().unwrap_or_else(PoisonError::into_inner) = ResolveCache::default();
    }

    /// Resolves the merchant of a booking from counterparty and purpose.
    ///
    /// The result only depends on the two texts, and the booking list asks
    /// for every booking again on each reload, so results are remembered
    /// while a vault is open (resolving ~19 000 bookings took about 270 ms
    /// per reload; a remembered one is a hash lookup).
    pub(crate) fn resolve(&self, counterparty: &str, purpose: &str) -> MerchantInfo {
        MerchantInfo::clone(&self.lookup(counterparty, purpose).info)
    }

    /// [`resolve`](Self::resolve) and what the bundled table alone says.
    pub(crate) fn resolve_with_bundled(
        &self,
        counterparty: &str,
        purpose: &str,
    ) -> (MerchantInfo, BundledMerchant) {
        let hit = self.lookup(counterparty, purpose);
        (MerchantInfo::clone(&hit.info), hit.bundled)
    }

    /// What the bundled table alone says, without copying the shown merchant.
    pub(crate) fn bundled(&self, counterparty: &str, purpose: &str) -> BundledMerchant {
        self.lookup(counterparty, purpose).bundled
    }

    fn lookup(&self, counterparty: &str, purpose: &str) -> Resolved {
        let hit = self
            .cache
            .lock()
            .ok()
            .and_then(|c| c.by_counterparty.get(counterparty)?.get(purpose).cloned());
        if let Some(hit) = hit {
            return hit;
        }
        let info = self.resolve_uncached(counterparty, purpose);
        let bundled = if self.bundled {
            BundledMerchant {
                key: info.key.as_str().into(),
                kind: info.kind,
            }
        } else {
            // from the shared cache: still warm from before the first change, so a
            // reload after a change costs one cold resolve per booking, not two
            Self::builtin().bundled(counterparty, purpose)
        };
        let hit = Resolved {
            info: Arc::new(info),
            bundled,
        };
        if let Ok(mut c) = self.cache.lock() {
            // bounded: far above any real booking count, cleared rather than evicted
            if c.len >= RESOLVE_CACHE_MAX {
                *c = ResolveCache::default();
            }
            let by_purpose = c
                .by_counterparty
                .entry(counterparty.to_string())
                .or_default();
            if by_purpose
                .insert(purpose.to_string(), hit.clone())
                .is_none()
            {
                c.len += 1;
            }
        }
        hit
    }

    /// The first bundled entry with a needle in `text` that the user did not switch
    /// off; a stock entry only with securities evidence.
    fn find_checked(&self, text: &str, ctx: &str) -> Option<&'static Entry> {
        entries().iter().find(|e| {
            e.needles.iter().any(|n| needle_in(text, n))
                && (e.kind != K::Stock || stock_confirmed(e, text, ctx))
                && !self.settings.disabled.contains(e.key)
        })
    }

    /// The bundled entry `key` unless the user switched it off.
    fn bundled_entry(&self, key: &str) -> Option<&'static Entry> {
        entry_by_key(key).filter(|e| !self.settings.disabled.contains(e.key))
    }

    /// The own merchant with the longest search word `len` finds; a tie goes to the
    /// older one, so the order the user created them in never matters otherwise.
    fn best_custom(&self, len: impl Fn(&CustomEntry) -> Option<usize>) -> Option<&CustomEntry> {
        let mut best: Option<(usize, &CustomEntry)> = None;
        for c in &self.custom {
            if let Some(l) = len(c)
                && best.is_none_or(|(b, _)| l > b)
            {
                best = Some((l, c));
            }
        }
        best.map(|(_, c)| c)
    }

    /// The sub-brand of the parent company `parent` that the booking names anywhere
    /// (`ctx`): an own copy of it first, then the bundled one unless switched off.
    fn sub_brand(&self, parent: &str, t: &Texts) -> Option<MerchantInfo> {
        let (_, subs) = SUB_BRANDS.iter().find(|(p, _)| *p == parent)?;
        if let Some(c) = self.best_custom(|c| {
            c.base
                .filter(|b| subs.contains(&b.key))
                .and_then(|_| c.longest_in(&t.wctx, &t.wctx, 0))
        }) {
            return Some(c.info());
        }
        subs.iter()
            .filter_map(|k| self.bundled_entry(k))
            .find(|sub| sub.needles.iter().any(|n| needle_in(&t.ctx, n)))
            .map(to_info)
    }

    /// What a payment processor (`needle` in the counterparty) collected for: an own or
    /// bundled merchant behind its name or in the purpose, else the shop named right
    /// after its `*` (#243). `None` when nothing is behind it.
    fn look_behind(
        &self,
        needle: &str,
        counterparty: &str,
        purpose: &str,
        t: &Texts,
    ) -> Option<MerchantInfo> {
        let after = |text: &str| {
            text.split_once(needle)
                .map(|x| x.1.to_string())
                .unwrap_or_default()
        };
        let (behind, wbehind) = (after(&t.cp), after(&t.wcp));
        let shop_in = |c: &CustomEntry, text: &str| {
            (c.kind() != K::PaymentService)
                .then(|| c.longest_in(text, &t.wctx, 0))
                .flatten()
        };
        if let Some(c) = self
            .best_custom(|c| shop_in(c, &wbehind))
            .or_else(|| self.best_custom(|c| shop_in(c, &t.wpu)))
        {
            return Some(c.info());
        }
        if let Some(real) = self
            .find_checked(&behind, &t.ctx)
            .or_else(|| self.find_checked(&t.pu, &t.ctx))
            .filter(|r| r.kind != K::PaymentService)
        {
            return Some(to_info(real));
        }
        // "PAYPAL *HAENDLER 1234567890" on card statements (#243): a shop the
        // dictionary doesn't know is still named right behind the `*`.
        behind_processor(counterparty).map(|shop| self.resolve_uncached(&shop, purpose))
    }

    fn resolve_uncached(&self, counterparty: &str, purpose: &str) -> MerchantInfo {
        if !self.settings.enabled {
            return unknown_merchant(counterparty, purpose, false);
        }
        // "PayPal *Spotify", "PayPal Europe ... Ihr Einkauf bei Spotify AB": look behind the processor.
        let t = Texts::new(counterparty, purpose, !self.custom.is_empty());
        // Own merchants come first wherever the bundled table looks (#1373). A copy keeps
        // what its original does about matching: a copy of a payment processor still
        // looks behind it, a copy of a sub-brand still wins over the parent company.
        if let Some(c) = self.best_custom(|c| c.longest_in(&t.wcp, &t.wctx, 0)) {
            if c.kind() == K::PaymentService
                && let Some(needle) = c.matched_in(&t.wcp, &t.wctx, 0)
                && let Some(real) = self.look_behind(needle, counterparty, purpose, &t)
            {
                return real;
            }
            // a copy of a parent company still yields to its sub-brands
            if let Some(sub) = c.base.and_then(|b| self.sub_brand(b.key, &t)) {
                return sub;
            }
            return c.info();
        }
        if let Some(entry) = self.find_checked(&t.cp, &t.ctx) {
            if entry.kind == K::PaymentService
                && let Some(real) = self.look_behind(entry.needles[0], counterparty, purpose, &t)
            {
                return real;
            }
            if let Some(sub) = self.sub_brand(entry.key, &t) {
                return sub;
            }
            return group_member(entry, counterparty).unwrap_or_else(|| to_info(entry));
        }
        // Only the parent company is switched off: the sub-brand it names is still on
        // ("Telekom Deutschland GmbH", purpose "congstar …").
        if let Some(sub) = SUB_BRANDS
            .iter()
            .filter(|(parent, _)| self.settings.disabled.contains(*parent))
            .filter(|(parent, _)| {
                entry_by_key(parent).is_some_and(|e| e.needles.iter().any(|n| needle_in(&t.cp, n)))
            })
            .find_map(|(parent, _)| self.sub_brand(parent, &t))
        {
            return sub;
        }
        // The purpose names securities and payment processors; anything else only
        // when there is no counterparty, and then not with a short word (" TK ", #1133).
        let no_counterparty = counterparty.trim().is_empty();
        if let Some(c) = self.best_custom(|c| {
            if matches!(c.kind(), K::Etf | K::Crypto | K::Stock | K::PaymentService) {
                c.longest_in(&t.wpu, &t.wctx, 0)
            } else if no_counterparty {
                c.longest_in(&t.wpu, &t.wctx, 4)
            } else {
                None
            }
        }) {
            return c.info();
        }
        if let Some(entry) = self.find_checked(&t.pu, &t.ctx).filter(|e| {
            matches!(e.kind, K::Etf | K::Crypto | K::Stock | K::PaymentService)
                || (no_counterparty
                    && e.needles
                        .iter()
                        .any(|n| n.trim().len() >= 4 && needle_in(&t.pu, n)))
        }) {
            return to_info(entry);
        }
        unknown_merchant(counterparty, purpose, true)
    }
}

/// A booking's texts, normalised for the bundled table (`cp`, `pu`, `ctx`, see
/// [`normalise`]) and for the user's own search words (`w…`, see [`normalise_words`];
/// empty while there are no own merchants).
struct Texts {
    cp: String,
    pu: String,
    ctx: String,
    wcp: String,
    wpu: String,
    wctx: String,
}

impl Texts {
    fn new(counterparty: &str, purpose: &str, own: bool) -> Self {
        let counterparty = without_mail_local_parts(counterparty);
        let purpose = without_mail_local_parts(purpose);
        let (cp, pu) = (normalise(&counterparty), normalise(&purpose));
        let (wcp, wpu) = if own {
            (normalise_words(&counterparty), normalise_words(&purpose))
        } else {
            (String::new(), String::new())
        };
        Self {
            ctx: format!("{cp} {pu}"),
            wctx: format!("{wcp} {wpu}"),
            cp,
            pu,
            wcp,
            wpu,
        }
    }
}

/// Calm colour of a merchant without a brand colour, the same for the same name.
fn fallback_color(key_base: &str) -> &'static str {
    let hash = key_base
        .bytes()
        .fold(0u32, |a, b| a.wrapping_mul(31).wrapping_add(b as u32));
    FALLBACK_COLORS[(hash as usize) % FALLBACK_COLORS.len()]
}

/// A merchant the table does not name: the cleaned counterparty, else the start of
/// the purpose. `logos` false (recognition switched off, #1373): no guessed company
/// domain either, so no logo.
fn unknown_merchant(counterparty: &str, purpose: &str, logos: bool) -> MerchantInfo {
    let name = {
        let n = clean_name(counterparty);
        if n.is_empty() {
            clean_name(
                purpose
                    .split_whitespace()
                    .take(3)
                    .collect::<Vec<_>>()
                    .join(" ")
                    .as_str(),
            )
        } else {
            n
        }
    };
    let key_base: String = normalise(&name)
        .trim()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '-' })
        .collect();
    let raw = if counterparty.trim().is_empty() {
        name.clone()
    } else {
        counterparty.to_string()
    };
    // Strict whitelist: a domain only for curated brands (handled above)
    // or companies with an explicit legal suffix – never for persons.
    let company = has_legal_suffix(&raw);
    let person = !company && looks_like_person(&raw);
    let candidates = if company && logos {
        heuristic_domains(&raw)
    } else {
        vec![]
    };
    MerchantInfo {
        key: format!("x:{key_base}"),
        monogram: if person {
            person_initials(&raw)
        } else {
            monogram(&name)
        },
        name,
        domain: candidates.first().cloned().unwrap_or_default(),
        domain_source: if person {
            "person".into()
        } else if candidates.is_empty() {
            String::new()
        } else {
            "company".into()
        },
        is_person: person,
        domain_candidates: candidates,
        color_hex: if person {
            "#64748B".to_string()
        } else {
            fallback_color(&key_base).to_string()
        },
        sf_symbol: String::new(),
        kind: K::Unknown,
        known: false,
        isin: String::new(),
        wkn: String::new(),
        asset_class: String::new(),
        svg_path: String::new(),
        icon_slug: String::new(),
    }
}

fn contains_any(text: &str, needles: &[&str]) -> bool {
    needles.iter().any(|n| text.contains(n))
}

/// Category name or path ("Finanzen/Investments -> Kauf") of an investment group,
/// e.g. imported from other apps. A bare "Kauf" outside such a group does not match.
fn is_investment_category_path(path: &str) -> bool {
    let p = path.to_lowercase();
    contains_any(
        &p,
        &[
            "investment",
            "invest",
            "wertpapier",
            "aktie",
            "etf",
            "depot",
            "sparen",
            "vorsorge",
        ],
    )
}

/// Classifies a booking. `top_category` is the immutable role of the top-level
/// category, using the original German catalog keys (empty for custom entries).
pub fn classify(
    amount_cents: i64,
    counterparty: &str,
    purpose: &str,
    booking_text: &str,
    merchant: &MerchantInfo,
    top_category: &str,
    account_kind: AccountKind,
) -> FlowKind {
    classify_by_kind(
        amount_cents,
        counterparty,
        purpose,
        booking_text,
        merchant.kind,
        top_category,
        account_kind,
    )
}

/// [`classify`] with the merchant kind alone (the bundled table's, see
/// [`BundledMerchant`]).
pub(crate) fn classify_by_kind(
    amount_cents: i64,
    counterparty: &str,
    purpose: &str,
    booking_text: &str,
    merchant_kind: MerchantKind,
    top_category: &str,
    account_kind: AccountKind,
) -> FlowKind {
    let t = normalise(&format!("{counterparty} {purpose} {booking_text}"));
    if contains_any(
        &t,
        &["saveback", "round up", "roundup", "round-up", "aufrunden"],
    ) {
        return FlowKind::Perk;
    }
    if top_category == "Sparen & Investieren"
        || matches!(merchant_kind, K::Etf | K::Crypto | K::Stock)
        || contains_any(
            &t,
            &[
                "sparplan",
                "wertpapierkauf",
                "kauf order",
                "wertp.abrechn",
                "wertp abrechn",
                "wertpapierabrechnung",
                "wp-abrechnung",
                "wp abrechnung",
            ],
        )
        || is_investment_category_path(top_category)
    {
        return FlowKind::Investment;
    }
    if top_category == "Kredite & Darlehen"
        || account_kind == AccountKind::Loan
        || contains_any(&t, &["darlehen", "tilgung", "kreditrate"])
    {
        return FlowKind::Loan;
    }
    if matches!(top_category, "Umbuchungen" | "import:transfers")
        || contains_any(
            &t,
            &[
                "umbuchung",
                "eigenes konto",
                "eigene konten",
                "kreditkartenabrechnung",
                "zahlung erhalten",
                "einzahlung",
                "bankeinzug",
                "übertrag",
            ],
        )
    {
        return FlowKind::Transfer;
    }
    if amount_cents > 0 {
        FlowKind::Income
    } else {
        FlowKind::Consumption
    }
}

/// "Kartenzahlung", "Lastschrift", "Überweisung", "Sparplan" … for the row subtitle.
/// `paypal`: the booking's account is a PayPal account (see
/// `BookingFinisher`); other payment services (Uberspace, Amazon orders)
/// get the labels from their texts.
pub fn payment_method(
    booking_text: &str,
    purpose: &str,
    account_kind: AccountKind,
    amount_cents: i64,
    paypal: bool,
) -> String {
    // Amex portal bookings name the (partner) card they were paid with (#243).
    if let Some(card) = booking_text
        .strip_prefix(crate::importers::portal_import::CARD_BOOKING_TEXT)
        .and_then(|r| r.strip_prefix(crate::importers::portal_import::CARD_SEPARATOR))
        .filter(|c| !c.trim().is_empty())
    {
        return card.trim().to_string();
    }
    let t = normalise(&format!("{booking_text} {purpose}"));
    let m = if booking_text == "Amazon-Bestellung" {
        "Bestellung"
    } else if booking_text == "Amazon-Erstattung" {
        "Erstattung"
    } else if contains_any(&t, &["saveback"]) {
        "Saveback"
    } else if contains_any(&t, &["round up", "roundup"]) {
        "Round up"
    } else if t.contains("sparplan") {
        "Sparplan"
    } else if contains_any(&t, &["zinsen"]) {
        "Zinsen"
    } else if contains_any(&t, &["lohn", "gehalt"]) {
        "Gehalt"
    } else if contains_any(&t, &["bargeld", "geldautomat"]) {
        "Bargeld"
    } else if contains_any(&t, &["dauerauftrag"]) {
        "Dauerauftrag"
    } else if contains_any(&t, &["lastschrift"]) {
        "Lastschrift"
    } else if contains_any(
        &t,
        &[
            "kartenzahlung",
            "kartenumsatz",
            "girocard",
            "debitk",
            "visa debit",
        ],
    ) {
        "Kartenzahlung"
    } else if contains_any(&t, &["entgelt", "kontoführung"]) {
        "Entgelt"
    } else if account_kind == AccountKind::CreditCard {
        "Kreditkarte"
    } else if paypal {
        "PayPal"
    } else if contains_any(
        &t,
        &["überweisung", "gutschrift", "einzahlung", "umbuchung"],
    ) {
        if amount_cents > 0 {
            "Gutschrift"
        } else {
            "Überweisung"
        }
    } else if amount_cents > 0 {
        "Gutschrift"
    } else {
        "Buchung"
    };
    // Labels are German source strings; translated for display only.
    crate::i18n::tr(m).to_string()
}

/// `s` with the part before the `@` of e-mail addresses removed: a mailbox name
/// says nothing about the merchant ("paypal@shop.de" is the shop, not PayPal),
/// the domain does.
fn without_mail_local_parts(s: &str) -> std::borrow::Cow<'_, str> {
    if !s.contains('@') {
        return std::borrow::Cow::Borrowed(s);
    }
    let words: Vec<&str> = s
        .split(' ')
        .map(|w| match w.split_once('@') {
            Some((local, domain)) if !local.is_empty() && domain.contains('.') => domain,
            _ => w,
        })
        .collect();
    std::borrow::Cow::Owned(words.join(" "))
}

/// Human purpose without SEPA keys and terminal noise.
pub fn clean_purpose(raw: &str) -> String {
    let mut s = raw.replace('\n', " ");
    if let Some(p) = s.find("SVWZ+") {
        let rest = &s[p + 5..];
        let end = [
            "EREF+", "KREF+", "MREF+", "CRED+", "DEBT+", "ABWA+", "ABWE+", "IBAN+", "BIC+",
        ]
        .iter()
        .filter_map(|k| rest.find(k))
        .min()
        .unwrap_or(rest.len());
        s = rest[..end].to_string();
    } else {
        for key in [
            "EREF+", "KREF+", "MREF+", "CRED+", "DEBT+", "ABWA+", "IBAN+", "BIC+",
        ] {
            while let Some(p) = s.find(key) {
                let rest = &s[p..];
                let end = rest.find(' ').unwrap_or(rest.len());
                s.replace_range(p..p + end, "");
            }
        }
    }
    // Card terminal strings: "Debitk.1 2029-12", "2026-11-07T18:22", "PP.1234.PP"
    let words: Vec<&str> = s
        .split_whitespace()
        .filter(|w| {
            !(w.starts_with("Debitk")
                || w.starts_with("PP.")
                // a date: four digits, then '-' (not a reference like "54544a4-…")
                || (w.len() >= 7
                    && w.chars().take(4).all(|c| c.is_ascii_digit())
                    && w.as_bytes()[4] == b'-'))
        })
        .collect();
    words.join(" ").trim().trim_matches('.').trim().to_string()
}

/// Exposed for tests / tooling: resolve without a vault. Bypasses the cache,
/// which only the last vault to close clears.
pub fn resolve_merchant(counterparty: String, purpose: String) -> MerchantInfo {
    MerchantResolver::resolve_uncached(&counterparty, &purpose)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dictionary_file_parses_completely() {
        use crate::data_tables::malformed_rows;
        assert_eq!(malformed_rows(MERCHANTS_TSV, 7, 9), Vec::<&str>::new());
        // a row with an unknown kind or no needles would be dropped silently
        assert_eq!(
            entries().len(),
            crate::data_tables::rows::<9>(MERCHANTS_TSV).count()
        );
        let mut keys = std::collections::HashSet::new();
        for e in entries() {
            assert!(keys.insert(e.key), "duplicate key {}", e.key);
            assert!(!e.name.is_empty() && !e.needles.is_empty(), "{}", e.key);
            for n in &e.needles {
                assert!(!n.trim().is_empty(), "{}: empty needle", e.key);
                assert_eq!(*n, n.to_lowercase(), "{}: needle not lower-case", e.key);
            }
            assert!(
                e.color.len() == 7 && e.color.starts_with('#'),
                "{}: {}",
                e.key,
                e.color
            );
        }
    }

    #[test]
    fn private_surname_is_not_investment() {
        for name in ["Max Bayer", "Anna Siemens", "Peter Henkel", "Lisa Allianz"] {
            let info = MerchantResolver::resolve(name, "Anteil Abendessen");
            assert_ne!(info.kind, K::Stock, "{name}");
            let f = classify(
                -25_00,
                name,
                "Anteil Abendessen",
                "",
                &info,
                "",
                AccountKind::Checking,
            );
            assert_ne!(f, FlowKind::Investment, "{name}");
        }
    }

    #[test]
    fn security_booking_is_investment() {
        let p = "WP-ABRECHNUNG Kauf DE000BAY0017";
        let info = MerchantResolver::resolve("Depotbank", p);
        assert_eq!(info.key, "stock-bayer");
        let f = classify(
            -500_00,
            "Depotbank",
            p,
            "",
            &info,
            "",
            AccountKind::Checking,
        );
        assert_eq!(f, FlowKind::Investment);
        let info = MerchantResolver::resolve("Bayer AG", "Dividende 2025");
        assert_eq!(info.key, "stock-bayer");
    }

    #[test]
    fn remembered_merchants_equal_fresh_ones() {
        for (cp, pu) in [
            ("REWE Markt GmbH", "Einkauf Filiale 12"),
            ("PayPal Europe S.a.r.l.", "Ihr Einkauf bei Spotify AB"),
            ("Max Mustermann", "Miete November"),
            ("", ""),
        ] {
            let fresh = MerchantResolver::resolve_uncached(cp, pu);
            // first call fills the cache, second one reads it
            assert_eq!(MerchantResolver::resolve(cp, pu), fresh, "{cp}");
            assert_eq!(MerchantResolver::resolve(cp, pu), fresh, "{cp}");
        }
        // the purpose is part of the key
        assert_ne!(
            MerchantResolver::resolve("PayPal Europe S.a.r.l.", "Ihr Einkauf bei Spotify AB").key,
            MerchantResolver::resolve("PayPal Europe S.a.r.l.", "Ihr Einkauf bei Zalando SE").key
        );
    }

    #[test]
    fn resolves_noisy_strings() {
        assert_eq!(
            MerchantResolver::resolve("REWE SAGT DANKE 4711", "").key,
            "rewe"
        );
        assert_eq!(MerchantResolver::resolve("Lidl", "").name, "Lidl");
        assert_eq!(
            MerchantResolver::resolve("EDEKA Center Kassel", "").key,
            "edeka"
        );
        assert_eq!(MerchantResolver::resolve("Metro", "").key, "metro");
        assert_eq!(
            MerchantResolver::resolve("Barmenia Allgemeine Vers. AG", "").key,
            "barmenia"
        );
        assert_eq!(
            MerchantResolver::resolve("Vinzenz Murr Vertriebs GmbH", "").key,
            "vinzenz-murr"
        );
        assert_eq!(
            MerchantResolver::resolve("Too Good To Go", "").key,
            "too-good-to-go"
        );
        assert_eq!(
            MerchantResolver::resolve("PayPal *Spotify", "").key,
            "spotify"
        );
        // unknown shop behind the processor (#243): its own name, not "PayPal"
        let shop = MerchantResolver::resolve("PAYPAL *HAENDLER MUSTER 1234567890", "");
        assert_eq!(shop.name, "Haendler Muster");
        assert_ne!(shop.key, "paypal");
        // no shop named: still PayPal
        assert_eq!(MerchantResolver::resolve("PayPal *", "").key, "paypal");
        assert_eq!(
            MerchantResolver::resolve("PayPal Europe S.a.r.l. et Cie S.C.A", "").key,
            "paypal"
        );
        assert_eq!(
            MerchantResolver::resolve(
                "PayPal Europe S.a.r.l. et Cie S.C.A",
                "PP.1234.PP . Spotify AB, Ihr Einkauf bei Spotify AB"
            )
            .key,
            "spotify"
        );
        assert_eq!(
            MerchantResolver::resolve("AMZN Mktp DE*AB12CD34E", "").key,
            "amazon"
        );
        let w = MerchantResolver::resolve("Core MSCI World USD (Acc)", "Sparplan ausgeführt");
        assert_eq!(w.isin, "IE00B4L5Y983");
        assert_eq!(w.kind, MerchantKind::Etf);
        let u = MerchantResolver::resolve("Mustermann Bau GmbH", "Rechnung 12");
        assert!(!u.known);
        assert_eq!(u.name, "Mustermann Bau");
        assert_eq!(u.monogram, "MB");
    }

    #[test]
    fn brings_simple_icons_paths_and_domains() {
        for (cp, domain, slug) in [
            ("Lidl", "lidl.de", "lidl"),
            ("REWE SAGT DANKE", "rewe.de", "rewe"),
            ("Barmenia Allgemeine Vers. AG", "barmenia.de", "barmenia"),
            ("PayPal *Spotify", "spotify.com", "spotify"),
            ("DB Fernverkehr AG", "bahn.de", "deutschebahn"),
            ("Bitcoin", "bitcoin.org", "bitcoin"),
        ] {
            let m = MerchantResolver::resolve(cp, "");
            assert_eq!(m.domain, domain, "{cp}");
            assert_eq!(m.icon_slug, slug, "{cp}");
            assert!(
                m.svg_path.starts_with('M') || m.svg_path.starts_with('m'),
                "{cp}: {}",
                &m.svg_path[..m.svg_path.len().min(20)]
            );
        }
        let ishares = MerchantResolver::resolve("Core MSCI World USD (Acc)", "");
        assert_eq!(ishares.domain, "ishares.com");
        assert!(
            ishares.svg_path.is_empty(),
            "no simple-icon -> favicon / monogram"
        );
    }

    #[test]
    fn three_stage_domain_resolver() {
        assert!(
            dictionary_size() >= 200,
            "dictionary has {}",
            dictionary_size()
        );
        let m = MerchantResolver::resolve("EnBW Energie Baden-Wuerttemberg AG", "Abschlag Strom");
        assert_eq!(
            (m.domain.as_str(), m.domain_source.as_str()),
            ("enbw.com", "dictionary")
        );
        assert_eq!(
            MerchantResolver::resolve("EnBW mobility+ AG & Co. KG", "Ladevorgang").domain,
            "enbw.com"
        );
        assert_eq!(
            MerchantResolver::resolve("Techniker Krankenkasse", "").domain,
            "tk.de"
        );
        assert_eq!(
            MerchantResolver::resolve("TK Maxx Kassel", "").domain,
            "tkmaxx.de"
        );
        assert_eq!(
            MerchantResolver::resolve("HORNBACH Baumarkt AG", "").domain,
            "hornbach.de"
        );
        assert_eq!(
            MerchantResolver::resolve("1&1 Telecom GmbH", "").domain,
            "1und1.de"
        );
        assert_eq!(
            MerchantResolver::resolve("Core Stoxx Europe 600 EUR (Acc)", "").domain,
            "amundi.de"
        );
        assert_eq!(
            MerchantResolver::resolve("ALDI TALK", "").domain,
            "alditalk.de"
        );
        // Strict whitelist: no domain guessing without a legal suffix
        let u = MerchantResolver::resolve("SumUp *Blumenhaus Schmidt", "");
        assert!(
            u.domain.is_empty() && u.domain_candidates.is_empty(),
            "{:?}",
            u.domain_candidates
        );
        let c = MerchantResolver::resolve("Gärtnerei Grünwald GmbH", "Rechnung 4711");
        assert_eq!(c.domain_source, "company");
        assert_eq!(c.domain_candidates[0], "gaertnereigruenwald.de");
        for p in [
            "Laura Schneider",
            "Hannah Berger",
            "Lisa Wagner",
            "Dr. Anna von Berg",
        ] {
            let m = MerchantResolver::resolve(p, "Danke fürs Auslegen");
            assert!(
                m.is_person
                    && m.domain.is_empty()
                    && m.svg_path.is_empty()
                    && m.domain_candidates.is_empty(),
                "{p}"
            );
        }
        assert_eq!(
            MerchantResolver::resolve("Laura Schneider", "").monogram,
            "LS"
        );
        assert_eq!(
            MerchantResolver::resolve("Hannah Berger", "").monogram,
            "HB"
        );
        assert!(!looks_like_person("Café Nenninger"));
        assert!(!looks_like_person("Hotel Schwarzer Bock"));
        assert!(!looks_like_person("Eigenes Konto"));
        assert!(!looks_like_person("Mustermann Bau GmbH"));
        assert!(
            MerchantResolver::resolve("Hotel Schwarzer Bock", "")
                .domain
                .is_empty()
        );
        assert_eq!(
            heuristic_domains("Gärtnerei Grünwald"),
            vec![
                "gaertnereigruenwald.de",
                "gaertnereigruenwald.com",
                "gaertnerei.de",
                "gaertnerei.com"
            ]
        );
        assert_eq!(
            heuristic_domains("Hotel Schwarzer Bock")[0],
            "schwarzerbock.de"
        );
        assert_eq!(
            heuristic_domains("PayPal *Zalando Lounge Retail GmbH")[2],
            "zalando.de"
        );
        assert!(
            heuristic_domains("Markus Schneider").is_empty(),
            "private persons get no domain"
        );
        assert!(heuristic_domains("Eigenes Konto").is_empty());
        // #1133: bookings without counterparty must not match 2-letter acronyms like " TK " in purpose.
        assert_eq!(
            MerchantResolver::resolve("", "WP-ABRECHNUNG VERKAUF TK 45,20 EUR").domain,
            ""
        );
        assert_eq!(MerchantResolver::resolve("TK", "Beitrag").domain, "tk.de");
        assert_eq!(
            MerchantResolver::resolve("", "Beitrag Techniker Krankenkasse").domain,
            "tk.de"
        );
    }

    #[test]
    fn needles_match_at_word_start_only() {
        let name = |cp: &str, pu: &str| resolve_merchant(cp.into(), pu.into()).name;
        // "Bausparkasse" is not a Sparkasse (#204).
        assert_eq!(
            name("Dt. Bausparkasse Badenia AG", ""),
            "Dt. Bausparkasse Badenia"
        );
        let key = |cp: &str| resolve_merchant(cp.into(), String::new()).key;
        assert_eq!(key("Stadtsparkasse Muenchen"), "sparkasse");
        assert_eq!(key("Kreissparkasse Koeln"), "sparkasse");
        assert_eq!(key("Sparkasse Hannover"), "sparkasse");
    }

    #[test]
    fn clean_name_cuts_legal_forms_as_whole_words() {
        // #1410: " SE" / " AG" / " eG" inside a word cut the name short.
        assert_eq!(clean_name("HOTEL SEEBLICK"), "Hotel Seeblick");
        assert_eq!(clean_name("MUELLER AGRARHANDEL"), "Mueller Agrarhandel");
        assert_eq!(
            clean_name("Foo eGovernment Service"),
            "Foo eGovernment Service"
        );
        assert_eq!(clean_name("Muster AG, Berlin"), "Muster");
        assert_eq!(clean_name("Muster AG"), "Muster");
        assert_eq!(clean_name("MUSTER S.A.R.L."), "Muster");
        assert_eq!(clean_name("MUSTER S.A.S."), "Muster");
        assert_eq!(clean_name("Muster SE & Co. KGaA"), "Muster");
        assert_eq!(clean_name("VR-BANK NORD"), "VR-Bank Nord");
        let key = |cp: &str| resolve_merchant(cp.into(), String::new()).key;
        assert_ne!(key("HOTEL SEEBLICK"), key("HOTEL SEEROSE"));
    }

    #[test]
    fn group_banks_keep_their_own_name() {
        // #1365: every Volksbank showed up as "Volksbank Kassel Göttingen".
        let m = |cp: &str, pu: &str| resolve_merchant(cp.into(), pu.into());
        for (cp, want) in [
            ("Volksbank Mittelhessen eG", "Volksbank Mittelhessen"),
            ("VOLKSBANK MITTELHESSEN EG", "Volksbank Mittelhessen"),
            ("VR Bank Nord eG", "VR Bank Nord"),
            ("VR BANK NORD EG", "VR Bank Nord"),
            ("VEREINIGTE VR BANK EG", "Vereinigte VR Bank"),
            ("SPARKASSE SEELAND", "Sparkasse Seeland"),
            ("STADTSPARKASSE AGGERTAL", "Stadtsparkasse Aggertal"),
            ("Raiffeisenbank Musterdorf eG", "Raiffeisenbank Musterdorf"),
            ("Stadtsparkasse München", "Stadtsparkasse München"),
        ] {
            let info = m(cp, "Kontoführung");
            assert_eq!(info.name, want, "{cp}");
            assert!(info.known && info.kind == K::Bank, "{cp}");
        }
        let vb = m("Volksbank Mittelhessen eG", "");
        assert_eq!((vb.key.as_str(), vb.monogram.as_str()), ("volksbank", "VM"));
        // Only the purpose names the bank: the group's neutral name.
        assert_eq!(
            m("", "Abschluss Volksbank").name,
            "Volksbank / Raiffeisenbank"
        );
        assert_eq!(m("", "Sparkasse Entgelt").name, "Sparkasse");
    }

    #[test]
    fn sub_brand_in_purpose_beats_parent_counterparty() {
        let name = |cp: &str, pu: &str| resolve_merchant(cp.into(), pu.into()).name;
        assert_eq!(
            name("Telekom Deutschland GmbH", "Rechnung fraenk Mobilfunk"),
            "fraenk"
        );
        assert_eq!(
            name("Telekom Deutschland GmbH", "congstar Mobilfunk"),
            "congstar"
        );
        assert_eq!(name("Telekom Deutschland GmbH", "Festnetz"), "Telekom");
        // Real booking (#204): the counterparty itself names both brands.
        assert_eq!(
            name("Fraenk - eine Marke der Telekom Deu tschland GmbH", ""),
            "fraenk"
        );
    }

    #[test]
    fn classifies_flows() {
        let m = |cp: &str| MerchantResolver::resolve(cp, "");
        assert_eq!(
            classify(
                -4_04,
                "Core MSCI World USD (Acc)",
                "Saveback",
                "",
                &m("Core MSCI World USD (Acc)"),
                "",
                AccountKind::Checking
            ),
            FlowKind::Perk
        );
        assert_eq!(
            classify(
                -100_00,
                "Core MSCI World USD (Acc)",
                "Sparplan ausgeführt",
                "",
                &m("Core MSCI World USD (Acc)"),
                "",
                AccountKind::Checking
            ),
            FlowKind::Investment
        );
        assert_eq!(
            classify(
                -31_96,
                "Lidl",
                "Kartenzahlung",
                "",
                &m("Lidl"),
                "",
                AccountKind::Checking
            ),
            FlowKind::Consumption
        );
        assert_eq!(
            classify(
                -50_00,
                "Bitcoin",
                "Sparplan ausgeführt",
                "",
                &m("Bitcoin"),
                "",
                AccountKind::Checking
            ),
            FlowKind::Investment
        );
        assert_eq!(
            classify(
                754_61,
                "Barmenia",
                "Erstattung",
                "",
                &m("Barmenia"),
                "",
                AccountKind::Checking
            ),
            FlowKind::Income
        );
    }

    #[test]
    fn investment_category_paths_and_securities_texts_are_investments() {
        let m = MerchantResolver::resolve("", "");
        let flow = |cp: &str, purpose: &str, cat: &str| {
            classify(-500_00, cp, purpose, "", &m, cat, AccountKind::Checking)
        };
        assert_eq!(
            flow("", "", "Finanzen/Investments -> Kauf"),
            FlowKind::Investment
        );
        assert_eq!(
            flow("", "Depot 123456 Wertp.Abrechn.", ""),
            FlowKind::Investment
        );
        assert_eq!(flow("", "WP-Abrechnung", ""), FlowKind::Investment);
        assert_eq!(
            flow("Lidl", "Einkauf", "Lebensmittel"),
            FlowKind::Consumption
        );
    }

    #[test]
    fn cleans_purpose() {
        assert_eq!(
            clean_purpose("EREF+ZV123 MREF+M-1 CRED+DE98ZZZ0 SVWZ+Beitrag November 2026"),
            "Beitrag November 2026"
        );
        assert_eq!(
            clean_purpose("Debitk.1 2029-12 Lidl sagt Danke KASSEL"),
            "Lidl sagt Danke KASSEL"
        ); // references that start with digits stay
        assert_eq!(
            clean_purpose("9AB12345CD678901E / 54544a4-4545bc45-4545 / shop@example.com"),
            "9AB12345CD678901E / 54544a4-4545bc45-4545 / shop@example.com"
        );
    }

    #[test]
    fn mailbox_names_do_not_make_the_merchant() {
        // "paypal@…" is the shop's mailbox, not a PayPal payment
        let m = resolve_merchant(
            "Beispiel GmbH".into(),
            "T1 / R-1 / paypal@beispiel.de".into(),
        );
        assert_ne!(m.name, "PayPal");
        let m = resolve_merchant("".into(), "paypal@beispiel.de".into());
        assert_ne!(m.name, "PayPal");
        // the domain still counts
        assert_eq!(
            resolve_merchant("".into(), "service@paypal.de".into()).name,
            "PayPal"
        );
    }

    /// Rules with own merchants (`(uuid, name, needles, based_on)`, oldest first),
    /// switched-off bundled keys and the master switch.
    fn rules(
        custom: &[(&str, &str, &[&str], &str)],
        disabled: &[&str],
        enabled: bool,
    ) -> MerchantRules {
        MerchantRules::new(MerchantSettings {
            enabled,
            disabled: disabled.iter().map(|k| k.to_string()).collect(),
            custom: custom
                .iter()
                .map(|(uuid, name, needles, based_on)| CustomSpec {
                    uuid: uuid.to_string(),
                    name: name.to_string(),
                    needles: needles.iter().map(|n| n.to_string()).collect(),
                    based_on: based_on.to_string(),
                })
                .collect(),
        })
    }

    #[test]
    fn own_merchants_come_before_bundled_ones() {
        let r = rules(
            &[("a", "Meine Bank", &["volksbank mittelhessen"], "")],
            &[],
            true,
        );
        let m = r.resolve("VOLKSBANK MITTELHESSEN EG", "Bargeldauszahlung");
        assert_eq!((m.key.as_str(), m.name.as_str()), ("u:a", "Meine Bank"));
        assert_eq!(m.kind, K::Unknown);
        assert!(!m.known && m.svg_path.is_empty() && m.domain_candidates.is_empty());
        // another member bank still goes to the bundled group entry
        assert_eq!(r.resolve("Volksbank Kassel", "").key, "volksbank");
        // without changes the shared bundled rules answer as before
        assert_eq!(
            MerchantRules::builtin()
                .resolve("VOLKSBANK MITTELHESSEN EG", "")
                .key,
            "volksbank"
        );
    }

    #[test]
    fn switched_off_entries_fall_through_and_keep_the_flow() {
        let cp = "MSCI World USD (Acc)";
        assert_eq!(MerchantResolver::resolve(cp, "").key, "etf-core-msci-world");
        let r = rules(&[], &["etf-core-msci-world"], true);
        let (m, bundled) = r.resolve_with_bundled(cp, "");
        assert_ne!(m.key, "etf-core-msci-world");
        assert!(!m.name.contains("iShares"), "{}", m.name);
        // the flow still reads the bundled kind: an ETF purchase stays an investment
        assert_eq!(bundled.kind, K::Etf);
        assert_eq!(&*bundled.key, "etf-core-msci-world");
        // an own merchant for it, as in #1373
        let r = rules(
            &[(
                "b",
                "MSCI World (anderer Anbieter)",
                &["msci world usd"],
                "",
            )],
            &["etf-core-msci-world"],
            true,
        );
        let (m, bundled) = r.resolve_with_bundled(cp, "Sparplan");
        assert_eq!(m.name, "MSCI World (anderer Anbieter)");
        assert_eq!(bundled.kind, K::Etf);
    }

    #[test]
    fn switched_off_sub_brand_leaves_the_parent() {
        let cp = "Fraenk - eine Marke der Telekom Deutschland GmbH";
        assert_eq!(MerchantResolver::resolve(cp, "").key, "fraenk");
        assert_eq!(rules(&[], &["fraenk"], true).resolve(cp, "").key, "telekom");
    }

    #[test]
    fn recognition_off_shows_the_counterparty_without_logo() {
        let r = rules(&[("a", "Eigener", &["rewe"], "")], &[], false);
        let (m, bundled) = r.resolve_with_bundled("REWE Markt GmbH", "Einkauf");
        assert_eq!(m.name, "REWE Markt");
        assert!(m.key.starts_with("x:"), "{}", m.key);
        assert!(!m.known && m.svg_path.is_empty() && m.icon_slug.is_empty());
        assert!(m.domain.is_empty() && m.domain_candidates.is_empty());
        assert_eq!(&*bundled.key, "rewe");
        assert_eq!(bundled.kind, K::Supermarket);
        // a company is not looked up online either
        let m = r.resolve("Muster Handwerk GmbH", "");
        assert!(m.domain_candidates.is_empty() && m.domain_source.is_empty());
        // a private person keeps the initials circle
        assert!(r.resolve("Laura Schneider", "").is_person);
        // without a counterparty the start of the purpose
        assert_eq!(
            r.resolve("", "Spotify Premium Familie").name,
            "Spotify Premium Familie"
        );
    }

    #[test]
    fn the_longest_own_search_word_wins_a_tie_goes_to_the_older() {
        let r = rules(
            &[
                ("old", "Amazon allgemein", &["amazon"], ""),
                ("new", "Amazon Prime", &["amazon prime"], ""),
                ("same", "Amazon doppelt", &["amazon"], ""),
            ],
            &[],
            true,
        );
        assert_eq!(r.resolve("Amazon Prime Video", "").key, "u:new");
        assert_eq!(r.resolve("AMAZON EU S.A R.L.", "").key, "u:old");
    }

    #[test]
    fn own_search_words_match_whole_words() {
        let r = rules(
            &[
                ("a", "Drogerie", &["dm"], ""),
                ("b", "Bäcker", &["back"], ""),
                ("c", "Fonds", &["msci world usd (acc)"], ""),
            ],
            &[],
            true,
        );
        assert_eq!(r.resolve("DM Fil. 1234", "").key, "u:a");
        assert_ne!(r.resolve("Dmitri Petrov", "").key, "u:a");
        assert_ne!(r.resolve("Adm Verwaltung", "").key, "u:a");
        assert_eq!(r.resolve("Back Shop Muster", "").key, "u:b");
        assert_ne!(r.resolve("Backstube Muster", "").key, "u:b");
        assert_ne!(r.resolve("Rueckback Muster", "").key, "u:b");
        // an edge that is no letter needs no boundary
        assert_eq!(r.resolve("Core MSCI World USD (Acc)", "").key, "u:c");
        // a rejected hit does not hide a later overlapping one
        let r = rules(&[("o", "Overlap", &["ab-ab"], "")], &[], true);
        assert_eq!(r.resolve("xab-ab-ab", "").key, "u:o");
        assert_eq!(word_starts(" xab-ab-ab ", "ab-ab").collect::<Vec<_>>(), [5]);
        assert_eq!(
            word_starts(" muster ", "").count(),
            0,
            "an empty word matches nothing"
        );
    }

    #[test]
    fn a_copy_of_a_padded_needle_stays_a_whole_word() {
        // bundled as " tier ": the copy must not start to catch "Tierarzt" (#1373 review)
        let tier = entry_by_key("tier").expect("tier in the table");
        assert!(tier.needles.contains(&" tier "));
        let r = rules(&[("t", "TIER Scooter", &["tier"], "tier")], &["tier"], true);
        assert_eq!(r.resolve("TIER Mobility SE", "").key, "u:t");
        assert!(!r.resolve("Tierarztpraxis Muster", "").key.starts_with("u:"));
    }

    #[test]
    fn a_copy_of_a_sub_brand_still_wins_over_the_parent() {
        let (cp, pu) = ("Telekom Deutschland GmbH", "congstar Kd-Nr 4711");
        assert_eq!(MerchantResolver::resolve(cp, pu).key, "congstar");
        let r = rules(
            &[("c", "Mein Handyvertrag", &["congstar"], "congstar")],
            &["congstar"],
            true,
        );
        assert_eq!(r.resolve(cp, pu).name, "Mein Handyvertrag");
        // a plain Telekom booking stays Telekom
        assert_eq!(r.resolve(cp, "Rechnung 11/2026").key, "telekom");
    }

    #[test]
    fn a_copy_of_a_parent_company_still_yields_to_its_sub_brands() {
        let r = rules(
            &[("t", "Mein Telekom", &["telekom"], "telekom")],
            &["telekom"],
            true,
        );
        let fraenk = "Fraenk - eine Marke der Telekom Deutschland GmbH";
        assert_eq!(r.resolve(fraenk, "").key, "fraenk");
        assert_eq!(
            r.resolve("Telekom Deutschland GmbH", "congstar Kd-Nr 4711")
                .key,
            "congstar"
        );
        assert_eq!(
            r.resolve("Telekom Deutschland GmbH", "Rechnung 11/2026")
                .key,
            "u:t"
        );
    }

    #[test]
    fn a_copy_of_a_payment_processor_still_looks_behind_it() {
        let r = rules(
            &[("p", "Mein PayPal", &["paypal"], "paypal")],
            &["paypal"],
            true,
        );
        let cp = "PayPal Europe S.a.r.l. et Cie S.C.A";
        assert_eq!(r.resolve(cp, "Ihr Einkauf bei Spotify AB").key, "spotify");
        assert_eq!(
            r.resolve("PAYPAL *HAENDLER MUSTER 1234567890", "").name,
            "Haendler Muster"
        );
        // nothing behind it: the copy's own name
        assert_eq!(r.resolve(cp, "Rueckzahlung").name, "Mein PayPal");
        // an own merchant behind it
        let r = rules(
            &[
                ("p", "Mein PayPal", &["paypal"], "paypal"),
                ("k", "Kleiner Laden", &["kleiner laden"], ""),
            ],
            &["paypal"],
            true,
        );
        assert_eq!(r.resolve(cp, "Ihr Einkauf bei Kleiner Laden").key, "u:k");
    }

    #[test]
    fn own_merchants_in_the_purpose_follow_the_bundled_rules() {
        let r = rules(&[("a", "Kleiner Laden", &["kleiner laden"], "")], &[], true);
        // behind a payment processor
        let m = r.resolve(
            "PayPal Europe S.a.r.l. et Cie S.C.A",
            "Ihr Einkauf bei Kleiner Laden",
        );
        assert_eq!(m.key, "u:a");
        // without a counterparty
        assert_eq!(r.resolve("", "Kartenzahlung Kleiner Laden").key, "u:a");
        // not when a counterparty names someone else
        assert_ne!(
            r.resolve("Max Mustermann", "Geschenk Kleiner Laden").key,
            "u:a"
        );
        // a short word never from the purpose alone (" TK ", #1133)
        let r = rules(&[("t", "Kasse", &["tk"], "")], &[], true);
        assert_ne!(r.resolve("", "WP-Abrechnung TK Depot").key, "u:t");
    }

    #[test]
    fn a_copy_keeps_logo_colour_and_kind() {
        let r = rules(
            &[("c", "Mein Supermarkt", &["rewe"], "rewe")],
            &["rewe"],
            true,
        );
        let m = r.resolve("REWE SAGT DANKE 4711", "");
        let rewe = MerchantResolver::resolve("REWE SAGT DANKE 4711", "");
        assert_eq!(
            (m.key.as_str(), m.name.as_str()),
            ("u:c", "Mein Supermarkt")
        );
        assert_eq!(m.monogram, "MS");
        assert_eq!(
            (m.kind, &m.color_hex, &m.svg_path),
            (rewe.kind, &rewe.color_hex, &rewe.svg_path)
        );
        assert_eq!(m.domain_source, "dictionary");
        assert!(!m.known, "a typed name is covered in bug reports");
        // unchanged name: the bundled monogram stays
        let r = rules(
            &[("d", "dm-drogerie markt", &["dm drogerie"], "dm")],
            &["dm"],
            true,
        );
        assert_eq!(r.resolve("DM Drogerie Markt", "").monogram, "dm");
        // a copy of a securities entry is found in the purpose like the original
        let r = rules(
            &[("e", "Mein ETF", &["core msci world"], "etf-core-msci-world")],
            &[],
            true,
        );
        assert_eq!(
            r.resolve("Depotbank", "Sparplan Core MSCI World").key,
            "u:e"
        );
    }

    #[test]
    fn a_copy_of_a_share_keeps_the_securities_check() {
        let r = rules(
            &[("s", "Bayer-Aktie", &["bayer"], "stock-bayer")],
            &[],
            true,
        );
        assert_ne!(r.resolve("Max Bayer", "Anteil Abendessen").key, "u:s");
        assert_eq!(r.resolve("Bayer AG", "Dividende 2025").key, "u:s");
    }

    #[test]
    fn own_rules_remember_their_merchants_apart_from_the_bundled_ones() {
        let r = rules(&[("a", "Eigener Markt", &["rewe"], "")], &[], true);
        for _ in 0..2 {
            assert_eq!(r.resolve("REWE Markt", "").key, "u:a");
            assert_eq!(MerchantResolver::resolve("REWE Markt", "").key, "rewe");
        }
        assert_eq!(
            r.resolve("REWE Markt", ""),
            r.resolve_uncached("REWE Markt", "")
        );
        assert_eq!(&*r.bundled("REWE Markt", "").key, "rewe");
    }

    #[test]
    fn own_search_words_review_cases() {
        // overlapping occurrences: the first "ab-ab" fails its left edge, the second counts
        let r = rules(&[("o", "Overlap", &["ab-ab"], "")], &[], true);
        assert_eq!(r.resolve("xab-ab-ab", "").key, "u:o");
        // a reference keeps all its digits
        let r = rules(&[("d", "Vertrag", &["123456"], "")], &[], true);
        assert_eq!(r.resolve("Vertrag 123456", "").key, "u:d");
        assert_ne!(r.resolve("Vertrag 123459", "").key, "u:d");
        // a legal form in the middle leaves one space between the words
        let r = rules(&[("m", "Shop", &["muster shop"], "")], &[], true);
        assert_eq!(r.resolve("Muster GmbH Shop", "").key, "u:m");
        // a copy of a share checks the legal form at a whole-word match only
        let r = rules(
            &[("s", "Bayer-Aktie", &["bayer"], "stock-bayer")],
            &[],
            true,
        );
        assert_ne!(r.resolve("ABayerInc, Max Bayer", "Geschenk").key, "u:s");
        // only the parent company is switched off: its sub-brand still shows
        let r = rules(&[], &["telekom"], true);
        assert_eq!(
            r.resolve("Telekom Deutschland GmbH", "congstar Kd-Nr 4711")
                .key,
            "congstar"
        );
        assert!(
            r.resolve("Telekom Deutschland GmbH", "Festnetz")
                .key
                .starts_with("x:")
        );
    }
}
