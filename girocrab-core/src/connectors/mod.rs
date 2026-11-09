//! Modular two-phase bank connectors.
//!
//! Phase 1 `begin()` logs in. It either finishes (`Phase::Ready`) or returns a
//! `Challenge` the user must answer: a decoupled push-TAN (approve in the
//! banking app, then we poll), a code (SMS/app TAN, 2FA PIN) or a redirect
//! (PSD2 consent in the browser).
//!
//! Phase 2 `respond()` answers the challenge (or polls the decoupled one) and
//! again returns `Ready` or another `Challenge`.
//!
//! Once ready, `fetch()` downloads accounts and transactions, which the
//! `SyncSession` merges into the vault and runs the categorisation rules over.

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use rusqlite::{params, OptionalExtension};
use tokio::sync::Mutex as AsyncMutex;

use crate::error::{CoreError, CoreResult};
use crate::models::{AccountKind, ConnectorKind};
use crate::secret::SecretString;
use crate::vault::Vault;

pub mod comdirect;
pub mod demo;
pub mod enable_banking;
pub mod fints;
pub mod paypal;
pub mod portal_import;
pub mod template;
pub mod trade_republic;

// ------------------------------------------------------------------ FFI types

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ChallengeKind {
    /// Approve in the bank's app (FinTS decoupled, comdirect P_TAN_PUSH).
    /// The UI shows a spinner and calls `poll()` every few seconds.
    DecoupledPush,
    /// Type a code (SMS/app TAN, Trade Republic 2FA PIN).
    Code,
    /// Scan a photoTAN/chipTAN image, then type the code.
    ImageCode,
    /// Open `redirect_url` in the browser, then paste the resulting URL/code.
    Redirect,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Challenge {
    pub kind: ChallengeKind,
    pub title: String,
    pub message: String,
    /// Name of the TAN method ("SecureGo plus", "pushTAN", "SMS") if known.
    pub method_name: String,
    pub redirect_url: Option<String>,
    /// PNG/JPEG bytes for photoTAN (ImageCode).
    pub image: Option<Vec<u8>>,
    /// Seconds until the challenge expires, if the bank says so.
    pub expires_in_seconds: Option<u32>,
    /// Recommended poll interval for DecoupledPush.
    pub poll_interval_seconds: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SyncSummary {
    pub accounts_updated: u32,
    pub transactions_imported: u32,
    pub transactions_categorized: u32,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum SyncStep {
    NeedsChallenge {
        challenge: Challenge,
    },
    /// Decoupled approval not yet given; keep polling.
    StillWaiting {
        challenge: Challenge,
    },
    Finished {
        summary: SyncSummary,
    },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct BankDescriptor {
    pub kind: ConnectorKind,
    pub name: String,
    pub protocol: String,
    pub bank_code: String,
    /// SF Symbol shown instead of a proprietary bank logo.
    pub sf_symbol: String,
    pub login_label: String,
    pub secret_label: String,
    /// Setting keys that must be filled before a sync can start.
    pub required_settings: Vec<String>,
    pub note: String,
}

/// The seven institutions with their public protocol facts.
#[uniffi::export]
pub fn bank_catalog() -> Vec<BankDescriptor> {
    ConnectorKind::all().into_iter().map(descriptor).collect()
}

pub fn descriptor(kind: ConnectorKind) -> BankDescriptor {
    let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    match kind {
        ConnectorKind::VolksbankKasselGoettingen => BankDescriptor {
            kind,
            name: "Volksbank Kassel Göttingen".into(),
            protocol: "FinTS 3.0 PIN/TAN".into(),
            bank_code: "52090000".into(),
            sf_symbol: "building.columns.fill".into(),
            login_label: "VR-NetKey oder Alias".into(),
            secret_label: "Online-Banking-PIN".into(),
            required_settings: s(&["fints.product_id", "fints.url.52090000"]),
            note: "Freigabe in der SecureGo-plus-App (Decoupled, TAN-Prozess 4, HKTAN v7). Server: fints1.atruvia.de".into(),
        },
        ConnectorKind::Direkt1822 => BankDescriptor {
            kind,
            name: "1822direkt".into(),
            protocol: "FinTS 3.0 PIN/TAN".into(),
            bank_code: "50050201".into(),
            sf_symbol: "building.columns".into(),
            login_label: "Anmeldename / Kontonummer".into(),
            secret_label: "Online-Banking-PIN".into(),
            required_settings: s(&["fints.product_id", "fints.url.50050201"]),
            note: "pushTAN-App (Decoupled) oder chipTAN. Server: banking-hs5.s-fints-pt-hs.de".into(),
        },
        ConnectorKind::Comdirect => BankDescriptor {
            kind,
            name: "comdirect".into(),
            protocol: "comdirect REST-API (OAuth2 + Session-TAN)".into(),
            bank_code: "20041111".into(),
            sf_symbol: "building.2".into(),
            login_label: "Zugangsnummer".into(),
            secret_label: "PIN".into(),
            required_settings: s(&["comdirect.client_id", "comdirect.client_secret"]),
            note: "Session-TAN per photoTAN-Push, photoTAN-Grafik oder mobileTAN.".into(),
        },
        ConnectorKind::PayPal => BankDescriptor {
            kind,
            name: "PayPal".into(),
            protocol: "PayPal Transaction Search REST-API".into(),
            bank_code: String::new(),
            sf_symbol: "p.circle".into(),
            login_label: "E-Mail (nur Anzeige)".into(),
            secret_label: "(nicht nötig – nutzt Ihre REST-App)".into(),
            required_settings: s(&["paypal.client_id", "paypal.client_secret"]),
            note: "OAuth2 Client Credentials; Historie in 31-Tage-Fenstern.".into(),
        },
        ConnectorKind::TradeRepublic => BankDescriptor {
            kind,
            name: "Trade Republic".into(),
            protocol: "WebSocket-API + 2FA".into(),
            bank_code: String::new(),
            sf_symbol: "chart.line.uptrend.xyaxis.circle".into(),
            login_label: "Telefonnummer (+49…)".into(),
            secret_label: "4-stellige App-PIN".into(),
            required_settings: vec![],
            note: "Web-Login mit 4-stelligem Code aus der App/SMS. Inoffizielle Schnittstelle – kann sich jederzeit ändern.".into(),
        },
        ConnectorKind::AmericanExpress => BankDescriptor {
            kind,
            name: "American Express".into(),
            protocol: "Direkt-Login (Web-Session) oder CSV/PDF-Kontoauszug".into(),
            bank_code: String::new(),
            sf_symbol: "creditcard.fill".into(),
            login_label: "Kartenbezeichnung".into(),
            secret_label: "(Anmeldung im Browser-Fenster)".into(),
            required_settings: vec![],
            note: "Anmeldung im eingebetteten Browser (Benutzername, Passwort, 2FA wie gewohnt) – keine API-Schlüssel nötig. Optional: eigene PSD2-/Enable-Banking-API unter „Erweitert“.".into(),
        },
        ConnectorKind::AmazonVisa => BankDescriptor {
            kind,
            name: "Amazon Visa".into(),
            protocol: "Direkt-Login (Web-Session) oder CSV/PDF-Kontoauszug".into(),
            bank_code: String::new(),
            sf_symbol: "creditcard".into(),
            login_label: "Kartenbezeichnung".into(),
            secret_label: "(Anmeldung im Browser-Fenster)".into(),
            required_settings: vec![],
            note: "Herausgeber: Open Bank S.A. (Zinia). Anmeldung im eingebetteten Browser – keine API-Schlüssel nötig. Optional: eigene PSD2-/Enable-Banking-API unter „Erweitert“.".into(),
        },
    }
}

// ------------------------------------------------------------------ connector trait

/// Answer to a challenge.
#[derive(Debug)]
pub enum ChallengeResponse {
    /// Ask the bank whether the decoupled approval happened.
    Poll,
    /// Code typed by the user (TAN, 2FA PIN, redirect URL/code).
    Code(SecretString),
}

#[derive(Debug)]
pub enum Phase {
    Ready,
    Challenge(Challenge),
    /// Decoupled approval still pending.
    Pending(Challenge),
}

/// Everything a connector needs to log in. Secrets are wiped on drop.
pub struct ConnectContext {
    pub connection_id: i64,
    pub login_name: String,
    pub secret: SecretString,
    /// Resolved settings (product ID, API keys ...), secrets included.
    pub settings: HashMap<String, SecretString>,
    /// Opaque connector state persisted between syncs (FinTS system id, PSD2 session ...).
    pub state: serde_json::Value,
    /// Fetch transactions booked on or after this date (YYYY-MM-DD).
    pub since: String,
}

impl ConnectContext {
    pub fn setting(&self, key: &str) -> CoreResult<&str> {
        self.settings
            .get(key)
            .map(|s| s.expose())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| CoreError::MissingSetting {
                key: key.to_string(),
            })
    }
    pub fn setting_or<'a>(&'a self, key: &str, default: &'a str) -> &'a str {
        self.settings
            .get(key)
            .map(|s| s.expose())
            .filter(|s| !s.is_empty())
            .unwrap_or(default)
    }
}

#[derive(Debug, Clone)]
pub struct RemoteAccount {
    /// Stable id at the bank (IBAN, account id, PSD2 uid).
    pub external_ref: String,
    pub name: String,
    pub owner: String,
    pub iban: String,
    pub account_number: String,
    pub currency: String,
    pub kind: AccountKind,
    pub balance_cents: i64,
    pub balance_date: String,
}

#[derive(Debug, Clone)]
pub struct RemoteTransaction {
    pub account_ref: String,
    /// De-duplication key; derived from bank ids or a content hash.
    pub external_id: String,
    pub booking_date: String,
    pub value_date: String,
    pub amount_cents: i64,
    pub currency: String,
    pub counterparty: String,
    pub counterparty_iban: String,
    pub purpose: String,
    pub booking_text: String,
}

impl RemoteTransaction {
    /// Content-based id for banks that don't deliver a transaction id.
    pub fn content_id(&self, occurrence: u32) -> String {
        use std::hash::{Hash, Hasher};
        let mut h = std::collections::hash_map::DefaultHasher::new();
        (
            &self.booking_date,
            &self.value_date,
            self.amount_cents,
            &self.counterparty,
            &self.purpose,
            occurrence,
        )
            .hash(&mut h);
        format!("h{:016x}", h.finish())
    }
}

#[derive(Debug, Default)]
pub struct FetchResult {
    pub accounts: Vec<RemoteAccount>,
    pub transactions: Vec<RemoteTransaction>,
    /// Updated connector state to persist.
    pub state: Option<serde_json::Value>,
    /// Keep stored balances and add newly imported bookings to them
    /// (for sources that don't report a balance).
    pub adjust_balances: bool,
    /// PDFs fetched from the bank (trade confirmations, PostBox, statements).
    pub documents: Vec<crate::documents::RemoteDocument>,
}

#[async_trait]
pub trait BankConnector: Send {
    /// Phase 1: log in, possibly returning a challenge.
    async fn begin(&mut self, ctx: &ConnectContext) -> CoreResult<Phase>;
    /// Phase 2: answer or poll a challenge.
    async fn respond(
        &mut self,
        ctx: &ConnectContext,
        response: ChallengeResponse,
    ) -> CoreResult<Phase>;
    /// Download accounts + transactions (only valid after `Ready`).
    async fn fetch(&mut self, ctx: &ConnectContext) -> CoreResult<FetchResult>;
    /// Close the bank session (FinTS dialog end, logout). Best effort.
    async fn finish(&mut self, _ctx: &ConnectContext) {}
}

pub fn make_connector(kind: ConnectorKind, demo: bool) -> Box<dyn BankConnector> {
    if demo {
        return Box::new(demo::DemoConnector::new(kind));
    }
    match kind {
        ConnectorKind::VolksbankKasselGoettingen => {
            Box::new(fints::FinTsConnector::new("52090000"))
        }
        ConnectorKind::Direkt1822 => Box::new(fints::FinTsConnector::new("50050201")),
        ConnectorKind::Comdirect => Box::new(comdirect::ComdirectConnector::new()),
        ConnectorKind::PayPal => Box::new(paypal::PayPalConnector::new()),
        ConnectorKind::TradeRepublic => Box::new(trade_republic::TradeRepublicConnector::new()),
        ConnectorKind::AmericanExpress => Box::new(enable_banking::EnableBankingConnector::new(
            "enablebanking.aspsp.amex",
            "American Express",
            "enablebanking.country.amex",
        )),
        ConnectorKind::AmazonVisa => Box::new(enable_banking::EnableBankingConnector::new(
            "enablebanking.aspsp.amazonvisa",
            "Open Bank",
            "enablebanking.country.amazonvisa",
        )),
    }
}

pub(crate) fn http_client() -> CoreResult<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .user_agent(concat!(
            "GiroCrab/",
            env!("CARGO_PKG_VERSION"),
            " (open source; +https://github.com/)"
        ))
        .timeout(std::time::Duration::from_secs(60))
        .cookie_store(true)
        .build()?)
}

pub(crate) fn today() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}

// ------------------------------------------------------------------ sync session (FFI object)

struct SessionState {
    connector: Box<dyn BankConnector>,
    ctx: ConnectContext,
    done: bool,
}

/// One sync run for one bank connection. Created by `Vault::begin_sync`.
#[derive(uniffi::Object)]
pub struct SyncSession {
    vault: Arc<Vault>,
    kind: ConnectorKind,
    state: AsyncMutex<SessionState>,
}

impl SyncSession {
    async fn advance(
        &self,
        phase: CoreResult<Phase>,
        st: &mut SessionState,
    ) -> CoreResult<SyncStep> {
        match phase {
            Err(e) => {
                st.done = true;
                st.connector.finish(&st.ctx).await;
                Err(e)
            }
            Ok(Phase::Challenge(c)) => Ok(SyncStep::NeedsChallenge { challenge: c }),
            Ok(Phase::Pending(c)) => Ok(SyncStep::StillWaiting { challenge: c }),
            Ok(Phase::Ready) => {
                let fetched = st.connector.fetch(&st.ctx).await;
                st.connector.finish(&st.ctx).await;
                st.done = true;
                let fetched = fetched?;
                let summary = self.store(st.ctx.connection_id, fetched)?;
                Ok(SyncStep::Finished { summary })
            }
        }
    }

    fn store(&self, connection_id: i64, data: FetchResult) -> CoreResult<SyncSummary> {
        store_fetch(&self.vault, self.kind, connection_id, data)
    }
}

/// Persists accounts, bookings and documents of one fetch (shared by bank
/// syncs and the keyless web-portal / statement import).
pub(crate) fn store_fetch(
    vault: &Vault,
    kind: ConnectorKind,
    connection_id: i64,
    data: FetchResult,
) -> CoreResult<SyncSummary> {
    {
        let db = vault.db()?;
        let tx = db.unchecked_transaction()?;
        let bank_name = descriptor(kind).name;
        let mut data = data;
        // safety net for every connector: repair UTF-8/Latin-1 mojibake
        for a in &mut data.accounts {
            a.name = crate::text::clean_bank_text(&a.name);
            a.owner = crate::text::clean_bank_text(&a.owner);
        }
        for t in &mut data.transactions {
            t.counterparty = crate::text::clean_bank_text(&t.counterparty);
            t.purpose = crate::text::clean_bank_text(&t.purpose);
            t.booking_text = crate::text::clean_bank_text(&t.booking_text);
        }
        let mut account_ids: HashMap<String, i64> = HashMap::new();
        let mut accounts_updated = 0u32;
        for acc in &data.accounts {
            let existing: Option<i64> = tx
                .query_row(
                    "SELECT id FROM accounts WHERE connection_id = ?1 AND external_ref = ?2",
                    params![connection_id, acc.external_ref],
                    |r| r.get(0),
                )
                .optional()?;
            let id = match existing {
                Some(id) => {
                    if !data.adjust_balances {
                        tx.execute(
                            "UPDATE accounts SET balance_cents = ?1, balance_date = ?2, currency = ?3 WHERE id = ?4",
                            params![acc.balance_cents, acc.balance_date, acc.currency, id],
                        )?;
                    }
                    id
                }
                None => {
                    let (group, sym, order) = group_for(acc.kind);
                    let gid = Vault::ensure_group(&tx, group, sym, order)?;
                    tx.execute(
                        "INSERT INTO accounts(connection_id, group_id, external_ref, name, bank_name, owner, iban, account_number, currency, kind,
                                              balance_cents, balance_date, sf_symbol, sort_order)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, (SELECT IFNULL(MAX(sort_order),0)+1 FROM accounts))",
                        params![connection_id, gid, acc.external_ref, acc.name, bank_name, acc.owner, acc.iban, acc.account_number,
                                acc.currency, acc.kind.as_str(), acc.balance_cents, acc.balance_date, acc.kind.sf_symbol()],
                    )?;
                    tx.last_insert_rowid()
                }
            };
            accounts_updated += 1;
            account_ids.insert(acc.external_ref.clone(), id);
        }
        let mut imported = 0u32;
        {
            let mut ins = tx.prepare(
                "INSERT OR IGNORE INTO transactions(account_id, external_id, booking_date, value_date, amount_cents, currency,
                         counterparty, counterparty_iban, purpose, booking_text)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            )?;
            for t in &data.transactions {
                let Some(acc_id) = account_ids.get(&t.account_ref) else {
                    continue;
                };
                let n = ins.execute(params![
                    acc_id,
                    t.external_id,
                    t.booking_date,
                    t.value_date,
                    t.amount_cents,
                    t.currency,
                    t.counterparty,
                    t.counterparty_iban,
                    t.purpose,
                    t.booking_text
                ])? as u32;
                if n > 0 && data.adjust_balances {
                    tx.execute(
                        "UPDATE accounts SET balance_cents = balance_cents + ?1, balance_date = ?2 WHERE id = ?3",
                        params![t.amount_cents, t.booking_date, acc_id],
                    )?;
                }
                imported += n;
                if n == 0 {
                    // Existing row: heal corrupted text (U+FFFD / mojibake) with freshly decoded text.
                    let bad = |s: &str| s.contains('\u{FFFD}') || crate::text::has_mojibake(s);
                    let good = |s: &str| !bad(s);
                    let existing: Option<(i64, String, String)> = tx
                        .query_row(
                            "SELECT id, counterparty, purpose FROM transactions WHERE account_id = ?1 AND external_id = ?2",
                            params![acc_id, t.external_id],
                            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                        )
                        .ok();
                    if let Some((row_id, cp, pu)) = existing {
                        if bad(&cp) && good(&t.counterparty) {
                            tx.execute(
                                "UPDATE transactions SET counterparty = ?1 WHERE id = ?2",
                                params![t.counterparty, row_id],
                            )?;
                        }
                        if bad(&pu) && good(&t.purpose) {
                            tx.execute(
                                "UPDATE transactions SET purpose = ?1 WHERE id = ?2",
                                params![t.purpose, row_id],
                            )?;
                        }
                    }
                }
            }
        }
        for d in &data.documents {
            let Some(acc_id) = account_ids
                .get(&d.account_ref)
                .copied()
                .or_else(|| account_ids.values().next().copied())
            else {
                continue;
            };
            let booking_id: Option<i64> = match &d.booking_external_id {
                Some(ext) => tx
                    .query_row(
                        "SELECT id FROM transactions WHERE account_id = ?1 AND external_id = ?2",
                        params![acc_id, ext],
                        |r| r.get(0),
                    )
                    .optional()?,
                None => None,
            };
            let _ = crate::documents::insert_doc(
                &tx,
                booking_id,
                Some(acc_id),
                &d.title,
                &d.doc_type,
                &d.mime_type,
                &d.file_name,
                &d.bytes,
                &d.source_url,
                &d.date,
            );
        }
        for acc in data.accounts.iter().filter(|a| a.kind == AccountKind::Loan) {
            if let Some(id) = account_ids.get(&acc.external_ref) {
                Vault::derive_initial_balance(&tx, *id)?;
            }
        }
        let categorized = Vault::apply_rules_inner(&tx, true)?;
        if let Some(state) = data.state {
            tx.execute(
                "UPDATE bank_connections SET state_json = ?1 WHERE id = ?2",
                params![state.to_string(), connection_id],
            )?;
        }
        tx.execute(
            "UPDATE bank_connections SET last_sync_unix = strftime('%s','now') WHERE id = ?1",
            [connection_id],
        )?;
        tx.commit()?;
        Ok(SyncSummary {
            accounts_updated,
            transactions_imported: imported,
            transactions_categorized: categorized,
        })
    }
}

/// Sidebar sections (fixed order).
pub(crate) fn group_for(kind: AccountKind) -> (&'static str, &'static str, i32) {
    match kind {
        AccountKind::Checking
        | AccountKind::Savings
        | AccountKind::Cash
        | AccountKind::PaymentService => ("Giro & Tagesgeld", "building.columns", 1),
        AccountKind::CreditCard => ("Kreditkarten", "creditcard", 2),
        AccountKind::Brokerage => ("Depots & ETFs", "chart.pie", 3),
        AccountKind::Loan => ("Darlehen & Kredite", "house", 4),
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl SyncSession {
    /// Phase 1: log in. Returns a challenge or finishes the sync.
    pub async fn start(&self) -> Result<SyncStep, CoreError> {
        let mut st = self.state.lock().await;
        if st.done {
            return Err(CoreError::SessionClosed);
        }
        let SessionState { connector, ctx, .. } = &mut *st;
        let phase = connector.begin(ctx).await;
        self.advance(phase, &mut st).await
    }

    /// Phase 2a: submit the code / redirect URL the user typed.
    pub async fn submit_code(&self, code: String) -> Result<SyncStep, CoreError> {
        let mut st = self.state.lock().await;
        if st.done {
            return Err(CoreError::SessionClosed);
        }
        let SessionState { connector, ctx, .. } = &mut *st;
        let phase = connector
            .respond(ctx, ChallengeResponse::Code(SecretString::new(code)))
            .await;
        self.advance(phase, &mut st).await
    }

    /// Phase 2b: ask whether the decoupled push approval happened.
    pub async fn poll(&self) -> Result<SyncStep, CoreError> {
        let mut st = self.state.lock().await;
        if st.done {
            return Err(CoreError::SessionClosed);
        }
        let SessionState { connector, ctx, .. } = &mut *st;
        let phase = connector.respond(ctx, ChallengeResponse::Poll).await;
        self.advance(phase, &mut st).await
    }

    /// Cancels the sync and closes the bank dialog.
    pub async fn cancel(&self) {
        let mut st = self.state.lock().await;
        if !st.done {
            let SessionState { connector, ctx, .. } = &mut *st;
            connector.finish(ctx).await;
            st.done = true;
        }
    }

    pub fn bank_name(&self) -> String {
        descriptor(self.kind).name
    }
}

#[uniffi::export]
impl Vault {
    /// Prepares a sync for one bank connection. `secret` is the PIN/password
    /// (wiped from memory when the session ends). With `demo = true` the bank
    /// is simulated (push-TAN / code challenge included) – no network.
    pub fn begin_sync(
        self: Arc<Self>,
        connection_id: i64,
        secret: String,
        demo: bool,
    ) -> Result<Arc<SyncSession>, CoreError> {
        // No PIN typed: use the one stored in the vault ("PIN im Tresor speichern").
        let secret = if secret.is_empty() {
            let db = self.db()?;
            Vault::setting_inner(&db, &crate::connections::pin_key(connection_id))?
                .unwrap_or_default()
        } else {
            secret
        };
        let secret = SecretString::new(secret);
        let (kind, login, state_json, ctx_settings, since) = {
            let db = self.db()?;
            let (kind, login, state): (String, String, String) = db
                .query_row(
                    "SELECT connector, login_name, state_json FROM bank_connections WHERE id = ?1",
                    [connection_id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .optional()?
                .ok_or_else(|| CoreError::NotFound {
                    what: format!("bank connection {connection_id}"),
                })?;
            let kind = ConnectorKind::from_str(&kind).ok_or_else(|| CoreError::InvalidInput {
                message: format!("unknown connector {kind}"),
            })?;
            let mut settings = HashMap::new();
            for (key, ..) in crate::vault::KNOWN_SETTINGS {
                if let Some(v) = Vault::setting_inner(&db, key)? {
                    settings.insert(key.to_string(), SecretString::new(v));
                }
            }
            if !demo {
                for key in descriptor(kind).required_settings {
                    if !settings.contains_key(&key) {
                        return Err(CoreError::MissingSetting { key });
                    }
                }
            }
            // Incremental: from the newest booking minus 10 days, else N days back.
            let newest: Option<String> = db
                .query_row(
                    "SELECT MAX(t.booking_date) FROM transactions t JOIN accounts a ON a.id = t.account_id WHERE a.connection_id = ?1",
                    [connection_id],
                    |r| r.get(0),
                )
                .optional()?
                .flatten();
            let days: i64 = Vault::setting_inner(&db, "sync.days_back")?
                .and_then(|d| d.parse().ok())
                .unwrap_or(90);
            let since =
                match newest.and_then(|d| chrono::NaiveDate::parse_from_str(&d, "%Y-%m-%d").ok()) {
                    Some(d) => (d - chrono::Duration::days(10))
                        .format("%Y-%m-%d")
                        .to_string(),
                    None => (chrono::Local::now().date_naive() - chrono::Duration::days(days))
                        .format("%Y-%m-%d")
                        .to_string(),
                };
            (kind, login, state, settings, since)
        };
        let ctx = ConnectContext {
            connection_id,
            login_name: login,
            secret,
            settings: ctx_settings,
            state: serde_json::from_str(&state_json).unwrap_or(serde_json::json!({})),
            since,
        };
        Ok(Arc::new(SyncSession {
            vault: self.clone(),
            kind,
            state: AsyncMutex::new(SessionState {
                connector: make_connector(kind, demo),
                ctx,
                done: false,
            }),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vault::Vault;

    fn demo_vault() -> (Arc<Vault>, std::path::PathBuf) {
        let path = std::env::temp_dir().join(format!("girocrab-sync-{}.db", uuid::Uuid::new_v4()));
        let v = Vault::open(path.to_string_lossy().to_string(), vec![3u8; 32]).unwrap();
        v.seed_demo_data().unwrap();
        (v, path)
    }

    #[tokio::test]
    async fn demo_push_tan_flow_imports_and_categorises() {
        let (v, path) = demo_vault();
        let conn = v
            .list_bank_connections()
            .unwrap()
            .into_iter()
            .find(|c| c.connector == ConnectorKind::VolksbankKasselGoettingen)
            .unwrap();
        let before = v
            .list_accounts()
            .unwrap()
            .into_iter()
            .find(|a| a.name == "Musterbank Girokonto" && a.connection_id == Some(conn.id))
            .unwrap();
        let s = v.clone().begin_sync(conn.id, "pin".into(), true).unwrap();
        match s.start().await.unwrap() {
            SyncStep::NeedsChallenge { challenge } => {
                assert_eq!(challenge.kind, ChallengeKind::DecoupledPush)
            }
            other => panic!("expected push challenge, got {other:?}"),
        }
        assert!(matches!(
            s.poll().await.unwrap(),
            SyncStep::StillWaiting { .. }
        ));
        match s.poll().await.unwrap() {
            SyncStep::Finished { summary } => {
                assert_eq!(summary.transactions_imported, 1);
                assert_eq!(
                    summary.transactions_categorized, 1,
                    "REWE booking is categorised by a rule"
                );
            }
            other => panic!("expected finish, got {other:?}"),
        }
        let after = v
            .list_accounts()
            .unwrap()
            .into_iter()
            .find(|a| a.id == before.id)
            .unwrap();
        assert_eq!(after.balance_cents, before.balance_cents - 27_65);
        assert!(matches!(s.poll().await, Err(CoreError::SessionClosed)));
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn demo_code_and_redirect_flows() {
        let (v, path) = demo_vault();
        let conns = v.list_bank_connections().unwrap();
        let tr = conns
            .iter()
            .find(|c| c.connector == ConnectorKind::TradeRepublic)
            .unwrap();
        let s = v.clone().begin_sync(tr.id, "1234".into(), true).unwrap();
        assert!(
            matches!(s.start().await.unwrap(), SyncStep::NeedsChallenge { challenge } if challenge.kind == ChallengeKind::Code)
        );
        assert!(
            s.submit_code("12".into()).await.is_err(),
            "bad code rejected"
        );
        let amex = conns
            .iter()
            .find(|c| c.connector == ConnectorKind::AmericanExpress)
            .unwrap();
        let s = v.clone().begin_sync(amex.id, String::new(), true).unwrap();
        assert!(
            matches!(s.start().await.unwrap(), SyncStep::NeedsChallenge { challenge } if challenge.kind == ChallengeKind::Redirect)
        );
        assert!(matches!(
            s.submit_code("https://localhost/cb?code=x".into())
                .await
                .unwrap(),
            SyncStep::Finished { .. }
        ));
        let pp_id = v
            .add_bank_connection(
                ConnectorKind::PayPal,
                String::new(),
                "demo@example.org".into(),
            )
            .unwrap();
        let pp = v
            .list_bank_connections()
            .unwrap()
            .into_iter()
            .find(|c| c.id == pp_id)
            .unwrap();
        let s = v.clone().begin_sync(pp.id, String::new(), true).unwrap();
        assert!(matches!(
            s.start().await.unwrap(),
            SyncStep::Finished { .. }
        ));
        // Real (non-demo) sync refuses to start without the user's own keys.
        assert!(matches!(
            v.clone().begin_sync(pp.id, String::new(), false),
            Err(CoreError::MissingSetting { .. })
        ));
        let _ = std::fs::remove_file(path);
    }
}
