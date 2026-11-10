//! American Express and Amazon Visa through the Enable Banking PSD2
//! aggregation API (enablebanking.com/docs/api/reference).
//!
//!  Auth: every request carries a JWT (RS256) signed with the user's own
//!        application key: header kid=<application id>,
//!        claims iss="enablebanking.com", aud="api.enablebanking.com".
//!  POST /auth      {access.valid_until, aspsp{name,country}, state, redirect_url, psu_type}
//!                  -> {url}   (user gives consent at the card issuer)
//!  POST /sessions  {code}     -> {session_id, accounts[]}
//!  GET  /accounts/{uid}/balances
//!  GET  /accounts/{uid}/transactions?date_from=…[&continuation_key=…]
//!
//! The PSD2 session is stored (encrypted) and reused until it expires, so the
//! browser consent is only needed every ~90-180 days.

use async_trait::async_trait;
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::{
    http_client, BankConnector, Challenge, ChallengeKind, ChallengeResponse, ConnectContext,
    FetchResult, Phase, RemoteAccount, RemoteTransaction,
};
use crate::error::{CoreError, CoreResult};
use crate::i18n::{tr, trf};
use crate::models::AccountKind;
use crate::money::json_number_to_cents;

const API: &str = "https://api.enablebanking.com";

#[derive(Serialize)]
struct Claims<'a> {
    iss: &'a str,
    aud: &'a str,
    iat: i64,
    exp: i64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct PsdState {
    session_id: String,
    valid_until: String,
    /// (uid, name, iban, currency)
    accounts: Vec<(String, String, String, String)>,
}

pub struct EnableBankingConnector {
    /// Setting that may override the ASPSP name; empty = fixed bank (generic kind).
    aspsp_setting: &'static str,
    aspsp_default: String,
    country_setting: &'static str,
    country_default: String,
    client: Option<reqwest::Client>,
    jwt: String,
    expected_state: String,
    st: PsdState,
}

impl EnableBankingConnector {
    pub fn new(
        aspsp_setting: &'static str,
        aspsp_default: &'static str,
        country_setting: &'static str,
    ) -> Self {
        EnableBankingConnector {
            aspsp_setting,
            aspsp_default: aspsp_default.to_string(),
            country_setting,
            country_default: "DE".to_string(),
            client: None,
            jwt: String::new(),
            expected_state: String::new(),
            st: PsdState::default(),
        }
    }

    /// Connector for one fixed bank (generic `ConnectorKind::EnableBanking`).
    pub fn for_aspsp(aspsp: &str, country: &str) -> Self {
        EnableBankingConnector {
            aspsp_setting: "",
            aspsp_default: aspsp.to_string(),
            country_setting: "",
            country_default: country.to_uppercase(),
            client: None,
            jwt: String::new(),
            expected_state: String::new(),
            st: PsdState::default(),
        }
    }

    fn make_jwt(ctx: &ConnectContext) -> CoreResult<String> {
        Self::make_jwt_for(
            ctx.setting("enablebanking.application_id")?,
            ctx.setting("enablebanking.private_key_pem")?,
        )
    }

    /// RS256 JWT for the Enable Banking API from the user's own application.
    pub(crate) fn make_jwt_for(app_id: &str, private_key_pem: &str) -> CoreResult<String> {
        let key = EncodingKey::from_rsa_pem(private_key_pem.as_bytes()).map_err(|e| {
            CoreError::InvalidInput {
                message: format!("Enable Banking private key: {e}"),
            }
        })?;
        let mut header = Header::new(Algorithm::RS256);
        header.kid = Some(app_id.to_string());
        let now = chrono::Utc::now().timestamp();
        encode(
            &header,
            &Claims {
                iss: "enablebanking.com",
                aud: "api.enablebanking.com",
                iat: now,
                exp: now + 3600,
            },
            &key,
        )
        .map_err(|e| CoreError::InvalidInput {
            message: format!("JWT: {e}"),
        })
    }

    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> CoreResult<Value> {
        let client = self.client.as_ref().ok_or(CoreError::SessionClosed)?;
        let mut req = client
            .request(method, format!("{API}{path}"))
            .bearer_auth(&self.jwt)
            .header("Accept", "application/json");
        if let Some(b) = body {
            req = req.json(&b);
        }
        let resp = req.send().await?;
        let status = resp.status();
        let v: Value = resp.json().await.unwrap_or(Value::Null);
        if !status.is_success() {
            let msg = v["message"]
                .as_str()
                .or(v["detail"].as_str())
                .unwrap_or("Enable Banking error")
                .to_string();
            return Err(if status.as_u16() == 401 || status.as_u16() == 403 {
                CoreError::Authentication { message: msg }
            } else {
                CoreError::Bank {
                    code: status.as_u16().to_string(),
                    message: msg,
                }
            });
        }
        Ok(v)
    }
}

/// A bank as listed by `GET /aspsps` (only what the picker needs).
pub(crate) fn parse_aspsps(v: &Value) -> Vec<(String, String)> {
    v["aspsps"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|b| {
                    // keep banks that offer personal accounts (field absent = keep)
                    b["psu_types"]
                        .as_array()
                        .map(|t| t.iter().any(|x| x.as_str() == Some("personal")))
                        .unwrap_or(true)
                })
                .filter_map(|b| {
                    Some((
                        b["name"].as_str()?.to_string(),
                        b["country"].as_str().unwrap_or_default().to_uppercase(),
                    ))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Exact ASPSP spelling for `wanted` from a `GET /aspsps` answer: a
/// case-insensitive match, else the single bank whose name contains / is
/// contained in `wanted`. `None` when nothing (or more than one) fits.
pub(crate) fn pick_aspsp_name(list: &Value, wanted: &str) -> Option<String> {
    let w = wanted.trim().to_lowercase();
    if w.is_empty() {
        return None;
    }
    let names: Vec<String> = parse_aspsps(list).into_iter().map(|(n, _)| n).collect();
    if let Some(n) = names.iter().find(|n| n.to_lowercase() == w) {
        return Some(n.clone());
    }
    let mut fuzzy = names.iter().filter(|n| {
        let l = n.to_lowercase();
        l.contains(&w) || w.contains(&l)
    });
    match (fuzzy.next(), fuzzy.next()) {
        (Some(n), None) => Some(n.clone()),
        _ => None,
    }
}

/// Accepts a full redirect URL ("https://…/callback?code=…&state=…") or a bare code.
fn extract_code(input: &str, expected_state: &str) -> CoreResult<String> {
    let input = input.trim();
    if let Ok(u) = url::Url::parse(input) {
        let mut code = None;
        let mut state = None;
        for (k, v) in u.query_pairs() {
            match k.as_ref() {
                "code" => code = Some(v.to_string()),
                "state" => state = Some(v.to_string()),
                "error" => {
                    return Err(CoreError::Authentication {
                        message: trf("Zustimmung verweigert: {0}", &[&v]),
                    })
                }
                _ => {}
            }
        }
        if let Some(s) = state {
            if !expected_state.is_empty() && s != expected_state {
                return Err(CoreError::Authentication {
                    message: tr("Status stimmt nicht überein – bitte die Zustimmung neu starten")
                        .into(),
                });
            }
        }
        return code.ok_or_else(|| CoreError::InvalidInput {
            message: tr("Kein „code“ in der eingefügten Adresse").into(),
        });
    }
    if input.is_empty() {
        return Err(CoreError::InvalidInput {
            message: tr("Bitte die Adresse einfügen, auf die Sie weitergeleitet wurden").into(),
        });
    }
    Ok(input.to_string())
}

#[async_trait]
impl BankConnector for EnableBankingConnector {
    async fn begin(&mut self, ctx: &ConnectContext) -> CoreResult<Phase> {
        self.jwt = Self::make_jwt(ctx)?;
        self.client = Some(http_client()?);
        if let Ok(st) = serde_json::from_value::<PsdState>(ctx.state.clone()) {
            self.st = st;
        }
        let now = chrono::Utc::now().to_rfc3339();
        if !self.st.session_id.is_empty() && self.st.valid_until > now {
            return Ok(Phase::Ready);
        }
        self.expected_state = uuid::Uuid::new_v4().to_string();
        let valid_until = (chrono::Utc::now() + chrono::Duration::days(90)).to_rfc3339();
        let configured = ctx
            .setting_or(self.aspsp_setting, &self.aspsp_default)
            .to_string();
        let country = ctx
            .setting_or(self.country_setting, &self.country_default)
            .to_string();
        // Amazon Visa is issued by Open Bank S.A. under the brand "Zinia": try both names.
        let mut names = vec![configured.clone()];
        // Generic banks come from our built-in catalog, whose names are
        // best-effort: ask the live ASPSP list for the exact spelling first.
        if self.aspsp_setting.is_empty() {
            if let Ok(list) = self
                .call(
                    reqwest::Method::GET,
                    &format!("/aspsps?country={country}"),
                    None,
                )
                .await
            {
                if let Some(exact) = pick_aspsp_name(&list, &configured) {
                    if exact != configured {
                        names.insert(0, exact);
                    }
                }
            }
        }
        for alt in ["Open Bank", "Zinia"] {
            if self.aspsp_setting.ends_with("amazonvisa")
                && !names.iter().any(|n| n.eq_ignore_ascii_case(alt))
            {
                names.push(alt.to_string());
            }
        }
        let mut last_err = None;
        let mut v = serde_json::Value::Null;
        for name in &names {
            let body = json!({
                "access": {"valid_until": valid_until},
                "aspsp": {"name": name, "country": country},
                "state": self.expected_state,
                "redirect_url": ctx.setting("enablebanking.redirect_url")?,
                "psu_type": "personal",
            });
            match self.call(reqwest::Method::POST, "/auth", Some(body)).await {
                Ok(r) => {
                    v = r;
                    last_err = None;
                    break;
                }
                // 4xx other than auth errors: probably unknown ASPSP name -> try the next one
                Err(CoreError::Bank { code, message }) if code.starts_with('4') => {
                    last_err = Some(CoreError::Bank {
                        code,
                        message: trf("ASPSP „{0}“: {1}", &[&name, &message]),
                    });
                }
                Err(e) => return Err(e),
            }
        }
        if let Some(e) = last_err {
            return Err(e);
        }
        let url = v["url"].as_str().ok_or_else(|| CoreError::Protocol {
            message: "no consent URL".into(),
        })?;
        Ok(Phase::Challenge(Challenge {
            kind: ChallengeKind::Redirect,
            title: tr("Zustimmung beim Kartenherausgeber erteilen").into(),
            message: tr("Seite öffnen, anmelden und Zugriff erlauben. Danach die Adresse einfügen, auf die der Browser weitergeleitet wurde.").into(),
            method_name: tr("PSD2-Weiterleitung").into(),
            redirect_url: Some(url.to_string()),
            image: None,
            expires_in_seconds: Some(900),
            poll_interval_seconds: 0,
        }))
    }

    async fn respond(
        &mut self,
        _ctx: &ConnectContext,
        response: ChallengeResponse,
    ) -> CoreResult<Phase> {
        let ChallengeResponse::Code(input) = response else {
            return Err(CoreError::InvalidInput {
                message: tr("Bitte die Weiterleitungsadresse einfügen").into(),
            });
        };
        let code = extract_code(input.expose(), &self.expected_state)?;
        let v = self
            .call(
                reqwest::Method::POST,
                "/sessions",
                Some(json!({"code": code})),
            )
            .await?;
        self.st.session_id = v["session_id"].as_str().unwrap_or_default().to_string();
        self.st.valid_until = v["access"]["valid_until"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        self.st.accounts = v["accounts"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .iter()
            .map(|a| {
                (
                    a["uid"].as_str().unwrap_or_default().to_string(),
                    a["name"]
                        .as_str()
                        .or(a["product"].as_str())
                        .unwrap_or(&self.aspsp_default)
                        .to_string(),
                    a["account_id"]["iban"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string(),
                    a["currency"].as_str().unwrap_or("EUR").to_string(),
                )
            })
            .collect();
        Ok(Phase::Ready)
    }

    async fn fetch(&mut self, ctx: &ConnectContext) -> CoreResult<FetchResult> {
        let mut out = FetchResult::default();
        for (uid, name, iban, currency) in self.st.accounts.clone() {
            let bal = self
                .call(
                    reqwest::Method::GET,
                    &format!("/accounts/{uid}/balances"),
                    None,
                )
                .await?;
            let balances = bal["balances"].as_array().cloned().unwrap_or_default();
            let pick = ["CLBD", "ITBD", "XPCD", "ITAV"]
                .iter()
                .find_map(|t| {
                    balances
                        .iter()
                        .find(|b| b["balance_type"].as_str() == Some(t))
                })
                .or(balances.first())
                .cloned()
                .unwrap_or(Value::Null);
            out.accounts.push(RemoteAccount {
                external_ref: uid.clone(),
                name: name.clone(),
                owner: String::new(),
                iban: iban.clone(),
                account_number: String::new(),
                currency: currency.clone(),
                kind: AccountKind::CreditCard,
                balance_cents: json_number_to_cents(&pick["balance_amount"]["amount"]).unwrap_or(0),
                balance_date: pick["reference_date"]
                    .as_str()
                    .map(|s| s.to_string())
                    .unwrap_or_else(super::today),
            });
            let mut continuation: Option<String> = None;
            let mut n = 0u32;
            for _ in 0..100 {
                let mut path = format!("/accounts/{uid}/transactions?date_from={}", ctx.since);
                if let Some(c) = &continuation {
                    path.push_str(&format!(
                        "&continuation_key={}",
                        url::form_urlencoded::byte_serialize(c.as_bytes()).collect::<String>()
                    ));
                }
                let page = self.call(reqwest::Method::GET, &path, None).await?;
                for t in page["transactions"].as_array().cloned().unwrap_or_default() {
                    if t["status"].as_str().map(|s| s != "BOOK").unwrap_or(false) {
                        continue;
                    }
                    let mut amount = json_number_to_cents(&t["transaction_amount"]["amount"])
                        .unwrap_or(0)
                        .abs();
                    if t["credit_debit_indicator"].as_str() == Some("DBIT") {
                        amount = -amount;
                    }
                    let party = if amount < 0 {
                        &t["creditor"]
                    } else {
                        &t["debtor"]
                    };
                    let party_acc = if amount < 0 {
                        &t["creditor_account"]
                    } else {
                        &t["debtor_account"]
                    };
                    let date = t["booking_date"]
                        .as_str()
                        .or(t["transaction_date"].as_str())
                        .unwrap_or_default()
                        .to_string();
                    let mut rt = RemoteTransaction {
                        account_ref: uid.clone(),
                        external_id: t["entry_reference"]
                            .as_str()
                            .or(t["transaction_id"].as_str())
                            .unwrap_or_default()
                            .to_string(),
                        booking_date: date.clone(),
                        value_date: t["value_date"].as_str().unwrap_or(&date).to_string(),
                        amount_cents: amount,
                        currency: t["transaction_amount"]["currency"]
                            .as_str()
                            .unwrap_or("EUR")
                            .to_string(),
                        counterparty: party["name"].as_str().unwrap_or_default().to_string(),
                        counterparty_iban: party_acc["iban"]
                            .as_str()
                            .unwrap_or_default()
                            .to_string(),
                        purpose: t["remittance_information"]
                            .as_array()
                            .map(|a| {
                                a.iter()
                                    .filter_map(|x| x.as_str())
                                    .collect::<Vec<_>>()
                                    .join(" ")
                            })
                            .unwrap_or_default(),
                        booking_text: t["bank_transaction_code"]["description"]
                            .as_str()
                            .unwrap_or_default()
                            .to_string(),
                    };
                    if rt.counterparty.is_empty() {
                        rt.counterparty = rt
                            .purpose
                            .split_whitespace()
                            .take(4)
                            .collect::<Vec<_>>()
                            .join(" ");
                    }
                    if rt.external_id.is_empty() {
                        rt.external_id = rt.content_id(n);
                    }
                    n += 1;
                    out.transactions.push(rt);
                }
                continuation = page["continuation_key"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string());
                if continuation.is_none() {
                    break;
                }
            }
        }
        out.state = Some(serde_json::to_value(&self.st)?);
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn aspsp_name_resolution() {
        use serde_json::json;
        let list = json!({"aspsps": [
            {"name": "N26 Bank", "country": "DE"},
            {"name": "Revolut", "country": "DE"},
            {"name": "Santander Consumer Bank", "country": "DE"},
            {"name": "Santander Bank Polska", "country": "DE"}
        ]});
        // exact, case-insensitive
        assert_eq!(
            super::pick_aspsp_name(&list, "revolut").as_deref(),
            Some("Revolut")
        );
        // unique partial match
        assert_eq!(
            super::pick_aspsp_name(&list, "N26").as_deref(),
            Some("N26 Bank")
        );
        // ambiguous / unknown / empty
        assert_eq!(super::pick_aspsp_name(&list, "Santander"), None);
        assert_eq!(super::pick_aspsp_name(&list, "Nope"), None);
        assert_eq!(super::pick_aspsp_name(&list, " "), None);
        assert_eq!(super::pick_aspsp_name(&json!({}), "N26"), None);
    }

    #[test]
    fn generic_connector_key() {
        use crate::models::ConnectorKind;
        let k = ConnectorKind::enable_banking_key("de", "N26");
        assert_eq!(k, "enablebanking:DE:N26");
        assert_eq!(
            ConnectorKind::from_str(&k),
            Some(ConnectorKind::EnableBanking)
        );
        assert_eq!(
            ConnectorKind::enable_banking_target(&k),
            Some(("DE", "N26"))
        );
        assert_eq!(
            ConnectorKind::enable_banking_target("enablebanking:AT:Erste Bank"),
            Some(("AT", "Erste Bank"))
        );
        // legacy keys keep their dedicated kinds
        assert_eq!(
            ConnectorKind::from_str("enablebanking:amex"),
            Some(ConnectorKind::AmericanExpress)
        );
        assert_eq!(
            ConnectorKind::enable_banking_target("enablebanking:amex"),
            None
        );
        assert_eq!(ConnectorKind::from_str("enablebanking:DEU:N26"), None);
        assert_eq!(ConnectorKind::from_str("enablebanking:DE:"), None);
    }
    #[test]
    fn extracts_code_from_redirect() {
        assert_eq!(
            super::extract_code("https://localhost/cb?code=abc&state=s1", "s1").unwrap(),
            "abc"
        );
        assert!(super::extract_code("https://localhost/cb?code=abc&state=bad", "s1").is_err());
        assert_eq!(super::extract_code(" xyz ", "s1").unwrap(), "xyz");
    }
}
