//! Händler-Historie, Sparplan-/Perks-Dashboard und der optionale
//! Logo-Cache (Tier 2 des Merchant-Resolvers).

use std::collections::{BTreeMap, HashMap};

use chrono::{Datelike, Local, NaiveDate};
use rusqlite::{params, OptionalExtension};

use crate::error::CoreError;
use crate::merchants::FlowKind;
use crate::models::*;
use crate::vault::Vault;

fn all_bookings(v: &Vault, scope: BookingScope) -> Result<Vec<Booking>, CoreError> {
    Ok(v.list_transactions(BookingFilter {
        scope,
        ..Default::default()
    })?
    .transactions)
}

fn month_key(date: &str) -> String {
    date.chars().take(7).collect()
}

fn last_months(n: u32) -> Vec<String> {
    let today = Local::now().date_naive();
    let (mut y, mut m) = (today.year(), today.month() as i32);
    let mut out = Vec::new();
    for _ in 0..n.max(1) {
        out.push(format!("{y:04}-{m:02}"));
        m -= 1;
        if m == 0 {
            m = 12;
            y -= 1;
        }
    }
    out.reverse();
    out
}

fn lower_contains(b: &Booking, needles: &[&str]) -> bool {
    let t = format!("{} {} {}", b.counterparty, b.purpose, b.booking_text).to_lowercase();
    needles.iter().any(|n| t.contains(n))
}

#[uniffi::export]
impl Vault {
    /// "Händler-Historie": how often and how much at this merchant.
    pub fn merchant_stats(&self, merchant_key: String) -> Result<MerchantStats, CoreError> {
        let page = self.list_transactions(BookingFilter {
            merchant_key: Some(merchant_key.clone()),
            ..Default::default()
        })?;
        let txs = page.transactions;
        let count = txs.len() as u32;
        let total: i64 = txs.iter().map(|t| t.amount_cents).sum();
        Ok(MerchantStats {
            name: txs
                .first()
                .map(|t| t.merchant.name.clone())
                .unwrap_or_default(),
            key: merchant_key,
            count,
            total_cents: total,
            average_cents: if count > 0 { total / count as i64 } else { 0 },
            first_date: txs
                .last()
                .map(|t| t.booking_date.clone())
                .unwrap_or_default(),
            last_date: txs
                .first()
                .map(|t| t.booking_date.clone())
                .unwrap_or_default(),
        })
    }

    /// KPI tiles for the selected accounts (empty = all) and period. Sums in the
    /// core, so the bookings never cross the FFI boundary.
    pub fn selection_flow(
        &self,
        account_ids: Vec<i64>,
        date_from: Option<String>,
        date_to: Option<String>,
    ) -> Result<SelectionFlow, CoreError> {
        Ok(self
            .list_transactions(BookingFilter {
                account_ids,
                date_from,
                date_to,
                ..Default::default()
            })?
            .flow)
    }

    /// "Sparpläne & Perks": recurring plans with a month grid, Saveback and
    /// Round up totals, and consumption vs. investment per month.
    pub fn investment_dashboard(&self, months: u32) -> Result<InvestmentDashboard, CoreError> {
        let months_list = last_months(months);
        let first_month = months_list.first().cloned().unwrap_or_default();
        let this_month = months_list.last().cloned().unwrap_or_default();
        let all = all_bookings(self, BookingScope::All)?;

        // Monthly flows
        let mut monthly: BTreeMap<String, MonthFlow> = months_list
            .iter()
            .map(|m| {
                (
                    m.clone(),
                    MonthFlow {
                        month: m.clone(),
                        consumption_cents: 0,
                        investment_cents: 0,
                        income_cents: 0,
                    },
                )
            })
            .collect();
        for b in &all {
            if let Some(mf) = monthly.get_mut(&month_key(&b.booking_date)) {
                match b.flow {
                    FlowKind::Consumption => mf.consumption_cents += -b.amount_cents,
                    FlowKind::Investment => mf.investment_cents += -b.amount_cents,
                    FlowKind::Perk if b.amount_cents < 0 => mf.investment_cents += -b.amount_cents,
                    FlowKind::Income => mf.income_cents += b.amount_cents,
                    _ => {}
                }
            }
        }

        // Savings plans: investment outflows that look like plan executions
        let mut plans: HashMap<String, (crate::merchants::MerchantInfo, Vec<&Booking>)> =
            HashMap::new();
        let (mut sb_earned, mut sb_count, mut ru_inv, mut ru_count, mut perks_month) =
            (0i64, 0u32, 0i64, 0u32, 0i64);
        for b in &all {
            if b.flow == FlowKind::Perk {
                if lower_contains(b, &["saveback"]) {
                    if b.amount_cents > 0 {
                        sb_earned += b.amount_cents;
                        sb_count += 1;
                        if month_key(&b.booking_date) == this_month {
                            perks_month += b.amount_cents;
                        }
                    }
                } else if b.amount_cents < 0 {
                    ru_inv += -b.amount_cents;
                    ru_count += 1;
                    if month_key(&b.booking_date) == this_month {
                        perks_month += -b.amount_cents;
                    }
                }
                continue;
            }
            if b.flow == FlowKind::Investment
                && b.amount_cents < 0
                && b.booking_date.as_str() >= first_month.as_str()
            {
                plans
                    .entry(b.merchant.key.clone())
                    .or_insert_with(|| (b.merchant.clone(), Vec::new()))
                    .1
                    .push(b);
            }
        }
        let today = Local::now().date_naive();
        let mut out_plans: Vec<SavingsPlan> = plans
            .into_values()
            .filter(|(_, v)| v.len() >= 2 || v.iter().any(|b| lower_contains(b, &["sparplan"])))
            .map(|(m, v)| {
                let latest = v.iter().max_by_key(|b| b.booking_date.clone()).unwrap();
                let mut per_month: HashMap<String, i64> = HashMap::new();
                for b in &v {
                    *per_month.entry(month_key(&b.booking_date)).or_default() += -b.amount_cents;
                }
                let last = NaiveDate::parse_from_str(&latest.booking_date, "%Y-%m-%d").ok();
                SavingsPlan {
                    merchant: m,
                    monthly_cents: -latest.amount_cents,
                    day_of_month: last.map(|d| d.day()).unwrap_or(1),
                    last_date: latest.booking_date.clone(),
                    active: last.map(|d| (today - d).num_days() <= 40).unwrap_or(false),
                    total_invested_cents: v.iter().map(|b| -b.amount_cents).sum(),
                    executions: months_list
                        .iter()
                        .map(|mk| PlanExecution {
                            month: mk.clone(),
                            amount_cents: per_month.get(mk).copied().unwrap_or(0),
                        })
                        .collect(),
                }
            })
            .collect();
        out_plans.sort_by(|a, b| {
            b.monthly_cents
                .cmp(&a.monthly_cents)
                .then(a.merchant.name.cmp(&b.merchant.name))
        });
        let total_monthly = out_plans
            .iter()
            .filter(|p| p.active)
            .map(|p| p.monthly_cents)
            .sum();
        Ok(InvestmentDashboard {
            months: months_list,
            plans: out_plans,
            total_monthly_cents: total_monthly,
            saveback_earned_cents: sb_earned,
            saveback_count: sb_count,
            roundup_invested_cents: ru_inv,
            roundup_count: ru_count,
            perks_this_month_cents: perks_month,
            monthly: monthly.into_values().collect(),
        })
    }

    /// Tier 2: cached logo bytes (PNG/ICO) for a domain – never touches the network.
    pub fn get_merchant_logo_png(&self, domain: String) -> Result<Option<Vec<u8>>, CoreError> {
        let db = self.db()?;
        let bytes: Option<Option<Vec<u8>>> = db
            .query_row(
                "SELECT image_bytes FROM merchant_logo_cache WHERE domain = ?1",
                [&domain],
                |r| r.get(0),
            )
            .optional()?;
        Ok(bytes.flatten().filter(|b| good_logo(b)))
    }

    /// Manual domain for a merchant (inspector "edit" button). None/empty
    /// removes the override. Returns the stored, normalised domain.
    pub fn set_merchant_domain(
        &self,
        merchant_key: String,
        domain: Option<String>,
    ) -> Result<Option<String>, CoreError> {
        let db = self.db()?;
        match domain
            .map(|d| normalise_domain(&d))
            .filter(|d| d.contains('.'))
        {
            Some(d) => {
                db.execute(
                    "INSERT INTO merchant_domain_overrides(merchant_key, domain) VALUES (?1, ?2)
                     ON CONFLICT(merchant_key) DO UPDATE SET domain = excluded.domain, updated_at = strftime('%s','now')",
                    params![merchant_key, d],
                )?;
                // forget a previous negative result so the logo is fetched again
                db.execute("DELETE FROM merchant_logo_cache WHERE domain = ?1 AND (image_bytes IS NULL OR length(image_bytes) = 0)", [&d])?;
                Ok(Some(d))
            }
            None => {
                db.execute(
                    "DELETE FROM merchant_domain_overrides WHERE merchant_key = ?1",
                    [&merchant_key],
                )?;
                Ok(None)
            }
        }
    }

    pub fn clear_logo_cache(&self) -> Result<u32, CoreError> {
        Ok(self.db()?.execute("DELETE FROM merchant_logo_cache", [])? as u32)
    }

    pub fn online_logos_enabled(&self) -> Result<bool, CoreError> {
        Ok(self.online_logo_provider()? != "off")
    }

    /// Selected favicon provider: "off" (default), "duckduckgo" or "google".
    /// Legacy values from the former on/off toggle ("1"/"true") map to
    /// "google" (what they used first); anything else means "off".
    pub fn online_logo_provider(&self) -> Result<String, CoreError> {
        let db = self.db()?;
        let raw = Vault::setting_inner(&db, "merchants.online_logos")?;
        Ok(normalize_logo_provider(raw.as_deref()).to_string())
    }
}

fn normalize_logo_provider(raw: Option<&str>) -> &'static str {
    match raw.map(|v| v.trim().to_lowercase()).as_deref() {
        Some("duckduckgo") => "duckduckgo",
        Some("google") | Some("1") | Some("true") => "google",
        _ => "off",
    }
}

/// Pixel size of a PNG / ICO / GIF (None for other formats).
pub(crate) fn image_size(b: &[u8]) -> Option<(u32, u32)> {
    if b.len() > 24 && b.starts_with(&[0x89, b'P', b'N', b'G']) {
        return Some((
            u32::from_be_bytes([b[16], b[17], b[18], b[19]]),
            u32::from_be_bytes([b[20], b[21], b[22], b[23]]),
        ));
    }
    if b.len() > 6 && b.starts_with(&[0, 0, 1, 0]) {
        let count = u16::from_le_bytes([b[4], b[5]]) as usize;
        let mut best = 0u32;
        for i in 0..count.min(32) {
            let off = 6 + i * 16;
            if off + 2 > b.len() {
                break;
            }
            let w = if b[off] == 0 { 256 } else { b[off] as u32 };
            best = best.max(w);
        }
        return Some((best, best));
    }
    if b.len() > 10 && b.starts_with(b"GIF8") {
        return Some((
            u16::from_le_bytes([b[6], b[7]]) as u32,
            u16::from_le_bytes([b[8], b[9]]) as u32,
        ));
    }
    None
}

/// A real logo, not the tiny 16×16 default globe: dimensions > 16 px when
/// known, otherwise more than 400 bytes.
pub(crate) fn good_logo(b: &[u8]) -> bool {
    looks_like_image(b)
        && match image_size(b) {
            Some((w, h)) => w > 16 && h > 16,
            None => b.len() > 400,
        }
}

/// "https://www.EnBW.com/privat" -> "enbw.com"
pub fn normalise_domain(input: &str) -> String {
    let s = input.trim().to_lowercase();
    let s = s.split("://").last().unwrap_or(&s).to_string();
    let s = s.split(['/', '?', '#']).next().unwrap_or("").to_string();
    s.trim_start_matches("www.").trim_matches('.').to_string()
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MerchantLogo {
    pub domain: String,
    pub bytes: Vec<u8>,
}

pub(crate) const OVERRIDE_SCHEMA: &str = "CREATE TABLE IF NOT EXISTS merchant_domain_overrides (
    merchant_key TEXT PRIMARY KEY, domain TEXT NOT NULL, updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')));";

/// One-time cleanup (v1): deletes cached favicons whose domain is neither a
/// curated brand nor a manual override (e.g. "paula.de" fetched for the
/// private person "Laura Schneider" by the old guesser).
pub(crate) fn purge_untrusted_logos(conn: &rusqlite::Connection) -> rusqlite::Result<u32> {
    let done: Option<String> = conn
        .query_row(
            "SELECT value FROM settings WHERE key = 'maintenance.logo_purge_v1'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if done.is_some() {
        return Ok(0);
    }
    let mut keep: std::collections::HashSet<String> = crate::merchants::known_brand_domains()
        .into_iter()
        .map(|s| s.to_string())
        .collect();
    keep.extend(load_overrides(conn)?.into_values());
    let domains: Vec<String> = {
        let mut st = conn.prepare("SELECT domain FROM merchant_logo_cache")?;
        let r = st
            .query_map([], |r| r.get(0))?
            .collect::<Result<Vec<_>, _>>()?;
        r
    };
    let mut n = 0;
    for d in domains {
        if !keep.contains(&d) {
            n += conn.execute("DELETE FROM merchant_logo_cache WHERE domain = ?1", [&d])? as u32;
        }
    }
    conn.execute("INSERT OR REPLACE INTO settings(key, value, is_secret) VALUES ('maintenance.logo_purge_v1', '1', 0)", [])?;
    Ok(n)
}

pub(crate) fn load_overrides(
    conn: &rusqlite::Connection,
) -> rusqlite::Result<HashMap<String, String>> {
    let mut st = conn.prepare("SELECT merchant_key, domain FROM merchant_domain_overrides")?;
    let r = st
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<Result<HashMap<_, _>, _>>();
    r
}

#[cfg(test)]
mod logo_tests {
    use super::*;

    fn png(w: u32, h: u32, len: usize) -> Vec<u8> {
        let mut b = vec![
            0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, b'I', b'H', b'D', b'R',
        ];
        b.extend(w.to_be_bytes());
        b.extend(h.to_be_bytes());
        b.resize(len, 0);
        b
    }

    #[test]
    fn rejects_default_globe_and_normalises_domains() {
        assert!(!good_logo(&png(16, 16, 726)), "16x16 globe is rejected");
        assert!(good_logo(&png(128, 128, 2000)));
        assert_eq!(
            normalise_domain("https://www.EnBW.com/privat?x=1"),
            "enbw.com"
        );
        assert_eq!(normalise_domain(" vinzenzmurr.de "), "vinzenzmurr.de");
    }

    #[test]
    fn online_logos_are_off_until_enabled() {
        let p = std::env::temp_dir().join(format!("girocrab-logos-{}.db", uuid::Uuid::new_v4()));
        let v = Vault::open(p.to_string_lossy().to_string(), vec![5u8; 32]).unwrap();
        assert!(!v.online_logos_enabled().unwrap());
        // Off means no request: an uncached domain comes back empty and is not cached.
        let rt = tokio::runtime::Runtime::new().unwrap();
        assert_eq!(rt.block_on(v.fetch_logo("lidl.de".into())).unwrap(), None);
        let cached: i64 = v
            .db()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM merchant_logo_cache", [], |r| r.get(0))
            .unwrap();
        assert_eq!(cached, 0);
        v.set_setting("merchants.online_logos".into(), "1".into())
            .unwrap();
        assert!(v.online_logos_enabled().unwrap());
        assert_eq!(v.online_logo_provider().unwrap(), "google");
        v.set_setting("merchants.online_logos".into(), "duckduckgo".into())
            .unwrap();
        assert_eq!(v.online_logo_provider().unwrap(), "duckduckgo");
        v.set_setting("merchants.online_logos".into(), "0".into())
            .unwrap();
        assert_eq!(v.online_logo_provider().unwrap(), "off");
    }

    #[test]
    fn domain_override_applies_to_bookings() {
        let p = std::env::temp_dir().join(format!("girocrab-ovr-{}.db", uuid::Uuid::new_v4()));
        let v = Vault::open(p.to_string_lossy().to_string(), vec![5u8; 32]).unwrap();
        v.seed_demo_data().unwrap();
        let page = v
            .list_transactions(BookingFilter {
                search: Some("Konditorei König".into()),
                ..Default::default()
            })
            .unwrap();
        let key = page.transactions[0].merchant.key.clone();
        assert_eq!(
            v.set_merchant_domain(key.clone(), Some("https://www.baeckerei-koenig.de/".into()))
                .unwrap()
                .as_deref(),
            Some("baeckerei-koenig.de")
        );
        let page = v
            .list_transactions(BookingFilter {
                search: Some("Konditorei König".into()),
                ..Default::default()
            })
            .unwrap();
        assert!(page
            .transactions
            .iter()
            .all(
                |t| t.merchant_domain.as_deref() == Some("baeckerei-koenig.de")
                    && t.merchant.domain_source == "override"
            ));
        let enbw = v
            .list_transactions(BookingFilter {
                search: Some("EnBW".into()),
                ..Default::default()
            })
            .unwrap();
        assert!(
            enbw.total_count > 0
                && enbw
                    .transactions
                    .iter()
                    .any(|t| t.merchant_domain.as_deref() == Some("enbw.com"))
        );
        let _ = std::fs::remove_file(p);
    }
}

fn looks_like_image(b: &[u8]) -> bool {
    b.len() > 64
        && b.len() < 512 * 1024
        && (b.starts_with(&[0x89, b'P', b'N', b'G'])
            || b.starts_with(&[0, 0, 1, 0])
            || b.starts_with(&[0xFF, 0xD8])
            || b.starts_with(b"GIF8")
            || (b.len() > 12 && &b[8..12] == b"WEBP"))
}

#[uniffi::export(async_runtime = "tokio")]
impl Vault {
    /// Tier 2 (opt-in): returns a cached favicon or, if "Händler-Logos online
    /// laden" is enabled, fetches it once from the selected provider's
    /// (Google or DuckDuckGo) favicon service and caches it in the encrypted vault. Only the domain
    /// is sent. Failures are cached for 7 days.
    pub async fn fetch_logo(&self, domain: String) -> Result<Option<Vec<u8>>, CoreError> {
        let domain = domain.trim().to_lowercase();
        if domain.is_empty()
            || !domain
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
        {
            return Ok(None);
        }
        let provider: &str;
        {
            let db = self.db()?;
            let row: Option<(Option<Vec<u8>>, i64)> = db
                .query_row(
                    "SELECT image_bytes, updated_at FROM merchant_logo_cache WHERE domain = ?1",
                    [&domain],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            if let Some((bytes, fetched)) = row {
                let fresh_negative = chrono::Utc::now().timestamp() - fetched < 7 * 86400;
                match bytes {
                    Some(b) if good_logo(&b) => return Ok(Some(b)),
                    _ if fresh_negative => return Ok(None),
                    _ => {}
                }
            }
            let raw = Vault::setting_inner(&db, "merchants.online_logos")?;
            provider = normalize_logo_provider(raw.as_deref());
            if provider == "off" {
                return Ok(None);
            }
        }
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(8))
            .user_agent(concat!("GiroCrab/", env!("CARGO_PKG_VERSION")))
            .build()?;
        // Only the provider the user picked is contacted – no silent fallback.
        let sources = [if provider == "duckduckgo" {
            (
                "duckduckgo",
                format!("https://icons.duckduckgo.com/ip3/{domain}.ico"),
            )
        } else {
            (
                "google",
                format!("https://www.google.com/s2/favicons?domain={domain}&sz=128"),
            )
        }];
        let mut found: Option<(Vec<u8>, &str)> = None;
        for (name, url) in sources.iter() {
            if let Ok(resp) = client.get(url).send().await {
                if resp.status().is_success() {
                    if let Ok(bytes) = resp.bytes().await {
                        if good_logo(&bytes) {
                            found = Some((bytes.to_vec(), name));
                            break;
                        }
                    }
                }
            }
        }
        let db = self.db()?;
        db.execute(
            "INSERT INTO merchant_logo_cache(domain, image_bytes, source, updated_at) VALUES (?1, ?2, ?3, strftime('%s','now'))
             ON CONFLICT(domain) DO UPDATE SET image_bytes = excluded.image_bytes, source = excluded.source, updated_at = excluded.updated_at",
            params![domain, found.as_ref().map(|f| f.0.clone()), found.as_ref().map(|f| f.1).unwrap_or("")],
        )?;
        Ok(found.map(|f| f.0))
    }

    /// Dual-source pipeline step 2: tries every candidate domain in order
    /// ("enbw.de" -> "enbw.com"): cache, then Google S2 (128 px), then
    /// DuckDuckGo; the tiny default globe is rejected so the next candidate
    /// is tried. Returns the first real logo and its domain.
    pub async fn fetch_merchant_logo(
        &self,
        candidates: Vec<String>,
    ) -> Result<Option<MerchantLogo>, CoreError> {
        for c in candidates {
            let d = normalise_domain(&c);
            if d.is_empty() {
                continue;
            }
            if let Some(bytes) = self.fetch_logo(d.clone()).await? {
                return Ok(Some(MerchantLogo { domain: d, bytes }));
            }
        }
        Ok(None)
    }
}
