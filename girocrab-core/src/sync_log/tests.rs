use std::sync::Arc;

use rusqlite::params;

use super::*;

fn vault(tag: &str) -> Arc<Vault> {
    Vault::open(
        crate::test_support::thread_temp_path(tag)
            .to_string_lossy()
            .into(),
        vec![7u8; 32],
    )
    .unwrap()
}

fn connection(v: &Vault, name: &str, login: &str) -> i64 {
    let db = v.db().unwrap();
    db.execute(
        "INSERT INTO bank_connections(connector, display_name, login_name) VALUES ('fints', ?1, ?2)",
        params![name, login],
    )
    .unwrap();
    db.last_insert_rowid()
}

fn all(v: &Vault) -> Vec<SyncLogEntry> {
    v.list_sync_log(SyncLogFilter::default()).unwrap()
}

#[test]
fn scrub_removes_secrets_but_keeps_the_error() {
    let s = scrub(
        "Anmeldung für Kunde max.muster fehlgeschlagen: PIN=12345 abgelehnt, \"token\":\"abc.def\", Authorization: Bearer abcdefgh12345678",
        "max.muster",
    );
    assert!(!s.contains("max.muster"), "{s}");
    assert!(!s.contains("12345"), "{s}");
    assert!(!s.contains("abc.def"), "{s}");
    assert!(!s.contains("abcdefgh"), "{s}");
    assert!(s.contains("fehlgeschlagen"), "{s}");
    assert!(s.contains("abgelehnt"), "{s}");
}

#[test]
fn scrub_masks_ibans_and_long_numbers_only() {
    let s = scrub(
        "Konto DE89 3704 0044 0532 0130 00 und Kundennummer 1234567 (Code 9050, Zeile 12)",
        "",
    );
    assert!(s.contains("DE89…3000"), "{s}");
    assert!(!s.contains("1234567"), "{s}");
    // short codes stay readable
    assert!(s.contains("9050") && s.contains("Zeile 12"), "{s}");
}

#[test]
fn scrub_keeps_plain_words_about_tans() {
    // no `key=value`: nothing to hide, so the text stays diagnosable
    let m = "TAN erforderlich, aber das Verfahren wird nicht unterstützt";
    assert_eq!(scrub(m, ""), m);
}

#[test]
fn scrub_cuts_long_messages() {
    let long = "x".repeat(5000);
    let s = scrub(&long, "");
    assert_eq!(s.chars().count(), MAX_MESSAGE_CHARS + 1);
    assert!(s.ends_with('…'));
}

#[test]
fn logs_lists_newest_first_and_filters() {
    let v = vault("synclog-list");
    let a = connection(&v, "Sparkasse", "kunde-a");
    let b = connection(&v, "ING", "kunde-b");
    for (i, (conn, outcome, msg)) in [
        (a, SyncLogOutcome::Ok, ""),
        (b, SyncLogOutcome::Error, "Zeitüberschreitung beim Abruf"),
        (a, SyncLogOutcome::Error, "PIN falsch (kunde-a)"),
        (b, SyncLogOutcome::Cancelled, ""),
    ]
    .into_iter()
    .enumerate()
    {
        v.log_sync_at(
            (Some(conn), SyncLogSource::Manual, outcome, msg, 0),
            1_000_000 + i as i64,
            KEEP_MS,
            MAX_BYTES,
        )
        .unwrap();
    }
    let log = all(&v);
    assert_eq!(log.len(), 4);
    assert_eq!(log[0].outcome, SyncLogOutcome::Cancelled);
    assert_eq!(log[0].connection_name, "ING");
    // the login never reaches the log
    assert!(log.iter().all(|e| !e.message.contains("kunde-a")));

    let errors = v
        .list_sync_log(SyncLogFilter {
            only_errors: true,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(errors.len(), 2);
    let of_a = v
        .list_sync_log(SyncLogFilter {
            connection_id: Some(a),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(of_a.len(), 2);
    let found = v
        .list_sync_log(SyncLogFilter {
            search: Some("zeitüber ing".into()),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(found.len(), 1);
    let limited = v
        .list_sync_log(SyncLogFilter {
            limit: 2,
            ..Default::default()
        })
        .unwrap();
    assert_eq!(limited.len(), 2);
}

#[test]
fn keeps_the_name_after_the_connection_is_deleted() {
    let v = vault("synclog-deleted");
    let a = connection(&v, "Sparkasse", "x-login");
    v.log_sync(
        Some(a),
        SyncLogSource::Automatic,
        SyncLogOutcome::Ok,
        String::new(),
        3,
    )
    .unwrap();
    v.db()
        .unwrap()
        .execute("DELETE FROM bank_connections WHERE id = ?1", [a])
        .unwrap();
    let log = all(&v);
    assert_eq!(log.len(), 1);
    assert_eq!(log[0].connection_name, "Sparkasse");
    assert_eq!(log[0].imported, 3);
    assert_eq!(log[0].source, SyncLogSource::Automatic);
}

#[test]
fn drops_rows_older_than_seven_days() {
    let v = vault("synclog-age");
    let day = 24 * 60 * 60 * 1000;
    let now = 100 * day;
    for age_days in [9, 8, 6, 0] {
        v.log_sync_at(
            (None, SyncLogSource::Manual, SyncLogOutcome::Ok, "", 0),
            now - age_days * day,
            KEEP_MS,
            MAX_BYTES,
        )
        .unwrap();
    }
    let ages: Vec<i64> = all(&v)
        .iter()
        .map(|e| (now - e.timestamp_ms) / day)
        .collect();
    assert_eq!(ages, vec![0, 6]);
}

#[test]
fn drops_the_oldest_rows_beyond_the_size_cap() {
    let v = vault("synclog-size");
    let msg = "m".repeat(100);
    // one row counts 100 + 0 + ROW_OVERHEAD; room for three
    let cap = 3 * (100 + ROW_OVERHEAD);
    for i in 0..6 {
        v.log_sync_at(
            (None, SyncLogSource::Manual, SyncLogOutcome::Error, &msg, 0),
            1_000 + i,
            KEEP_MS * 1_000_000,
            cap,
        )
        .unwrap();
    }
    let log = all(&v);
    assert_eq!(log.len(), 3);
    assert_eq!(log[0].timestamp_ms, 1_005, "the newest rows stay");
    assert_eq!(log[2].timestamp_ms, 1_003);
}

#[test]
fn clear_empties_the_log() {
    let v = vault("synclog-clear");
    v.log_sync(
        None,
        SyncLogSource::Manual,
        SyncLogOutcome::Ok,
        String::new(),
        0,
    )
    .unwrap();
    v.clear_sync_log().unwrap();
    assert!(all(&v).is_empty());
}
