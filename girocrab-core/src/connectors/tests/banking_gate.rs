use crate::error::CoreError;
use crate::models::SepaTransferRequest;
use crate::vault::Vault;

/// Sync and transfer stop before the bank is contacted (and before the
/// connector is even resolved) when the policy blocks the connection key.
#[test]
fn blocked_connector_cannot_sync_or_transfer() {
    let _g = crate::banking_gate::tests::SERIAL
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let dir = std::env::temp_dir().join(format!("gc-gate-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let v = Vault::open(dir.join("v.db").to_string_lossy().into(), vec![5u8; 32]).unwrap();
    let (conn, acct) = {
        let c = v.db().unwrap();
        c.execute(
            "INSERT INTO bank_connections(connector, login_name, display_name) VALUES ('zz-test:1', 'x', 'Bank')",
            [],
        )
        .unwrap();
        let conn = c.last_insert_rowid();
        c.execute("INSERT INTO account_groups(name) VALUES ('G')", [])
            .unwrap();
        c.execute(
            "INSERT INTO accounts(group_id, connection_id, external_ref, name, iban) VALUES ((SELECT id FROM account_groups), ?1, 'giro', 'Giro', 'DE02120300000000202051')",
            [conn],
        )
        .unwrap();
        (conn, c.last_insert_rowid())
    };
    crate::banking_gate::set_banking_block(false, vec!["zz-test".into()], "gesperrt".into());
    let sync = v.clone().begin_sync(conn, "pin".into(), true);
    let transfer = v.clone().begin_transfer(
        SepaTransferRequest {
            account_id: acct,
            recipient_name: "Max".into(),
            recipient_iban: "DE02120300000000202051".into(),
            recipient_bic: None,
            amount_cents: 100,
            purpose: "Test".into(),
            instant: false,
            execution_date: None,
        },
        "pin".into(),
        true,
    );
    crate::banking_gate::clear_banking_block();
    assert!(matches!(sync, Err(CoreError::BankingBlocked { .. })));
    assert!(matches!(transfer, Err(CoreError::BankingBlocked { .. })));
    // Without the block the same sync gets past the gate (and fails later
    // only because `zz-test` is no real connector).
    assert!(!matches!(
        v.clone().begin_sync(conn, "pin".into(), true),
        Err(CoreError::BankingBlocked { .. })
    ));
    drop(v);
    let _ = std::fs::remove_dir_all(dir);
}
