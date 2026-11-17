//! `TransferSession`: the two-phase SEPA transfer state machine exposed via FFI.

use std::sync::Arc;

use tokio::sync::Mutex as AsyncMutex;

use crate::error::{CoreError, CoreResult};
use crate::i18n::tr;
use crate::secret::SecretString;
use crate::vault::Vault;

use super::*;

/// A direct debit collection handed to the bank by this session.
pub(crate) struct DebitSubmission {
    pub job: DebitJob,
    pub mandate_ids: Vec<i64>,
}

/// What the session sends to the bank.
pub(crate) enum OrderKind {
    Single,
    /// `job` then describes the sum (see `Vault::begin_batch_transfer`).
    Batch(BatchTransferJob),
    /// `job` then describes the sum.
    Debit(DebitSubmission),
    /// `job` is then a placeholder.
    Standing(StandingOrderJob),
}

/// Where the session stands. Every stage after `Submitted` closes the dialog
/// for further steps; that says nothing about whether the bank still holds an
/// open order (see `cancel` and `BankConnector::has_open_order`).
#[derive(PartialEq, Eq)]
enum Stage {
    LoggingIn,
    /// The order was sent; waiting for its TAN.
    Submitted,
    /// The bank executed the order: it can no longer be cancelled.
    Executed,
    /// The bank confirmed the order is not payable any more.
    Cancelled,
    /// Failed, declined, outcome unknown or cancellation not (yet) confirmed.
    Closed,
}

struct TransferState {
    connector: Box<dyn BankConnector>,
    ctx: ConnectContext,
    job: TransferJob,
    order: OrderKind,
    account_id: i64,
    stage: Stage,
}

/// After the order was handed to the bank, only errors that prove it was
/// refused (wrong credentials, invalid input) mean "not executed". Anything
/// else (network, garbled reply, ...) leaves the result unknown.
pub(super) fn error_leaves_outcome_unknown(e: &CoreError) -> bool {
    !matches!(
        e,
        CoreError::Authentication { .. } | CoreError::InvalidInput { .. }
    )
}

/// One SEPA transfer. Created by `Vault::begin_transfer`; same two-phase
/// challenge handling as `SyncSession` (login SCA, then transfer SCA).
#[derive(uniffi::Object)]
pub struct TransferSession {
    vault: Arc<Vault>,
    state: AsyncMutex<TransferState>,
}

impl TransferSession {
    pub(crate) fn new(
        vault: Arc<Vault>,
        connector: Box<dyn BankConnector>,
        ctx: ConnectContext,
        order: OrderKind,
        job: TransferJob,
        account_id: i64,
    ) -> Self {
        Self {
            vault,
            state: AsyncMutex::new(TransferState {
                connector,
                ctx,
                job,
                order,
                account_id,
                stage: Stage::LoggingIn,
            }),
        }
    }

    /// Runs one dialog step; `SessionClosed` once the dialog is over.
    async fn step(
        &self,
        call: impl AsyncFnOnce(&mut TransferState) -> CoreResult<Phase>,
    ) -> CoreResult<TransferStep> {
        let mut st = self.state.lock().await;
        if !matches!(st.stage, Stage::LoggingIn | Stage::Submitted) {
            return Err(CoreError::SessionClosed);
        }
        let phase = call(&mut st).await;
        self.advance(phase, &mut st).await
    }

    async fn advance(
        &self,
        mut phase: CoreResult<Phase>,
        st: &mut TransferState,
    ) -> CoreResult<TransferStep> {
        loop {
            match phase {
                Err(e) => {
                    // A dropped connection after the order reached the bank:
                    // it may have been executed, so never report "failed".
                    let unknown = st.stage == Stage::Submitted
                        && st.connector.order_submitted()
                        && error_leaves_outcome_unknown(&e);
                    st.stage = Stage::Closed;
                    st.connector.finish(&st.ctx).await;
                    if unknown {
                        return self.outcome_unknown(st, e.to_string());
                    }
                    return Err(e);
                }
                Ok(Phase::Challenge(c)) => {
                    return Ok(TransferStep::NeedsChallenge { challenge: c })
                }
                Ok(Phase::Pending(c)) => return Ok(TransferStep::StillWaiting { challenge: c }),
                Ok(Phase::ConfirmPayee(check)) => {
                    return Ok(TransferStep::NeedsPayeeConfirmation { check })
                }
                Ok(Phase::Ready) if st.stage == Stage::LoggingIn => {
                    st.stage = Stage::Submitted;
                    phase = match &st.order {
                        OrderKind::Single => st.connector.send_transfer(&st.ctx, &st.job).await,
                        OrderKind::Batch(b) => st.connector.send_batch_transfer(&st.ctx, b).await,
                        OrderKind::Debit(d) => {
                            st.connector.send_direct_debit(&st.ctx, &d.job).await
                        }
                        OrderKind::Standing(o) => {
                            st.connector.send_standing_order(&st.ctx, o).await
                        }
                    };
                }
                Ok(Phase::Ready) => {
                    st.connector.finish(&st.ctx).await;
                    st.stage = Stage::Closed;
                    return match st.connector.transfer_result() {
                        TransferResult::Executed { instant } => {
                            // Set before recording: a failed write does not
                            // undo the executed order.
                            st.stage = Stage::Executed;
                            match &st.order {
                                OrderKind::Standing(o) => {
                                    self.vault.record_standing_order(st.account_id, o)?
                                }
                                OrderKind::Debit(d) => {
                                    self.vault.record_direct_debit(st.account_id, d)?
                                }
                                OrderKind::Batch(b) => {
                                    self.vault
                                        .record_batch_transfer(st.account_id, b, &st.job)?
                                }
                                // scheduled: shown under "Geplant" until the
                                // bank books it, not as a booking dated today
                                OrderKind::Single if st.job.execution_date.is_some() => {
                                    self.vault.record_planned_transfer(st.account_id, &st.job)?
                                }
                                OrderKind::Single => self.vault.record_pending_transfer(
                                    st.account_id,
                                    &st.job,
                                    if instant {
                                        "Echtzeitüberweisung (vorgemerkt)"
                                    } else {
                                        "Überweisung (vorgemerkt)"
                                    },
                                )?,
                            }
                            Ok(TransferStep::Finished {
                                outcome: TransferOutcome {
                                    instant,
                                    end_to_end_id: st.job.end_to_end_id.clone(),
                                },
                            })
                        }
                        TransferResult::InstantDeclined { reason } => {
                            Ok(TransferStep::InstantDeclined { reason })
                        }
                        TransferResult::Unknown { reason } => self.outcome_unknown(st, reason),
                    };
                }
            }
        }
    }

    /// Stores a booking marked "Status unklar" so the possibly executed order
    /// stays visible (until the bank's booking arrives or 14 days pass).
    fn outcome_unknown(&self, st: &TransferState, reason: String) -> CoreResult<TransferStep> {
        match &st.order {
            // A standing order is no booking: nothing to show until the next
            // fetch, where it appears (or does not). A collection is incoming
            // money: no optimistic booking and no mandate update. Either way
            // the user checks with the bank first.
            OrderKind::Standing(_) | OrderKind::Debit(_) => {}
            OrderKind::Batch(b) => {
                self.vault
                    .record_batch_pending(st.account_id, b, &st.job, "(Status unklar)")?
            }
            OrderKind::Single => self.vault.record_pending_transfer(
                st.account_id,
                &st.job,
                if st.job.instant {
                    "Echtzeitüberweisung (Status unklar)"
                } else {
                    "Überweisung (Status unklar)"
                },
            )?,
        }
        Ok(TransferStep::OutcomeUnknown {
            reason,
            end_to_end_id: st.job.end_to_end_id.clone(),
        })
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl TransferSession {
    pub async fn start(&self) -> Result<TransferStep, CoreError> {
        self.step(async |s| s.connector.begin(&s.ctx).await).await
    }

    pub async fn submit_code(&self, code: String) -> Result<TransferStep, CoreError> {
        let code = ChallengeResponse::Code(SecretString::new(code));
        self.step(async |s| s.connector.respond(&s.ctx, code).await)
            .await
    }

    pub async fn poll(&self) -> Result<TransferStep, CoreError> {
        self.step(async |s| s.connector.respond(&s.ctx, ChallengeResponse::Poll).await)
            .await
    }

    /// Send the transfer although the name check did not confirm the
    /// recipient (after `NeedsPayeeConfirmation`).
    pub async fn confirm_payee(&self) -> Result<TransferStep, CoreError> {
        self.step(async |s| {
            s.connector
                .respond(&s.ctx, ChallengeResponse::ConfirmPayee)
                .await
        })
        .await
    }

    /// Cancels the transfer. The result says whether the bank confirmed it:
    /// only `Cancelled` is final. For `CancellationPending`, `-Unknown` and
    /// `-Failed` the order stays tracked and `cancel()` can simply be called
    /// again; it re-checks the bank's status and never resends the order.
    /// Calling it again after `Cancelled` is a no-op.
    pub async fn cancel(&self) -> CancelOutcome {
        let mut st = self.state.lock().await;
        match st.stage {
            Stage::Cancelled => return CancelOutcome::Cancelled,
            Stage::Executed => {
                return CancelOutcome::CancellationFailed {
                    reason: tr("Die Überweisung wurde bereits ausgeführt.").into(),
                }
            }
            // A closed session only needs another round if the bank may still
            // hold an open order from an earlier, unconfirmed cancellation.
            Stage::Closed if !st.connector.has_open_order() => return CancelOutcome::Cancelled,
            _ => {}
        }
        let TransferState { connector, ctx, .. } = &mut *st;
        let outcome = connector.cancel_transfer(ctx).await;
        st.stage = if outcome == CancelOutcome::Cancelled {
            Stage::Cancelled
        } else {
            Stage::Closed
        };
        outcome
    }
}

/// "GC" + 30 hex digits: unique, within the 35-char SEPA limit and the
/// restricted character set.
pub(super) fn new_end_to_end_id() -> String {
    format!(
        "GC{}",
        &uuid::Uuid::new_v4().simple().to_string().to_uppercase()[..30]
    )
}

/// ISO 13616 Mod-97 IBAN check (whitespace and case ignored).
pub fn validate_iban(iban: String) -> bool {
    crate::connectors::fints::sepa::validate_iban(&iban)
}
