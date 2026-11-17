//! Project announcements ("Mitteilungen", docs/announcements.md): the signed
//! `policy/announcements.json` bundled at build time. Same Ed25519 keys as the banking policy; a
//! bundle whose signature does not verify shows nothing. Dismissed ids live in the vault setting
//! `announcements.dismissed` (comma separated).

use serde::Deserialize;
use serde_json::Value;

const BUNDLED_JSON: &[u8] = include_bytes!("../../policy/announcements.json");
const BUNDLED_SIG: &[u8] = include_bytes!("../../policy/announcements.json.sig");
#[allow(dead_code)]
pub const DISMISSED_KEY: &str = "announcements.dismissed";

#[derive(Debug, Deserialize)]
struct Document {
    schema: i64,
    announcements: Vec<Item>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Item {
    id: String,
    severity: Option<String>,
    from: Option<String>,
    until: Option<String>,
    min_version: Option<String>,
    max_version: Option<String>,
    title: Value,
    summary: Option<Value>,
    body: Option<Value>,
    link: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Announcement {
    pub id: String,
    pub important: bool,
    pub title: String,
    pub summary: String,
    pub body: String,
    pub link: String,
}

fn text(v: &Option<Value>, lang: &str) -> String {
    v.as_ref().map(|v| localized(v, lang)).unwrap_or_default()
}

fn localized(v: &Value, lang: &str) -> String {
    v.get(lang)
        .or_else(|| v.get("de"))
        .or_else(|| v.get("en"))
        .and_then(Value::as_str)
        .or_else(|| v.as_str())
        .unwrap_or_default()
        .to_string()
}

/// Applicable announcements for `version` on `today` (`YYYY-MM-DD`), in file order.
fn evaluate(json: &[u8], sig: &[u8], version: &str, today: &str, lang: &str) -> Vec<Announcement> {
    if !crate::policy::verify(json, sig) {
        return vec![];
    }
    let Some(doc) = serde_json::from_slice::<Document>(json)
        .ok()
        .filter(|d| d.schema == 1)
    else {
        return vec![];
    };
    doc.announcements
        .into_iter()
        .filter(|a| a.from.as_deref().is_none_or(|f| f <= today))
        .filter(|a| a.until.as_deref().is_none_or(|u| today <= u))
        .filter(|a| {
            a.min_version
                .as_deref()
                .is_none_or(|m| !crate::policy::version_lt(version, m))
        })
        .filter(|a| {
            a.max_version
                .as_deref()
                .is_none_or(|m| !crate::policy::version_lt(m, version))
        })
        .map(|a| Announcement {
            important: a.severity.as_deref() == Some("important"),
            title: localized(&a.title, lang),
            summary: text(&a.summary, lang),
            body: text(&a.body, lang),
            link: a.link.unwrap_or_default(),
            id: a.id,
        })
        .collect()
}

pub fn current(version: &str, today: &str, lang: &str) -> Vec<Announcement> {
    evaluate(BUNDLED_JSON, BUNDLED_SIG, version, today, lang)
}

pub fn dismissed_ids(setting: &str) -> Vec<String> {
    setting
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect()
}

pub fn with_dismissed(setting: &str, id: &str) -> String {
    let mut ids = dismissed_ids(setting);
    if !ids.iter().any(|i| i == id) {
        ids.push(id.to_string());
    }
    ids.join(",")
}

/// Plain-text rendering of the Markdown body (bold/italic markers dropped).
pub fn plain(body: &str) -> String {
    body.replace("**", "").replace('*', "")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_file_verifies_and_filters_by_date_and_version() {
        let v = current("0.8.0", "2026-11-20", "de");
        assert!(v.iter().all(|a| !a.title.is_empty()));
        assert!(current("0.8.0", "2030-01-01", "de").is_empty());
        assert!(current("0.7.0", "2026-11-20", "de").is_empty());
    }

    #[test]
    fn tampered_file_shows_nothing() {
        let mut j = BUNDLED_JSON.to_vec();
        j.push(b' ');
        assert!(evaluate(&j, BUNDLED_SIG, "0.8.0", "2026-11-20", "de").is_empty());
    }

    #[test]
    fn dismissed_ids_round_trip() {
        let s = with_dismissed("a", "b");
        assert_eq!(dismissed_ids(&s), vec!["a", "b"]);
        assert_eq!(with_dismissed(&s, "a"), s);
    }
}
