//! Per-login authentication preference, stored in the encrypted connector state.
use super::*;
pub(super) fn default_method() -> String {
    "sms".into()
}
#[uniffi::export]
impl Vault {
    pub fn set_advanzia_auth_method(&self, connection_id: i64, method: String) -> CoreResult<()> {
        if !matches!(method.as_str(), "sms" | "app") {
            return Err(invalid("Ungültiges Freigabeverfahren."));
        }
        let db = self.db()?;
        let (_, mut state) = connection(&db, connection_id)?;
        state.auth_method = method;
        db.execute(
            "UPDATE bank_connections SET state_json=?1 WHERE id=?2",
            params![serialize(&state)?.to_string(), connection_id],
        )?;
        Ok(())
    }
}
