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

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use crate::models::AccountKind;

/// Entries kept by the merchant cache of [`MerchantResolver::resolve`].
const RESOLVE_CACHE_MAX: usize = 200_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
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
        if digits > 5 {
            continue;
        }
        if c == ' ' && out.ends_with(' ') {
            continue;
        }
        out.push(c);
    }
    let mut s = out;
    for noise in [
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
    ] {
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
    if (!e.isin.is_empty() && ctx.contains(&e.isin.to_lowercase()))
        || (!e.wkn.is_empty() && ctx.contains(&e.wkn.to_lowercase()))
    {
        return true;
    }
    if contains_any(ctx, SECURITIES_HINTS) {
        return true;
    }
    e.needles.iter().any(|n| {
        text.find(n.trim()).is_some_and(|p| {
            let rest = text[p + n.trim().len()..].trim_start();
            let word: String = rest
                .chars()
                .take_while(|c| c.is_alphanumeric() || *c == '.')
                .collect();
            matches!(
                word.trim_end_matches('.'),
                "ag" | "se" | "kgaa" | "inc" | "corp" | "plc"
            )
        })
    })
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

fn entry_by_key(key: &str) -> Option<&'static Entry> {
    entries().iter().find(|e| e.key == key)
}

/// Like `find`, but skips stock entries without securities evidence.
fn find_checked(text: &str, ctx: &str) -> Option<&'static Entry> {
    entries().iter().find(|e| {
        e.needles.iter().any(|n| needle_in(text, n))
            && (e.kind != K::Stock || stock_confirmed(e, text, ctx))
    })
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
        if let Some(p) = t.find(suffix) {
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
                let mut cs = w.chars();
                match cs.next() {
                    Some(f) => f.to_uppercase().collect::<String>() + &cs.as_str().to_lowercase(),
                    None => String::new(),
                }
            })
            .collect::<Vec<_>>()
            .join(" ")
    } else {
        t
    }
}

impl MerchantResolver {
    /// Resolves the merchant of a booking from counterparty and purpose.
    ///
    /// The result only depends on the two texts, and the booking list asks
    /// for every booking again on each reload, so results are remembered
    /// for the lifetime of the process (resolving ~19 000 bookings took
    /// about 270 ms per reload; a remembered one is a hash lookup).
    pub fn resolve(counterparty: &str, purpose: &str) -> MerchantInfo {
        static CACHE: OnceLock<Mutex<HashMap<(String, String), MerchantInfo>>> = OnceLock::new();
        let cache = CACHE.get_or_init(Default::default);
        let key = (counterparty.to_string(), purpose.to_string());
        if let Some(hit) = cache.lock().ok().and_then(|c| c.get(&key).cloned()) {
            return hit;
        }
        let info = Self::resolve_uncached(counterparty, purpose);
        if let Ok(mut c) = cache.lock() {
            // bounded: far above any real booking count, cleared rather than evicted
            if c.len() >= RESOLVE_CACHE_MAX {
                c.clear();
            }
            c.insert(key, info.clone());
        }
        info
    }

    /// Empty merchant for a booking that is enriched right afterwards.
    pub fn placeholder() -> MerchantInfo {
        static EMPTY: OnceLock<MerchantInfo> = OnceLock::new();
        EMPTY.get_or_init(|| Self::resolve_uncached("", "")).clone()
    }

    fn resolve_uncached(counterparty: &str, purpose: &str) -> MerchantInfo {
        let cp = normalise(counterparty);
        let pu = normalise(purpose);
        // "PayPal *Spotify", "PayPal Europe ... Ihr Einkauf bei Spotify AB": look behind the processor.
        let ctx = format!("{cp} {pu}");
        if let Some(entry) = find_checked(&cp, &ctx) {
            if entry.kind == K::PaymentService {
                let behind = cp
                    .split_once(entry.needles[0])
                    .map(|x| x.1.to_string())
                    .unwrap_or_default();
                if let Some(real) = find_checked(&behind, &ctx)
                    .or_else(|| find_checked(&pu, &ctx))
                    .filter(|r| r.kind != K::PaymentService)
                {
                    return to_info(real);
                }
            }
            if let Some((_, subs)) = SUB_BRANDS.iter().find(|(parent, _)| *parent == entry.key) {
                if let Some(sub) = subs
                    .iter()
                    .filter_map(|k| entry_by_key(k))
                    .find(|sub| sub.needles.iter().any(|n| needle_in(&ctx, n)))
                {
                    return to_info(sub);
                }
            }
            return to_info(entry);
        }
        if let Some(entry) = find_checked(&pu, &ctx).filter(|e| {
            matches!(e.kind, K::Etf | K::Crypto | K::Stock | K::PaymentService)
                || counterparty.trim().is_empty()
        }) {
            return to_info(entry);
        }
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
        let hash = key_base
            .bytes()
            .fold(0u32, |a, b| a.wrapping_mul(31).wrapping_add(b as u32));
        let raw = if counterparty.trim().is_empty() {
            name.clone()
        } else {
            counterparty.to_string()
        };
        // Strict whitelist: a domain only for curated brands (handled above)
        // or companies with an explicit legal suffix – never for persons.
        let company = has_legal_suffix(&raw);
        let person = !company && looks_like_person(&raw);
        let candidates = if company {
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
                FALLBACK_COLORS[(hash as usize) % FALLBACK_COLORS.len()].to_string()
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
}

fn contains_any(text: &str, needles: &[&str]) -> bool {
    needles.iter().any(|n| text.contains(n))
}

/// Classifies a booking. `top_category` is the name of the top-level category
/// ("Sparen & Investieren", "Umbuchungen", "Kredite & Darlehen"...).
pub fn classify(
    amount_cents: i64,
    counterparty: &str,
    purpose: &str,
    booking_text: &str,
    merchant: &MerchantInfo,
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
        || matches!(merchant.kind, K::Etf | K::Crypto | K::Stock)
        || contains_any(&t, &["sparplan", "wertpapierkauf", "kauf order"])
    {
        return FlowKind::Investment;
    }
    if top_category == "Kredite & Darlehen"
        || account_kind == AccountKind::Loan
        || contains_any(&t, &["darlehen", "tilgung", "kreditrate"])
    {
        return FlowKind::Loan;
    }
    if top_category == "Umbuchungen"
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
pub fn payment_method(
    booking_text: &str,
    purpose: &str,
    account_kind: AccountKind,
    amount_cents: i64,
) -> String {
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
    } else if account_kind == AccountKind::PaymentService {
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
                || (w.len() >= 7
                    && w.chars().take(4).all(|c| c.is_ascii_digit())
                    && w.contains('-')))
        })
        .collect();
    words.join(" ").trim().trim_matches('.').trim().to_string()
}

/// Exposed for tests / tooling: resolve without a vault.
#[uniffi::export]
pub fn resolve_merchant(counterparty: String, purpose: String) -> MerchantInfo {
    MerchantResolver::resolve(&counterparty, &purpose)
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
        assert!(MerchantResolver::resolve("Hotel Schwarzer Bock", "")
            .domain
            .is_empty());
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
    }

    #[test]
    fn needles_match_at_word_start_only() {
        let name = |cp: &str, pu: &str| resolve_merchant(cp.into(), pu.into()).name;
        // "Bausparkasse" is not a Sparkasse (#204).
        assert_eq!(
            name("Dt. Bausparkasse Badenia AG", ""),
            "Dt. Bausparkasse Badenia"
        );
        assert_eq!(name("Stadtsparkasse Muenchen", ""), "Sparkasse");
        assert_eq!(name("Kreissparkasse Koeln", ""), "Sparkasse");
        assert_eq!(name("Sparkasse Hannover", ""), "Sparkasse");
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
    fn cleans_purpose() {
        assert_eq!(
            clean_purpose("EREF+ZV123 MREF+M-1 CRED+DE98ZZZ0 SVWZ+Beitrag November 2026"),
            "Beitrag November 2026"
        );
        assert_eq!(
            clean_purpose("Debitk.1 2029-12 Lidl sagt Danke KASSEL"),
            "Lidl sagt Danke KASSEL"
        );
    }
}
