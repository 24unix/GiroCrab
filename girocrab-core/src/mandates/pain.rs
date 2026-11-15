//! Import of an existing `pain.008` file (e.g. last month's collection of a
//! club): its debtors become mandates, the creditor ID and the sequence types
//! are taken over.

use crate::connectors::fints::pain008::{parse_pain008, SequenceType};
use crate::connectors::fints::sepa::{normalize_iban, validate_creditor_iban_matches};
use crate::error::CoreError;
use crate::i18n::tr;
use crate::vault::Vault;

use super::{invalid, MandateImportResult, MandateInput, MandateScheme};

#[uniffi::export]
impl Vault {
    /// Reads a `pain.008` file and saves its debtors as mandates of the creditor
    /// account `account_id` (a known reference updates that mandate). The file's
    /// creditor IBAN must be the account's. A creditor ID the account lacks is
    /// taken from the file. `RCUR`/`FNAL` entries count as already collected
    /// once, so their next collection is again a follow-up.
    pub fn import_pain008(
        &self,
        account_id: i64,
        xml: String,
    ) -> Result<MandateImportResult, CoreError> {
        let account = self
            .list_accounts()?
            .into_iter()
            .find(|a| a.id == account_id)
            .ok_or_else(|| invalid(tr("Das Konto gibt es nicht mehr.")))?;
        let blocks = parse_pain008(&xml)?;
        let mut result = MandateImportResult::default();
        for (n, block) in blocks.iter().enumerate() {
            if !validate_creditor_iban_matches(&block.creditor_iban, &account.iban) {
                return Err(invalid(tr(
                    "Die Datei gehört zu einem anderen Gläubigerkonto als dem gewählten.",
                )));
            }
            if n == 0 && self.creditor_id(account_id)?.is_empty() && !block.creditor_id.is_empty() {
                // an invalid ID in the file is simply not taken over
                let _ = self.set_creditor_id(account_id, block.creditor_id.clone());
            }
            let scheme = match block.scheme.code() {
                "COR1" => MandateScheme::Cor1,
                "B2B" => MandateScheme::B2b,
                _ => MandateScheme::Core,
            };
            for (i, c) in block.collections.iter().enumerate() {
                let line = format!("{}.{}", n + 1, i + 1);
                let existing = self
                    .list_mandates(Some(account_id))?
                    .into_iter()
                    .find(|m| m.reference == c.mandate_id.trim());
                let input = MandateInput {
                    account_id,
                    debtor_name: c.debtor_name.clone(),
                    debtor_iban: normalize_iban(&c.debtor_iban),
                    debtor_bic: c.debtor_bic.clone().unwrap_or_default(),
                    reference: c.mandate_id.clone(),
                    signed_date: c.mandate_date.clone(),
                    scheme,
                    one_off: block.sequence == SequenceType::OneOff,
                    default_amount_cents: c.amount_cents,
                    default_purpose: c.purpose.clone(),
                    note: existing
                        .as_ref()
                        .map(|m| m.note.clone())
                        .unwrap_or_default(),
                    active: existing.as_ref().is_none_or(|m| m.active),
                };
                match self.save_mandate(existing.as_ref().map(|m| m.id), input) {
                    Ok(m) => {
                        if matches!(
                            block.sequence,
                            SequenceType::Recurring | SequenceType::Final
                        ) {
                            self.mark_collected(vec![m.id], m.signed_date.clone())?;
                        }
                        if existing.is_some() {
                            result.updated += 1;
                        } else {
                            result.created += 1;
                        }
                    }
                    Err(e) => result.failed.push(format!("{line}: {e}")),
                }
            }
        }
        Ok(result)
    }
}
