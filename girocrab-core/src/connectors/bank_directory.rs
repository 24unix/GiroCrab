//! Unified bank search for the "Bank hinzufügen" picker.
//!
//! One query (bank name, 8-digit BLZ or German IBAN) is answered from three
//! sources, each result tagged with how GiroCrab connects to the bank:
//!
//!  * `FinTs`  – FinTS 3.0 / HBCI, no third-party registration (`fints_directory`)
//!  * `OwnApi` – the bank's own API: bunq, comdirect, Trade Republic, PayPal
//!  * `Psd2`   – PSD2 via the user's Enable Banking application: a curated
//!    catalog of popular DE/AT banks and fintechs, plus – when the
//!    user's credentials are set – the full live `GET /aspsps` list.
//!
//! The curated PSD2 names are best effort: at connect time the connector asks
//! the live ASPSP list for the exact spelling (`pick_aspsp_name`).

use std::sync::Arc;

use super::enable_banking::{parse_aspsps, EnableBankingConnector};
use super::fints_directory::{self, fold, FinTsBankInfo};
use crate::error::CoreError;
use crate::models::ConnectorKind;
use crate::vault::Vault;

/// How GiroCrab talks to a bank.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BankAccessMode {
    /// FinTS 3.0 / HBCI – direct, nothing to register.
    FinTs,
    /// The bank's own API (bunq, comdirect, Trade Republic, PayPal).
    OwnApi,
    /// PSD2 through Enable Banking.
    Psd2,
}

/// A bank reachable through Enable Banking.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Psd2Bank {
    /// Name shown to the user.
    pub name: String,
    /// ISO 3166 alpha-2 country the ASPSP is listed under.
    pub country: String,
    /// ASPSP name for the Enable Banking API.
    pub aspsp: String,
    /// Dedicated connector for banks that already have one (American Express,
    /// Amazon Visa: keyless web login, PSD2 optional). `None` = generic PSD2.
    pub connector: Option<ConnectorKind>,
    /// `true` when the entry came from the live `GET /aspsps` list.
    pub live: bool,
}

/// One row of the picker.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BankSearchResult {
    /// Stable id: `fints:<blz>`, `api:<connector>` or `psd2:<CC>:<aspsp>`.
    pub id: String,
    pub name: String,
    pub mode: BankAccessMode,
    pub country: String,
    /// FinTS only.
    pub blz: String,
    /// FinTS only: PIN/TAN endpoint.
    pub url: String,
    /// Own API / dedicated connector, if any.
    pub connector: Option<ConnectorKind>,
    /// PSD2 only: Enable Banking ASPSP name.
    pub aspsp: String,
}

fn psd2(name: &str, country: &str, aspsp: &str, connector: Option<ConnectorKind>) -> Psd2Bank {
    Psd2Bank {
        name: name.into(),
        country: country.into(),
        aspsp: aspsp.into(),
        connector,
        live: false,
    }
}

/// Curated, searchable PSD2 catalog (works without any credentials).
#[uniffi::export]
pub fn psd2_catalog() -> Vec<Psd2Bank> {
    use ConnectorKind::{AmazonVisa, AmericanExpress};
    vec![
        psd2("N26", "DE", "N26", None),
        psd2("Revolut", "DE", "Revolut", None),
        psd2("C24 Bank", "DE", "C24 Bank", None),
        psd2("Tomorrow", "DE", "Tomorrow", None),
        psd2("Vivid Money", "DE", "Vivid Money", None),
        psd2("Wise", "DE", "Wise", None),
        psd2(
            "American Express",
            "DE",
            "American Express",
            Some(AmericanExpress),
        ),
        psd2("Amazon Visa (Zinia)", "DE", "Open Bank", Some(AmazonVisa)),
        psd2("Barclays", "DE", "Barclays", None),
        psd2("Hanseatic Bank", "DE", "Hanseatic Bank", None),
        psd2("Advanzia Bank", "DE", "Advanzia", None),
        psd2("Santander", "DE", "Santander", None),
        psd2("Commerzbank", "DE", "Commerzbank", None),
        psd2("Raiffeisen Bank (Österreich)", "AT", "Raiffeisen", None),
        psd2("Erste Bank (Österreich)", "AT", "Erste Bank", None),
        psd2("Bank Austria", "AT", "Bank Austria", None),
        psd2("BAWAG", "AT", "BAWAG", None),
        psd2("N26 (Österreich)", "AT", "N26", None),
        psd2("Revolut (Österreich)", "AT", "Revolut", None),
    ]
}

/// Banks with their own API: (connector, display name, extra search words).
fn own_api() -> Vec<(ConnectorKind, &'static str, &'static str)> {
    vec![
        (ConnectorKind::Bunq, "bunq", "bunq niederlande"),
        (ConnectorKind::Comdirect, "comdirect", "comdirect"),
        (
            ConnectorKind::TradeRepublic,
            "Trade Republic",
            "trade republic depot broker",
        ),
        (ConnectorKind::PayPal, "PayPal", "paypal"),
        (
            ConnectorKind::ScalableCapital,
            "Scalable Capital",
            "scalable capital depot broker overnight festgeld",
        ),
    ]
}

/// BLZs served by comdirect's own API.
const COMDIRECT_BLZ: &[&str] = &["20041111", "20041133", "20041144", "20041155"];

fn matches_all(haystack: &str, words: &[&str]) -> bool {
    words.iter().all(|w| haystack.contains(w))
}

fn fints_result(b: FinTsBankInfo) -> BankSearchResult {
    BankSearchResult {
        id: format!("fints:{}", b.blz),
        name: b.name,
        mode: BankAccessMode::FinTs,
        country: "DE".into(),
        blz: b.blz,
        url: b.url,
        connector: None,
        aspsp: String::new(),
    }
}

fn own_result(kind: ConnectorKind, name: &str) -> BankSearchResult {
    BankSearchResult {
        id: format!("api:{}", kind.as_str()),
        name: name.into(),
        mode: BankAccessMode::OwnApi,
        country: String::new(),
        blz: String::new(),
        url: String::new(),
        connector: Some(kind),
        aspsp: String::new(),
    }
}

fn psd2_result(b: Psd2Bank) -> BankSearchResult {
    BankSearchResult {
        id: format!("psd2:{}:{}", b.country, b.aspsp),
        name: b.name,
        mode: BankAccessMode::Psd2,
        country: b.country,
        blz: String::new(),
        url: String::new(),
        connector: b.connector,
        aspsp: b.aspsp,
    }
}

/// Static catalog merged with the live list. Live entries win on
/// (country, ASPSP) clashes because their spelling is authoritative.
fn merged_psd2(live: Vec<Psd2Bank>) -> Vec<Psd2Bank> {
    let key = |b: &Psd2Bank| (b.country.to_uppercase(), b.aspsp.to_lowercase());
    let mut out: Vec<Psd2Bank> = Vec::new();
    for mut b in psd2_catalog() {
        if let Some(l) = live.iter().find(|l| key(l) == key(&b)) {
            b.live = true;
            b.aspsp = l.aspsp.clone();
        }
        out.push(b);
    }
    for l in live {
        if !out.iter().any(|b| key(b) == key(&l)) {
            out.push(l);
        }
    }
    out
}

/// Searches every source. `query` is a bank name, an 8-digit BLZ or a German
/// IBAN; `live_psd2` is the list from `Vault::list_enable_banking_aspsps`
/// (empty without credentials). At most `per_group_limit` rows per access
/// mode; order: FinTS, own API, PSD2.
pub fn search(
    query: &str,
    live_psd2: Vec<Psd2Bank>,
    per_group_limit: usize,
) -> Vec<BankSearchResult> {
    let mut out = Vec::new();
    let q = fold(query);
    if q.is_empty() || per_group_limit == 0 {
        return out;
    }

    // BLZ / IBAN: exactly one answer.
    if let Some(blz) = fints_directory::blz_from_input(query) {
        if COMDIRECT_BLZ.contains(&blz.as_str()) {
            out.push(own_result(ConnectorKind::Comdirect, "comdirect"));
        } else if let Some(b) = fints_directory::lookup(&blz) {
            out.push(fints_result(b));
        }
        return out;
    }

    let words: Vec<&str> = q.split(' ').collect();
    out.extend(
        fints_directory::search(query, per_group_limit)
            .into_iter()
            .map(fints_result),
    );
    for (kind, name, extra) in own_api() {
        if matches_all(&format!("{} {}", fold(name), extra), &words) {
            out.push(own_result(kind, name));
        }
    }
    let mut n = 0;
    for b in merged_psd2(live_psd2) {
        if n >= per_group_limit {
            break;
        }
        if matches_all(&format!("{} {}", fold(&b.name), fold(&b.aspsp)), &words) {
            out.push(psd2_result(b));
            n += 1;
        }
    }
    out
}

/// Searches the FinTS directory, the own-API banks and the PSD2 catalog
/// (plus `live_psd2`, the live ASPSP list, if the app has loaded it).
#[uniffi::export]
pub fn search_banks(
    query: String,
    live_psd2: Vec<Psd2Bank>,
    per_group_limit: u32,
) -> Vec<BankSearchResult> {
    search(&query, live_psd2, per_group_limit as usize)
}

/// Offline PSD2 search over the curated catalog.
#[uniffi::export]
pub fn search_psd2_catalog(query: String) -> Vec<Psd2Bank> {
    let q = fold(&query);
    let words: Vec<&str> = q.split(' ').filter(|w| !w.is_empty()).collect();
    psd2_catalog()
        .into_iter()
        .filter(|b| matches_all(&format!("{} {}", fold(&b.name), fold(&b.aspsp)), &words))
        .collect()
}

/// Converts a `GET /aspsps` answer into picker rows.
pub(crate) fn live_banks(v: &serde_json::Value) -> Vec<Psd2Bank> {
    parse_aspsps(v)
        .into_iter()
        .map(|(name, country)| Psd2Bank {
            name: name.clone(),
            country,
            aspsp: name,
            connector: None,
            live: true,
        })
        .collect()
}

#[uniffi::export(async_runtime = "tokio")]
impl Vault {
    /// Every bank Enable Banking offers (`GET /aspsps`), for one country
    /// (ISO alpha-2) or all of them (empty). Needs the Enable Banking
    /// application ID and private key from the settings.
    pub async fn list_enable_banking_aspsps(
        self: Arc<Self>,
        country: String,
    ) -> Result<Vec<Psd2Bank>, CoreError> {
        let (app_id, pem) = {
            let db = self.db()?;
            let get = |k: &str| {
                Vault::setting_inner(&db, k)?
                    .filter(|v| !v.is_empty())
                    .ok_or_else(|| CoreError::MissingSetting { key: k.to_string() })
            };
            (
                get("enablebanking.application_id")?,
                get("enablebanking.private_key_pem")?,
            )
        };
        let jwt = EnableBankingConnector::make_jwt_for(&app_id, &pem)?;
        let country = country.trim().to_uppercase();
        if !country.is_empty()
            && !(country.len() == 2 && country.bytes().all(|b| b.is_ascii_uppercase()))
        {
            return Err(CoreError::InvalidInput {
                message: "country must be a two-letter code".into(),
            });
        }
        let mut req = super::http_client()?
            .get("https://api.enablebanking.com/aspsps")
            .bearer_auth(jwt)
            .header("Accept", "application/json");
        if !country.is_empty() {
            req = req.query(&[("country", country.as_str())]);
        }
        let resp = req.send().await?;
        let status = resp.status();
        let v: serde_json::Value = resp.json().await.unwrap_or(serde_json::Value::Null);
        if !status.is_success() {
            let msg = v["message"]
                .as_str()
                .unwrap_or("Enable Banking error")
                .to_string();
            return Err(if matches!(status.as_u16(), 401 | 403) {
                CoreError::Authentication { message: msg }
            } else {
                CoreError::Bank {
                    code: status.as_u16().to_string(),
                    message: msg,
                }
            });
        }
        let mut banks = live_banks(&v);
        banks.sort_by_key(|b| (b.name.to_lowercase(), b.country.clone()));
        Ok(banks)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ids(r: &[BankSearchResult]) -> Vec<String> {
        r.iter().map(|b| b.id.clone()).collect()
    }

    #[test]
    fn catalog_has_the_popular_psd2_banks() {
        let c = psd2_catalog();
        for n in [
            "N26",
            "Revolut",
            "C24",
            "Tomorrow",
            "Vivid",
            "Wise",
            "American Express",
            "Barclays",
            "Hanseatic",
            "Advanzia",
            "Santander",
            "Commerzbank",
            "Raiffeisen",
            "Erste",
        ] {
            assert!(c.iter().any(|b| b.name.contains(n)), "{n}");
        }
        for b in &c {
            assert_eq!(b.country.len(), 2);
            assert!(!b.aspsp.is_empty() && !b.live);
        }
        assert_eq!(search_psd2_catalog("revolut".into()).len(), 2);
        assert!(search_psd2_catalog("österreich erste".into())
            .iter()
            .all(|b| b.country == "AT"));
        // Amex / Amazon Visa keep their dedicated connectors
        let amex = c.iter().find(|b| b.name == "American Express").unwrap();
        assert_eq!(amex.connector, Some(ConnectorKind::AmericanExpress));
    }

    #[test]
    fn name_search_groups_by_access_mode() {
        let r = search("n26", vec![], 10);
        assert!(r.iter().all(|b| b.mode == BankAccessMode::Psd2));
        assert!(ids(&r).contains(&"psd2:DE:N26".to_string()));

        let r = search("bunq", vec![], 10);
        assert_eq!(ids(&r), vec!["api:bunq"]);
        assert_eq!(r[0].mode, BankAccessMode::OwnApi);
        assert_eq!(r[0].connector, Some(ConnectorKind::Bunq));

        for (q, kind) in [
            ("trade republic", ConnectorKind::TradeRepublic),
            ("PayPal", ConnectorKind::PayPal),
            ("comdirect", ConnectorKind::Comdirect),
            ("Scalable Capital", ConnectorKind::ScalableCapital),
            ("scalable", ConnectorKind::ScalableCapital),
        ] {
            let r = search(q, vec![], 10);
            assert!(
                r.iter()
                    .any(|b| b.mode == BankAccessMode::OwnApi && b.connector == Some(kind)),
                "{q}"
            );
        }

        let r = search("sparkasse", vec![], 5);
        assert_eq!(r.len(), 5);
        assert!(r
            .iter()
            .all(|b| b.mode == BankAccessMode::FinTs && b.url.starts_with("https://")));

        let r = search("ING", vec![], 10);
        assert!(r
            .iter()
            .any(|b| b.mode == BankAccessMode::FinTs && b.blz == "50010517"));
        assert!(search("DKB", vec![], 5).iter().any(|b| b.blz == "12030000"));
        assert!(search("volksbank", vec![], 5)
            .iter()
            .all(|b| b.mode == BankAccessMode::FinTs));
        assert!(search("postbank", vec![], 3).len() == 3);
        assert!(search("", vec![], 5).is_empty());
        assert!(search("zzzzqqq", vec![], 5).is_empty());
    }

    #[test]
    fn blz_and_iban_queries_find_exactly_one_bank() {
        let r = search("50010517", vec![], 10);
        assert_eq!(ids(&r), vec!["fints:50010517"]);
        assert_eq!(r[0].name, "ING");
        let r = search("DE41 5001 0517 0123 4567 89", vec![], 10);
        assert_eq!(ids(&r), vec!["fints:50010517"]);
        // valid IBAN of a bank that is not in the directory: nothing to offer
        assert!(search("DE89 3704 0044 0532 0130 00", vec![], 10).is_empty());
    }

    #[test]
    fn comdirect_blz_routes_to_its_own_api() {
        let r = search("20041111", vec![], 10);
        assert_eq!(ids(&r), vec!["api:comdirect"]);
        assert_eq!(r[0].mode, BankAccessMode::OwnApi);
    }

    #[test]
    fn live_list_adds_banks_and_fixes_spelling() {
        let live = vec![
            Psd2Bank {
                name: "Sparebank 1".into(),
                country: "NO".into(),
                aspsp: "Sparebank 1".into(),
                connector: None,
                live: true,
            },
            Psd2Bank {
                name: "n26".into(),
                country: "DE".into(),
                aspsp: "N26 Bank".into(),
                connector: None,
                live: true,
            },
        ];
        let r = search("sparebank", live.clone(), 10);
        assert_eq!(ids(&r), vec!["psd2:NO:Sparebank 1"]);
        // a live entry with a different spelling replaces nothing: matched by
        // (country, ASPSP) case-insensitively, so "n26" merges into the catalog row
        let live_same = vec![Psd2Bank {
            name: "N26".into(),
            country: "DE".into(),
            aspsp: "n26".into(),
            connector: None,
            live: true,
        }];
        let r = search("n26", live_same, 10);
        let de: Vec<_> = r.iter().filter(|b| b.country == "DE").collect();
        assert_eq!(de.len(), 1);
        assert_eq!(de[0].aspsp, "n26"); // live spelling wins
        let _ = live;
    }

    #[test]
    fn live_response_parsing() {
        let v = json!({"aspsps": [
            {"name": "N26", "country": "de", "psu_types": ["personal", "business"]},
            {"name": "Only Business", "country": "DE", "psu_types": ["business"]},
            {"name": "No Types", "country": "AT"}
        ]});
        let b = live_banks(&v);
        assert_eq!(b.len(), 2);
        assert_eq!(b[0].country, "DE");
        assert!(b.iter().all(|x| x.live));
        assert!(live_banks(&json!({})).is_empty());
    }
}
