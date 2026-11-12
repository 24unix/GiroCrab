//! Direct FNZ portal import. Requests run inside the logged-in web view;
//! credentials/cookies never cross this bridge. Schema checked live 2026-11-11.
use std::{collections::HashSet, sync::Arc};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rusqlite::{params, OptionalExtension};
use serde_json::Value;

use super::{store_fetch, FetchResult, RemoteAccount, SyncSummary};
use crate::{
    error::{CoreError, CoreResult},
    i18n::tr,
    models::{AccountKind, ConnectorKind},
    vault::Vault,
};

fn invalid(message: &'static str) -> CoreError {
    CoreError::InvalidInput {
        message: tr(message).into(),
    }
}

fn field<'a>(v: &'a Value, pointer: &str) -> CoreResult<&'a str> {
    v.pointer(pointer)
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| invalid("FNZ: Unvollständige Portalantwort. Bitte erneut anmelden."))
}

fn overview(json: &str) -> CoreResult<FetchResult> {
    let v: Value =
        serde_json::from_str(json).map_err(|_| invalid("FNZ: Ungültige Kontoübersicht."))?;
    let groups = v["ownerGroups"]
        .as_array()
        .ok_or_else(|| invalid("FNZ: Keine Kontoübersicht erkannt. Bitte erneut anmelden."))?;
    let mut accounts = Vec::new();
    let mut seen = HashSet::new();
    for group in groups {
        let owners: Vec<&str> = group["sortedDepotOwners"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|o| o["displayName"].as_str())
            .collect();
        for key in [
            "investmentDepots",
            "managedDepots",
            "stockDepots",
            "preciousMetalDepots",
            "cashAccounts",
        ] {
            let Some(rows) = group[key].as_array() else {
                return Err(invalid("FNZ: Unvollständige Kontoübersicht."));
            };
            for row in rows {
                let account = &row["depotOrCashAccount"];
                if account["closedFlag"].as_bool() == Some(true) {
                    continue;
                }
                // Never turn an absent/hidden/stale valuation into a current zero.
                if [
                    "hideInventoryAndProfitAndLossFlag",
                    "inventoryMightBeOutdatedFlag",
                ]
                .iter()
                .any(|k| row[*k].as_bool() == Some(true))
                {
                    return Err(invalid("FNZ: Bestände sind ausgeblendet oder veraltet. Es wurden keine Salden aktualisiert."));
                }
                let number = field(account, "/externalDepotNumber/externalDepotNumber")?;
                let amount = field(row, "/depotInventorySumAccountCurrency/value")?;
                let currency = field(row, "/depotInventorySumAccountCurrency/currencyId/id")?;
                if currency.len() != 3 || !currency.bytes().all(|b| b.is_ascii_uppercase()) {
                    return Err(invalid("FNZ: Unbekannte Kontowährung."));
                }
                let cents = crate::money::parse_cents(amount)
                    .map_err(|_| invalid("FNZ: Ungültiger Saldo in der Kontoübersicht."))?;
                if !seen.insert(number.to_string()) {
                    continue;
                }
                accounts.push(RemoteAccount {
                    external_ref: number.into(),
                    account_number: number.into(),
                    name: field(account, "/externalDepotName")?.into(),
                    owner: owners.join(", "),
                    iban: String::new(),
                    currency: currency.into(),
                    kind: if key == "cashAccounts" {
                        match account["cashAccountContractTypeAndSubtype"].as_str() {
                            Some(
                                "SAVINGS_ACCOUNT" | "FIXED_TERM_ACCOUNT" | "TIME_DEPOSIT_ACCOUNT",
                            ) => AccountKind::Savings,
                            _ => AccountKind::Checking,
                        }
                    } else {
                        AccountKind::Brokerage
                    },
                    balance_cents: cents,
                    // The overview has no valuation timestamp: this is the retrieval date.
                    balance_date: chrono::Utc::now().date_naive().to_string(),
                });
            }
        }
    }
    if accounts.is_empty() {
        return Err(invalid(
            "FNZ: Keine aktuellen Konten oder Depotwerte erkannt.",
        ));
    }
    Ok(FetchResult {
        accounts,
        bank_name: Some("FNZ Bank".into()),
        ..Default::default()
    })
}

fn document_source(connection_id: i64, id: &str) -> String {
    format!("fnz:{connection_id}:{}", URL_SAFE_NO_PAD.encode(id))
}

fn document_account(v: &Value) -> CoreResult<&str> {
    field(v, "/depot/externalDepotNumber/externalDepotNumber")
}

impl Vault {
    fn check_fnz(&self, connection_id: i64) -> CoreResult<()> {
        if self.portal_connection(connection_id)?.0 != ConnectorKind::Fnz {
            return Err(invalid("Keine FNZ-Bankverbindung."));
        }
        Ok(())
    }
}

#[uniffi::export]
impl Vault {
    /// Update separate cash accounts and depots, keeping existing holdings/bookings.
    pub fn import_fnz_overview(
        self: Arc<Self>,
        connection_id: i64,
        overview_json: String,
    ) -> CoreResult<SyncSummary> {
        self.check_fnz(connection_id)?;
        let summary = store_fetch(
            &self,
            ConnectorKind::Fnz,
            connection_id,
            overview(&overview_json)?,
        )?;
        let _ = self.checkpoint();
        Ok(summary)
    }

    /// Validated metadata JSON for documents not already archived. Skip known
    /// IDs before downloading; session prefixes are deliberately not persisted.
    pub fn pending_fnz_documents(
        self: Arc<Self>,
        connection_id: i64,
        documents_json: String,
    ) -> CoreResult<Vec<String>> {
        self.check_fnz(connection_id)?;
        let docs: Vec<Value> = serde_json::from_str(&documents_json)
            .map_err(|_| invalid("FNZ: Ungültige Dokumentenliste."))?;
        let db = self.db()?;
        let mut known = db.prepare("SELECT 1 FROM booking_documents WHERE source_url = ?1")?;
        let mut seen = HashSet::new();
        let mut pending = Vec::new();
        for doc in docs {
            let id = field(&doc, "/id")?;
            document_account(&doc)?;
            if seen.insert(id.to_string())
                && known
                    .query_row([document_source(connection_id, id)], |_| Ok(()))
                    .optional()?
                    .is_none()
            {
                pending.push(
                    serde_json::to_string(&doc)
                        .map_err(|_| invalid("FNZ: Ungültige Dokumentdaten."))?,
                );
            }
        }
        Ok(pending)
    }

    /// Persist each validated PDF independently so partial success survives retries.
    pub fn import_fnz_document(
        self: Arc<Self>,
        connection_id: i64,
        document_json: String,
        bytes: Vec<u8>,
    ) -> CoreResult<bool> {
        self.check_fnz(connection_id)?;
        if !bytes.starts_with(b"%PDF-") {
            return Err(invalid("FNZ: Der Download ist kein PDF."));
        }
        let doc: Value = serde_json::from_str(&document_json)
            .map_err(|_| invalid("FNZ: Ungültige Dokumentdaten."))?;
        let id = field(&doc, "/id")?;
        let account_ref = document_account(&doc)?;
        let title = doc["subject"]
            .as_str()
            .filter(|s| !s.trim().is_empty())
            .or_else(|| doc["documentKindText"].as_str())
            .unwrap_or("FNZ Dokument");
        let date = doc["receivedDate"]
            .as_str()
            .unwrap_or_default()
            .get(..10)
            .filter(|d| chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").is_ok())
            .unwrap_or_default();
        let db = self.db()?;
        let account_id = db.query_row(
            "SELECT id FROM accounts WHERE connection_id = ?1 AND external_ref = ?2",
            params![connection_id, account_ref], |r| r.get::<_, i64>(0),
        ).optional()?.ok_or_else(|| invalid("FNZ: Zum Dokument gehört ein unbekanntes Konto oder Depot. Bitte zuerst die Salden abrufen."))?;
        let source = document_source(connection_id, id);
        let name = format!("FNZ_{}.pdf", URL_SAFE_NO_PAD.encode(id));
        Ok(crate::documents::insert_doc(
            &db,
            None,
            Some(account_id),
            title,
            "postbox",
            "application/pdf",
            &name,
            &bytes,
            &source,
            date,
        )?
        .is_some())
    }
}

pub struct WebOnlyConnector;

#[async_trait::async_trait]
impl super::BankConnector for WebOnlyConnector {
    async fn begin(&mut self, _ctx: &super::ConnectContext) -> CoreResult<super::Phase> {
        Err(CoreError::BrowserLoginRequired {
            message: tr("Bitte bei FNZ anmelden und in FNZsecure freigeben.").into(),
        })
    }
    async fn respond(
        &mut self,
        ctx: &super::ConnectContext,
        _response: super::ChallengeResponse,
    ) -> CoreResult<super::Phase> {
        self.begin(ctx).await
    }
    async fn fetch(&mut self, _ctx: &super::ConnectContext) -> CoreResult<FetchResult> {
        Err(CoreError::BrowserLoginRequired {
            message: tr("Bitte im FNZ-Browserfenster abrufen.").into(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn account(number: &str, name: &str, amount: &str) -> Value {
        json!({
            "depotOrCashAccount": {"externalDepotNumber":{"externalDepotNumber":number},
                "externalDepotName":name, "closedFlag":false,
                "cashAccountContractTypeAndSubtype":"CURRENT_ACCOUNT"},
            "depotInventorySumAccountCurrency":{"value":amount,"currencyId":{"id":"EUR"}},
            "depotInventorySumDefaultCurrency":{"value":"999999.99","currencyId":{"id":"EUR"}}
        })
    }

    fn fixture() -> Value {
        let group = |owner: &str, depot: &str, cash: &str| {
            json!({
                "sortedDepotOwners":[{"displayName":owner}],
                "investmentDepots":[account(depot,"Investmentdepot","1234.56")],
                "managedDepots":[], "stockDepots":[], "preciousMetalDepots":[],
                "cashAccounts":[account(cash,"Konto flex","-12.34")],
                "totalDepotInventorySum":{"value":"999999.99","currencyId":{"id":"EUR"}}
            })
        };
        json!({"ownerGroups":[group("Test Parent","D1","C1"),group("Test Child","D2","C2")]})
    }

    fn metadata(id: &str, account: &str) -> String {
        json!({"id":id,"subject":"Test statement","receivedDate":"2026-11-10T12:00:00",
            "depot":{"externalDepotNumber":{"externalDepotNumber":account}}})
        .to_string()
    }

    #[test]
    fn separates_owners_accounts_and_depots_without_counting_totals() {
        let r = overview(&fixture().to_string()).unwrap();
        assert_eq!(r.accounts.len(), 4);
        assert_eq!(r.accounts[0].kind, AccountKind::Brokerage);
        assert_eq!(r.accounts[1].kind, AccountKind::Checking);
        assert_eq!(r.accounts[0].balance_cents, 123456);
        assert_eq!(r.accounts[1].balance_cents, -1234);
        assert_eq!(r.accounts[2].owner, "Test Child");
        assert_eq!(r.accounts[3].external_ref, "C2");
        assert!(r.holdings.is_empty());
        assert!(r.transactions.is_empty());
        let mut zero = fixture();
        zero["ownerGroups"][0]["cashAccounts"][0]["depotInventorySumAccountCurrency"]["value"] =
            json!("0.00");
        assert_eq!(
            overview(&zero.to_string()).unwrap().accounts[1].balance_cents,
            0
        );
    }

    #[test]
    fn refuses_missing_hidden_stale_or_invalid_balances() {
        for key in [
            "hideInventoryAndProfitAndLossFlag",
            "inventoryMightBeOutdatedFlag",
        ] {
            let mut v = fixture();
            v["ownerGroups"][0]["cashAccounts"][0][key] = json!(true);
            assert!(overview(&v.to_string()).is_err());
        }
        for value in [Value::Null, json!(""), json!("invalid"), json!("12.345")] {
            let mut v = fixture();
            v["ownerGroups"][0]["cashAccounts"][0]["depotInventorySumAccountCurrency"]["value"] =
                value;
            assert!(overview(&v.to_string()).is_err());
        }
        for v in ["{}", "[]", "<html>login</html>", "{\"ownerGroups\":[]}"] {
            assert!(overview(v).is_err());
        }
    }

    #[test]
    fn repeated_sync_is_stable_preserves_holdings_and_retries_only_missing_pdfs() {
        let path_dir = crate::test_support::TempDir::new("girocrab-fnz");
        let path = path_dir.join("v.db");
        let v = Vault::open(path.to_string_lossy().to_string(), vec![3u8; 32]).unwrap();
        let conn = v
            .add_bank_connection(ConnectorKind::Fnz, "FNZ Test".into(), "test".into())
            .unwrap();
        let mut initial = overview(&fixture().to_string()).unwrap();
        initial.holdings.push(super::super::RemoteHolding {
            account_ref: "D1".into(),
            holding: crate::models::Holding {
                isin: "DE0001234567".into(),
                name: "Test fund".into(),
                quantity: 1.0,
                value_cents: 123456,
                ..Default::default()
            },
        });
        store_fetch(&v, ConnectorKind::Fnz, conn, initial).unwrap();
        let depot = v
            .list_accounts()
            .unwrap()
            .into_iter()
            .find(|a| a.account_number == "D1")
            .unwrap();
        let doc = metadata("doc-1", "D1");
        let list = format!("[{doc},{doc}]");
        assert_eq!(
            v.clone()
                .pending_fnz_documents(conn, list.clone())
                .unwrap()
                .len(),
            1
        );
        assert!(v
            .clone()
            .import_fnz_document(conn, doc.clone(), b"%PDF-1.7\nsynthetic".to_vec())
            .unwrap());
        assert!(!v
            .clone()
            .import_fnz_document(conn, doc.clone(), b"%PDF-1.7\nsynthetic".to_vec())
            .unwrap());
        assert!(v
            .clone()
            .import_fnz_document(conn, metadata("bad", "D1"), b"<html>login</html>".to_vec())
            .is_err());
        assert!(v
            .clone()
            .import_fnz_document(
                conn,
                metadata("unknown", "missing"),
                b"%PDF-1.7\nsynthetic".to_vec()
            )
            .is_err());
        let mut changed = fixture();
        changed["ownerGroups"][0]["investmentDepots"][0]["depotInventorySumAccountCurrency"]
            ["value"] = json!("2000.00");
        v.clone()
            .import_fnz_overview(conn, changed.to_string())
            .unwrap();
        assert_eq!(v.list_accounts().unwrap().len(), 4);
        assert_eq!(
            v.list_accounts()
                .unwrap()
                .iter()
                .find(|a| a.id == depot.id)
                .unwrap()
                .balance_cents,
            200000
        );
        assert_eq!(v.list_holdings(depot.id).unwrap().len(), 1);
        assert!(v
            .clone()
            .pending_fnz_documents(conn, list)
            .unwrap()
            .is_empty());
        assert_eq!(
            v.db()
                .unwrap()
                .query_row("SELECT count(*) FROM booking_documents", [], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            1
        );
        let other = v
            .add_bank_connection(ConnectorKind::Fnz, "Other FNZ".into(), "other".into())
            .unwrap();
        assert_eq!(
            v.clone()
                .pending_fnz_documents(other, format!("[{doc}]"))
                .unwrap()
                .len(),
            1
        );
        let wrong = v
            .add_bank_connection(ConnectorKind::PayPal, "Other Bank".into(), "test".into())
            .unwrap();
        assert!(v
            .clone()
            .import_fnz_overview(wrong, fixture().to_string())
            .is_err());
        assert!(v
            .clone()
            .pending_fnz_documents(conn, "[{}]".into())
            .is_err());
        drop(v);
        let _ = std::fs::remove_file(path);
    }
}
