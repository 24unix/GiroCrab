//! Simulated connector for verification mode: shows the real two-phase flow
//! (push-TAN, code, PSD2 redirect) without touching any bank.

use async_trait::async_trait;

use super::{
    BankConnector, Challenge, ChallengeKind, ChallengeResponse, ConnectContext, FetchResult, Phase,
    RemoteAccount, RemoteTransaction, TransferJob,
};
use crate::demo::DEMO_ACCOUNTS;
use crate::error::{CoreError, CoreResult};
use crate::i18n::{tr, trf};
use crate::models::ConnectorKind;

pub struct DemoConnector {
    kind: ConnectorKind,
    polls: u32,
    challenge: Option<Challenge>,
}

impl DemoConnector {
    pub fn new(kind: ConnectorKind) -> Self {
        DemoConnector {
            kind,
            polls: 0,
            challenge: None,
        }
    }
}

#[async_trait]
impl BankConnector for DemoConnector {
    async fn begin(&mut self, _ctx: &ConnectContext) -> CoreResult<Phase> {
        tokio::time::sleep(std::time::Duration::from_millis(600)).await;
        let c = match self.kind {
            ConnectorKind::VolksbankKasselGoettingen | ConnectorKind::Direkt1822 | ConnectorKind::FinTsGeneric | ConnectorKind::Comdirect | ConnectorKind::ScalableCapital => Challenge {
                kind: ChallengeKind::DecoupledPush,
                title: tr("Bitte in der Banking-App freigeben").into(),
                message: tr("Demo: Eine Push-Nachricht wurde „gesendet“. Die Freigabe wird nach wenigen Sekunden simuliert.").into(),
                method_name: match self.kind {
                    ConnectorKind::VolksbankKasselGoettingen => "SecureGo plus (Demo)".into(),
                    ConnectorKind::Direkt1822 => "pushTAN (Demo)".into(),
                    ConnectorKind::ScalableCapital => "Browser-Anmeldung (Demo)".into(),
                    _ => "photoTAN push (Demo)".into(),
                },
                redirect_url: None,
                image: None,
                expires_in_seconds: Some(300),
                poll_interval_seconds: 2,
            },
            ConnectorKind::TradeRepublic => Challenge {
                kind: ChallengeKind::Code,
                title: "Trade Republic 2FA".into(),
                message: tr("Demo: beliebigen 4-stelligen Code eingeben.").into(),
                method_name: tr("App-Code (Demo)").into(),
                redirect_url: None,
                image: None,
                expires_in_seconds: Some(120),
                poll_interval_seconds: 0,
            },
            ConnectorKind::AmericanExpress | ConnectorKind::AmazonVisa | ConnectorKind::EnableBanking => Challenge {
                kind: ChallengeKind::Redirect,
                title: tr("Zustimmung beim Kartenherausgeber erteilen").into(),
                message: tr("Demo: Es wird keine echte Seite geöffnet. Beliebigen Text einfügen (z. B. https://localhost/cb?code=demo).").into(),
                method_name: tr("PSD2-Weiterleitung (Demo)").into(),
                redirect_url: Some("https://example.org/psd2-consent-demo".into()),
                image: None,
                expires_in_seconds: Some(900),
                poll_interval_seconds: 0,
            },
            ConnectorKind::PayPal | ConnectorKind::Bunq => return Ok(Phase::Ready),
        };
        self.challenge = Some(c.clone());
        Ok(Phase::Challenge(c))
    }

    async fn respond(
        &mut self,
        _ctx: &ConnectContext,
        response: ChallengeResponse,
    ) -> CoreResult<Phase> {
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        match response {
            ChallengeResponse::Poll => {
                self.polls += 1;
                if self.polls < 2 {
                    Ok(Phase::Pending(
                        self.challenge.clone().ok_or(CoreError::SessionClosed)?,
                    ))
                } else {
                    Ok(Phase::Ready)
                }
            }
            ChallengeResponse::Code(code) => {
                if self.kind == ConnectorKind::TradeRepublic
                    && !(code.expose().len() == 4
                        && code.expose().chars().all(|c| c.is_ascii_digit()))
                {
                    return Err(CoreError::Authentication {
                        message: tr("Demo: Der Code muss 4 Ziffern haben").into(),
                    });
                }
                Ok(Phase::Ready)
            }
        }
    }

    async fn send_transfer(
        &mut self,
        _ctx: &ConnectContext,
        job: &TransferJob,
    ) -> CoreResult<Phase> {
        self.polls = 0;
        let c = Challenge {
            kind: ChallengeKind::DecoupledPush,
            title: tr("Überweisung in der Banking-App freigeben").into(),
            message: trf(
                "Demo: {0} an {1} wird nach wenigen Sekunden „freigegeben“.",
                &[
                    &crate::money::format_cents(job.amount_cents, "EUR".into()),
                    &job.recipient_name,
                ],
            ),
            method_name: "pushTAN (Demo)".into(),
            redirect_url: None,
            image: None,
            expires_in_seconds: Some(300),
            poll_interval_seconds: 2,
        };
        self.challenge = Some(c.clone());
        Ok(Phase::Challenge(c))
    }

    async fn fetch(&mut self, _ctx: &ConnectContext) -> CoreResult<FetchResult> {
        let today = super::today();
        let stamp = chrono::Local::now().timestamp();
        let mut out = FetchResult::default();
        for spec in DEMO_ACCOUNTS.iter().filter(|s| s.connector == self.kind) {
            out.accounts.push(RemoteAccount {
                external_ref: spec.external_ref.into(),
                name: spec.name.into(),
                owner: "Erika Mustermann".into(),
                iban: spec.iban.into(),
                account_number: String::new(),
                currency: "EUR".into(),
                kind: spec.kind,
                balance_cents: spec.opening_cents,
                balance_date: today.clone(),
            });
        }
        if let Some(first) = DEMO_ACCOUNTS
            .iter()
            .find(|s| s.connector == self.kind && s.kind != crate::models::AccountKind::Brokerage)
        {
            let (cp, purpose, cents) = match self.kind {
                ConnectorKind::PayPal => ("Lieferando.de", "Bestellung Lieferando", -23_40),
                ConnectorKind::TradeRepublic => ("Trade Republic", "Zinsen", 3_87),
                ConnectorKind::ScalableCapital => ("Scalable Capital", "Zinsen Overnight", 5_12),
                ConnectorKind::AmericanExpress
                | ConnectorKind::AmazonVisa
                | ConnectorKind::EnableBanking => ("AMZN Mktp DE", "Amazon.de Bestellung", -34_99),
                _ => (
                    "REWE Markt GmbH",
                    "Kartenzahlung girocard (Demo-Sync)",
                    -27_65,
                ),
            };
            out.transactions.push(RemoteTransaction {
                account_ref: first.external_ref.into(),
                external_id: format!("demo-sync-{stamp}"),
                booking_date: today.clone(),
                value_date: today.clone(),
                amount_cents: cents,
                currency: "EUR".into(),
                counterparty: cp.into(),
                counterparty_iban: String::new(),
                purpose: purpose.into(),
                booking_text: "DEMO".into(),
            });
        }
        // Balances are not re-reported by the simulated bank; the vault adds
        // the new bookings to the stored balances instead.
        out.adjust_balances = true;
        Ok(out)
    }
}
