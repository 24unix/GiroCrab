//! bunq – official public API (doc.bunq.com), using the user's own API key.
//!
//! The user creates a personal API key in the bunq app (Profile → Settings →
//! Developers → API keys), so GiroCrab needs no PSD2/OAuth registration.
//!
//!  POST /v1/installation     RSA public key  -> installation token + server key
//!  POST /v1/device-server    API key          -> registers this Mac as a device
//!  POST /v1/session-server   API key (signed) -> session token + user id
//!  GET  /v1/user/{u}/monetary-account?count=200
//!  GET  /v1/user/{u}/monetary-account/{a}/payment?count=200 (+ Pagination.older_url)
//!
//! Requests with a body are signed (SHA-256, RSA PKCS#1 v1.5, base64 in
//! `X-Bunq-Client-Signature`); responses are verified against the server key
//! (`X-Bunq-Server-Signature`). Installation, device and session are kept in
//! the encrypted connector state so a sync normally needs one session check.

use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use base64::Engine as _;
use rsa::pkcs1v15::{Signature, SigningKey, VerifyingKey};
use rsa::pkcs8::{DecodePrivateKey, DecodePublicKey, EncodePrivateKey, EncodePublicKey, LineEnding};
use rsa::signature::{SignatureEncoding, Signer, Verifier};
use rsa::{RsaPrivateKey, RsaPublicKey};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use super::{
    http_client, BankConnector, Challenge, ChallengeKind, ChallengeResponse, ConnectContext,
    FetchResult, Phase, RemoteAccount, RemoteTransaction, TransferJob,
};
use crate::error::{CoreError, CoreResult};
use crate::i18n::{tr, trf};
use crate::models::AccountKind;
use crate::money::json_number_to_cents;

const PRODUCTION: &str = "https://api.bunq.com";
const SANDBOX: &str = "https://public-api.sandbox.bunq.com";
/// bunq allows 3 GET requests per 3 seconds per endpoint.
const MIN_GAP: Duration = Duration::from_millis(1050);
/// Safety cap so a broken pagination link can't loop forever.
const MAX_PAGES_PER_ACCOUNT: usize = 200;
/// Card holds and foreign-currency details are read for this many days back.
const HOLD_WINDOW_DAYS: i64 = 45;
/// At most this many extra calls per account to link foreign card actions to payments.
const MAX_FOREIGN_LOOKUPS: usize = 30;
/// external_id prefix of card holds; the vault replaces them on every sync.
pub(crate) const HOLD_PREFIX: &str = "pending-hold-bunq-";
/// Receipts (note attachments) are looked for on payments this many days old.
const RECEIPT_WINDOW_DAYS: i64 = 60;
/// Payments this recent are re-checked for new receipts on every sync.
const RECEIPT_RECHECK_DAYS: i64 = 7;
/// At most this many receipt lookups per sync (each is one rate-limited call).
const MAX_RECEIPT_LOOKUPS: usize = 30;
/// Remembered receipt checks (newest payment ids).
const MAX_RECEIPT_STATE: usize = 1000;
/// Monthly PDF statements: look back this many completed months …
const STATEMENT_MONTHS: u32 = 12;
/// … and create at most this many per sync (each export takes a few calls).
const MAX_STATEMENTS_PER_SYNC: usize = 3;

/// Persisted connector state (inside the encrypted vault).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
struct BunqState {
    /// "production" or "sandbox" – a change starts over.
    env: String,
    /// SHA-256 prefix of the API key – a new key starts over.
    key_fp: String,
    private_key_pem: String,
    installation_token: String,
    server_public_key: String,
    device_registered: bool,
    session_token: String,
    user_id: i64,
    /// Payment id -> `updated` timestamp when its receipts were last checked.
    receipts_checked: BTreeMap<i64, String>,
    /// Monthly statements already imported ("{account id}:{YYYY-MM}").
    statements_done: BTreeSet<String>,
}

pub struct BunqConnector {
    client: Option<reqwest::Client>,
    base: String,
    state: BunqState,
    last_request: Option<Instant>,
    /// Transfer waiting for approval in the bunq app.
    draft: Option<PendingDraft>,
    /// Account id -> local creation date (statements start there).
    account_created: BTreeMap<i64, String>,
}

/// A draft payment the user still has to accept in the bunq app.
#[derive(Debug, Clone)]
struct PendingDraft {
    account_id: i64,
    draft_id: i64,
    challenge: Challenge,
}

impl Default for BunqConnector {
    fn default() -> Self {
        Self::new()
    }
}

/// Error returned by bunq: HTTP status + `Error[0].error_description`.
#[derive(Debug)]
struct ApiError {
    status: u16,
    message: String,
}

impl ApiError {
    fn into_core(self) -> CoreError {
        match self.status {
            401 | 403 => CoreError::Authentication {
                message: format!(
                    "{} ({})",
                    tr("bunq hat den API-Schlüssel oder diese IP-Adresse abgelehnt. Erstellen Sie in der bunq-App einen API-Schlüssel mit „Alle IP-Adressen erlauben“ und tragen Sie ihn neu ein."),
                    self.message
                ),
            },
            _ => CoreError::Bank {
                code: self.status.to_string(),
                message: self.message,
            },
        }
    }
}

type ApiResult<T> = Result<T, ApiError>;

impl From<CoreError> for ApiError {
    fn from(e: CoreError) -> Self {
        ApiError {
            status: 0,
            message: e.to_string(),
        }
    }
}

impl BunqConnector {
    pub fn new() -> Self {
        BunqConnector {
            client: None,
            base: PRODUCTION.into(),
            state: BunqState::default(),
            last_request: None,
            draft: None,
            account_created: BTreeMap::new(),
        }
    }

    fn signing_key(&self) -> CoreResult<SigningKey<Sha256>> {
        let key = RsaPrivateKey::from_pkcs8_pem(&self.state.private_key_pem).map_err(|e| {
            CoreError::Protocol {
                message: format!("bunq key: {e}"),
            }
        })?;
        Ok(SigningKey::<Sha256>::new(key))
    }

    /// One API call. `auth` = token for `X-Bunq-Client-Authentication`.
    /// One API call returning the raw body and its content type.
    /// `body` = (bytes, content type); it is signed as sent.
    async fn send(
        &mut self,
        method: reqwest::Method,
        path: &str,
        body: Option<(Vec<u8>, &str)>,
        extra_headers: &[(&str, &str)],
        auth: Option<&str>,
    ) -> ApiResult<(Vec<u8>, String)> {
        let mut attempt = 0;
        loop {
            // Throttle: bunq rate limits are per endpoint and very low for GET.
            if let Some(last) = self.last_request {
                let elapsed = last.elapsed();
                if elapsed < MIN_GAP {
                    tokio::time::sleep(MIN_GAP - elapsed).await;
                }
            }
            self.last_request = Some(Instant::now());

            let client = self.client.as_ref().ok_or(CoreError::SessionClosed)?;
            let url = format!("{}{}", self.base, path);
            let mut req = client
                .request(method.clone(), &url)
                .header("Cache-Control", "no-cache")
                .header("X-Bunq-Client-Request-Id", uuid::Uuid::new_v4().to_string())
                .header("X-Bunq-Geolocation", "0 0 0 0 000")
                .header("X-Bunq-Language", "en_US")
                .header("X-Bunq-Region", "en_US");
            for (k, v) in extra_headers {
                req = req.header(*k, *v);
            }
            if let Some(token) = auth {
                req = req.header("X-Bunq-Client-Authentication", token);
            }
            if let Some((bytes, content_type)) = &body {
                // Sign exactly the bytes we send.
                if !self.state.private_key_pem.is_empty() {
                    let sig = self.signing_key()?.sign(bytes);
                    req = req.header(
                        "X-Bunq-Client-Signature",
                        base64::engine::general_purpose::STANDARD.encode(sig.to_bytes()),
                    );
                }
                req = req.header("Content-Type", *content_type).body(bytes.clone());
            }
            let resp = req.send().await.map_err(CoreError::from)?;
            let status = resp.status().as_u16();
            let header = |k: &str| {
                resp.headers()
                    .get(k)
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_string)
            };
            let server_sig = header("X-Bunq-Server-Signature");
            let content_type = header("Content-Type").unwrap_or_default();
            let raw = resp.bytes().await.map_err(CoreError::from)?.to_vec();

            if status == 429 && attempt < 4 {
                attempt += 1;
                tokio::time::sleep(Duration::from_secs(3 * attempt)).await;
                continue;
            }
            if !(200..300).contains(&status) {
                let v: Value = serde_json::from_slice(&raw).unwrap_or(Value::Null);
                return Err(ApiError {
                    status,
                    message: v["Error"][0]["error_description"]
                        .as_str()
                        .unwrap_or("bunq error")
                        .to_string(),
                });
            }
            self.verify_response(&raw, server_sig.as_deref())?;
            return Ok((raw, content_type));
        }
    }

    /// JSON API call. `auth` = token for `X-Bunq-Client-Authentication`.
    async fn call(
        &mut self,
        method: reqwest::Method,
        path: &str,
        body: Option<&Value>,
        auth: Option<&str>,
    ) -> ApiResult<Value> {
        let body = match body {
            Some(b) => Some((
                serde_json::to_vec(b).map_err(|e| CoreError::Protocol {
                    message: e.to_string(),
                })?,
                "application/json",
            )),
            None => None,
        };
        let (raw, _) = self.send(method, path, body, &[], auth).await?;
        Ok(serde_json::from_slice(&raw).unwrap_or(Value::Null))
    }

    /// Raw GET with the session token (attachments, statement files).
    async fn get_raw(&mut self, path: &str) -> ApiResult<(Vec<u8>, String)> {
        let token = self.state.session_token.clone();
        self.send(reqwest::Method::GET, path, None, &[], Some(&token)).await
    }

    /// Checks `X-Bunq-Server-Signature` (body only) once the server key is known.
    fn verify_response(&self, raw: &[u8], sig: Option<&str>) -> CoreResult<()> {
        if self.state.server_public_key.is_empty() {
            return Ok(()); // installation response itself
        }
        let invalid = || CoreError::Protocol {
            message: tr("Die Antwort von bunq ist nicht korrekt signiert.").into(),
        };
        let sig = sig.ok_or_else(invalid)?;
        let key = RsaPublicKey::from_public_key_pem(&self.state.server_public_key)
            .map_err(|_| invalid())?;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(sig)
            .map_err(|_| invalid())?;
        let sig = Signature::try_from(bytes.as_slice()).map_err(|_| invalid())?;
        VerifyingKey::<Sha256>::new(key)
            .verify(raw, &sig)
            .map_err(|_| invalid())
    }

    async fn get(&mut self, path: &str) -> ApiResult<Value> {
        let token = self.state.session_token.clone();
        self.call(reqwest::Method::GET, path, None, Some(&token)).await
    }

    /// POST /installation with a fresh 2048-bit key.
    async fn install(&mut self) -> CoreResult<()> {
        let key = tokio::task::spawn_blocking(|| {
            RsaPrivateKey::new(&mut rsa::rand_core::OsRng, 2048)
        })
        .await
        .map_err(|e| CoreError::Protocol {
            message: e.to_string(),
        })?
        .map_err(|e| CoreError::Protocol {
            message: format!("bunq key: {e}"),
        })?;
        let pem_err = |e: String| CoreError::Protocol { message: e };
        let public_pem = key
            .to_public_key()
            .to_public_key_pem(LineEnding::LF)
            .map_err(|e| pem_err(e.to_string()))?;
        self.state = BunqState {
            env: self.state.env.clone(),
            key_fp: self.state.key_fp.clone(),
            private_key_pem: key
                .to_pkcs8_pem(LineEnding::LF)
                .map_err(|e| pem_err(e.to_string()))?
                .to_string(),
            ..Default::default()
        };
        let v = self
            .call(
                reqwest::Method::POST,
                "/v1/installation",
                Some(&json!({ "client_public_key": public_pem })),
                None,
            )
            .await
            .map_err(ApiError::into_core)?;
        self.state.installation_token = find(&v, "Token")["token"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        self.state.server_public_key = find(&v, "ServerPublicKey")["server_public_key"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        if self.state.installation_token.is_empty() || self.state.server_public_key.is_empty() {
            return Err(CoreError::Protocol {
                message: "bunq installation: missing token".into(),
            });
        }
        Ok(())
    }

    /// POST /device-server. Asks for "any IP" first so the Mac keeps working
    /// when its address changes; keys bound to one IP fall back to that IP.
    async fn register_device(&mut self, api_key: &str) -> CoreResult<()> {
        let token = self.state.installation_token.clone();
        let mut body = json!({
            "description": "GiroCrab",
            "secret": api_key,
            "permitted_ips": ["*"],
        });
        let first = self
            .call(reqwest::Method::POST, "/v1/device-server", Some(&body), Some(&token))
            .await;
        if let Err(e) = first {
            if e.status != 400 {
                return Err(e.into_core());
            }
            body.as_object_mut().unwrap().remove("permitted_ips");
            self.call(reqwest::Method::POST, "/v1/device-server", Some(&body), Some(&token))
                .await
                .map_err(ApiError::into_core)?;
        }
        self.state.device_registered = true;
        Ok(())
    }

    /// POST /session-server -> session token + user id.
    async fn open_session(&mut self, api_key: &str) -> ApiResult<()> {
        let token = self.state.installation_token.clone();
        let v = self
            .call(
                reqwest::Method::POST,
                "/v1/session-server",
                Some(&json!({ "secret": api_key })),
                Some(&token),
            )
            .await?;
        let session = find(&v, "Token")["token"].as_str().unwrap_or_default();
        let user_id = ["UserPerson", "UserCompany", "UserPaymentServiceProvider", "UserApiKey"]
            .iter()
            .find_map(|k| find(&v, k)["id"].as_i64())
            .unwrap_or(0);
        if session.is_empty() || user_id == 0 {
            return Err(CoreError::Protocol {
                message: "bunq session: missing token or user".into(),
            }
            .into());
        }
        self.state.session_token = session.to_string();
        self.state.user_id = user_id;
        Ok(())
    }

    /// Reuses the stored session if it is still valid.
    async fn session_alive(&mut self) -> bool {
        if self.state.session_token.is_empty() || self.state.user_id == 0 {
            return false;
        }
        let path = format!("/v1/user/{}", self.state.user_id);
        self.get(&path).await.is_ok()
    }

    async fn accounts(&mut self) -> CoreResult<Vec<(i64, RemoteAccount)>> {
        let path = format!("/v1/user/{}/monetary-account?count=200", self.state.user_id);
        let v = self.get(&path).await.map_err(ApiError::into_core)?;
        let today = super::today();
        let mut out = Vec::new();
        for item in v["Response"].as_array().into_iter().flatten() {
            if let Some((id, acc)) = parse_account(item, &today) {
                let created = item
                    .as_object()
                    .and_then(|o| o.values().next())
                    .and_then(|a| a["created"].as_str())
                    .and_then(local_date);
                if let Some(c) = created {
                    self.account_created.insert(id, c);
                }
                out.push((id, acc));
            }
        }
        Ok(out)
    }

    /// Pages through a bunq list (newest first) and returns the objects under
    /// `key` created on/after `since` (local date).
    async fn list_since(&mut self, first: String, key: &str, since: &str) -> CoreResult<Vec<Value>> {
        let mut out = Vec::new();
        let mut path = Some(first);
        let mut pages = 0;
        while let Some(p) = path.take() {
            pages += 1;
            let v = self.get(&p).await.map_err(ApiError::into_core)?;
            let mut reached_since = false;
            for item in v["Response"].as_array().into_iter().flatten() {
                let obj = &item[key];
                let Some(date) = obj["created"].as_str().and_then(local_date) else {
                    continue;
                };
                if date.as_str() < since {
                    reached_since = true; // newest first: everything after is older
                    continue;
                }
                out.push(obj.clone());
            }
            if !reached_since && pages < MAX_PAGES_PER_ACCOUNT {
                path = v["Pagination"]["older_url"].as_str().map(str::to_string);
            }
        }
        Ok(out)
    }

    /// Raw `Payment` objects created on/after `since`.
    async fn raw_payments(&mut self, account_id: i64, since: &str) -> CoreResult<Vec<Value>> {
        let first = format!(
            "/v1/user/{}/monetary-account/{account_id}/payment?count=200",
            self.state.user_id
        );
        self.list_since(first, "Payment", since).await
    }

    /// Downloads one attachment. Only the user-level path works for reading
    /// (`…/monetary-account/{a}/attachment/{id}/content` answers 405).
    async fn attachment(&mut self, attachment_id: i64) -> CoreResult<(Vec<u8>, String)> {
        let path = format!(
            "/v1/user/{}/attachment/{attachment_id}/content",
            self.state.user_id
        );
        self.get_raw(&path).await.map_err(ApiError::into_core)
    }

    /// Receipts of recent payments: files sent with the payment plus the
    /// ones the user attached in the bunq app (note attachments).
    async fn receipts(
        &mut self,
        account_id: i64,
        account_ref: &str,
        payments: &[Value],
    ) -> Vec<crate::documents::RemoteDocument> {
        let today = chrono::Local::now().date_naive();
        let days_ago = |p: &Value| {
            p["created"]
                .as_str()
                .and_then(local_date)
                .and_then(|d| chrono::NaiveDate::parse_from_str(&d, "%Y-%m-%d").ok())
                .map(|d| (today - d).num_days())
                .unwrap_or(i64::MAX)
        };
        // Receipt lookups cost one call each: never-checked payments first,
        // then recent ones again (receipts are usually added within days;
        // adding one does not change the payment's `updated`).
        let mut fresh = Vec::new();
        let mut recheck = Vec::new();
        for p in payments {
            let (Some(pid), age) = (p["id"].as_i64(), days_ago(p)) else {
                continue;
            };
            let updated = p["updated"].as_str().unwrap_or_default();
            if age > RECEIPT_WINDOW_DAYS {
                continue;
            }
            if self.state.receipts_checked.get(&pid).map(String::as_str) != Some(updated) {
                fresh.push(pid);
            } else if age <= RECEIPT_RECHECK_DAYS {
                recheck.push(pid);
            }
        }
        let lookup: BTreeSet<i64> = fresh
            .into_iter()
            .chain(recheck)
            .take(MAX_RECEIPT_LOOKUPS)
            .collect();
        let mut docs = Vec::new();
        for p in payments {
            let Some(pid) = p["id"].as_i64() else {
                continue;
            };
            let date = p["created"].as_str().and_then(local_date).unwrap_or_default();
            let ext = format!("bunq-{pid}");
            let label = receipt_label(p);
            // 1) attachments sent along with the payment (no extra listing call)
            let mut found: Vec<(i64, String)> = attachment_items(&p["attachment"])
                .into_iter()
                .filter_map(|a| Some((a["id"].as_i64()?, String::new())))
                .collect();
            // 2) receipts added in the app (one call per payment, so limited)
            let updated = p["updated"].as_str().unwrap_or_default().to_string();
            if lookup.contains(&pid) {
                let path = format!(
                    "/v1/user/{}/monetary-account/{account_id}/payment/{pid}/note-attachment",
                    self.state.user_id
                );
                if let Ok(v) = self.get(&path).await {
                    for item in v["Response"].as_array().into_iter().flatten() {
                        let note = item
                            .as_object()
                            .and_then(|o| o.values().next())
                            .unwrap_or(&Value::Null);
                        let desc = note["description"].as_str().unwrap_or_default().to_string();
                        // The API returns one object here (the spec says array).
                        for a in attachment_items(&note["attachment"]) {
                            if let Some(aid) = a["id"].as_i64() {
                                found.push((aid, desc.clone()));
                            }
                        }
                    }
                    self.state.receipts_checked.insert(pid, updated);
                }
            }
            found.dedup_by_key(|(aid, _)| *aid);
            for (aid, desc) in found {
                let source_url = format!("bunq:attachment:{aid}");
                let Ok((bytes, content_type)) = self.attachment(aid).await else {
                    continue;
                };
                if bytes.is_empty() {
                    continue;
                }
                docs.push(receipt_document(
                    account_ref, &ext, &date, &label, &desc, aid, bytes, &content_type, source_url,
                ));
            }
        }
        // Keep the state small: bunq ids grow over time, so drop the oldest.
        while self.state.receipts_checked.len() > MAX_RECEIPT_STATE {
            self.state.receipts_checked.pop_first();
        }
        docs
    }

    /// Monthly PDF statements of completed months not imported yet.
    async fn statements(
        &mut self,
        account_id: i64,
        account: &RemoteAccount,
    ) -> Vec<crate::documents::RemoteDocument> {
        let mut docs = Vec::new();
        let today = chrono::Local::now().date_naive();
        let mut created = 0;
        for (first, last) in completed_months(today, STATEMENT_MONTHS) {
            if created >= MAX_STATEMENTS_PER_SYNC {
                break;
            }
            // No statements for months before the account was opened.
            let opened = self.account_created.get(&account_id).cloned().unwrap_or_default();
            if last.format("%Y-%m-%d").to_string() < opened {
                break; // older months are earlier still
            }
            let key = format!("{account_id}:{}", first.format("%Y-%m"));
            if self.state.statements_done.contains(&key) {
                continue;
            }
            created += 1;
            match self.export_statement(account_id, first, last).await {
                Ok(bytes) => {
                    docs.push(statement_document(account, account_id, first, last, bytes));
                    self.state.statements_done.insert(key);
                }
                // Months before the account existed are refused: don't retry them.
                Err(e) if e.status == 400 => {
                    self.state.statements_done.insert(key);
                }
                Err(_) => break, // try again next sync
            }
        }
        docs
    }

    /// POST customer-statement, wait until bunq has rendered it, download the PDF.
    async fn export_statement(
        &mut self,
        account_id: i64,
        first: chrono::NaiveDate,
        last: chrono::NaiveDate,
    ) -> ApiResult<Vec<u8>> {
        let base = format!(
            "/v1/user/{}/monetary-account/{account_id}/customer-statement",
            self.state.user_id
        );
        let token = self.state.session_token.clone();
        let body = json!({
            "statement_format": "PDF",
            "date_start": first.format("%Y-%m-%d").to_string(),
            "date_end": last.format("%Y-%m-%d").to_string(),
            "include_attachment": false,
        });
        let v = self
            .call(reqwest::Method::POST, &base, Some(&body), Some(&token))
            .await?;
        let id = find(&v, "Id")["id"].as_i64().ok_or_else(|| ApiError {
            status: 0,
            message: "bunq statement: missing id".into(),
        })?;
        let mut result = Err(ApiError {
            status: 0,
            message: "bunq statement not ready".into(),
        });
        for attempt in 0..8u64 {
            if attempt > 0 {
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
            match self.get_raw(&format!("{base}/{id}/content")).await {
                Ok((bytes, _)) if bytes.starts_with(b"%PDF") => {
                    result = Ok(bytes);
                    break;
                }
                Ok(_) => continue, // not rendered yet
                Err(e) if e.status >= 500 || e.status == 404 || e.status == 400 => continue,
                Err(e) => {
                    result = Err(e);
                    break;
                }
            }
        }
        // The export itself is no longer needed at bunq.
        let _ = self
            .call(reqwest::Method::DELETE, &format!("{base}/{id}"), None, Some(&token))
            .await;
        result
    }

    /// Card authorisations (MasterCardAction) of the last weeks.
    async fn card_actions(&mut self, account_id: i64, since: &str) -> CoreResult<Vec<Value>> {
        let first = format!(
            "/v1/user/{}/monetary-account/{account_id}/mastercard-action?count=200",
            self.state.user_id
        );
        self.list_since(first, "MasterCardAction", since).await
    }

    /// Payment ids booked for a card action (`…/mastercard-action/{id}/payment`).
    async fn payments_of_action(&mut self, account_id: i64, action_id: i64) -> CoreResult<Vec<i64>> {
        let path = format!(
            "/v1/user/{}/monetary-account/{account_id}/mastercard-action/{action_id}/payment",
            self.state.user_id
        );
        let v = self.get(&path).await.map_err(ApiError::into_core)?;
        Ok(v["Response"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|item| item.as_object()?.values().next()?["id"].as_i64())
            .collect())
    }

    /// Open card holds as "vorgemerkt" bookings plus the original currency
    /// of foreign card payments (appended to the purpose).
    async fn card_details(
        &mut self,
        account_id: i64,
        account: &RemoteAccount,
        payments: &mut [RemoteTransaction],
    ) -> CoreResult<Vec<RemoteTransaction>> {
        // Always the full window: an old hold (hotel, rental car) must not
        // vanish just because this sync only asks for recent bookings.
        // Foreign-currency notes are therefore added for recent payments only.
        let window = chrono::Local::now().date_naive() - chrono::Duration::days(HOLD_WINDOW_DAYS);
        let window = window.format("%Y-%m-%d").to_string();
        let actions = self.card_actions(account_id, &window).await?;
        let now = chrono::Utc::now().naive_utc();
        let mut holds = Vec::new();
        let mut lookups = 0;
        for a in &actions {
            if is_open_hold(a, now) {
                if let Some(t) = parse_hold(a, &account.external_ref) {
                    holds.push(t);
                }
                continue;
            }
            let Some(note) = foreign_amount_note(a, &account.currency) else {
                continue;
            };
            if lookups >= MAX_FOREIGN_LOOKUPS {
                continue;
            }
            lookups += 1;
            let Some(action_id) = a["id"].as_i64() else {
                continue;
            };
            for pid in self.payments_of_action(account_id, action_id).await.unwrap_or_default() {
                let ext = format!("bunq-{pid}");
                if let Some(t) = payments.iter_mut().find(|t| t.external_id == ext) {
                    if !t.purpose.contains(&note) {
                        t.purpose = if t.purpose.is_empty() {
                            note.clone()
                        } else {
                            format!("{} · {note}", t.purpose)
                        };
                    }
                }
            }
        }
        Ok(holds)
    }

    fn draft_path(&self, account_id: i64, draft_id: Option<i64>) -> String {
        let base = format!(
            "/v1/user/{}/monetary-account/{account_id}/draft-payment",
            self.state.user_id
        );
        match draft_id {
            Some(id) => format!("{base}/{id}"),
            None => base,
        }
    }

    /// Current status of the pending draft: PENDING, ACCEPTED, REJECTED, EXPIRED.
    async fn draft_status(&mut self, d: &PendingDraft) -> CoreResult<String> {
        let path = self.draft_path(d.account_id, Some(d.draft_id));
        let v = self.get(&path).await.map_err(ApiError::into_core)?;
        Ok(find(&v, "DraftPayment")["status"]
            .as_str()
            .unwrap_or_default()
            .to_string())
    }
}

/// Cents -> bunq decimal string ("-12.5" is never sent; always "12.50").
fn cents_to_decimal(cents: i64) -> String {
    let sign = if cents < 0 { "-" } else { "" };
    let c = cents.unsigned_abs();
    format!("{sign}{}.{:02}", c / 100, c % 100)
}

/// Finds the object wrapped under `key` in a bunq `Response` array.
fn find<'a>(v: &'a Value, key: &str) -> &'a Value {
    v["Response"]
        .as_array()
        .and_then(|a| a.iter().find(|o| o.get(key).is_some()))
        .map(|o| &o[key])
        .unwrap_or(&Value::Null)
}

fn key_fingerprint(api_key: &str) -> String {
    hex::encode(&Sha256::digest(api_key.as_bytes())[..8])
}

/// `{"MonetaryAccountBank": {...}}` -> (bunq id, account).
fn parse_account(item: &Value, today: &str) -> Option<(i64, RemoteAccount)> {
    let (wrapper, a) = item.as_object()?.iter().next()?;
    let id = a["id"].as_i64()?;
    if matches!(a["status"].as_str(), Some("CANCELLED")) {
        return None;
    }
    let iban_alias = a["alias"]
        .as_array()
        .and_then(|al| al.iter().find(|x| x["type"] == "IBAN"));
    let kind = if wrapper == "MonetaryAccountSavings" {
        AccountKind::Savings
    } else {
        AccountKind::Checking
    };
    Some((
        id,
        RemoteAccount {
            external_ref: format!("bunq:{id}"),
            name: a["description"].as_str().unwrap_or("bunq").to_string(),
            owner: iban_alias
                .and_then(|x| x["name"].as_str())
                .or(a["display_name"].as_str())
                .unwrap_or_default()
                .to_string(),
            iban: iban_alias
                .and_then(|x| x["value"].as_str())
                .unwrap_or_default()
                .to_string(),
            account_number: String::new(),
            currency: a["currency"].as_str().unwrap_or("EUR").to_string(),
            kind,
            balance_cents: json_number_to_cents(&a["balance"]["value"]).unwrap_or(0),
            balance_date: today.to_string(),
        },
    ))
}

/// Signed amount in the account currency: card purchases are debits.
fn card_amount_cents(a: &Value) -> Option<i64> {
    let cents = json_number_to_cents(&a["amount_billing"]["value"]).ok()?;
    let kind = a["authorisation_type"].as_str().unwrap_or_default().to_uppercase();
    let credit = ["REFUND", "CREDIT", "RETURN"].iter().any(|k| kind.contains(k));
    Some(if credit { cents.abs() } else { -cents.abs() })
}

/// Allowed authorisation that has not been cleared (booked) or expired yet.
fn is_open_hold(a: &Value, now: chrono::NaiveDateTime) -> bool {
    if a["decision"].as_str() != Some("ALLOWED") {
        return false;
    }
    if !matches!(a["clearing_status"].as_str(), Some("PENDING") | None) {
        return false;
    }
    if a["payment_status"].as_str().is_some_and(|s| s.contains("FAIL")) {
        return false;
    }
    let expired = |k: &str| {
        a[k].as_str()
            .and_then(|t| chrono::NaiveDateTime::parse_from_str(t, "%Y-%m-%d %H:%M:%S%.f").ok())
            .is_some_and(|t| t < now)
    };
    !(expired("reservation_expiry_time") || expired("clearing_expiry_time"))
}

fn parse_hold(a: &Value, account_ref: &str) -> Option<RemoteTransaction> {
    let id = a["id"].as_i64()?;
    let date = local_date(a["created"].as_str()?)?;
    let amount = card_amount_cents(a)?;
    if amount == 0 {
        return None;
    }
    let counterparty = a["counterparty_alias"]["display_name"]
        .as_str()
        .filter(|s| !s.is_empty())
        .or(a["description"].as_str())
        .unwrap_or_default()
        .trim()
        .to_string();
    let mut purpose = a["description"].as_str().unwrap_or_default().trim().to_string();
    if let Some(note) = foreign_amount_note(a, a["amount_billing"]["currency"].as_str().unwrap_or("EUR")) {
        purpose = if purpose.is_empty() { note } else { format!("{purpose} · {note}") };
    }
    Some(RemoteTransaction {
        account_ref: account_ref.to_string(),
        external_id: format!("{HOLD_PREFIX}{id}"),
        booking_date: date.clone(),
        value_date: date,
        amount_cents: amount,
        currency: a["amount_billing"]["currency"].as_str().unwrap_or("EUR").to_string(),
        counterparty,
        counterparty_iban: String::new(),
        purpose,
        booking_text: format!("{} ({})", tr("Kartenzahlung"), tr("vorgemerkt")),
    })
}

/// "Originalbetrag 12,00 USD" when the merchant charged a foreign currency.
fn foreign_amount_note(a: &Value, account_currency: &str) -> Option<String> {
    let local = &a["amount_local"];
    let ccy = local["currency"].as_str()?;
    if ccy.is_empty() || ccy.eq_ignore_ascii_case(account_currency) {
        return None;
    }
    let cents = json_number_to_cents(&local["value"]).ok()?.abs();
    Some(trf(
        "Originalbetrag {0}",
        &[&crate::money::format_cents(cents, ccy.to_string())],
    ))
}

/// bunq returns attachments as an array or as a single object.
fn attachment_items(v: &Value) -> Vec<&Value> {
    match v {
        Value::Array(items) => items.iter().collect(),
        Value::Object(_) => vec![v],
        _ => Vec::new(),
    }
}

/// Short label for a payment's receipt: counterparty or description.
fn receipt_label(p: &Value) -> String {
    let cp = &p["counterparty_alias"];
    cp["display_name"]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .or(cp["label_user"]["display_name"].as_str())
        .or(p["description"].as_str())
        .unwrap_or("bunq")
        .trim()
        .to_string()
}

fn extension_for(mime: &str) -> &'static str {
    match mime {
        "application/pdf" => "pdf",
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "image/heic" => "heic",
        _ => "bin",
    }
}

/// File-name safe: letters, digits, '-' and '_' only.
fn slug(s: &str) -> String {
    let out: String = s
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' { c } else { '_' })
        .collect();
    out.trim_matches('_').chars().take(40).collect()
}

#[allow(clippy::too_many_arguments)]
fn receipt_document(
    account_ref: &str,
    booking_ext: &str,
    date: &str,
    label: &str,
    description: &str,
    attachment_id: i64,
    bytes: Vec<u8>,
    content_type: &str,
    source_url: String,
) -> crate::documents::RemoteDocument {
    let ct = content_type.split(';').next().unwrap_or_default().trim().to_lowercase();
    let mime = if ct.is_empty() || ct == "application/octet-stream" || ct == "application/json" {
        crate::documents::sniff_mime(&bytes, "")
    } else {
        ct
    };
    let title = if description.trim().is_empty() {
        trf("Beleg {0}", &[&label])
    } else {
        description.trim().to_string()
    };
    crate::documents::RemoteDocument {
        account_ref: account_ref.to_string(),
        booking_external_id: Some(booking_ext.to_string()),
        title,
        doc_type: "beleg".into(),
        file_name: format!("{date}_{}_{attachment_id}.{}", slug(label), extension_for(&mime)),
        mime_type: mime,
        bytes,
        source_url,
        date: date.to_string(),
    }
}

fn statement_document(
    account: &RemoteAccount,
    account_id: i64,
    first: chrono::NaiveDate,
    last: chrono::NaiveDate,
    bytes: Vec<u8>,
) -> crate::documents::RemoteDocument {
    let month = first.format("%Y-%m").to_string();
    crate::documents::RemoteDocument {
        account_ref: account.external_ref.clone(),
        booking_external_id: None,
        title: trf("Kontoauszug {0} – {1}", &[&month, &account.name]),
        doc_type: "kontoauszug".into(),
        mime_type: "application/pdf".into(),
        file_name: format!("{month}_bunq_{}.pdf", slug(&account.name)),
        bytes,
        source_url: format!("bunq:statement:{account_id}:{month}"),
        date: last.format("%Y-%m-%d").to_string(),
    }
}

/// The `n` most recent completed calendar months as (first day, last day), newest first.
fn completed_months(today: chrono::NaiveDate, n: u32) -> Vec<(chrono::NaiveDate, chrono::NaiveDate)> {
    use chrono::Datelike;
    let mut out = Vec::new();
    let mut first_of_this = today.with_day(1).unwrap_or(today);
    for _ in 0..n {
        let last = first_of_this.pred_opt().unwrap_or(first_of_this);
        let first = last.with_day(1).unwrap_or(last);
        out.push((first, last));
        first_of_this = first;
    }
    out
}

/// bunq timestamps are UTC ("2026-11-10 12:34:56.123456"); bookings use the local date.
fn local_date(ts: &str) -> Option<String> {
    let naive = chrono::NaiveDateTime::parse_from_str(ts, "%Y-%m-%d %H:%M:%S%.f").ok()?;
    let local = naive.and_utc().with_timezone(&chrono::Local);
    Some(local.format("%Y-%m-%d").to_string())
}

fn booking_text(kind: &str, sub_type: &str) -> String {
    let base = match kind {
        "MASTERCARD" | "MAESTRO" | "FIS" => tr("Kartenzahlung"),
        "IDEAL" => "iDEAL",
        "EBA_SCT" | "SWIFT" => tr("Überweisung"),
        "EBA_SDD" | "DIRECT_DEBIT" => tr("Lastschrift"),
        "INTEREST" => tr("Zinsen"),
        "SAVINGS" => tr("Sparen"),
        "BUNQ" => "bunq",
        other => return other.to_string(),
    };
    match sub_type {
        "REVERSAL" => format!("{base} ({})", tr("Rückbuchung")),
        "WITHDRAWAL" => format!("{base} ({})", tr("Abhebung")),
        _ => base.to_string(),
    }
}

fn parse_payment(p: &Value, account_ref: &str) -> Option<RemoteTransaction> {
    let id = p["id"].as_i64()?;
    let date = local_date(p["created"].as_str()?)?;
    let cp = &p["counterparty_alias"];
    let counterparty = cp["display_name"]
        .as_str()
        .filter(|s| !s.is_empty())
        .or(cp["label_user"]["display_name"].as_str())
        .unwrap_or_default();
    Some(RemoteTransaction {
        account_ref: account_ref.to_string(),
        external_id: format!("bunq-{id}"),
        booking_date: date.clone(),
        value_date: date,
        amount_cents: json_number_to_cents(&p["amount"]["value"]).ok()?,
        currency: p["amount"]["currency"].as_str().unwrap_or("EUR").to_string(),
        counterparty: counterparty.trim().to_string(),
        counterparty_iban: cp["iban"].as_str().unwrap_or_default().to_string(),
        purpose: p["description"].as_str().unwrap_or_default().trim().to_string(),
        booking_text: booking_text(
            p["type"].as_str().unwrap_or_default(),
            p["sub_type"].as_str().unwrap_or_default(),
        ),
    })
}

#[async_trait]
impl BankConnector for BunqConnector {
    async fn begin(&mut self, ctx: &ConnectContext) -> CoreResult<Phase> {
        let api_key = ctx.secret.expose().trim().to_string();
        if api_key.is_empty() {
            return Err(CoreError::Authentication {
                message: tr("Bitte den bunq-API-Schlüssel eingeben.").into(),
            });
        }
        let env = if ctx.setting_or("bunq.environment", "production") == "sandbox" {
            "sandbox"
        } else {
            "production"
        };
        self.base = if env == "sandbox" { SANDBOX } else { PRODUCTION }.into();
        self.client = Some(http_client()?);

        let fp = key_fingerprint(&api_key);
        let stored: BunqState = serde_json::from_value(ctx.state.clone()).unwrap_or_default();
        self.state = if stored.env == env && stored.key_fp == fp {
            stored
        } else {
            BunqState {
                env: env.into(),
                key_fp: fp,
                ..Default::default()
            }
        };

        if self.session_alive().await {
            return Ok(Phase::Ready);
        }
        self.state.session_token.clear();
        if !self.state.installation_token.is_empty() && self.state.device_registered {
            if self.open_session(&api_key).await.is_ok() {
                return Ok(Phase::Ready);
            }
        }
        // Start over: new key pair, installation, device and session.
        self.install().await?;
        self.register_device(&api_key).await?;
        self.open_session(&api_key)
            .await
            .map_err(ApiError::into_core)?;
        Ok(Phase::Ready)
    }

    /// Polls the draft payment until it is accepted in the bunq app.
    async fn respond(
        &mut self,
        _ctx: &ConnectContext,
        _response: ChallengeResponse,
    ) -> CoreResult<Phase> {
        let Some(d) = self.draft.clone() else {
            return Ok(Phase::Ready);
        };
        match self.draft_status(&d).await?.as_str() {
            "ACCEPTED" | "DEPRECATED_ACCEPTED_PENDING_PAYMENT" => {
                self.draft = None;
                Ok(Phase::Ready)
            }
            "PENDING" | "" => Ok(Phase::Pending(d.challenge)),
            _ => {
                self.draft = None;
                Err(CoreError::Bank {
                    code: "draft".into(),
                    message: tr("bunq hat die Überweisung abgelehnt oder sie wurde abgebrochen.")
                        .into(),
                })
            }
        }
    }

    /// Creates a draft payment; the user approves it in the bunq app, so
    /// GiroCrab can never move money without a tap on the phone.
    async fn send_transfer(&mut self, _ctx: &ConnectContext, job: &TransferJob) -> CoreResult<Phase> {
        let source = job.source_iban.replace(' ', "").to_uppercase();
        let account_id = self
            .accounts()
            .await?
            .into_iter()
            .find(|(_, a)| a.iban.replace(' ', "").to_uppercase() == source)
            .map(|(id, _)| id)
            .ok_or_else(|| CoreError::InvalidInput {
                message: tr("Das Quellkonto wurde bei bunq nicht gefunden.").into(),
            })?;
        let body = json!({
            "entries": [{
                "amount": {"value": cents_to_decimal(job.amount_cents), "currency": "EUR"},
                "counterparty_alias": {
                    "type": "IBAN",
                    "value": job.recipient_iban,
                    "name": job.recipient_name,
                },
                "description": job.purpose,
            }],
            "number_of_required_accepts": 1,
        });
        let token = self.state.session_token.clone();
        let path = self.draft_path(account_id, None);
        let v = self
            .call(reqwest::Method::POST, &path, Some(&body), Some(&token))
            .await
            .map_err(ApiError::into_core)?;
        let draft_id = find(&v, "Id")["id"].as_i64().ok_or_else(|| CoreError::Protocol {
            message: "bunq draft-payment: missing id".into(),
        })?;
        let challenge = Challenge {
            kind: ChallengeKind::DecoupledPush,
            title: tr("Überweisung in der bunq-App freigeben").into(),
            message: trf(
                "{0} an {1}: Bitte öffnen Sie die bunq-App und bestätigen Sie die Zahlung.",
                &[
                    &crate::money::format_cents(job.amount_cents, "EUR".into()),
                    &job.recipient_name,
                ],
            ),
            method_name: tr("Freigabe in der bunq-App").into(),
            redirect_url: None,
            image: None,
            expires_in_seconds: None,
            poll_interval_seconds: 3,
        };
        self.draft = Some(PendingDraft {
            account_id,
            draft_id,
            challenge: challenge.clone(),
        });
        Ok(Phase::Challenge(challenge))
    }

    /// Cancelled in GiroCrab while still pending: withdraw the draft at bunq
    /// so it can't be approved later by accident. Best effort.
    async fn finish(&mut self, _ctx: &ConnectContext) {
        if let Some(d) = self.draft.take() {
            let path = self.draft_path(d.account_id, Some(d.draft_id));
            let token = self.state.session_token.clone();
            let _ = self
                .call(
                    reqwest::Method::PUT,
                    &path,
                    Some(&json!({"status": "REJECTED"})),
                    Some(&token),
                )
                .await;
        }
    }

    async fn fetch(&mut self, ctx: &ConnectContext) -> CoreResult<FetchResult> {
        let mut out = FetchResult {
            hold_prefix: Some(HOLD_PREFIX.into()),
            ..Default::default()
        };
        for (id, account) in self.accounts().await? {
            let raw = self.raw_payments(id, &ctx.since).await?;
            let mut txs: Vec<RemoteTransaction> = raw
                .iter()
                .filter_map(|p| parse_payment(p, &account.external_ref))
                .collect();
            // Receipts and statements are extras: a failure must not break the sync.
            let receipts = self.receipts(id, &account.external_ref, &raw).await;
            out.documents.extend(receipts);
            let statements = self.statements(id, &account).await;
            out.documents.extend(statements);
            // Accounts without a card can refuse this endpoint: holds are optional.
            let holds = self
                .card_details(id, &account, &mut txs)
                .await
                .unwrap_or_default();
            out.transactions.extend(txs);
            out.transactions.extend(holds);
            out.accounts.push(account);
        }
        out.state = Some(serde_json::to_value(&self.state).unwrap_or(Value::Null));
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_accounts_and_payments() {
        let acc = json!({"MonetaryAccountSavings": {
            "id": 42, "description": "Rücklagen", "currency": "EUR", "status": "ACTIVE",
            "balance": {"value": "1234.56", "currency": "EUR"},
            "alias": [{"type": "EMAIL", "value": "x@example.com"},
                      {"type": "IBAN", "value": "NL00BUNQ0000000000", "name": "Erika Mustermann"}]
        }});
        let (id, a) = parse_account(&acc, "2026-11-10").unwrap();
        assert_eq!(id, 42);
        assert_eq!(a.external_ref, "bunq:42");
        assert_eq!(a.kind, AccountKind::Savings);
        assert_eq!(a.balance_cents, 123_456);
        assert_eq!(a.iban, "NL00BUNQ0000000000");
        assert_eq!(a.owner, "Erika Mustermann");

        let cancelled = json!({"MonetaryAccountBank": {"id": 1, "status": "CANCELLED"}});
        assert!(parse_account(&cancelled, "2026-11-10").is_none());

        let pay = json!({
            "id": 7, "created": "2026-11-09 12:00:00.000000",
            "amount": {"value": "-12.50", "currency": "EUR"},
            "description": " Lunch ", "type": "MASTERCARD", "sub_type": "PAYMENT",
            "counterparty_alias": {"display_name": "Café", "iban": null}
        });
        let t = parse_payment(&pay, "bunq:42").unwrap();
        assert_eq!(t.external_id, "bunq-7");
        assert_eq!(t.amount_cents, -1_250);
        assert_eq!(t.counterparty, "Café");
        assert_eq!(t.purpose, "Lunch");
        assert_eq!(t.booking_date, "2026-11-09");
        assert_eq!(t.booking_text, tr("Kartenzahlung"));
    }

    #[test]
    fn signature_roundtrip_and_find() {
        let key = RsaPrivateKey::new(&mut rsa::rand_core::OsRng, 1024).unwrap();
        let mut c = BunqConnector::new();
        c.state.private_key_pem = key.to_pkcs8_pem(LineEnding::LF).unwrap().to_string();
        c.state.server_public_key = key
            .to_public_key()
            .to_public_key_pem(LineEnding::LF)
            .unwrap();
        let body = br#"{"Response":[{"Id":{"id":1}},{"Token":{"token":"abc"}}]}"#;
        let sig = base64::engine::general_purpose::STANDARD
            .encode(c.signing_key().unwrap().sign(body).to_bytes());
        assert!(c.verify_response(body, Some(&sig)).is_ok());
        assert!(c.verify_response(b"tampered", Some(&sig)).is_err());
        assert!(c.verify_response(body, None).is_err());
        let v: Value = serde_json::from_slice(body).unwrap();
        assert_eq!(find(&v, "Token")["token"], "abc");
        assert_eq!(key_fingerprint("k").len(), 16);
    }

    #[test]
    fn card_holds_and_foreign_amounts() {
        let now = chrono::NaiveDateTime::parse_from_str("2026-11-10 12:00:00.0", "%Y-%m-%d %H:%M:%S%.f").unwrap();
        let mut a = json!({
            "id": 99, "created": "2026-11-08 10:00:00.000000",
            "amount_local": {"value": "20.00", "currency": "USD"},
            "amount_billing": {"value": "18.70", "currency": "EUR"},
            "decision": "ALLOWED", "clearing_status": "PENDING",
            "authorisation_type": "NORMAL_AUTHORISATION",
            "reservation_expiry_time": "2026-11-20 10:00:00.000000",
            "description": "NYC Deli", "counterparty_alias": {"display_name": "NYC Deli"}
        });
        assert!(is_open_hold(&a, now));
        let t = parse_hold(&a, "bunq:1").unwrap();
        assert_eq!(t.external_id, "pending-hold-bunq-99");
        assert_eq!(t.amount_cents, -1_870);
        assert!(t.purpose.contains("USD"), "{}", t.purpose);
        assert!(t.booking_text.contains(tr("vorgemerkt")));
        assert_eq!(foreign_amount_note(&a, "EUR"), Some(trf("Originalbetrag {0}", &[&crate::money::format_cents(2_000, "USD".into())])));
        assert_eq!(foreign_amount_note(&a, "USD"), None);

        a["amount_billing"]["value"] = json!("-18.70");
        assert_eq!(card_amount_cents(&a), Some(-1_870));
        a["authorisation_type"] = json!("REFUND");
        assert_eq!(card_amount_cents(&a), Some(1_870));

        a["clearing_status"] = json!("FIRST_PRESENTMENT_COMPLETE");
        assert!(!is_open_hold(&a, now), "cleared = booked");
        a["clearing_status"] = json!("PENDING");
        a["decision"] = json!("INSUFFICIENT_BALANCE");
        assert!(!is_open_hold(&a, now), "declined");
        a["decision"] = json!("ALLOWED");
        a["reservation_expiry_time"] = json!("2026-11-01 00:00:00.000000");
        assert!(!is_open_hold(&a, now), "expired");
    }

    #[test]
    fn receipts_and_statement_documents() {
        let d = |s: &str| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap();
        let months = completed_months(d("2026-03-15"), 3);
        assert_eq!(
            months,
            vec![
                (d("2026-02-01"), d("2026-02-28")),
                (d("2026-01-01"), d("2026-01-31")),
                (d("2025-12-01"), d("2025-12-31")),
            ]
        );
        let doc = receipt_document(
            "bunq:1", "bunq-7", "2026-11-09", "Café Ü/1", "", 55,
            b"%PDF-1.4 x".to_vec(), "application/octet-stream", "bunq:attachment:55".into(),
        );
        assert_eq!(doc.mime_type, "application/pdf");
        assert_eq!(doc.file_name, "2026-11-09_Café_Ü_1_55.pdf");
        assert_eq!(doc.booking_external_id.as_deref(), Some("bunq-7"));
        assert_eq!(doc.doc_type, "beleg");
        let png = receipt_document("bunq:1", "bunq-7", "2026-11-09", "x", "Kassenbon", 56,
            vec![1, 2], "image/png; charset=binary", "bunq:attachment:56".into());
        assert_eq!((png.mime_type.as_str(), png.title.as_str()), ("image/png", "Kassenbon"));

        let acc = RemoteAccount {
            external_ref: "bunq:1".into(), name: "Main account".into(), owner: String::new(),
            iban: String::new(), account_number: String::new(), currency: "EUR".into(),
            kind: AccountKind::Checking, balance_cents: 0, balance_date: String::new(),
        };
        let st = statement_document(&acc, 1, d("2026-10-01"), d("2026-10-31"), b"%PDF".to_vec());
        assert_eq!(st.source_url, "bunq:statement:1:2026-10");
        assert_eq!(st.file_name, "2026-10_bunq_Main_account.pdf");
        assert_eq!((st.doc_type.as_str(), st.date.as_str()), ("kontoauszug", "2026-10-31"));
        // Old stored state without the new fields still loads.
        let old: BunqState = serde_json::from_value(json!({"env": "sandbox", "user_id": 5})).unwrap();
        assert_eq!(old.user_id, 5);
        assert!(old.statements_done.is_empty());
    }

    #[test]
    fn decimal_amounts() {
        assert_eq!(cents_to_decimal(1_234), "12.34");
        assert_eq!(cents_to_decimal(5), "0.05");
        assert_eq!(cents_to_decimal(-100), "-1.00");
    }

    /// Minimal valid RGB PNG (bunq rejects tiny or malformed images).
    fn test_png(w: u32, h: u32) -> Vec<u8> {
        fn crc32(data: &[u8]) -> u32 {
            let mut c = 0xffff_ffffu32;
            for &b in data {
                c ^= b as u32;
                for _ in 0..8 {
                    c = if c & 1 != 0 { 0xedb8_8320 ^ (c >> 1) } else { c >> 1 };
                }
            }
            !c
        }
        fn chunk(out: &mut Vec<u8>, kind: &[u8], data: &[u8]) {
            out.extend((data.len() as u32).to_be_bytes());
            let mut body = kind.to_vec();
            body.extend(data);
            out.extend(&body);
            out.extend(crc32(&body).to_be_bytes());
        }
        let mut raw = Vec::new();
        for y in 0..h {
            raw.push(0); // filter: none
            for x in 0..w {
                raw.extend([(x * 2) as u8, (y * 2) as u8, 0x80]);
            }
        }
        let mut ihdr = Vec::new();
        ihdr.extend(w.to_be_bytes());
        ihdr.extend(h.to_be_bytes());
        ihdr.extend([8, 2, 0, 0, 0]);
        let mut out = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
        chunk(&mut out, b"IHDR", &ihdr);
        chunk(&mut out, b"IDAT", &miniz_oxide::deflate::compress_to_vec_zlib(&raw, 6));
        chunk(&mut out, b"IEND", &[]);
        out
    }

    /// Live check against the bunq sandbox:
    /// `BUNQ_SANDBOX_KEY=sandbox_... cargo test -p girocrab-core bunq_sandbox -- --ignored --nocapture`
    #[tokio::test]
    #[ignore]
    async fn bunq_sandbox_live() {
        use crate::secret::SecretString;
        let key = std::env::var("BUNQ_SANDBOX_KEY").expect("BUNQ_SANDBOX_KEY");
        let mut settings = std::collections::HashMap::new();
        settings.insert("bunq.environment".to_string(), SecretString::new("sandbox".into()));
        let mut ctx = ConnectContext {
            connection_id: 1,
            login_name: String::new(),
            secret: SecretString::new(key),
            settings,
            state: Value::Null,
            since: "2020-01-01".into(),
        };
        let mut c = BunqConnector::new();
        assert!(matches!(c.begin(&ctx).await.unwrap(), Phase::Ready));
        let r = c.fetch(&ctx).await.unwrap();
        println!("accounts: {:?}", r.accounts);
        let (acc_id, _) = c.accounts().await.unwrap()[0].clone();
        // Ask the sandbox "Sugar Daddy" for money so there is a payment to read.
        let token = c.state.session_token.clone();
        let path = format!("/v1/user/{}/monetary-account/{acc_id}/request-inquiry", c.state.user_id);
        let body = json!({
            "amount_inquired": {"value": "12.34", "currency": "EUR"},
            "counterparty_alias": {"type": "EMAIL", "value": "sugardaddy@bunq.com", "name": "Sugar Daddy"},
            "description": "GiroCrab test",
            "allow_bunqme": false
        });
        c.call(reqwest::Method::POST, &path, Some(&body), Some(&token)).await.unwrap();
        tokio::time::sleep(Duration::from_secs(3)).await;
        let r = c.fetch(&ctx).await.unwrap();
        println!("transactions: {:#?}", r.transactions);
        assert!(r.transactions.iter().any(|t| t.amount_cents == 1_234));
        // Receipt: upload a PNG, attach it to the Sugar Daddy payment as a note,
        // and expect the next sync to deliver it as a booking document.
        let png = test_png(100, 100);
        let png_ref: &[u8] = &png;
        // Notes can't be added to the incoming request payment: pay 0.10 out first.
        let pay_path = format!("/v1/user/{}/monetary-account/{acc_id}/payment", c.state.user_id);
        let v = c
            .call(
                reqwest::Method::POST,
                &pay_path,
                Some(&json!({
                    "amount": {"value": "0.10", "currency": "EUR"},
                    "counterparty_alias": {"type": "EMAIL", "value": "sugardaddy@bunq.com", "name": "Sugar Daddy"},
                    "description": "GiroCrab receipt test"
                })),
                Some(&token),
            )
            .await
            .unwrap();
        let pid = find(&v, "Id")["id"].as_i64().unwrap();
        let pay_ext = format!("bunq-{pid}");
        let up_path = format!("/v1/user/{}/monetary-account/{acc_id}/attachment", c.state.user_id);
        let (up, _) = c
            .send(
                reqwest::Method::POST,
                &up_path,
                Some((png.clone(), "image/png")),
                &[("X-Bunq-Attachment-Description", "Kassenbon")],
                Some(&token),
            )
            .await
            .unwrap();
        let up: Value = serde_json::from_slice(&up).unwrap();
        let att_id = find(&up, "Id")["id"].as_i64().unwrap();
        let note_path = format!(
            "/v1/user/{}/monetary-account/{acc_id}/payment/{pid}/note-attachment",
            c.state.user_id
        );
        c.call(
            reqwest::Method::POST,
            &note_path,
            Some(&json!({"attachment_id": att_id, "description": "Kassenbon"})),
            Some(&token),
        )
        .await
        .unwrap();
        let r = c.fetch(&ctx).await.unwrap();
        for d in &r.documents {
            println!("document: {} {} {} {} bytes", d.doc_type, d.title, d.file_name, d.bytes.len());
        }
        let receipt = r.documents.iter().find(|d| d.doc_type == "beleg").expect("receipt");
        assert_eq!(receipt.booking_external_id.as_deref(), Some(pay_ext.as_str()));
        assert!(receipt.bytes.starts_with(&png_ref[..8]), "PNG expected");
        assert_eq!(receipt.mime_type, "image/png");
        // Statement for the current month (the account is too new for a completed one).
        let today = chrono::Local::now().date_naive();
        use chrono::Datelike;
        let pdf = c
            .export_statement(acc_id, today.with_day(1).unwrap(), today)
            .await
            .unwrap_or_else(|e| panic!("statement: {} {}", e.status, e.message));
        assert!(pdf.starts_with(b"%PDF"));
        println!("statement pdf: {} bytes", pdf.len());

        // Second sync reuses the stored session.
        ctx.state = r.state.unwrap();
        let token_before = ctx.state["session_token"].clone();
        let mut c2 = BunqConnector::new();
        assert!(matches!(c2.begin(&ctx).await.unwrap(), Phase::Ready));
        assert_eq!(Value::String(c2.state.session_token.clone()), token_before);

        // Transfer: draft payment stays pending (no app in the sandbox), then
        // cancelling in GiroCrab withdraws it at bunq.
        let iban = r.accounts[0].iban.clone();
        let job = TransferJob {
            source_iban: iban,
            source_owner: String::new(),
            recipient_name: "Sugar Daddy".into(),
            recipient_iban: "NL32BUNQ2025313705".into(),
            recipient_bic: None,
            amount_cents: 1_00,
            purpose: "GiroCrab draft test".into(),
        };
        let phase = c2.send_transfer(&ctx, &job).await.unwrap();
        assert!(matches!(phase, Phase::Challenge(ref ch) if ch.kind == ChallengeKind::DecoupledPush));
        let d = c2.draft.clone().unwrap();
        let polled = c2.respond(&ctx, ChallengeResponse::Poll).await.unwrap();
        assert!(matches!(polled, Phase::Pending(_)));
        c2.finish(&ctx).await;
        assert!(c2.draft.is_none());
        let status = c2.draft_status(&d).await.unwrap();
        println!("draft status after cancel: {status}");
        assert_eq!(status, "REJECTED");
    }

    /// Prints only the card-action status values and amount signs of a real
    /// account (no names, amounts or descriptions) to check `is_open_hold`:
    /// `BUNQ_API_KEY=... cargo test -p girocrab-core bunq_card_survey -- --ignored --nocapture`
    #[tokio::test]
    #[ignore]
    async fn bunq_card_survey() {
        use crate::secret::SecretString;
        let key = std::env::var("BUNQ_API_KEY").expect("BUNQ_API_KEY");
        let ctx = ConnectContext {
            connection_id: 1,
            login_name: String::new(),
            secret: SecretString::new(key),
            settings: Default::default(),
            state: Value::Null,
            since: "2020-01-01".into(),
        };
        let mut c = BunqConnector::new();
        c.begin(&ctx).await.unwrap();
        let window = (chrono::Local::now().date_naive() - chrono::Duration::days(HOLD_WINDOW_DAYS))
            .format("%Y-%m-%d")
            .to_string();
        let now = chrono::Utc::now().naive_utc();
        let mut seen = std::collections::BTreeMap::new();
        for (id, acc) in c.accounts().await.unwrap() {
            let actions = match c.card_actions(id, &window).await {
                Ok(a) => a,
                Err(e) => {
                    println!("account {}: card actions unavailable ({e})", acc.kind.as_str());
                    continue;
                }
            };
            for a in &actions {
                let f = |k: &str| a[k].as_str().unwrap_or("-").to_string();
                let sign = match json_number_to_cents(&a["amount_billing"]["value"]) {
                    Ok(c) if c < 0 => "neg",
                    Ok(_) => "pos",
                    Err(_) => "?",
                };
                let foreign = foreign_amount_note(a, &acc.currency).is_some();
                // Days relative to now (negative = past), rounded; "-" if absent.
                let rel = |k: &str| match a[k].as_str() {
                    None => "none".to_string(),
                    Some(t) => match chrono::NaiveDateTime::parse_from_str(t, "%Y-%m-%d %H:%M:%S%.f") {
                        Ok(t) => format!("{:+}d", (t - now).num_days()),
                        Err(_) => format!("unparsed({})", t.len()),
                    },
                };
                let linked = match a["id"].as_i64() {
                    Some(aid) => c.payments_of_action(id, aid).await.map(|p| p.len().to_string()).unwrap_or_else(|_| "err".into()),
                    None => "?".into(),
                };
                let row = format!(
                    "decision={} auth_status={} auth_type={} payment_status={} clearing={} settlement={} billing_sign={sign} foreign={foreign} created={} reservation_expiry={} clearing_expiry={} linked_payments={linked} => open_hold={}",
                    f("decision"), f("authorisation_status"), f("authorisation_type"),
                    f("payment_status"), f("clearing_status"), f("settlement_status"),
                    rel("created"), rel("reservation_expiry_time"), rel("clearing_expiry_time"),
                    is_open_hold(a, now)
                );
                *seen.entry(row).or_insert(0) += 1;
            }
        }
        for (row, n) in seen {
            println!("{n:>4}x {row}");
        }
    }
}
