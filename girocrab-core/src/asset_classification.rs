//! Offline classification primitives for #351. No network, vault writes or UI dependency.
//! Classes describe exposure; instruments describe the wrapper. Resolve each axis separately.
use crate::models::Holding;
pub(crate) mod store;
pub use store::ClassifiedAsset;

macro_rules! classification_enum {
    ($name:ident { $($variant:ident => $key:literal),+ $(,)? }) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
        #[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
        pub enum $name { $(#[cfg_attr(feature = "serde", serde(rename = $key))] $variant),+ }
        impl $name {
            pub fn as_str(self) -> &'static str { match self { $(Self::$variant => $key),+ } }
            /// Unknown future keys remain visibly unclassified.
            pub fn from_db(key: &str) -> Self { match key { $($key => Self::$variant),+, _ => Self::Unclassified } }
        }
    }
}
classification_enum!(AssetClass {
    Unclassified => "unclassified", Equity => "equity", Bond => "bond",
    RealEstate => "real_estate", Commodity => "commodity", Crypto => "crypto",
    Cash => "cash", MultiAsset => "multi_asset", Other => "other",
});
classification_enum!(InstrumentKind {
    Unclassified => "unclassified", SingleSecurity => "single", Etf => "etf",
    Fund => "fund", EtcEtn => "etc_etn", Derivative => "derivative",
    DirectHolding => "direct", Other => "other",
});
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum ClassificationSource {
    User,
    Import,
    Rule,
    Unknown,
}

/// None means automatic, independently for each axis. User overrides and resets
/// are stored separately with a timestamp per field.
#[derive(Debug, Default, Clone, PartialEq, Eq, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct ClassificationValues {
    pub asset_class: Option<AssetClass>,
    pub instrument: Option<InstrumentKind>,
}
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct AssetClassification {
    /// Stable key for user overrides. Empty ISINs and ambiguous ticker/name fallbacks have none.
    pub security_key: Option<String>,
    pub asset_class: AssetClass,
    pub asset_class_source: ClassificationSource,
    pub instrument: InstrumentKind,
    pub instrument_source: ClassificationSource,
}

/// Normalize and validate ISO 6166 structure and Luhn check digit. A valid identifier
/// is not evidence for any class; its country prefix is never used for inference.
pub fn normalized_isin(raw: &str) -> Option<String> {
    let s = raw.trim().to_ascii_uppercase();
    let b = s.as_bytes();
    if b.len() != 12
        || !b[..2].iter().all(u8::is_ascii_uppercase)
        || !b[2..11].iter().all(u8::is_ascii_alphanumeric)
        || !b[11].is_ascii_digit()
    {
        return None;
    }
    let mut digits = Vec::with_capacity(24);
    for &c in b {
        if c.is_ascii_digit() {
            digits.push(c - b'0');
        } else {
            let n = c - b'A' + 10;
            digits.extend([n / 10, n % 10]);
        }
    }
    let sum: u32 = digits
        .iter()
        .rev()
        .enumerate()
        .map(|(i, &n)| {
            let n = u32::from(n) * if i % 2 == 1 { 2 } else { 1 };
            n / 10 + n % 10
        })
        .sum();
    sum.is_multiple_of(10).then_some(s)
}

fn known_isin(isin: &str) -> ClassificationValues {
    // Small public reference set from the issue's validated examples. Exact identifiers
    // only; no inference about unrelated products issued by the same fund manager.
    use AssetClass as A;
    use InstrumentKind as I;
    let value = match isin {
        "US0378331005" | "DE0008404005" => Some((A::Equity, I::SingleSecurity)),
        "IE00B4L5Y983" | "IE00BKM4GZ66" | "IE00BK5BQT80" => Some((A::Equity, I::Etf)),
        "DE0001102580" => Some((A::Bond, I::SingleSecurity)),
        "LU0360863863" => Some((A::MultiAsset, I::Fund)),
        // overnight-rate swap ETF: money market exposure that its name does not spell out
        "LU0290358497" => Some((A::Cash, I::Etf)),
        "DE000A0S9GB0" => Some((A::Commodity, I::EtcEtn)),
        _ => None,
    };
    value
        .map(|(a, i)| ClassificationValues {
            asset_class: Some(a),
            instrument: Some(i),
        })
        .unwrap_or_default()
}

fn name_rules(name: &str) -> ClassificationValues {
    use AssetClass as A;
    use InstrumentKind as I;
    let lower = name.to_lowercase();
    let words: Vec<_> = lower
        .split(|c: char| !c.is_alphanumeric())
        .filter(|s| !s.is_empty())
        .collect();
    let has = |list: &[&str]| words.iter().any(|w| list.contains(w));
    let pair = |a: &str, b: &str| words.windows(2).any(|w| w == [a, b]);
    let derivative = has(&["optionsschein", "warrant", "knockout", "zertifikat"]);
    let complex = derivative || has(&["leveraged", "gehebelt", "short", "2x", "3x"]);
    let etf = has(&["etf"]);
    let etc = has(&["etc", "etn"]);
    let fund = has(&["fund", "funds", "fonds", "immobilienfonds", "mischfonds"]);
    let instrument = if derivative {
        Some(I::Derivative)
    } else if etf && etc {
        None
    } else if etf {
        Some(I::Etf)
    } else if etc {
        Some(I::EtcEtn)
    } else if fund {
        Some(I::Fund)
    } else {
        None
    };
    if complex || (etf && etc) {
        return ClassificationValues {
            asset_class: None,
            instrument,
        };
    }
    // Generic fund/ETF markers establish the wrapper only.
    if instrument.is_none() {
        return ClassificationValues::default();
    }
    if pair("multi", "asset") || has(&["multiasset", "mischfonds"]) {
        return ClassificationValues {
            asset_class: Some(A::MultiAsset),
            instrument,
        };
    }
    let mining = has(&["miners", "mining", "producers", "goldminen"]);
    let real_estate = pair("real", "estate") || has(&["immobilien", "immobilienfonds"]);
    let reit = has(&["reit", "reits"]);
    let mut candidates = Vec::new();
    if mining
        || reit
        || (real_estate && etf)
        || has(&["equity", "equities", "aktien"])
        || pair("msci", "world")
        || (pair("ftse", "all") && has(&["world"]))
    {
        candidates.push(A::Equity);
    }
    if has(&["bond", "bonds", "anleihen", "renten"]) {
        candidates.push(A::Bond);
    }
    if real_estate && fund && !etf && !reit {
        candidates.push(A::RealEstate);
    }
    if has(&[
        "gold",
        "silver",
        "silber",
        "platinum",
        "platin",
        "palladium",
        "commodity",
        "commodities",
        "rohstoffe",
    ]) && !mining
    {
        candidates.push(A::Commodity);
    }
    if has(&["bitcoin", "ethereum", "crypto", "krypto"]) {
        candidates.push(A::Crypto);
    }
    if pair("money", "market") || has(&["geldmarkt"]) {
        candidates.push(A::Cash);
    }
    candidates.sort_by_key(|a| a.as_str());
    candidates.dedup();
    ClassificationValues {
        asset_class: if candidates.len() == 1 {
            Some(candidates[0])
        } else {
            None
        },
        instrument,
    }
}

/// A connector must explicitly confirm direct crypto custody. Never treat an arbitrary
/// WKN as a ticker. Limit global ticker keys to this small, unambiguous supported set.
fn crypto_ticker(holding: &Holding, confirmed: bool) -> Option<String> {
    if !confirmed || !holding.isin.trim().is_empty() {
        return None;
    }
    let ticker = holding.wkn.trim().to_ascii_uppercase();
    matches!(
        ticker.as_str(),
        "BTC" | "ETH" | "SOL" | "ADA" | "XRP" | "LTC" | "DOGE"
    )
    .then_some(ticker)
}

/// Stable key of user overrides: a valid ISIN, else a confirmed direct crypto ticker.
pub(crate) fn security_key(holding: &Holding, confirmed_direct_crypto: bool) -> Option<String> {
    normalized_isin(&holding.isin)
        .map(|s| format!("isin:{s}"))
        .or_else(|| crypto_ticker(holding, confirmed_direct_crypto).map(|t| format!("crypto:{t}")))
}

pub fn classify_asset(
    holding: Holding,
    imported: ClassificationValues,
    user: ClassificationValues,
    confirmed_direct_crypto: bool,
) -> AssetClassification {
    use ClassificationSource as S;
    let isin = normalized_isin(&holding.isin);
    let ticker = crypto_ticker(&holding, confirmed_direct_crypto);
    let security_key = security_key(&holding, confirmed_direct_crypto);
    let rules = if ticker.is_some() {
        ClassificationValues {
            asset_class: Some(AssetClass::Crypto),
            instrument: Some(InstrumentKind::DirectHolding),
        }
    } else if let Some(ref isin) = isin {
        let known = known_isin(isin);
        let names = name_rules(&holding.name);
        ClassificationValues {
            asset_class: known.asset_class.or(names.asset_class),
            instrument: known.instrument.or(names.instrument),
        }
    } else {
        name_rules(&holding.name)
    };
    // Unknown imported types must not prevent a useful local fallback. An explicit
    // user choice of Unclassified is retained, separately from automatic (None).
    let (asset_class, asset_class_source) = if let Some(v) = user.asset_class {
        (v, S::User)
    } else if let Some(v) = imported
        .asset_class
        .filter(|v| *v != AssetClass::Unclassified)
    {
        (v, S::Import)
    } else if let Some(v) = rules.asset_class {
        (v, S::Rule)
    } else {
        (AssetClass::Unclassified, S::Unknown)
    };
    let (instrument, instrument_source) = if let Some(v) = user.instrument {
        (v, S::User)
    } else if let Some(v) = imported
        .instrument
        .filter(|v| *v != InstrumentKind::Unclassified)
    {
        (v, S::Import)
    } else if let Some(v) = rules.instrument {
        (v, S::Rule)
    } else {
        (InstrumentKind::Unclassified, S::Unknown)
    };
    AssetClassification {
        security_key,
        asset_class,
        asset_class_source,
        instrument,
        instrument_source,
    }
}

#[cfg(test)]
mod tests;

/// Exact broker/import labels only. Unknown labels do not become a guessed class.
pub(crate) fn from_labels(asset: &str, instrument: &str) -> ClassificationValues {
    let asset_class = match asset.trim().to_lowercase().as_str() {
        "aktien" | "equity" | "equities" => Some(AssetClass::Equity),
        "anleihen" | "renten" | "bond" | "bonds" => Some(AssetClass::Bond),
        "immobilien" | "real estate" => Some(AssetClass::RealEstate),
        "rohstoffe" | "edelmetalle" | "commodity" | "commodities" => Some(AssetClass::Commodity),
        "krypto" | "crypto" => Some(AssetClass::Crypto),
        "geldmarkt" | "cash" | "money market" => Some(AssetClass::Cash),
        "multi-asset" | "mischfonds" => Some(AssetClass::MultiAsset),
        _ => None,
    };
    let instrument = match instrument.trim().to_lowercase().as_str() {
        "etf" => Some(InstrumentKind::Etf),
        "etc" | "etn" => Some(InstrumentKind::EtcEtn),
        "common stock" | "aktie" | "anleihe" => Some(InstrumentKind::SingleSecurity),
        _ => None,
    };
    ClassificationValues {
        asset_class,
        instrument,
    }
}

#[cfg(test)]
mod store_tests;
