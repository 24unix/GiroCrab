//! Preparing a collection run: the chosen mandates become `pain.008` files,
//! one per scheme and sequence type (a message carries exactly one of each).

use std::collections::BTreeMap;

use crate::connectors::fints::pain008::{
    build_pain008, Collection, DebitVersion, Pain008, SequenceType,
};
use crate::error::{CoreError, CoreResult};
use crate::i18n::{tr, trf};
use crate::vault::Vault;

use super::{invalid, MandateScheme};

/// One debtor to collect from in this run.
#[derive(Debug, Clone, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct CollectionItem {
    pub mandate_id: i64,
    pub amount_cents: i64,
    /// Empty = the mandate's default purpose.
    pub purpose: String,
    /// Last collection under the mandate (`FNAL`; ignored for one-off mandates).
    pub last_collection: bool,
}

/// A ready `pain.008` message.
#[derive(Debug, Clone, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct DebitFile {
    /// Suggested file name, e.g. `lastschrift-CORE-FRST-2026-11-30.xml`.
    pub file_name: String,
    pub scheme: MandateScheme,
    /// `FRST`, `RCUR`, `OOFF` or `FNAL`.
    pub sequence: String,
    pub count: u32,
    pub total_cents: i64,
    pub xml: String,
    /// Mandates in this file, to mark as collected once it is submitted.
    pub mandate_ids: Vec<i64>,
}

fn check_date(d: &str) -> CoreResult<()> {
    chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d")
        .map(|_| ())
        .map_err(|_| invalid(tr("Das Fälligkeitsdatum ist ungültig.")))
}

#[uniffi::export]
impl Vault {
    /// Builds the `pain.008` files for `items` under the creditor account
    /// `account_id`, due on `collection_date` (`YYYY-MM-DD`). The creditor ID
    /// of the account must be set. Nothing is marked as collected.
    pub fn build_collection_files(
        &self,
        account_id: i64,
        items: Vec<CollectionItem>,
        collection_date: String,
    ) -> Result<Vec<DebitFile>, CoreError> {
        check_date(&collection_date)?;
        if items.is_empty() {
            return Err(invalid(tr("Der Einzug enthält keine Lastschrift.")));
        }
        let account = self
            .list_accounts()?
            .into_iter()
            .find(|a| a.id == account_id)
            .ok_or_else(|| invalid(tr("Das Konto gibt es nicht mehr.")))?;
        let creditor_id = self.creditor_id(account_id)?;
        if creditor_id.is_empty() {
            return Err(invalid(tr(
                "Für dieses Konto ist keine Gläubiger-ID hinterlegt.",
            )));
        }
        let creditor_name = if account.owner.trim().is_empty() {
            account.name.clone()
        } else {
            account.owner.clone()
        };
        // (scheme code, sequence code) -> collections, in the order given
        let mut groups: BTreeMap<
            (String, String),
            (MandateScheme, SequenceType, Vec<(i64, Collection)>),
        > = BTreeMap::new();
        let due_compact = collection_date.replace('-', "");
        for item in &items {
            let m = self
                .mandate(item.mandate_id)?
                .filter(|m| m.account_id == account_id)
                .ok_or_else(|| invalid(tr("Das Mandat gibt es nicht mehr.")))?;
            if !m.active {
                return Err(CoreError::InvalidInput {
                    message: trf("Das Mandat „{0}“ ist nicht aktiv.", &[&m.reference]),
                });
            }
            let mut seq = SequenceType::from_code(&m.next_sequence).unwrap_or(SequenceType::First);
            if item.last_collection && seq == SequenceType::Recurring {
                seq = SequenceType::Final;
            }
            let purpose = if item.purpose.trim().is_empty() {
                m.default_purpose.clone()
            } else {
                item.purpose.clone()
            };
            let c = Collection {
                debtor_name: m.debtor_name.clone(),
                debtor_iban: m.debtor_iban.clone(),
                debtor_bic: Some(m.debtor_bic.clone()).filter(|b| !b.is_empty()),
                amount_cents: item.amount_cents,
                purpose,
                end_to_end_id: format!(
                    "{}-{}",
                    m.reference.chars().take(26).collect::<String>(),
                    due_compact
                ),
                mandate_id: m.reference.clone(),
                mandate_date: m.signed_date.clone(),
            };
            groups
                .entry((m.scheme.debit().code().to_string(), seq.code().to_string()))
                .or_insert_with(|| (m.scheme, seq, Vec::new()))
                .2
                .push((m.id, c));
        }
        let now = chrono::Local::now();
        let created = now.format("%Y-%m-%dT%H:%M:%S").to_string();
        let stamp = now.format("%Y%m%d%H%M%S").to_string();
        let mut files = Vec::new();
        for (n, ((scheme_code, seq_code), (scheme, seq, rows))) in groups.into_iter().enumerate() {
            let collections: Vec<Collection> = rows.iter().map(|(_, c)| c.clone()).collect();
            let message_id = format!("GC{stamp}-{}", n + 1);
            let xml = build_pain008(&Pain008 {
                message_id: &message_id,
                created: &created,
                collection_date: &collection_date,
                creditor_name: &creditor_name,
                creditor_iban: &account.iban,
                creditor_bic: "",
                creditor_id: &creditor_id,
                scheme: scheme.debit(),
                sequence: seq,
                collections: &collections,
                version: DebitVersion::V02,
                batch_booking: true,
            })?;
            files.push(DebitFile {
                file_name: format!("lastschrift-{scheme_code}-{seq_code}-{collection_date}.xml"),
                scheme,
                sequence: seq_code,
                count: collections.len() as u32,
                total_cents: collections.iter().map(|c| c.amount_cents).sum(),
                xml,
                mandate_ids: rows.iter().map(|(id, _)| *id).collect(),
            });
        }
        Ok(files)
    }

    /// Records that these mandates were collected with the due date `due_date`
    /// (their next collection is then `RCUR`, a one-off mandate stays `OOFF`).
    pub fn mark_collected(&self, mandate_ids: Vec<i64>, due_date: String) -> Result<(), CoreError> {
        check_date(&due_date)?;
        let db = self.db()?;
        for id in mandate_ids {
            db.execute(
                "UPDATE mandates SET last_collected = ?2 WHERE id = ?1
                   AND (last_collected IS NULL OR last_collected < ?2)",
                rusqlite::params![id, due_date],
            )?;
        }
        Ok(())
    }
}
