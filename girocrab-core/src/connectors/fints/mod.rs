//! FinTS 3.0 PIN/TAN connector (HBCI+), clean-room implementation of the
//! public DK specification ("FinTS 3.0 Formals", "Sicherheitsverfahren
//! PIN/TAN", "Messages – Multibankfähige Geschäftsvorfälle").
//!
//! Flow:
//!   1. Synchronisation dialog (first run only): HKIDN/HKVVB/HKSYN with
//!      security function 999 -> customer system ID, bank parameters (BPD) and
//!      the TAN methods allowed for this user (code 3920).
//!   2. Authenticated dialog: HKIDN/HKVVB + HKTAN process 4 (PSD2 SCA).
//!      The bank answers with
//!        * 3955 -> decoupled: approve in the app; poll with HKTAN process S
//!        * 0030 -> enter TAN; send HKTAN process 2 + PIN:TAN in HNSHA
//!        * 3076 / success -> no SCA needed.
//!   3. Accounts from the UPD (HIUPD, incl. the business transactions each
//!      account allows) merged with HKSPA; per account only what the bank
//!      allows: HKSAL (balance) and statements via HKCAZ (camt.052, preferred)
//!      or HKKAZ (MT940, fallback). Loan accounts get statements only if their HIUPD allows it.
//!      Segment versions are negotiated from the BPD ("HIxxxS" parameter
//!      segments): always the highest version both sides support.
//!   4. Any 9xxx return code is reported with the code and the offending
//!      segment ("9050 [HKKAZ #3] Auftragsart wird nicht unterstützt").
//!
//! The registration-bound product ID is never hardcoded; it comes from
//! Settings (`fints.product_id`).

pub mod camt;
pub mod mt940;
pub mod sepa;
pub mod syntax;

use std::collections::{HashMap, HashSet};

use async_trait::async_trait;
use base64::Engine;
use serde::{Deserialize, Serialize};

use self::syntax::{escape, parse_response, Segment, SegmentBuilder};
use super::{
    BankConnector, Challenge, ChallengeKind, ChallengeResponse, ConnectContext, FetchResult, Phase,
    RemoteAccount, TransferJob,
};
use crate::error::{CoreError, CoreResult};
use crate::i18n::{tr, trf};
use crate::models::AccountKind;
use crate::money::parse_cents;

const COUNTRY: &str = "280";

/// Persisted between syncs (in bank_connections.state_json).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct FinTsState {
    system_id: String,
    /// Chosen two-step security function (e.g. "946"), "999" = one-step.
    sec_func: String,
    tan_method_name: String,
    tan_medium: String,
    /// Supported versions per business transaction (from BPD "...S" segments).
    versions: HashMap<String, Vec<u32>>,
    /// HKxxx -> TAN required (HIPINS).
    tan_required: HashMap<String, bool>,
    /// camt descriptors from HICAZS, best first.
    #[serde(default)]
    camt_formats: Vec<String>,
}

/// Versions of each business transaction this client implements.
const IMPLEMENTED: &[(&str, &[u32])] = &[
    ("HKSAL", &[5, 6, 7, 8]),
    ("HKCAZ", &[1]),
    ("HKCCS", &[1]),
    ("HKKAZ", &[5, 6, 7]),
    ("HKTAN", &[6, 7]),
    ("HKSPA", &[1, 2, 3]),
    ("HKTAB", &[4, 5]),
    ("HKEKA", &[3, 4, 5]),
];

/// Account from the user parameter data (HIUPD).
#[derive(Debug, Clone, Default)]
struct UpdAccount {
    iban: String,
    account_number: String,
    sub_account: String,
    blz: String,
    kind_code: u32,
    currency: String,
    owner: String,
    product: String,
    /// Business transactions allowed for this account (empty = unknown, all).
    allowed: HashSet<String>,
}

fn kind_from_code(code: u32) -> AccountKind {
    // FinTS Kontoart: 1-9 Kontokorrent, 10-19 Sparkonto, 20-29 Festgeld,
    // 30-39 Depot, 40-49 Darlehen, 50-59 Kreditkarte, 60-69 Fonds-Depot,
    // 70-79 Bausparvertrag, 80-89 Versicherung, 90-99 Sonstige
    match code {
        10..=29 | 70..=79 => AccountKind::Savings,
        30..=39 | 60..=69 => AccountKind::Brokerage,
        40..=49 => AccountKind::Loan,
        50..=59 => AccountKind::CreditCard,
        _ => AccountKind::Checking,
    }
}

fn is_segment_code(s: &str) -> bool {
    s.len() == 5
        && (s.starts_with("HK") || s.starts_with("DK"))
        && s[2..].chars().all(|c| c.is_ascii_uppercase())
}

/// Parses one HIUPD segment (v4–v6).
fn parse_upd(upd: &Segment) -> UpdAccount {
    let mut a = UpdAccount {
        account_number: upd.get(1, 0).to_string(),
        sub_account: upd.get(1, 1).to_string(),
        blz: upd.get(1, 3).to_string(),
        iban: upd.get(2, 0).to_string(),
        kind_code: upd.get(4, 0).parse().unwrap_or(1),
        currency: upd.get(5, 0).to_string(),
        owner: format!("{} {}", upd.get(6, 0), upd.get(7, 0))
            .trim()
            .to_string(),
        product: upd.get(8, 0).to_string(),
        allowed: HashSet::new(),
    };
    // HIUPD v4/v5 have no IBAN element: shift if element 2 is the customer id
    if !a.iban.is_empty()
        && !(a.iban.len() >= 15 && a.iban[..2].chars().all(|c| c.is_ascii_uppercase()))
    {
        a.iban.clear();
    }
    for el in upd.elements.iter().skip(9) {
        if let Some(first) = el.first() {
            if is_segment_code(first.text()) {
                a.allowed.insert(first.text().to_string());
            }
        }
    }
    a
}

#[derive(Debug, Clone)]
struct SepaAccount {
    iban: String,
    bic: String,
    account_number: String,
    sub_account: String,
    blz: String,
}

#[derive(Debug, Clone)]
struct BankReply {
    segments: Vec<Segment>,
    /// (code, reference segment number, text, params)
    codes: Vec<(String, Option<u32>, String, Vec<String>)>,
    /// Segment number -> segment id of the request (for error messages).
    sent: HashMap<u32, String>,
}

impl BankReply {
    fn has(&self, code: &str) -> bool {
        self.codes.iter().any(|c| c.0 == code)
    }
    fn code(&self, code: &str) -> Option<&(String, Option<u32>, String, Vec<String>)> {
        self.codes.iter().find(|c| c.0 == code)
    }
    fn errors(&self) -> Vec<&(String, Option<u32>, String, Vec<String>)> {
        self.codes.iter().filter(|c| c.0.starts_with('9')).collect()
    }
    fn first(&self, id: &str) -> Option<&Segment> {
        self.segments.iter().find(|s| s.id() == id)
    }
    fn all<'a>(&'a self, id: &'a str) -> impl Iterator<Item = &'a Segment> + 'a {
        self.segments.iter().filter(move |s| s.id() == id)
    }
    /// "9050 [HKKAZ #3] Auftragsart wird nicht unterstützt"
    fn describe(&self, code: &(String, Option<u32>, String, Vec<String>)) -> String {
        let seg = match code.1 {
            Some(n) => format!(
                "[{} #{n}]",
                self.sent
                    .get(&n)
                    .cloned()
                    .unwrap_or_else(|| "Segment".into())
            ),
            None => "[Nachricht]".into(),
        };
        let params = if code.3.is_empty() {
            String::new()
        } else {
            format!(" ({})", code.3.join(", "))
        };
        format!("{} {} {}{}", code.0, seg, code.2, params)
    }

    /// Like `check`, but with German explanations for typical HKCCS rejections.
    fn check_transfer(&self) -> CoreResult<()> {
        let errs = self.errors();
        let Some(first) = errs.first() else {
            return Ok(());
        };
        let msg = errs
            .iter()
            .map(|e| explain_transfer_code(e))
            .collect::<Vec<_>>()
            .join(" / ");
        Err(CoreError::Bank {
            code: first.0.clone(),
            message: msg,
        })
    }

    fn check(&self) -> CoreResult<()> {
        let errs = self.errors();
        if let Some(e) = errs.first() {
            return Err(CoreError::Bank {
                code: e.0.clone(),
                message: errs
                    .iter()
                    .map(|e| self.describe(e))
                    .collect::<Vec<_>>()
                    .join(" / "),
            });
        }
        Ok(())
    }
}

pub struct FinTsConnector {
    blz: String,
    url: String,
    client: Option<reqwest::Client>,
    dialog_id: String,
    msg_no: u32,
    st: FinTsState,
    task_reference: Option<String>,
    challenge: Option<Challenge>,
    tan_for_next: Option<String>,
    product_id: String,
    product_version: String,
    /// Accounts from the user parameter data (HIUPD).
    upd: Vec<UpdAccount>,
    /// A SEPA transfer (HKCCS) is awaiting its TAN.
    transferring: bool,
}

impl FinTsConnector {
    pub fn new(blz: &str) -> Self {
        FinTsConnector {
            blz: blz.to_string(),
            url: String::new(),
            client: None,
            dialog_id: "0".into(),
            msg_no: 1,
            st: FinTsState::default(),
            task_reference: None,
            challenge: None,
            tan_for_next: None,
            product_id: String::new(),
            product_version: String::new(),
            upd: Vec::new(),
            transferring: false,
        }
    }

    fn now() -> (String, String) {
        let n = chrono::Local::now();
        (
            n.format("%Y%m%d").to_string(),
            n.format("%H%M%S").to_string(),
        )
    }

    fn system_id(&self) -> &str {
        if self.st.system_id.is_empty() {
            "0"
        } else {
            &self.st.system_id
        }
    }

    /// Highest version of `tx` that both the bank (BPD) and this client support.
    fn negotiated(&self, tx: &str) -> Option<u32> {
        let ours = IMPLEMENTED
            .iter()
            .find(|(k, _)| *k == tx)
            .map(|(_, v)| *v)
            .unwrap_or(&[]);
        self.st
            .versions
            .get(tx)
            .and_then(|vs| vs.iter().copied().filter(|v| ours.contains(v)).max())
    }

    /// Like `negotiated`, but falls back to our highest version when the bank
    /// sent no parameters for it (e.g. before the first BPD).
    fn version(&self, tx: &str) -> u32 {
        self.negotiated(tx).unwrap_or_else(|| {
            IMPLEMENTED
                .iter()
                .find(|(k, _)| *k == tx)
                .and_then(|(_, v)| v.iter().max().copied())
                .unwrap_or(1)
        })
    }

    fn bank_supports(&self, tx: &str) -> bool {
        self.negotiated(tx).is_some()
    }

    /// Wraps payload segments (numbered from 3) into a signed, "encrypted"
    /// PIN/TAN message and returns the wire bytes.
    fn build_message(
        &self,
        ctx: &ConnectContext,
        payload: &[Vec<u8>],
        sec_func: &str,
        tan: Option<&str>,
    ) -> Vec<u8> {
        let (date, time) = Self::now();
        let user = escape(&ctx.login_name);
        let ctrl_ref = format!("{}", rand::random::<u32>() % 9_000_000 + 1_000_000);
        let mut inner: Vec<u8> = Vec::new();
        inner.extend(
            SegmentBuilder::new("HNSHK", 2, 4)
                .raw("PIN:2")
                .raw(sec_func)
                .raw(&ctrl_ref)
                .raw("1")
                .raw("1")
                .raw(&format!("1::{}", escape(self.system_id())))
                .raw("1")
                .raw(&format!("1:{date}:{time}"))
                .raw("1:999:1")
                .raw("6:10:16")
                .raw(&format!("{COUNTRY}:{}:{user}:S:0:0", self.blz))
                .build(),
        );
        for p in payload {
            inner.extend_from_slice(p);
        }
        let n_sha = 3 + payload.len() as u32;
        let pin = escape(ctx.secret.expose());
        let auth = match tan {
            Some(t) => format!("{pin}:{}", escape(t)),
            None => pin,
        };
        inner.extend(
            SegmentBuilder::new("HNSHA", n_sha, 2)
                .raw(&ctrl_ref)
                .raw("")
                .raw(&auth)
                .build(),
        );

        let hnvsk = SegmentBuilder::new("HNVSK", 998, 3)
            .raw("PIN:2")
            .raw("998")
            .raw("1")
            .raw(&format!("1::{}", escape(self.system_id())))
            .raw(&format!("1:{date}:{time}"))
            .raw("2:2:13:@8@00000000:5:1")
            .raw(&format!("{COUNTRY}:{}:{user}:V:0:0", self.blz))
            .raw("0")
            .build();
        let hnvsd = SegmentBuilder::new("HNVSD", 999, 1).binary(&inner).build();
        let hnhbs = SegmentBuilder::new("HNHBS", n_sha + 1, 1)
            .raw(&self.msg_no.to_string())
            .build();

        let build = |size: usize| {
            let mut m = SegmentBuilder::new("HNHBK", 1, 3)
                .raw(&format!("{size:012}"))
                .raw("300")
                .raw(&escape(&self.dialog_id))
                .raw(&self.msg_no.to_string())
                .build();
            m.extend_from_slice(&hnvsk);
            m.extend_from_slice(&hnvsd);
            m.extend_from_slice(&hnhbs);
            m
        };
        let len = build(0).len();
        build(len)
    }

    async fn send(
        &mut self,
        ctx: &ConnectContext,
        payload: Vec<Vec<u8>>,
        sec_func: &str,
        tan: Option<&str>,
    ) -> CoreResult<BankReply> {
        let mut sent = HashMap::new();
        sent.insert(2, "HNSHK".to_string());
        for p in &payload {
            let head = crate::text::decode_bank_bytes(&p[..p.len().min(16)]);
            let mut it = head.split(':');
            if let (Some(id), Some(n)) = (it.next(), it.next().and_then(|n| n.parse::<u32>().ok()))
            {
                sent.insert(n, id.to_string());
            }
        }
        sent.insert(3 + payload.len() as u32, "HNSHA".to_string());
        let msg = self.build_message(ctx, &payload, sec_func, tan);
        let client = match &self.client {
            Some(c) => c.clone(),
            None => {
                let c = super::http_client()?;
                self.client = Some(c.clone());
                c
            }
        };
        let body = base64::engine::general_purpose::STANDARD.encode(&msg);
        let resp = client
            .post(&self.url)
            .header("Content-Type", "text/plain")
            .body(body)
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(CoreError::Network {
                message: format!("FinTS server answered HTTP {}", resp.status()),
            });
        }
        let text = resp.text().await?;
        let cleaned: String = text.chars().filter(|c| !c.is_whitespace()).collect();
        let raw = base64::engine::general_purpose::STANDARD
            .decode(cleaned.as_bytes())
            .map_err(|e| CoreError::Protocol {
                message: format!("base64: {e}"),
            })?;
        let segments = parse_response(&raw)?;
        self.msg_no += 1;
        let mut codes = Vec::new();
        for s in &segments {
            if s.id() == "HIRMG" || s.id() == "HIRMS" {
                for el in s.elements.iter().skip(1) {
                    let t = |i: usize| el.get(i).map(|v| v.text().to_string()).unwrap_or_default();
                    let params = el.iter().skip(3).map(|v| v.text().to_string()).collect();
                    codes.push((t(0), s.reference(), t(2), params));
                }
            }
        }
        if let Some(h) = segments.iter().find(|s| s.id() == "HNHBK") {
            let did = h.get(3, 0);
            if !did.is_empty() && did != "0" {
                self.dialog_id = did.to_string();
            }
        }
        Ok(BankReply {
            segments,
            codes,
            sent,
        })
    }

    fn reset_dialog(&mut self) {
        self.dialog_id = "0".into();
        self.msg_no = 1;
    }

    fn learn_bpd(&mut self, reply: &BankReply) {
        for s in &reply.segments {
            let id = s.id();
            if id.starts_with("HI") && id.ends_with('S') && id.len() == 6 {
                let tx = format!("HK{}", &id[2..5]);
                let v = self.st.versions.entry(tx).or_default();
                if !v.contains(&s.version()) {
                    v.push(s.version());
                }
            }
            if id == "HIPINS" {
                // last element: list of (segment, J/N) pairs after 5 PIN fields
                if let Some(el) = s.elements.last() {
                    let texts: Vec<&str> = el.iter().map(|v| v.text()).collect();
                    for pair in texts.windows(2) {
                        if pair[0].starts_with("HK")
                            && pair[0].len() == 5
                            && (pair[1] == "J" || pair[1] == "N")
                        {
                            self.st
                                .tan_required
                                .insert(pair[0].to_string(), pair[1] == "J");
                        }
                    }
                }
            }
        }
        for cazs in reply.all("HICAZS") {
            for el in &cazs.elements {
                for v in el {
                    let t = v.text();
                    if t.contains("camt.052") && !self.st.camt_formats.iter().any(|f| f == t) {
                        self.st.camt_formats.push(t.to_string());
                    }
                }
            }
            // best (newest) format first: …camt.052.001.08 > …001.02
            self.st.camt_formats.sort_by(|a, b| b.cmp(a));
        }
        let upds: Vec<UpdAccount> = reply.all("HIUPD").map(parse_upd).collect();
        for a in upds {
            if let Some(existing) = self
                .upd
                .iter_mut()
                .find(|e| e.account_number == a.account_number && e.sub_account == a.sub_account)
            {
                *existing = a;
            } else {
                self.upd.push(a);
            }
        }
        if let Some(sync) = reply.first("HISYN") {
            let id = sync.get(1, 0);
            if !id.is_empty() {
                self.st.system_id = id.to_string();
            }
        }
        // Allowed TAN methods for this user.
        if let Some(c) = reply.code("3920") {
            let allowed: Vec<String> =
                c.3.iter()
                    .filter(|p| !p.is_empty() && p.as_str() != "999")
                    .cloned()
                    .collect();
            let names = self.tan_method_names(reply);
            if !allowed.is_empty()
                && (self.st.sec_func.is_empty() || !allowed.contains(&self.st.sec_func))
            {
                // Prefer app based / decoupled methods.
                let pick = choose_tan_function(&allowed, &names);
                self.st.tan_method_name = names.get(&pick).cloned().unwrap_or_default();
                self.st.sec_func = pick;
            }
        }
        if let Some(hitab) = reply.first("HITAB") {
            for el in hitab.elements.iter().skip(2) {
                let texts: Vec<&str> = el.iter().map(|v| v.text()).collect();
                if texts.get(1) == Some(&"1") {
                    if let Some(name) = texts
                        .iter()
                        .skip(2)
                        .find(|t| t.chars().any(|c| c.is_alphabetic()) && t.len() > 2)
                    {
                        self.st.tan_medium = name.to_string();
                        break;
                    }
                }
            }
        }
    }

    /// code -> human name, from HITANS (v6/v7: code, process, tech id, ZKA name, ZKA version, name …).
    fn tan_method_names(&self, reply: &BankReply) -> HashMap<String, String> {
        let mut out = HashMap::new();
        for s in reply.all("HITANS") {
            if let Some(el) = s.elements.get(4) {
                let t: Vec<&str> = el.iter().map(|v| v.text()).collect();
                for i in 0..t.len().saturating_sub(5) {
                    if t[i].len() == 3
                        && t[i].starts_with('9')
                        && (t[i + 1] == "1" || t[i + 1] == "2")
                    {
                        out.insert(t[i].to_string(), t[i + 5].to_string());
                    }
                }
            }
        }
        out
    }

    fn hkidn(&self, ctx: &ConnectContext, n: u32) -> Vec<u8> {
        SegmentBuilder::new("HKIDN", n, 2)
            .raw(&format!("{COUNTRY}:{}", self.blz))
            .de(&[&ctx.login_name])
            .de(&[self.system_id()])
            .raw("1")
            .build()
    }

    fn hkvvb(&self, n: u32) -> Vec<u8> {
        SegmentBuilder::new("HKVVB", n, 3)
            .raw("0")
            .raw("0")
            .raw("0")
            .de(&[&self.product_id])
            .de(&[&self.product_version])
            .build()
    }

    fn hktan_process4(&self, n: u32, reference_segment: &str) -> Vec<u8> {
        let mut b = SegmentBuilder::new("HKTAN", n, self.version("HKTAN"))
            .raw("4")
            .raw(reference_segment);
        if !self.st.tan_medium.is_empty() {
            for _ in 0..8 {
                b = b.raw("");
            }
            b = b.de(&[&self.st.tan_medium]);
        }
        b.build()
    }

    /// Analyses a reply that may carry a TAN challenge.
    fn challenge_from(&mut self, reply: &BankReply) -> CoreResult<Option<Phase>> {
        let hitan = reply.first("HITAN");
        if let Some(h) = hitan {
            let task = h.get(3, 0);
            if !task.is_empty() && task != "noref" {
                self.task_reference = Some(task.to_string());
            }
        }
        let challenge_text = hitan.map(|h| h.get(4, 0).to_string()).unwrap_or_default();
        let method = if self.st.tan_method_name.is_empty() {
            trf("TAN-Verfahren {0}", &[&self.st.sec_func])
        } else {
            self.st.tan_method_name.clone()
        };
        if reply.has("3955") || reply.has("3956") {
            let c = Challenge {
                kind: ChallengeKind::DecoupledPush,
                title: tr("Bitte in der Banking-App freigeben").into(),
                message: if challenge_text.is_empty() {
                    reply
                        .code("3955")
                        .or(reply.code("3956"))
                        .map(|c| c.2.clone())
                        .unwrap_or_default()
                } else {
                    clean_challenge(&challenge_text)
                },
                method_name: method,
                redirect_url: None,
                image: None,
                expires_in_seconds: Some(300),
                poll_interval_seconds: 3,
            };
            self.challenge = Some(c.clone());
            return Ok(Some(if reply.has("3956") {
                Phase::Pending(c)
            } else {
                Phase::Challenge(c)
            }));
        }
        if reply.has("0030") && self.task_reference.is_some() {
            let image = hitan
                .and_then(|h| h.binary(5))
                .map(|b| b.to_vec())
                .filter(|b| b.len() > 64);
            let c = Challenge {
                kind: if image.is_some() {
                    ChallengeKind::ImageCode
                } else {
                    ChallengeKind::Code
                },
                title: tr("TAN eingeben").into(),
                message: clean_challenge(&challenge_text),
                method_name: method,
                redirect_url: None,
                image: image.map(strip_mime_header),
                expires_in_seconds: Some(300),
                poll_interval_seconds: 0,
            };
            self.challenge = Some(c.clone());
            return Ok(Some(Phase::Challenge(c)));
        }
        Ok(None)
    }

    async fn sync_dialog(&mut self, ctx: &ConnectContext) -> CoreResult<()> {
        self.reset_dialog();
        let payload = vec![
            self.hkidn(ctx, 3),
            self.hkvvb(4),
            SegmentBuilder::new("HKSYN", 5, 3).raw("0").build(),
        ];
        let reply = self.send(ctx, payload, "999", None).await?;
        reply.check()?;
        self.learn_bpd(&reply);
        // Optional: TAN media list (needed by some banks for HKTAN).
        let tab_v = self.version("HKTAB");
        if self.bank_supports("HKTAB") {
            if let Ok(r) = self
                .send(
                    ctx,
                    vec![SegmentBuilder::new("HKTAB", 3, tab_v)
                        .raw("0")
                        .raw("A")
                        .build()],
                    "999",
                    None,
                )
                .await
            {
                self.learn_bpd(&r);
            }
        }
        self.end_dialog(ctx, "999").await;
        if self.st.system_id.is_empty() {
            return Err(CoreError::Protocol {
                message: "bank did not assign a customer system ID (HISYN)".into(),
            });
        }
        Ok(())
    }

    async fn end_dialog(&mut self, ctx: &ConnectContext, sec_func: &str) {
        if self.dialog_id != "0" {
            let seg = SegmentBuilder::new("HKEND", 3, 1)
                .de(&[&self.dialog_id.clone()])
                .build();
            let _ = self.send(ctx, vec![seg], sec_func, None).await;
        }
        self.reset_dialog();
    }

    /// Sends one business segment; adds HKTAN process 4 (referencing that
    /// segment) when the bank requires SCA for it (HIPINS), and waits for a
    /// decoupled approval (HKTAN process S polling) if the bank asks for one.
    async fn request(
        &mut self,
        ctx: &ConnectContext,
        seg_id: &str,
        segment: Vec<u8>,
    ) -> CoreResult<BankReply> {
        let sec = self.sec();
        let mut payload = vec![segment];
        if sec != "999" && self.st.tan_required.get(seg_id) == Some(&true) {
            payload.push(self.hktan_process4(4, seg_id));
        }
        let mut reply = self.send(ctx, payload, &sec, None).await?;
        if reply.has("3955") || reply.has("3956") {
            let _ = self.challenge_from(&reply)?;
            let task = self
                .task_reference
                .clone()
                .ok_or_else(|| CoreError::Protocol {
                    message: trf("{0}: Freigabe ohne Auftragsreferenz", &[&seg_id]),
                })?;
            for _ in 0..60 {
                tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                let seg = SegmentBuilder::new("HKTAN", 3, self.version("HKTAN"))
                    .raw("S")
                    .raw("")
                    .raw("")
                    .raw("")
                    .de(&[&task])
                    .raw("N")
                    .build();
                let r = self.send(ctx, vec![seg], &sec, None).await?;
                if !r.has("3956") {
                    reply = r;
                    break;
                }
            }
        } else if reply.has("0030") {
            return Err(CoreError::Bank {
                code: "0030".into(),
                message: trf("Die Bank verlangt für {0} eine TAN-Eingabe. Bitte ein Push-/App-Verfahren (z. B. SecureGo plus) verwenden oder „Tage beim ersten Abruf“ auf höchstens 90 setzen.", &[&seg_id]),
            });
        }
        reply.check()?;
        Ok(reply)
    }

    /// Accounts from UPD merged with HKSPA (BIC/IBAN). Returns (account, upd).
    async fn account_list(
        &mut self,
        ctx: &ConnectContext,
        errors: &mut Vec<String>,
    ) -> Vec<(SepaAccount, Option<UpdAccount>)> {
        let mut sepa: Vec<SepaAccount> = Vec::new();
        if self.bank_supports("HKSPA") {
            let v = self.version("HKSPA");
            match self
                .request(ctx, "HKSPA", SegmentBuilder::new("HKSPA", 3, v).build())
                .await
            {
                Ok(reply) => {
                    for hispa in reply.all("HISPA") {
                        for el in hispa.elements.iter().skip(1) {
                            let t = |i: usize| {
                                el.get(i).map(|v| v.text().to_string()).unwrap_or_default()
                            };
                            if !t(1).is_empty() {
                                sepa.push(SepaAccount {
                                    iban: t(1),
                                    bic: t(2),
                                    account_number: t(3),
                                    sub_account: t(4),
                                    blz: t(6),
                                });
                            }
                        }
                    }
                }
                Err(e) => errors.push(trf("Kontenliste (HKSPA) – {0}", &[&e])),
            }
        }
        let mut out: Vec<(SepaAccount, Option<UpdAccount>)> = Vec::new();
        for u in self.upd.clone() {
            // Only accounts of this bank with at least one usable transaction
            let usable = u.allowed.is_empty()
                || ["HKSAL", "HKCAZ", "HKKAZ"]
                    .iter()
                    .any(|t| u.allowed.contains(*t));
            if !usable {
                continue;
            }
            let s = sepa.iter().find(|s| {
                (!u.iban.is_empty() && s.iban == u.iban)
                    || (s.account_number == u.account_number && !u.account_number.is_empty())
            });
            let acc = SepaAccount {
                iban: s.map(|s| s.iban.clone()).unwrap_or_else(|| u.iban.clone()),
                bic: s.map(|s| s.bic.clone()).unwrap_or_default(),
                account_number: u.account_number.clone(),
                sub_account: u.sub_account.clone(),
                blz: if u.blz.is_empty() {
                    self.blz.clone()
                } else {
                    u.blz.clone()
                },
            };
            out.push((acc, Some(u)));
        }
        for s in sepa {
            if !out.iter().any(|(a, _)| a.iban == s.iban) {
                out.push((s, None));
            }
        }
        out
    }

    async fn balance(
        &mut self,
        ctx: &ConnectContext,
        acc: &SepaAccount,
    ) -> CoreResult<Option<(i64, String, String)>> {
        let v = self.version("HKSAL");
        let acct = if v >= 7 {
            Self::kti(acc)
        } else {
            Self::ktv(acc)
        };
        let r = self
            .request(
                ctx,
                "HKSAL",
                SegmentBuilder::new("HKSAL", 3, v)
                    .raw(&acct)
                    .raw("N")
                    .build(),
            )
            .await?;
        Ok(r.first("HISAL").and_then(|s| {
            // element 4: booked balance  C|D : amount : currency : date
            let c = parse_cents(s.get(4, 1)).ok()?;
            let sign = if s.get(4, 0) == "D" { -1 } else { 1 };
            let cur = if s.get(4, 2).is_empty() {
                "EUR".to_string()
            } else {
                s.get(4, 2).to_string()
            };
            let d = s.get(4, 3);
            let date = if d.len() == 8 {
                format!("{}-{}-{}", &d[..4], &d[4..6], &d[6..])
            } else {
                super::today()
            };
            Some((sign * c, cur, date))
        }))
    }

    fn hkcaz(
        &self,
        acc: &SepaAccount,
        format: &str,
        from: &str,
        to: &str,
        touchdown: Option<&str>,
    ) -> Vec<u8> {
        let mut b = SegmentBuilder::new("HKCAZ", 3, self.version("HKCAZ"))
            .raw(&Self::kti(acc))
            .de(&[format])
            .raw("N")
            .raw(from)
            .raw(to)
            .raw("");
        if let Some(t) = touchdown {
            b = b.de(&[t]);
        }
        b.build()
    }

    async fn statements_camt(
        &mut self,
        ctx: &ConnectContext,
        acc: &SepaAccount,
        label: &str,
    ) -> CoreResult<(Vec<super::RemoteTransaction>, Option<i64>)> {
        let format = self.st.camt_formats.first().cloned().unwrap_or_default();
        let from = ctx.since.replace('-', "");
        let to = super::today().replace('-', "");
        let mut touchdown: Option<String> = None;
        let mut txs = Vec::new();
        let mut closing = None;
        for _page in 0..50 {
            let seg = self.hkcaz(acc, &format, &from, &to, touchdown.as_deref());
            let r = self.request(ctx, "HKCAZ", seg).await?;
            for s in r.all("HICAZ") {
                // element 3: booked camt documents (one or more binaries)
                for v in s.element(3) {
                    if let syntax::Value::Binary(xml) = v {
                        // raw @len@ slice, decoded as the XML's own encoding (UTF-8) – never via the Latin-1 envelope
                        let (t, rep) = camt::parse(&crate::text::decode_xml_bytes(xml), label);
                        txs.extend(t);
                        if rep.closing_balance_cents.is_some() {
                            closing = rep.closing_balance_cents;
                        }
                    }
                }
            }
            touchdown = r.code("3040").and_then(|c| c.3.first().cloned());
            if touchdown.is_none() {
                break;
            }
        }
        Ok((txs, closing))
    }

    async fn statements_mt940(
        &mut self,
        ctx: &ConnectContext,
        acc: &SepaAccount,
        label: &str,
        currency: &str,
    ) -> CoreResult<(Vec<super::RemoteTransaction>, Option<i64>)> {
        let v = self.version("HKKAZ");
        let acct = if v >= 7 {
            Self::kti(acc)
        } else {
            Self::ktv(acc)
        };
        let from = ctx.since.replace('-', "");
        let to = super::today().replace('-', "");
        let mut touchdown: Option<String> = None;
        let mut data = Vec::<u8>::new();
        for _page in 0..50 {
            let mut b = SegmentBuilder::new("HKKAZ", 3, v)
                .raw(&acct)
                .raw("N")
                .raw(&from)
                .raw(&to)
                .raw("");
            if let Some(t) = &touchdown {
                b = b.de(&[t]);
            }
            let r = self.request(ctx, "HKKAZ", b.build()).await?;
            for s in r.all("HIKAZ") {
                if let Some(b) = s.binary(1) {
                    data.extend_from_slice(b);
                    data.extend_from_slice(b"\r\n");
                }
            }
            touchdown = r.code("3040").and_then(|c| c.3.first().cloned());
            if touchdown.is_none() {
                break;
            }
        }
        let (txs, stmt) = mt940::parse(&crate::text::decode_bank_bytes(&data), label, currency);
        Ok((txs, stmt.closing_balance_cents))
    }

    /// HKEKA: electronic statement as PDF (format 3). Optional – any error is ignored by the caller.
    async fn statements_pdf(
        &mut self,
        ctx: &ConnectContext,
        acc: &SepaAccount,
        label: &str,
    ) -> CoreResult<Vec<crate::documents::RemoteDocument>> {
        let v = self.version("HKEKA");
        let acct = if v >= 5 {
            Self::kti(acc)
        } else {
            Self::ktv(acc)
        };
        let mut docs = Vec::new();
        let mut touchdown: Option<String> = None;
        for _page in 0..12 {
            let mut b = SegmentBuilder::new("HKEKA", 3, v)
                .raw(&acct)
                .raw("3")
                .raw("")
                .raw("")
                .raw("");
            if let Some(t) = &touchdown {
                b = b.de(&[t]);
            }
            let r = self.request(ctx, "HKEKA", b.build()).await?;
            for s in r.all("HIEKA") {
                let period = format!("{}–{}", s.get(2, 0), s.get(2, 1));
                for el in &s.elements {
                    for val in el {
                        if let syntax::Value::Binary(pdf) = val {
                            if pdf.starts_with(b"%PDF") {
                                let to = s.get(2, 1);
                                let date = if to.len() == 8 {
                                    format!("{}-{}-{}", &to[..4], &to[4..6], &to[6..])
                                } else {
                                    super::today()
                                };
                                docs.push(crate::documents::RemoteDocument {
                                    account_ref: label.to_string(),
                                    booking_external_id: None,
                                    title: trf("Kontoauszug {0}", &[&period]),
                                    doc_type: "kontoauszug".into(),
                                    mime_type: "application/pdf".into(),
                                    file_name: format!("Kontoauszug_{}_{}.pdf", label, date),
                                    source_url: format!("fints:hkeka:{label}:{period}"),
                                    bytes: pdf.clone(),
                                    date,
                                });
                            }
                        }
                    }
                }
            }
            touchdown = r.code("3040").and_then(|c| c.3.first().cloned());
            if touchdown.is_none() {
                break;
            }
        }
        Ok(docs)
    }

    fn check_reply(&self, reply: &BankReply) -> CoreResult<()> {
        if self.transferring {
            reply.check_transfer()
        } else {
            reply.check()
        }
    }

    /// Sends HKCCS + HKTAN (process 4) and returns the bank's reply.
    async fn submit_hkccs(
        &mut self,
        ctx: &ConnectContext,
        job: &TransferJob,
    ) -> CoreResult<BankReply> {
        let not_allowed = || {
            CoreError::Bank {
            code: "HKCCS".into(),
            message: tr("Dieses Konto oder diese Bank erlaubt keine SEPA-Überweisungen per FinTS (HKCCS). Bitte in der Banking-App überweisen.").into(),
        }
        };
        if !self.bank_supports("HKCCS") {
            return Err(not_allowed());
        }
        let sec = self.sec();
        if sec == "999" {
            return Err(CoreError::Bank {
                code: "HKTAN".into(),
                message: tr("Für Überweisungen ist ein TAN-Verfahren nötig; es wurde keines gefunden. Bitte zuerst eine Synchronisation mit TAN-Verfahren durchführen.").into(),
            });
        }
        let mut errors = Vec::new();
        let accounts = self.account_list(ctx, &mut errors).await;
        let want = sepa::normalize_iban(&job.source_iban);
        let (acc, upd) = accounts
            .into_iter()
            .find(|(a, _)| sepa::normalize_iban(&a.iban) == want)
            .ok_or_else(|| CoreError::NotFound {
                what: trf(
                    "Konto {0} bei der Bank{1}",
                    &[
                        &job.source_iban,
                        &if errors.is_empty() {
                            String::new()
                        } else {
                            format!(" ({})", errors.join(" / "))
                        },
                    ],
                ),
            })?;
        if let Some(u) = &upd {
            if !u.allowed.is_empty() && !u.allowed.contains("HKCCS") {
                return Err(not_allowed());
            }
        }
        let (date, time) = Self::now();
        let created = format!(
            "{}-{}-{}T{}:{}:{}",
            &date[..4],
            &date[4..6],
            &date[6..],
            &time[..2],
            &time[2..4],
            &time[4..]
        );
        let exec = format!("{}-{}-{}", &date[..4], &date[4..6], &date[6..]);
        let msg_id = format!("GC{date}{time}{}", rand::random::<u16>());
        let owner = if job.source_owner.trim().is_empty() {
            "Kontoinhaber"
        } else {
            job.source_owner.trim()
        };
        let xml = sepa::build_pain001(&sepa::Pain001 {
            message_id: &msg_id,
            created: &created,
            execution_date: &exec,
            debtor_name: owner,
            debtor_iban: &acc.iban,
            debtor_bic: &acc.bic,
            creditor_name: &job.recipient_name,
            creditor_iban: &job.recipient_iban,
            creditor_bic: job.recipient_bic.as_deref(),
            amount_cents: job.amount_cents,
            purpose: &job.purpose,
        })?;
        let hkccs = SegmentBuilder::new("HKCCS", 3, self.version("HKCCS"))
            .raw(&Self::kti(&acc))
            .de(&[sepa::PAIN_DESCRIPTOR])
            .binary(xml.as_bytes())
            .build();
        let payload = vec![hkccs, self.hktan_process4(4, "HKCCS")];
        let reply = self.send(ctx, payload, &sec, None).await?;
        reply.check_transfer()?;
        Ok(reply)
    }

    fn sec(&self) -> String {
        if self.st.sec_func.is_empty() {
            "999".into()
        } else {
            self.st.sec_func.clone()
        }
    }

    /// KTI: IBAN:BIC, or (without IBAN, e.g. loans) ::Konto:Unterkonto:280:BLZ.
    fn kti(acc: &SepaAccount) -> String {
        if acc.iban.is_empty() {
            format!(
                "::{}:{}:{COUNTRY}:{}",
                escape(&acc.account_number),
                escape(&acc.sub_account),
                acc.blz
            )
        } else {
            format!("{}:{}", escape(&acc.iban), escape(&acc.bic))
        }
    }

    fn ktv(acc: &SepaAccount) -> String {
        format!(
            "{}:{}:{COUNTRY}:{}",
            escape(&acc.account_number),
            escape(&acc.sub_account),
            acc.blz
        )
    }
}

/// Localised text for a bank return code (HIRMG/HIRMS) during a transfer.
fn explain_transfer_code(c: &(String, Option<u32>, String, Vec<String>)) -> String {
    let hint = match c.0.as_str() {
        "9050" => tr("Die Nachricht enthält Fehler."),
        "9010" => tr("Die Bank hat die Nachricht nicht verarbeitet."),
        "9120" | "9130" | "9140" | "9160" => {
            tr("Ein Pflichtfeld der Überweisung fehlt oder ist ungültig.")
        }
        "9210" => tr("Der Auftrag wurde abgelehnt (Daten ungültig oder nicht erlaubt)."),
        "9340" => tr("Der Auftrag ist ungültig; bitte IBAN, Betrag und Name prüfen."),
        "9380" => tr("Der Betrag überschreitet das Limit des Kontos."),
        "9390" => tr("Das Konto lässt diese Überweisung nicht zu."),
        "9391" => tr("Das Konto ist für Überweisungen gesperrt."),
        "9931" | "9942" => tr("PIN oder Zugangsdaten wurden abgelehnt."),
        "9941" => tr("Die TAN ist ungültig oder abgelaufen."),
        "9955" | "9956" => tr("Die Freigabe wurde abgelehnt oder ist abgelaufen."),
        "9075" => {
            tr("Starke Kundenauthentifizierung ist erforderlich, wurde aber nicht abgeschlossen.")
        }
        _ => "",
    };
    let params = if c.3.is_empty() {
        String::new()
    } else {
        format!(" ({})", c.3.join(", "))
    };
    if hint.is_empty() {
        trf(
            "{0} Die Bank hat die Überweisung abgelehnt: {1}{2}",
            &[&c.0, &c.2, &params],
        )
    } else {
        trf("{0} {1} Bank: {2}{3}", &[&c.0, &hint, &c.2, &params])
    }
}

/// Picks the TAN function from the codes allowed by 3920: app/decoupled
/// methods first (SecureGo plus, pushTAN …), then a fixed preference list,
/// never 999 (one-step).
fn choose_tan_function(allowed: &[String], names: &HashMap<String, String>) -> String {
    let by_name = allowed.iter().find(|a| {
        let n = names.get(*a).map(|s| s.to_lowercase()).unwrap_or_default();
        [
            "decoupled",
            "securego",
            "pushtan",
            "push",
            "app",
            "banking-app",
        ]
        .iter()
        .any(|k| n.contains(k))
    });
    if let Some(a) = by_name {
        return a.clone();
    }
    for pref in [
        "946", "944", "942", "921", "962", "972", "982", "920", "923", "913", "912", "911", "910",
        "900",
    ] {
        if allowed.iter().any(|a| a == pref) {
            return pref.to_string();
        }
    }
    allowed.first().cloned().unwrap_or_else(|| "999".into())
}

fn clean_challenge(s: &str) -> String {
    s.replace("<br>", "\n")
        .replace("<br/>", "\n")
        .replace("<b>", "")
        .replace("</b>", "")
        .trim()
        .to_string()
}

/// photoTAN images come as 2-byte length + MIME type + 2-byte length + data.
fn strip_mime_header(b: Vec<u8>) -> Vec<u8> {
    if b.len() > 4 {
        let l = ((b[0] as usize) << 8) | b[1] as usize;
        if l > 0 && l < 64 && b.len() > l + 4 && b[2..2 + l].starts_with(b"image/") {
            return b[l + 4..].to_vec();
        }
    }
    b
}

#[async_trait]
impl BankConnector for FinTsConnector {
    async fn begin(&mut self, ctx: &ConnectContext) -> CoreResult<Phase> {
        self.url = ctx.setting(&format!("fints.url.{}", self.blz))?.to_string();
        self.product_id = ctx.setting("fints.product_id")?.to_string();
        self.product_version = ctx.setting_or("fints.product_version", "0.1").to_string();
        if ctx.secret.is_empty() {
            return Err(CoreError::Authentication {
                message: tr("PIN ist leer").into(),
            });
        }
        if let Ok(st) = serde_json::from_value::<FinTsState>(ctx.state.clone()) {
            self.st = st;
        }
        if self.st.system_id.is_empty() || self.st.sec_func.is_empty() {
            self.sync_dialog(ctx).await?;
        }
        // Authenticated dialog with strong customer authentication.
        self.reset_dialog();
        let sec = self.sec();
        let mut payload = vec![self.hkidn(ctx, 3), self.hkvvb(4)];
        if sec != "999" {
            payload.push(self.hktan_process4(5, "HKIDN"));
        }
        let reply = self.send(ctx, payload, &sec, None).await?;
        self.learn_bpd(&reply);
        if let Err(e) = reply.check() {
            // Stale system ID / TAN method -> force re-sync next time.
            if reply.has("9931") || reply.has("9942") || reply.has("9010") {
                self.st.system_id.clear();
            }
            return Err(e);
        }
        if let Some(p) = self.challenge_from(&reply)? {
            return Ok(p);
        }
        Ok(Phase::Ready)
    }

    async fn respond(
        &mut self,
        ctx: &ConnectContext,
        response: ChallengeResponse,
    ) -> CoreResult<Phase> {
        let task = self
            .task_reference
            .clone()
            .ok_or_else(|| CoreError::Protocol {
                message: "no pending TAN task".into(),
            })?;
        let sec = self.sec();
        match response {
            ChallengeResponse::Poll => {
                let seg = SegmentBuilder::new("HKTAN", 3, self.version("HKTAN"))
                    .raw("S")
                    .raw("")
                    .raw("")
                    .raw("")
                    .de(&[&task])
                    .raw("N")
                    .build();
                let reply = self.send(ctx, vec![seg], &sec, None).await?;
                self.check_reply(&reply)?;
                if reply.has("3956") {
                    let c = self.challenge.clone().ok_or(CoreError::SessionClosed)?;
                    return Ok(Phase::Pending(c));
                }
                Ok(Phase::Ready)
            }
            ChallengeResponse::Code(tan) => {
                let seg = SegmentBuilder::new("HKTAN", 3, self.version("HKTAN"))
                    .raw("2")
                    .raw("")
                    .raw("")
                    .raw("")
                    .de(&[&task])
                    .raw("N")
                    .build();
                self.tan_for_next = None;
                let reply = self.send(ctx, vec![seg], &sec, Some(tan.expose())).await?;
                self.check_reply(&reply)?;
                Ok(Phase::Ready)
            }
        }
    }

    async fn fetch(&mut self, ctx: &ConnectContext) -> CoreResult<FetchResult> {
        let mut errors: Vec<String> = Vec::new();
        let accounts = self.account_list(ctx, &mut errors).await;
        let mut result = FetchResult::default();
        let mut ok_any = false;
        for (acc, upd) in &accounts {
            let allowed = |tx: &str| {
                upd.as_ref()
                    .map(|u| u.allowed.is_empty() || u.allowed.contains(tx))
                    .unwrap_or(true)
            };
            let kind = upd
                .as_ref()
                .map(|u| kind_from_code(u.kind_code))
                .unwrap_or(AccountKind::Checking);
            let label = if acc.iban.is_empty() {
                acc.account_number.clone()
            } else {
                acc.iban.clone()
            };
            let mut currency = upd
                .as_ref()
                .map(|u| u.currency.clone())
                .filter(|c| !c.is_empty())
                .unwrap_or_else(|| "EUR".into());
            let mut balance: Option<i64> = None;
            let mut balance_date = super::today();

            // --- Balance (HKSAL), only if the account allows it
            if self.bank_supports("HKSAL") && allowed("HKSAL") {
                match self.balance(ctx, acc).await {
                    Ok(Some((b, cur, date))) => {
                        balance = Some(b);
                        currency = cur;
                        balance_date = date;
                        ok_any = true;
                    }
                    Ok(None) => {}
                    Err(e) => errors.push(trf("{0}: Saldo – {1}", &[&label, &e])),
                }
            }

            // --- Statements: camt (HKCAZ) first, MT940 (HKKAZ) as fallback. Loans are
            // included only when HIUPD permits it (or lists nothing); every request is
            // its own FinTS message, so a 9050 on one loan is just collected in `errors`.
            let mut txs = Vec::new();
            {
                let can_camt = self.bank_supports("HKCAZ")
                    && allowed("HKCAZ")
                    && !self.st.camt_formats.is_empty();
                let can_mt940 = self.bank_supports("HKKAZ") && allowed("HKKAZ");
                let mut done = false;
                if can_camt {
                    match self.statements_camt(ctx, acc, &label).await {
                        Ok((t, closing)) => {
                            // Loan sub-accounts ("Darlehen") often answer camt with an empty
                            // list; then MT940 is tried before giving up.
                            let empty_loan = kind == AccountKind::Loan && t.is_empty() && can_mt940;
                            txs = t;
                            if balance.is_none() {
                                balance = closing;
                            }
                            done = !empty_loan;
                            ok_any = true;
                        }
                        Err(e) => {
                            errors.push(trf("{0}: Umsätze (HKCAZ/camt.052) – {1}", &[&label, &e]))
                        }
                    }
                }
                if !done && can_mt940 {
                    match self.statements_mt940(ctx, acc, &label, &currency).await {
                        Ok((t, closing)) => {
                            if !t.is_empty() || txs.is_empty() {
                                txs = t;
                            }
                            if balance.is_none() {
                                balance = closing;
                            }
                            ok_any = true;
                        }
                        Err(e) => {
                            errors.push(trf("{0}: Umsätze (HKKAZ/MT940) – {1}", &[&label, &e]))
                        }
                    }
                }
            }
            result.transactions.extend(txs);

            // --- Elektronischer Kontoauszug (HKEKA, PDF) – optional
            if kind != AccountKind::Loan && self.bank_supports("HKEKA") && allowed("HKEKA") {
                if let Ok(docs) = self.statements_pdf(ctx, acc, &label).await {
                    result.documents.extend(docs);
                }
            }
            let name = upd
                .as_ref()
                .map(|u| u.product.clone())
                .filter(|p| !p.is_empty())
                .unwrap_or_else(|| match kind {
                    AccountKind::Loan => "Darlehen".into(),
                    AccountKind::Savings => "Sparkonto".into(),
                    AccountKind::CreditCard => "Kreditkarte".into(),
                    AccountKind::Brokerage => "Depot".into(),
                    _ => "Girokonto".into(),
                });
            result.accounts.push(RemoteAccount {
                external_ref: label.clone(),
                name,
                owner: upd.as_ref().map(|u| u.owner.clone()).unwrap_or_default(),
                iban: acc.iban.clone(),
                account_number: acc.account_number.clone(),
                currency,
                kind,
                balance_cents: balance.unwrap_or(0),
                balance_date,
            });
        }
        if !ok_any && !errors.is_empty() {
            return Err(CoreError::Bank {
                code: "FinTS".into(),
                message: errors.join(" / "),
            });
        }
        result.state = Some(serde_json::to_value(&self.st)?);
        Ok(result)
    }

    async fn finish(&mut self, ctx: &ConnectContext) {
        let sec = self.sec();
        self.end_dialog(ctx, &sec).await;
    }

    async fn send_transfer(
        &mut self,
        ctx: &ConnectContext,
        job: &TransferJob,
    ) -> CoreResult<Phase> {
        self.transferring = true;
        let reply = self.submit_hkccs(ctx, job).await;
        if reply.is_err() {
            self.transferring = false;
        }
        let reply = reply?;
        if let Some(p) = self.challenge_from(&reply)? {
            return Ok(p);
        }
        self.transferring = false;
        Ok(Phase::Ready)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secret::SecretString;

    #[test]
    fn message_has_correct_length_and_structure() {
        let mut c = FinTsConnector::new("52090000");
        c.product_id = "TESTPRODUCT".into();
        c.product_version = "0.1".into();
        let ctx = ConnectContext {
            connection_id: 1,
            login_name: "user:1".into(),
            secret: SecretString::new("12345".into()),
            settings: Default::default(),
            state: serde_json::json!({}),
            since: "2025-01-01".into(),
        };
        let payload = vec![c.hkidn(&ctx, 3), c.hkvvb(4), c.hktan_process4(5, "HKIDN")];
        let msg = c.build_message(&ctx, &payload, "946", None);
        let header_len: usize = std::str::from_utf8(&msg[10..22]).unwrap().parse().unwrap();
        assert_eq!(header_len, msg.len());
        let segs = syntax::parse_response(&msg).unwrap();
        let ids: Vec<&str> = segs.iter().map(|s| s.id()).collect();
        assert_eq!(
            ids,
            vec!["HNHBK", "HNVSK", "HNSHK", "HKIDN", "HKVVB", "HKTAN", "HNSHA", "HNHBS"]
        );
        assert_eq!(segs[3].get(2, 0), "user:1", "login is escaped and restored");
        assert_eq!(segs[6].get(3, 0), "12345");
        assert_eq!(segs[7].number(), 7);
    }

    fn reply(raw: &[u8]) -> BankReply {
        let segments = syntax::parse_response(raw).unwrap();
        let mut codes = Vec::new();
        for s in &segments {
            if s.id() == "HIRMG" || s.id() == "HIRMS" {
                for el in s.elements.iter().skip(1) {
                    let t = |i: usize| el.get(i).map(|v| v.text().to_string()).unwrap_or_default();
                    codes.push((
                        t(0),
                        s.reference(),
                        t(2),
                        el.iter().skip(3).map(|v| v.text().to_string()).collect(),
                    ));
                }
            }
        }
        BankReply {
            segments,
            codes,
            sent: HashMap::from([(3, "HKKAZ".to_string())]),
        }
    }

    #[test]
    fn negotiates_versions_from_bpd() {
        let mut c = FinTsConnector::new("52090000");
        let r = reply(b"HISALS:5:5:3+1+1+0'HISALS:6:7:3+1+1+0'HISALS:7:8:3+1+1+0'HICAZS:8:1:3+1+1+0+450:N:N:urn?:iso?:std?:iso?:20022?:tech?:xsd?:camt.052.001.02:urn?:iso?:std?:iso?:20022?:tech?:xsd?:camt.052.001.08'HITANS:9:6:3+1+1+0+J:N:0:946:2:SECUREGO:Decoupled::SecureGo plus:6:1:x'HITANS:10:7:3+1+1+0+J:N:0'HIKAZS:11:7:3+1+1+0+90:N:N'HIRMS:12:2:3+3920::Zugelassene Zwei-Schritt-Verfahren:942:946'");
        c.learn_bpd(&r);
        assert_eq!(c.version("HKSAL"), 8);
        assert_eq!(c.version("HKCAZ"), 1);
        assert_eq!(c.version("HKTAN"), 7);
        assert_eq!(c.version("HKKAZ"), 7);
        assert!(!c.bank_supports("HKSPA"));
        assert_eq!(
            c.st.camt_formats[0],
            "urn:iso:std:iso:20022:tech:xsd:camt.052.001.08"
        );
        assert_eq!(
            c.st.sec_func, "946",
            "decoupled SecureGo plus preferred over 942"
        );
        assert_eq!(c.st.tan_method_name, "SecureGo plus");
    }

    #[test]
    fn parses_upd_with_allowed_transactions_and_loans() {
        let r = reply(b"HIUPD:5:6:3+0012345601::280:52090000+DE44520900000012345601+KUNDE+1+EUR+Muster+Alex+Girokonto++HKSAL:1+HKCAZ:1+HKKAZ:1'HIUPD:6:6:3+0098765400::280:52090000++KUNDE+40+EUR+Muster+Alex+Baudarlehen++HKSAL:1'");
        let upds: Vec<UpdAccount> = r.all("HIUPD").map(parse_upd).collect();
        assert_eq!(upds.len(), 2);
        assert_eq!(upds[0].iban, "DE44520900000012345601");
        assert!(upds[0].allowed.contains("HKCAZ"));
        assert_eq!(kind_from_code(upds[1].kind_code), AccountKind::Loan);
        assert!(
            upds[1].allowed.contains("HKSAL") && !upds[1].allowed.contains("HKCAZ"),
            "loan: balance only"
        );
        let kti = FinTsConnector::kti(&SepaAccount {
            iban: String::new(),
            bic: String::new(),
            account_number: "0098765400".into(),
            sub_account: String::new(),
            blz: "52090000".into(),
        });
        assert_eq!(kti, "::0098765400::280:52090000");
    }

    #[test]
    fn error_names_offending_segment() {
        let r = reply(b"HIRMG:2:2+9050::Die Nachricht enth\xe4lt Fehler.'HIRMS:3:2:3+9010::Auftragsart wird nicht unterst\xfctzt.'");
        let err = r.check().unwrap_err().to_string();
        assert!(err.contains("9050 [Nachricht]"), "{err}");
        assert!(err.contains("9010 [HKKAZ #3]"), "{err}");
    }

    #[test]
    fn builds_hkcaz_with_escaped_camt_urn() {
        let mut c = FinTsConnector::new("52090000");
        c.st.versions.insert("HKCAZ".into(), vec![1]);
        let acc = SepaAccount {
            iban: "DE44520900000012345601".into(),
            bic: "GENODE51KS1".into(),
            account_number: String::new(),
            sub_account: String::new(),
            blz: "52090000".into(),
        };
        let seg = c.hkcaz(
            &acc,
            "urn:iso:std:iso:20022:tech:xsd:camt.052.001.08",
            "20260801",
            "20261109",
            None,
        );
        let text = String::from_utf8(seg.clone()).unwrap();
        assert!(text.starts_with("HKCAZ:3:1+DE44520900000012345601:GENODE51KS1+urn?:iso?:std?:iso?:20022?:tech?:xsd?:camt.052.001.08+N+20260801+20261109'"), "{text}");
        let parsed = syntax::parse(&seg).unwrap();
        assert_eq!(
            parsed[0].get(2, 0),
            "urn:iso:std:iso:20022:tech:xsd:camt.052.001.08"
        );
    }

    #[test]
    fn hktan_uses_negotiated_version() {
        let mut c = FinTsConnector::new("52090000");
        c.st.versions.insert("HKTAN".into(), vec![6]);
        let seg = String::from_utf8(c.hktan_process4(5, "HKIDN")).unwrap();
        assert!(seg.starts_with("HKTAN:5:6+4+HKIDN"), "{seg}");
    }
}
