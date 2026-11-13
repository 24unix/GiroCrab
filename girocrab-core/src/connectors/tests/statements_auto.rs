use crate::connectors::*;
use crate::vault::Vault;

#[test]
fn auto_statements_are_due_weekly_and_only_when_enabled() {
    let dir = std::env::temp_dir().join(format!("gc-stmt-auto-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let v = Vault::open(dir.join("v.db").to_string_lossy().into(), vec![4u8; 32]).unwrap();
    let (conn, giro, loan) = {
        let c = v.db().unwrap();
        c.execute(
            "INSERT INTO bank_connections(connector, login_name, display_name) VALUES ('fints:12345678', 'x', 'Bank')",
            [],
        )
        .unwrap();
        let conn = c.last_insert_rowid();
        c.execute("INSERT INTO account_groups(name) VALUES ('G')", [])
            .unwrap();
        c.execute(
            "INSERT INTO accounts(group_id, connection_id, external_ref, name) VALUES ((SELECT id FROM account_groups), ?1, 'giro', 'Giro')",
            [conn],
        )
        .unwrap();
        let giro = c.last_insert_rowid();
        c.execute(
            "INSERT INTO accounts(group_id, connection_id, external_ref, name, kind) VALUES ((SELECT id FROM account_groups), ?1, 'loan', 'Kredit', 'loan')",
            [conn],
        )
        .unwrap();
        (conn, giro, c.last_insert_rowid())
    };
    assert!(v.statements_due(conn).unwrap().is_empty());
    v.set_auto_statements(giro, true).unwrap();
    v.set_auto_statements(loan, true).unwrap();
    assert!(v.auto_statements_enabled(giro).unwrap());
    assert_eq!(v.statements_due(conn).unwrap(), vec!["giro".to_string()]);
    // fetched today -> not due; 8 days ago -> due again
    v.set_setting(statements_last_key(giro), today()).unwrap();
    assert!(v.statements_due(conn).unwrap().is_empty());
    let old = (chrono::Local::now().date_naive() - chrono::Duration::days(8))
        .format("%Y-%m-%d")
        .to_string();
    v.set_setting(statements_last_key(giro), old).unwrap();
    assert_eq!(v.statements_due(conn).unwrap().len(), 1);
    v.set_auto_statements(giro, false).unwrap();
    assert!(!v.auto_statements_enabled(giro).unwrap());
    assert!(v.statements_due(conn).unwrap().is_empty());
    drop(v);
    let _ = std::fs::remove_dir_all(dir);
}
