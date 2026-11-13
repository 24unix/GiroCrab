//! `SyncSession`: the two-phase login/fetch state machine exposed via FFI.

use std::sync::Arc;

use tokio::sync::Mutex as AsyncMutex;

use crate::error::{CoreError, CoreResult};
use crate::models::ConnectorKind;
use crate::secret::SecretString;
use crate::vault::Vault;

use super::*;

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
    pub(super) fn new(
        vault: Arc<Vault>,
        kind: ConnectorKind,
        connector: Box<dyn BankConnector>,
        ctx: ConnectContext,
    ) -> Self {
        Self {
            vault,
            kind,
            state: AsyncMutex::new(SessionState {
                connector,
                ctx,
                done: false,
            }),
        }
    }

    /// Copy of the prepared login context (settings, PIN, connector state),
    /// e.g. to reuse the sync set-up for a transfer.
    pub(super) fn clone_context(&self) -> CoreResult<ConnectContext> {
        let st = self
            .state
            .try_lock()
            .map_err(|_| CoreError::SessionClosed)?;
        Ok(ConnectContext {
            connection_id: st.ctx.connection_id,
            login_name: st.ctx.login_name.clone(),
            secret: SecretString::new(st.ctx.secret.expose().to_string()),
            settings: st.ctx.settings.clone(),
            state: st.ctx.state.clone(),
            since: st.ctx.since.clone(),
            since_by_account: st.ctx.since_by_account.clone(),
        })
    }

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
            Ok(Phase::ConfirmPayee(_)) => {
                st.done = true;
                st.connector.finish(&st.ctx).await;
                Err(CoreError::Protocol {
                    message: "payee confirmation outside of a transfer".into(),
                })
            }
            Ok(Phase::Ready) => {
                crate::depot_debug::log(&format!(
                    "sync advance: Ready, calling fetch for {:?}",
                    self.kind
                ));
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
