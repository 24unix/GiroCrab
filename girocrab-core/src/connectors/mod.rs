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
use crate::i18n::{tr, trf};
use crate::models::{AccountKind, ConnectorKind, KnownRecipient, SepaTransferRequest};
use crate::secret::SecretString;
use crate::vault::Vault;

pub mod bank_directory;
pub mod bunq;
pub mod comdirect;
pub mod demo;
pub mod enable_banking;
pub mod fints;
pub mod fints_directory;
mod fints_directory_data;
pub mod fints_presets;
pub mod moneymoney_db;
pub mod moneymoney_import;
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

/// Progress of a SEPA transfer (`TransferSession`).
#[derive(Debug, Clone, uniffi::Enum)]
pub enum TransferStep {
    NeedsChallenge {
        challenge: Challenge,
    },
    StillWaiting {
        challenge: Challenge,
    },
    /// Bank accepted the transfer; an optimistic booking was stored.
    Finished,
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

/// The supported institutions with their public protocol facts.
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
            login_label: tr("VR-NetKey oder Alias").into(),
            secret_label: tr("Online-Banking-PIN").into(),
            required_settings: s(&["fints.product_id", "fints.url.52090000"]),
            note: tr("Freigabe in der SecureGo-plus-App (Decoupled, TAN-Prozess 4, HKTAN v7). Server: fints1.atruvia.de").into(),
        },
        ConnectorKind::Direkt1822 => BankDescriptor {
            kind,
            name: "1822direkt".into(),
            protocol: "FinTS 3.0 PIN/TAN".into(),
            bank_code: "50050201".into(),
            sf_symbol: "building.columns".into(),
            login_label: tr("Anmeldename / Kontonummer").into(),
            secret_label: tr("Online-Banking-PIN").into(),
            required_settings: s(&["fints.product_id", "fints.url.50050201"]),
            note: tr("pushTAN-App (Decoupled) oder chipTAN. Server: banking-hs5.s-fints-pt-hs.de").into(),
        },
        ConnectorKind::FinTsGeneric => BankDescriptor {
            kind,
            name: tr("FinTS-Bank").into(),
            protocol: "FinTS 3.0 PIN/TAN".into(),
            bank_code: String::new(),
            sf_symbol: "building.columns".into(),
            login_label: tr("Anmeldename / VR-NetKey / Kontonummer").into(),
            secret_label: tr("Online-Banking-PIN").into(),
            required_settings: s(&["fints.product_id"]),
            note: tr("Beliebige FinTS-3.0-Bank (PIN/TAN). BLZ und FinTS-URL stehen im Bankzugang.").into(),
        },
        ConnectorKind::Comdirect => BankDescriptor {
            kind,
            name: "comdirect".into(),
            protocol: tr("comdirect REST-API (OAuth2 + Session-TAN)").into(),
            bank_code: "20041111".into(),
            sf_symbol: "building.2".into(),
            login_label: tr("Zugangsnummer").into(),
            secret_label: "PIN".into(),
            required_settings: s(&["comdirect.client_id", "comdirect.client_secret"]),
            note: tr("Session-TAN per photoTAN-Push, photoTAN-Grafik oder mobileTAN.").into(),
        },
        ConnectorKind::PayPal => BankDescriptor {
            kind,
            name: "PayPal".into(),
            protocol: tr("PayPal Transaction Search REST-API").into(),
            bank_code: String::new(),
            sf_symbol: "p.circle".into(),
            login_label: tr("E-Mail (nur Anzeige)").into(),
            secret_label: tr("(nicht nötig – nutzt Ihre REST-App)").into(),
            required_settings: s(&["paypal.client_id", "paypal.client_secret"]),
            note: tr("OAuth2 Client Credentials; Historie in 31-Tage-Fenstern.").into(),
        },
        ConnectorKind::TradeRepublic => BankDescriptor {
            kind,
            name: "Trade Republic".into(),
            protocol: tr("WebSocket-API + 2FA").into(),
            bank_code: String::new(),
            sf_symbol: "chart.line.uptrend.xyaxis.circle".into(),
            login_label: tr("Telefonnummer (+49…)").into(),
            secret_label: tr("4-stellige App-PIN").into(),
            required_settings: vec![],
            note: tr("Web-Login mit 4-stelligem Code aus der App/SMS. Inoffizielle Schnittstelle – kann sich jederzeit ändern.").into(),
        },
        ConnectorKind::AmericanExpress => BankDescriptor {
            kind,
            name: "American Express".into(),
            protocol: tr("Direkt-Login (Web-Session) oder CSV/PDF-Kontoauszug").into(),
            bank_code: String::new(),
            sf_symbol: "creditcard.fill".into(),
            login_label: tr("Kartenbezeichnung").into(),
            secret_label: tr("(Anmeldung im Browser-Fenster)").into(),
            required_settings: vec![],
            note: tr("Anmeldung im eingebetteten Browser (Benutzername, Passwort, 2FA wie gewohnt) – keine API-Schlüssel nötig. Optional: eigene PSD2-/Enable-Banking-API unter „Erweitert“.").into(),
        },
        ConnectorKind::AmazonVisa => BankDescriptor {
            kind,
            name: "Amazon Visa".into(),
            protocol: tr("Direkt-Login (Web-Session) oder CSV/PDF-Kontoauszug").into(),
            bank_code: String::new(),
            sf_symbol: "creditcard".into(),
            login_label: tr("Kartenbezeichnung").into(),
            secret_label: tr("(Anmeldung im Browser-Fenster)").into(),
            required_settings: vec![],
            note: tr("Herausgeber: Open Bank S.A. (Zinia). Anmeldung im eingebetteten Browser – keine API-Schlüssel nötig. Optional: eigene PSD2-/Enable-Banking-API unter „Erweitert“.").into(),
        },
        ConnectorKind::EnableBanking => BankDescriptor {
            kind,
            name: tr("Bank per PSD2 (Enable Banking)").into(),
            protocol: tr("PSD2 über Enable Banking (eigene Anwendung)").into(),
            bank_code: String::new(),
            sf_symbol: "building.columns.circle.fill".into(),
            login_label: tr("Bezeichnung (z. B. Kontoname)").into(),
            secret_label: tr("(Zustimmung im Browser)").into(),
            required_settings: s(&[
                "enablebanking.application_id",
                "enablebanking.private_key_pem",
                "enablebanking.redirect_url",
            ]),
            note: tr("Banken wie N26, Revolut oder C24 per PSD2. Benötigt eine kostenlose eigene Anwendung auf enablebanking.com (Application-ID, privater Schlüssel, Redirect-URL). Die Zustimmung erteilen Sie im Browser Ihrer Bank.").into(),
        },
        ConnectorKind::Bunq => BankDescriptor {
            kind,
            name: "bunq".into(),
            protocol: tr("bunq Public API (eigener API-Schlüssel)").into(),
            bank_code: String::new(),
            sf_symbol: "building.columns.circle".into(),
            login_label: tr("E-Mail (nur Anzeige)").into(),
            secret_label: tr("API-Schlüssel").into(),
            required_settings: vec![],
            note: tr("API-Schlüssel in der bunq-App unter Profil → Einstellungen → Entwickler → API-Schlüssel erstellen und „Alle IP-Adressen erlauben“ aktivieren. Keine PSD2-Registrierung nötig.").into(),
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

/// Securities position delivered by a connector for a depot account.
#[derive(Debug, Clone)]
pub struct RemoteHolding {
    pub account_ref: String,
    pub holding: crate::models::Holding,
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
    /// Depot positions; replace the stored holdings of each listed account.
    pub holdings: Vec<RemoteHolding>,
    /// Updated connector state to persist.
    pub state: Option<serde_json::Value>,
    /// Keep stored balances and add newly imported bookings to them
    /// (for sources that don't report a balance).
    pub adjust_balances: bool,
    /// PDFs fetched from the bank (trade confirmations, PostBox, statements).
    pub documents: Vec<crate::documents::RemoteDocument>,
    /// external_id prefix of provisional bookings (card holds) this fetch
    /// lists completely: stored ones missing from it are removed.
    pub hold_prefix: Option<String>,
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
    /// Submit a SEPA credit transfer (only valid after `Ready`). `Ready`
    /// means the bank accepted it; challenges are answered via `respond`.
    async fn send_transfer(
        &mut self,
        _ctx: &ConnectContext,
        _job: &TransferJob,
    ) -> CoreResult<Phase> {
        Err(CoreError::InvalidInput {
            message: tr("Für diese Bank werden Überweisungen nicht unterstützt.").into(),
        })
    }
}

/// Transfer request plus the source account data resolved from the vault.
#[derive(Debug, Clone)]
pub struct TransferJob {
    pub source_iban: String,
    pub source_owner: String,
    pub recipient_name: String,
    pub recipient_iban: String,
    pub recipient_bic: Option<String>,
    pub amount_cents: i64,
    pub purpose: String,
    pub instant: bool,
    pub execution_date: Option<String>,
}

pub fn make_connector(kind: ConnectorKind, demo: bool) -> Box<dyn BankConnector> {
    make_connector_for(kind, kind.as_str(), demo)
}

/// Like `make_connector`, but with the stored connector key so generic FinTS
/// connections get their BLZ (`fints:<blz>`).
pub fn make_connector_for(kind: ConnectorKind, key: &str, demo: bool) -> Box<dyn BankConnector> {
    if demo {
        return Box::new(demo::DemoConnector::new(kind));
    }
    match kind {
        ConnectorKind::FinTsGeneric => Box::new(fints::FinTsConnector::new(
            ConnectorKind::fints_blz(key).unwrap_or(""),
        )),
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
        ConnectorKind::Bunq => Box::new(bunq::BunqConnector::new()),
        ConnectorKind::EnableBanking => {
            let (country, aspsp) = ConnectorKind::enable_banking_target(key).unwrap_or(("DE", ""));
            Box::new(enable_banking::EnableBankingConnector::for_aspsp(
                aspsp, country,
            ))
        }
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
                crate::depot_debug::log(&format!("sync advance: Ready, calling fetch for {:?}", self.kind));
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
            // First sync after a MoneyMoney database import: take over the
            // unconnected imported account with the same IBAN (its bookings are
            // then adopted via the import fingerprint) instead of a second account.
            let existing = match existing {
                Some(id) => Some(id),
                None => moneymoney_db::adopt_account(
                    &tx,
                    connection_id,
                    &acc.external_ref,
                    &acc.iban,
                    acc.kind,
                )?,
            };
            // Sub-accounts known from an earlier import/sync without a connection
            // (e.g. comdirect Depot / Tagesgeld): link them to this connection.
            let existing = match existing {
                Some(id) => Some(id),
                None => adopt_unlinked(&tx, connection_id, &bank_name, acc)?,
            };
            let id = match existing {
                Some(id) => {
                    if !data.adjust_balances {
                        tx.execute(
                            "UPDATE accounts SET balance_cents = ?1, balance_date = ?2, currency = ?3 WHERE id = ?4",
                            params![acc.balance_cents, acc.balance_date, acc.currency, id],
                        )?;
                    }
                    // Trade Republic cash side is a clearing account, not a Girokonto.
                    if kind == ConnectorKind::TradeRepublic
                        && acc.kind != AccountKind::Brokerage
                        && acc.name == "Verrechnungskonto"
                    {
                        tx.execute(
                            "UPDATE accounts SET name = ?1 WHERE id = ?2 AND name = 'Girokonto'",
                            params![acc.name, id],
                        )?;
                    }
                    if acc.kind == AccountKind::Brokerage {
                        let (group, sym, order) = group_for(acc.kind);
                        let gid = Vault::ensure_group(&tx, group, sym, order)?;
                        tx.execute(
                            "UPDATE accounts SET kind = ?1, sf_symbol = ?2, group_id = ?3 WHERE id = ?4 AND kind <> ?1",
                            params![acc.kind.as_str(), acc.kind.sf_symbol(), gid, id],
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
        // Credit cards without a connector balance: derive the open amount.
        if !data.adjust_balances {
            for acc in data.accounts.iter().filter(|a| a.balance_cents == 0) {
                let Some(&id) = account_ids.get(&acc.external_ref) else {
                    continue;
                };
                let is_card = acc.kind == AccountKind::CreditCard
                    || is_amex_name(&acc.name)
                    || is_amex_name(bank_name.as_str());
                if !is_card {
                    continue;
                }
                let mut st = tx.prepare(
                    "SELECT booking_date, amount_cents, counterparty || ' ' || purpose || ' ' || booking_text
                     FROM transactions WHERE account_id = ?1 ORDER BY booking_date, id",
                )?;
                let rows: Vec<(String, i64, String)> = st
                    .query_map([id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                    .collect::<Result<_, _>>()?;
                drop(st);
                if let Some(open) = open_card_balance(&rows) {
                    tx.execute(
                        "UPDATE accounts SET balance_cents = ?1 WHERE id = ?2",
                        params![open, id],
                    )?;
                }
            }
        }
        // Resolve each position to a stored account: external ref, else IBAN /
        // account number (depots often have no IBAN, numbers differ in leading
        // zeros), else the only depot of this fetch.
        let norm = |x: &str| {
            x.chars()
                .filter(|c| !c.is_whitespace())
                .collect::<String>()
                .trim_start_matches('0')
                .to_uppercase()
        };
        let depots: Vec<&RemoteAccount> = data
            .accounts
            .iter()
            .filter(|a| a.kind == AccountKind::Brokerage || a.name.to_lowercase().contains("depot"))
            .collect();
        let resolve = |r: &str| -> Option<i64> {
            if let Some(id) = account_ids.get(r) {
                return Some(*id);
            }
            let n = norm(r);
            if !n.is_empty() {
                for a in &data.accounts {
                    if [&a.external_ref, &a.iban, &a.account_number]
                        .iter()
                        .any(|f| !f.is_empty() && norm(f) == n)
                    {
                        return account_ids.get(&a.external_ref).copied();
                    }
                }
            }
            match depots.as_slice() {
                [only] => account_ids.get(&only.external_ref).copied(),
                _ => None,
            }
        };
        let mut by_account: HashMap<i64, Vec<&crate::models::Holding>> = HashMap::new();
        let mut unresolved = 0usize;
        for h in &data.holdings {
            if let Some(id) = resolve(&h.account_ref) {
                by_account.entry(id).or_default().push(&h.holding);
            } else {
                unresolved += 1;
            }
        }
        crate::depot_debug::log(&format!(
            "store_fetch {kind:?}: incoming_holdings={} depot_accounts={} resolved_accounts={} unresolved={unresolved}",
            data.holdings.len(),
            depots.len(),
            by_account.len()
        ));
        for (acc_id, list) in &by_account {
            tx.execute("DELETE FROM holdings WHERE account_id = ?1", [acc_id])?;
            for h in list {
                tx.execute(
                    "INSERT INTO holdings(account_id, isin, wkn, name, quantity, current_price_cents, purchase_price_cents, value_cents)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                    params![acc_id, h.isin, h.wkn, h.name, h.quantity, h.current_price_cents, h.purchase_price_cents, h.value_cents],
                )?;
            }
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
                // Already imported from MoneyMoney? Adopt that row (keeps category + note).
                if moneymoney_import::adopt_import(
                    &tx,
                    *acc_id,
                    &t.external_id,
                    &t.booking_date,
                    t.amount_cents,
                    &t.counterparty_iban,
                    &t.counterparty,
                    &t.purpose,
                )? {
                    continue;
                }
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
        // Drop optimistic transfer bookings once the bank's real booking arrived
        // (same account, amount and recipient IBAN) or after 14 days.
        tx.execute(
            "DELETE FROM transactions WHERE external_id LIKE 'pending-%' AND (
                imported_unix < strftime('%s','now') - 14*86400 OR EXISTS (
                    SELECT 1 FROM transactions r WHERE r.account_id = transactions.account_id
                      AND r.external_id NOT LIKE 'pending-%' AND r.amount_cents = transactions.amount_cents
                      AND r.counterparty_iban = transactions.counterparty_iban
                      AND r.booking_date >= transactions.booking_date))",
            [],
        )?;
        // Card holds: keep exactly the ones the bank still reports as open.
        if let Some(prefix) = data.hold_prefix.as_deref().filter(|p| !p.is_empty()) {
            let current: std::collections::HashSet<&str> = data
                .transactions
                .iter()
                .filter(|t| t.external_id.starts_with(prefix))
                .map(|t| t.external_id.as_str())
                .collect();
            let like = format!("{}%", prefix.replace('%', "").replace('_', "\\_"));
            for acc_id in account_ids.values() {
                let stale: Vec<(i64, String)> = {
                    let mut q = tx.prepare(
                        "SELECT id, external_id FROM transactions
                         WHERE account_id = ?1 AND external_id LIKE ?2 ESCAPE '\\'",
                    )?;
                    let rows =
                        q.query_map(params![acc_id, like], |r| Ok((r.get(0)?, r.get(1)?)))?;
                    rows.collect::<Result<_, _>>()?
                };
                for (row_id, ext) in stale {
                    if !current.contains(ext.as_str()) {
                        tx.execute("DELETE FROM transactions WHERE id = ?1", [row_id])?;
                    }
                }
            }
        }
        for d in &data.documents {
            let by_ref = |tx: &rusqlite::Transaction| -> Option<i64> {
                tx.query_row(
                    "SELECT id FROM accounts WHERE connection_id = ?1 AND external_ref = ?2",
                    params![connection_id, d.account_ref],
                    |r| r.get(0),
                )
                .optional()
                .ok()
                .flatten()
            };
            let Some(acc_id) = account_ids
                .get(&d.account_ref)
                .copied()
                .or_else(|| by_ref(&tx))
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

/// Setting key marking a statements-only session (value = external_ref of the account).
pub(crate) const STATEMENTS_ONLY: &str = "__statements_only";

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
        self.begin_sync_inner(connection_id, secret, demo, None)
    }

    /// Explicitly fetches the electronic bank statements (FinTS HKEKA, PDF) of ONE account
    /// into the document archive. Same session / TAN flow as `begin_sync`; bookings and
    /// balances stay untouched. Regular syncs never fetch statements.
    pub fn fetch_account_statements(
        self: Arc<Self>,
        account_id: i64,
        secret: String,
        demo: bool,
    ) -> Result<Arc<SyncSession>, CoreError> {
        let (conn_id, ext): (Option<i64>, String) = {
            let db = self.db()?;
            db.query_row(
                "SELECT connection_id, external_ref FROM accounts WHERE id = ?1",
                [account_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?
            .ok_or_else(|| CoreError::NotFound {
                what: trf("Konto {0}", &[&account_id]),
            })?
        };
        let conn_id = conn_id.ok_or_else(|| CoreError::InvalidInput {
            message: tr("Dieses Konto hat keine Bankverbindung.").into(),
        })?;
        let kind: String = self.db()?.query_row(
            "SELECT connector FROM bank_connections WHERE id = ?1",
            [conn_id],
            |r| r.get(0),
        )?;
        let is_fints = ConnectorKind::from_str(&kind).is_some_and(|k| {
            matches!(
                k,
                ConnectorKind::FinTsGeneric
                    | ConnectorKind::VolksbankKasselGoettingen
                    | ConnectorKind::Direkt1822
            )
        });
        if !is_fints {
            return Err(CoreError::InvalidInput {
                message: tr("Kontoauszüge können nur per FinTS abgerufen werden.").into(),
            });
        }
        self.begin_sync_inner(conn_id, secret, demo, Some(ext))
    }
}

impl Vault {
    fn begin_sync_inner(
        self: Arc<Self>,
        connection_id: i64,
        secret: String,
        demo: bool,
        statements_only: Option<String>,
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
        let (kind, key_str, login, state_json, ctx_settings, since) = {
            let db = self.db()?;
            let (kind, login, state): (String, String, String) = db
                .query_row(
                    "SELECT connector, login_name, state_json FROM bank_connections WHERE id = ?1",
                    [connection_id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .optional()?
                .ok_or_else(|| CoreError::NotFound {
                    what: trf("Bankverbindung {0}", &[&connection_id]),
                })?;
            let key_str = kind.clone();
            let kind = ConnectorKind::from_str(&kind).ok_or_else(|| CoreError::InvalidInput {
                message: format!("unknown connector {kind}"),
            })?;
            let mut settings = HashMap::new();
            for (key, ..) in crate::vault::KNOWN_SETTINGS {
                if let Some(v) = Vault::setting_inner(&db, key)? {
                    settings.insert(key.to_string(), SecretString::new(v));
                }
            }
            if let Some(blz) = ConnectorKind::fints_blz(&key_str) {
                let k = format!("fints.url.{blz}");
                match Vault::setting_inner(&db, &k)? {
                    Some(v) if !v.is_empty() => {
                        settings.insert(k, SecretString::new(v));
                    }
                    // e.g. a MoneyMoney import created the login without a URL
                    _ => {
                        if let Some(url) = fints_directory::url_for_blz(blz) {
                            settings.insert(k, SecretString::new(url.to_string()));
                        }
                    }
                }
            }
            let tm_key = format!("fints.tan_medium.{connection_id}");
            if let Some(v) = Vault::setting_inner(&db, &tm_key)? {
                if !v.trim().is_empty() {
                    settings.insert(tm_key, SecretString::new(v));
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
            (kind, key_str, login, state, settings, since)
        };
        let mut ctx_settings = ctx_settings;
        if let Some(ext) = statements_only {
            ctx_settings.insert(STATEMENTS_ONLY.into(), SecretString::new(ext));
        }
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
                connector: make_connector_for(kind, &key_str, demo),
                ctx,
                done: false,
            }),
        }))
    }
}

// ------------------------------------------------------------------ SEPA transfer session

struct TransferState {
    connector: Box<dyn BankConnector>,
    ctx: ConnectContext,
    job: TransferJob,
    account_id: i64,
    /// false = still logging in, true = transfer submitted (waiting for TAN).
    submitted: bool,
    done: bool,
}

/// One SEPA transfer. Created by `Vault::begin_transfer`; same two-phase
/// challenge handling as `SyncSession` (login SCA, then transfer SCA).
#[derive(uniffi::Object)]
pub struct TransferSession {
    vault: Arc<Vault>,
    state: AsyncMutex<TransferState>,
}

impl TransferSession {
    async fn advance(
        &self,
        phase: CoreResult<Phase>,
        st: &mut TransferState,
    ) -> CoreResult<TransferStep> {
        let mut phase = phase;
        loop {
            match phase {
                Err(e) => {
                    st.done = true;
                    st.connector.finish(&st.ctx).await;
                    return Err(e);
                }
                Ok(Phase::Challenge(c)) => {
                    return Ok(TransferStep::NeedsChallenge { challenge: c })
                }
                Ok(Phase::Pending(c)) => return Ok(TransferStep::StillWaiting { challenge: c }),
                Ok(Phase::Ready) if !st.submitted => {
                    st.submitted = true;
                    phase = st.connector.send_transfer(&st.ctx, &st.job).await;
                }
                Ok(Phase::Ready) => {
                    st.connector.finish(&st.ctx).await;
                    st.done = true;
                    self.vault.record_pending_transfer(st.account_id, &st.job)?;
                    return Ok(TransferStep::Finished);
                }
            }
        }
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl TransferSession {
    pub async fn start(&self) -> Result<TransferStep, CoreError> {
        let mut st = self.state.lock().await;
        if st.done {
            return Err(CoreError::SessionClosed);
        }
        let TransferState { connector, ctx, .. } = &mut *st;
        let phase = connector.begin(ctx).await;
        self.advance(phase, &mut st).await
    }

    pub async fn submit_code(&self, code: String) -> Result<TransferStep, CoreError> {
        let mut st = self.state.lock().await;
        if st.done {
            return Err(CoreError::SessionClosed);
        }
        let TransferState { connector, ctx, .. } = &mut *st;
        let phase = connector
            .respond(ctx, ChallengeResponse::Code(SecretString::new(code)))
            .await;
        self.advance(phase, &mut st).await
    }

    pub async fn poll(&self) -> Result<TransferStep, CoreError> {
        let mut st = self.state.lock().await;
        if st.done {
            return Err(CoreError::SessionClosed);
        }
        let TransferState { connector, ctx, .. } = &mut *st;
        let phase = connector.respond(ctx, ChallengeResponse::Poll).await;
        self.advance(phase, &mut st).await
    }

    pub async fn cancel(&self) {
        let mut st = self.state.lock().await;
        if !st.done {
            let TransferState { connector, ctx, .. } = &mut *st;
            connector.finish(ctx).await;
            st.done = true;
        }
    }
}

#[uniffi::export]
impl Vault {
    /// Prepares a SEPA transfer from a FinTS account. `secret` = PIN (empty =
    /// PIN stored in the vault). `demo` simulates the bank.
    pub fn begin_transfer(
        self: Arc<Self>,
        request: SepaTransferRequest,
        secret: String,
        demo: bool,
    ) -> Result<Arc<TransferSession>, CoreError> {
        use crate::connectors::fints::sepa;
        if request.amount_cents <= 0 {
            return Err(CoreError::InvalidInput {
                message: tr("Der Betrag muss größer als 0 sein.").into(),
            });
        }
        if !sepa::validate_iban(&request.recipient_iban) {
            return Err(CoreError::InvalidInput {
                message: tr("Die Empfänger-IBAN ist ungültig.").into(),
            });
        }
        if let Some(b) = request
            .recipient_bic
            .as_deref()
            .filter(|b| !b.trim().is_empty())
        {
            if !sepa::validate_bic(b) {
                return Err(CoreError::InvalidInput {
                    message: tr("Die BIC ist ungültig.").into(),
                });
            }
        }
        if request.recipient_name.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: tr("Der Empfängername fehlt.").into(),
            });
        }
        if request.purpose.chars().count() > 140 {
            return Err(CoreError::InvalidInput {
                message: tr("Der Verwendungszweck darf höchstens 140 Zeichen lang sein.").into(),
            });
        }
        let (connection_id, iban, owner) = {
            let db = self.db()?;
            let row: (Option<i64>, String, String) = db
                .query_row(
                    "SELECT connection_id, iban, owner FROM accounts WHERE id = ?1",
                    [request.account_id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .optional()?
                .ok_or_else(|| CoreError::NotFound {
                    what: trf("Konto {0}", &[&request.account_id]),
                })?;
            let cid = row.0.ok_or_else(|| CoreError::InvalidInput {
                message: tr("Dieses Konto hat keine Bankverbindung.").into(),
            })?;
            (cid, row.1, row.2)
        };
        let key_str: String = {
            let db = self.db()?;
            db.query_row(
                "SELECT connector FROM bank_connections WHERE id = ?1",
                [connection_id],
                |r| r.get(0),
            )?
        };
        let kind = ConnectorKind::from_str(&key_str).ok_or_else(|| CoreError::InvalidInput {
            message: format!("unknown connector {key_str}"),
        })?;
        if !matches!(
            kind,
            ConnectorKind::VolksbankKasselGoettingen
                | ConnectorKind::Direkt1822
                | ConnectorKind::FinTsGeneric
                | ConnectorKind::Bunq
        ) {
            return Err(CoreError::InvalidInput {
                message: tr("Überweisungen sind nur für FinTS- und bunq-Konten möglich.").into(),
            });
        }
        let exec_date = request
            .execution_date
            .as_deref()
            .map(str::trim)
            .filter(|d| !d.is_empty())
            .map(str::to_string);
        if request.instant && exec_date.is_some() {
            return Err(CoreError::InvalidInput {
                message: tr("Echtzeitüberweisungen können nicht terminiert werden.").into(),
            });
        }
        if let Some(d) = &exec_date {
            let parsed = chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").map_err(|_| {
                CoreError::InvalidInput {
                    message: tr("Das Ausführungsdatum ist ungültig (JJJJ-MM-TT).").into(),
                }
            })?;
            if parsed <= chrono::Local::now().date_naive() {
                return Err(CoreError::InvalidInput {
                    message: tr("Das Ausführungsdatum muss in der Zukunft liegen.").into(),
                });
            }
        }
        if (request.instant || exec_date.is_some()) && matches!(kind, ConnectorKind::Bunq) {
            return Err(CoreError::InvalidInput {
                message: tr("Echtzeit- und Terminüberweisungen sind nur für FinTS-Konten möglich.")
                    .into(),
            });
        }
        if iban.is_empty() {
            return Err(CoreError::InvalidInput {
                message: tr("Das Konto hat keine IBAN.").into(),
            });
        }
        // Reuse the sync session set-up (settings, PIN, connector state).
        let sync = self.clone().begin_sync(connection_id, secret, demo)?;
        let ctx = {
            let st = sync
                .state
                .try_lock()
                .map_err(|_| CoreError::SessionClosed)?;
            ConnectContext {
                connection_id: st.ctx.connection_id,
                login_name: st.ctx.login_name.clone(),
                secret: SecretString::new(st.ctx.secret.expose().to_string()),
                settings: st.ctx.settings.clone(),
                state: st.ctx.state.clone(),
                since: st.ctx.since.clone(),
            }
        };
        let job = TransferJob {
            source_iban: iban,
            source_owner: owner,
            recipient_name: request.recipient_name.trim().to_string(),
            recipient_iban: sepa::normalize_iban(&request.recipient_iban),
            recipient_bic: request
                .recipient_bic
                .filter(|b| !b.trim().is_empty())
                .map(|b| sepa::normalize_iban(&b)),
            amount_cents: request.amount_cents,
            purpose: request.purpose.trim().to_string(),
            instant: request.instant,
            execution_date: exec_date,
        };
        Ok(Arc::new(TransferSession {
            vault: self.clone(),
            state: AsyncMutex::new(TransferState {
                connector: make_connector_for(kind, &key_str, demo),
                ctx,
                job,
                account_id: request.account_id,
                submitted: false,
                done: false,
            }),
        }))
    }

    /// Known recipients (name + IBAN) from past outgoing bookings, most used
    /// first. `query` filters by name/IBAN substring (empty = all).
    pub fn suggest_recipients(
        &self,
        query: String,
        limit: u32,
    ) -> Result<Vec<KnownRecipient>, CoreError> {
        let db = self.db()?;
        let q = query.trim().replace(' ', "").to_lowercase();
        let mut stmt = db.prepare(
            "SELECT counterparty, counterparty_iban, count(*) AS n FROM transactions
             WHERE counterparty_iban <> '' AND counterparty <> '' AND amount_cents < 0
             GROUP BY counterparty, counterparty_iban
             ORDER BY n DESC, MAX(booking_date) DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(KnownRecipient {
                name: r.get(0)?,
                iban: r.get(1)?,
                times_used: r.get(2)?,
            })
        })?;
        Ok(rows
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .filter(|r| {
                q.is_empty()
                    || r.name.replace(' ', "").to_lowercase().contains(&q)
                    || r.iban.replace(' ', "").to_lowercase().contains(&q)
            })
            .filter(|r| crate::connectors::fints::sepa::validate_iban(&r.iban))
            .take(limit as usize)
            .collect())
    }
}

impl Vault {
    /// Optimistic booking after a confirmed transfer. It disappears as soon
    /// as the bank's own booking for it arrives in a sync.
    pub(crate) fn record_pending_transfer(
        &self,
        account_id: i64,
        job: &TransferJob,
    ) -> CoreResult<()> {
        let db = self.db()?;
        db.execute(
            "INSERT INTO transactions(account_id, external_id, booking_date, value_date, amount_cents, currency,
                     counterparty, counterparty_iban, purpose, booking_text)
             VALUES (?1, ?2, ?3, ?3, ?4, 'EUR', ?5, ?6, ?7, 'Überweisung (vorgemerkt)')",
            params![
                account_id,
                format!("pending-{}", uuid::Uuid::new_v4()),
                today(),
                -job.amount_cents,
                job.recipient_name,
                job.recipient_iban,
                job.purpose
            ],
        )?;
        Vault::apply_rules_inner(&db, true)?;
        Ok(())
    }
}

/// ISO 13616 Mod-97 IBAN check (whitespace and case ignored).
#[uniffi::export]
pub fn validate_iban(iban: String) -> bool {
    crate::connectors::fints::sepa::validate_iban(&iban)
}

/// Links an unconnected stored account to `connection_id` when it matches the
/// remote one by account number / IBAN (ignoring spaces and leading zeros) or is
/// the single unlinked depot of the same bank. Sets `connection_id`, `external_ref`, `kind`.
fn adopt_unlinked(
    tx: &rusqlite::Connection,
    connection_id: i64,
    bank_name: &str,
    acc: &RemoteAccount,
) -> CoreResult<Option<i64>> {
    let norm = |x: &str| {
        x.chars()
            .filter(|c| !c.is_whitespace())
            .collect::<String>()
            .trim_start_matches('0')
            .to_uppercase()
    };
    let mut st = tx.prepare(
        "SELECT id, IFNULL(iban,''), IFNULL(account_number,''), name, IFNULL(bank_name,'') FROM accounts WHERE connection_id IS NULL",
    )?;
    let rows: Vec<(i64, String, String, String, String)> = st
        .query_map([], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        })?
        .collect::<Result<_, _>>()?;
    drop(st);
    let ours = [
        norm(&acc.iban),
        norm(&acc.account_number),
        norm(&acc.external_ref),
    ];
    let mut found = rows
        .iter()
        .find(|(_, iban, num, _, _)| {
            [norm(iban), norm(num)]
                .iter()
                .any(|f| !f.is_empty() && ours.contains(f))
        })
        .map(|r| r.0);
    if found.is_none()
        && (acc.kind == AccountKind::Brokerage || acc.name.to_lowercase().contains("depot"))
    {
        let same_bank = |b: &str| b.eq_ignore_ascii_case(bank_name);
        let depots: Vec<i64> = rows
            .iter()
            .filter(|(_, _, _, name, bank)| {
                name.to_lowercase().contains("depot") && same_bank(bank)
            })
            .map(|r| r.0)
            .collect();
        if let [only] = depots.as_slice() {
            found = Some(*only);
        }
    }
    if let Some(id) = found {
        tx.execute(
            "UPDATE accounts SET connection_id = ?1, external_ref = ?2, kind = ?3 WHERE id = ?4",
            params![connection_id, acc.external_ref, acc.kind.as_str(), id],
        )?;
    }
    Ok(found)
}

fn is_amex_name(s: &str) -> bool {
    let l = s.to_lowercase();
    l.contains("amex") || l.contains("american express")
}

/// Open card balance (negative = owed) from `(date, amount_cents, text)` rows
/// sorted ascending: sum of everything after the latest settlement booking
/// (a positive KARTENABRECHNUNG / LASTSCHRIFT / AUSGLEICH / ZAHLUNG ERHALTEN
/// entry). Without a settlement, the sum of all bookings.
pub(crate) fn open_card_balance(rows: &[(String, i64, String)]) -> Option<i64> {
    if rows.is_empty() {
        return None;
    }
    let is_settlement = |(_, amt, text): &(String, i64, String)| {
        let t = text.to_uppercase();
        *amt > 0
            && [
                "KARTENABRECHNUNG",
                "LASTSCHRIFT",
                "AUSGLEICH",
                "ZAHLUNG ERHALTEN",
            ]
            .iter()
            .any(|k| t.contains(k))
    };
    let start = match rows.iter().rposition(is_settlement) {
        Some(i) => i + 1,
        // Billing cycles cross month boundaries and a refund is no settlement:
        // without one, everything fetched belongs to the open cycle.
        None => 0,
    };
    Some(rows[start..].iter().map(|r| r.1).sum())
}

#[cfg(test)]
mod tests {
    #[test]
    fn store_fetch_matches_depot_holdings_without_iban() {
        let p = std::env::temp_dir().join(format!("girocrab-depot-{}.db", uuid::Uuid::new_v4()));
        let v = Vault::open(p.to_string_lossy().to_string(), vec![3u8; 32]).unwrap();
        let conn = v
            .add_bank_connection(ConnectorKind::Comdirect, String::new(), "login".into())
            .unwrap();
        let mk = |r: &str| RemoteHolding {
            account_ref: r.into(),
            holding: crate::models::Holding {
                isin: "DE0001234567".into(),
                name: "X".into(),
                quantity: 2.0,
                value_cents: 100,
                ..Default::default()
            },
        };
        let fetch = |hold_ref: &str| FetchResult {
            accounts: vec![RemoteAccount {
                external_ref: "0012345678".into(),
                name: "Depot".into(),
                owner: String::new(),
                iban: String::new(),
                account_number: "0012345678".into(),
                currency: "EUR".into(),
                kind: AccountKind::Brokerage,
                balance_cents: 5000,
                balance_date: "2026-11-10".into(),
            }],
            holdings: vec![mk(hold_ref)],
            ..Default::default()
        };
        // differently formatted ref (no leading zeros) and an unknown ref (single-depot fallback)
        for r in ["12345678", "unknown"] {
            store_fetch(&v, ConnectorKind::Comdirect, conn, fetch(r)).unwrap();
            let acc = v.list_accounts().unwrap().pop().unwrap();
            assert_eq!(v.list_holdings(acc.id).unwrap().len(), 1, "ref {r}");
        }
    }

    #[test]
    fn card_open_balance_since_settlement() {
        let r = |d: &str, a: i64, t: &str| (d.to_string(), a, t.to_string());
        let rows = vec![
            r("2026-09-20", -5000, "Shop"),
            r("2026-10-05", 5000, "LASTSCHRIFT Kartenabrechnung"),
            r("2026-10-10", -1200, "Cafe"),
            r("2026-11-02", -3400, "Hotel"),
        ];
        assert_eq!(open_card_balance(&rows), Some(-4600));
        let no_settle = vec![
            r("2026-10-30", -100, "x"),
            r("2026-11-01", -200, "y"),
            r("2026-11-03", -300, "z"),
        ];
        assert_eq!(open_card_balance(&no_settle), Some(-600));
        let with_refund = vec![
            r("2026-10-20", -170224, "Shops"),
            r("2026-11-02", 33853, "Refund Merchant"),
            r("2026-11-05", -1000, "Cafe"),
        ];
        assert_eq!(open_card_balance(&with_refund), Some(-137371));
        assert_eq!(open_card_balance(&[]), None);
    }

    use super::*;
    use crate::models::{BookingFilter, BookingScope};
    use crate::vault::Vault;

    fn demo_vault() -> (Arc<Vault>, std::path::PathBuf) {
        let path = std::env::temp_dir().join(format!("girocrab-sync-{}.db", uuid::Uuid::new_v4()));
        let v = Vault::open(path.to_string_lossy().to_string(), vec![3u8; 32]).unwrap();
        v.seed_demo_data().unwrap();
        (v, path)
    }

    #[test]
    fn card_holds_are_replaced_on_each_sync() {
        let (v, path) = demo_vault();
        let conn = v
            .add_bank_connection(ConnectorKind::Bunq, String::new(), "me@example.com".into())
            .unwrap();
        let acc = RemoteAccount {
            external_ref: "bunq:1".into(),
            name: "bunq".into(),
            owner: String::new(),
            iban: "NL00BUNQ0000000000".into(),
            account_number: String::new(),
            currency: "EUR".into(),
            kind: AccountKind::Checking,
            balance_cents: 0,
            balance_date: "2026-11-10".into(),
        };
        let hold = |id: &str, cents: i64| RemoteTransaction {
            account_ref: "bunq:1".into(),
            external_id: format!("pending-hold-bunq-{id}"),
            booking_date: "2026-11-09".into(),
            value_date: "2026-11-09".into(),
            amount_cents: cents,
            currency: "EUR".into(),
            counterparty: "Hotel".into(),
            counterparty_iban: String::new(),
            purpose: String::new(),
            booking_text: "Kartenzahlung (vorgemerkt)".into(),
        };
        let fetch = |txs: Vec<RemoteTransaction>| FetchResult {
            accounts: vec![acc.clone()],
            transactions: txs,
            hold_prefix: Some("pending-hold-bunq-".into()),
            ..Default::default()
        };
        let holds = || -> Vec<String> {
            let db = v.db().unwrap();
            let mut q = db
                .prepare("SELECT external_id FROM transactions WHERE external_id LIKE 'pending-hold-%' ORDER BY 1")
                .unwrap();
            q.query_map([], |r| r.get(0))
                .unwrap()
                .map(|r| r.unwrap())
                .collect()
        };
        store_fetch(
            &v,
            ConnectorKind::Bunq,
            conn,
            fetch(vec![hold("1", -50_00), hold("2", -7_10)]),
        )
        .unwrap();
        assert_eq!(holds(), vec!["pending-hold-bunq-1", "pending-hold-bunq-2"]);
        // Hold 1 cleared (booked elsewhere), hold 2 still open.
        store_fetch(&v, ConnectorKind::Bunq, conn, fetch(vec![hold("2", -7_10)])).unwrap();
        assert_eq!(holds(), vec!["pending-hold-bunq-2"]);
        std::fs::remove_file(path).ok();
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

    #[tokio::test]
    async fn demo_transfer_flow_adds_pending_booking_and_suggests_recipient() {
        let (v, path) = demo_vault();
        let acc = v
            .list_accounts()
            .unwrap()
            .into_iter()
            .find(|a| a.name == "Musterbank Girokonto" && a.connection_id.is_some())
            .unwrap();
        let req = |iban: &str, amount: i64| SepaTransferRequest {
            account_id: acc.id,
            recipient_name: "Müller GmbH".into(),
            recipient_iban: iban.into(),
            recipient_bic: None,
            amount_cents: amount,
            purpose: "Rechnung 42".into(),
            instant: false,
            execution_date: None,
        };
        assert!(v
            .clone()
            .begin_transfer(req("DE89370400440532013001", 100), "pin".into(), true)
            .is_err());
        assert!(v
            .clone()
            .begin_transfer(req("DE89370400440532013000", 0), "pin".into(), true)
            .is_err());
        let s = v
            .clone()
            .begin_transfer(req("DE89 3704 0044 0532 0130 00", 1250), "pin".into(), true)
            .unwrap();
        let mut step = s.start().await.unwrap();
        let mut challenges = 0;
        while matches!(
            step,
            TransferStep::NeedsChallenge { .. } | TransferStep::StillWaiting { .. }
        ) {
            challenges += 1;
            step = s.poll().await.unwrap();
        }
        assert!(challenges >= 2, "login + transfer challenge");
        let page = v
            .list_transactions(BookingFilter {
                account_ids: vec![acc.id],
                category_id: None,
                include_subcategories: false,
                uncategorized_only: false,
                search: Some("Müller GmbH".into()),
                date_from: None,
                date_to: None,
                limit: 10,
                offset: 0,
                scope: BookingScope::All,
                merchant_key: None,
            })
            .unwrap();
        assert_eq!(page.transactions.len(), 1);
        assert_eq!(page.transactions[0].amount_cents, -1250);
        assert_eq!(
            page.transactions[0].counterparty_iban,
            "DE89370400440532013000"
        );
        let sug = v.suggest_recipients("müller".into(), 5).unwrap();
        assert_eq!(sug.len(), 1);
        assert_eq!(sug[0].iban, "DE89370400440532013000");
        assert!(matches!(s.poll().await, Err(CoreError::SessionClosed)));
        let _ = std::fs::remove_file(path);
    }
}
