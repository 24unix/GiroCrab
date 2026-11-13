//! Abruf-Protokoll (GiroCrab/GiroCrab#238): one row per finished bank sync, so
//! a failed fetch can be looked at afterwards ("Protokoll" window).
//!
//! The log lives in the vault (encrypted, local to this device: it is not part
//! of a vault merge). It holds the time, the connection, the result and the
//! error text – never a login, PIN, TAN or token (#196): the message is
//! scrubbed before it is stored ([`scrub`]). Rows older than seven days go,
//! and the oldest rows go once the log passes 10 MB.

use std::sync::OnceLock;

use regex::Regex;
use rusqlite::{params, params_from_iter, types::Value, Connection, OptionalExtension};

use crate::error::CoreResult;
use crate::user_groups::now_ms;
use crate::vault::Vault;
use crate::CoreError;

/// How long a row is kept.
pub(crate) const KEEP_MS: i64 = 7 * 24 * 60 * 60 * 1000;
/// Size cap of the log (message + name + a fixed overhead per row).
pub(crate) const MAX_BYTES: i64 = 10 * 1024 * 1024;
/// Longest message that is stored.
const MAX_MESSAGE_CHARS: usize = 2000;
/// Per-row overhead counted against [`MAX_BYTES`].
const ROW_OVERHEAD: i64 = 64;

/// Result of a sync.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SyncLogOutcome {
    Ok,
    Error,
    Cancelled,
}

impl SyncLogOutcome {
    fn as_str(self) -> &'static str {
        match self {
            SyncLogOutcome::Ok => "ok",
            SyncLogOutcome::Error => "error",
            SyncLogOutcome::Cancelled => "cancelled",
        }
    }

    fn parse(s: &str) -> Self {
        match s {
            "ok" => SyncLogOutcome::Ok,
            "cancelled" => SyncLogOutcome::Cancelled,
            _ => SyncLogOutcome::Error,
        }
    }
}

/// What started the sync.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SyncLogSource {
    /// The user asked for it (Abrufen, Sammelabruf).
    Manual,
    /// The scheduled background fetch.
    Automatic,
    /// A statement (Kontoauszug) download.
    Statements,
}

impl SyncLogSource {
    fn as_str(self) -> &'static str {
        match self {
            SyncLogSource::Manual => "manual",
            SyncLogSource::Automatic => "auto",
            SyncLogSource::Statements => "statements",
        }
    }

    fn parse(s: &str) -> Self {
        match s {
            "auto" => SyncLogSource::Automatic,
            "statements" => SyncLogSource::Statements,
            _ => SyncLogSource::Manual,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncLogEntry {
    pub id: i64,
    /// Unix time in milliseconds.
    pub timestamp_ms: i64,
    /// `None` once the connection is gone; the name below stays.
    pub connection_id: Option<i64>,
    pub connection_name: String,
    pub source: SyncLogSource,
    pub outcome: SyncLogOutcome,
    /// Scrubbed error text (or a short note); empty for a plain success.
    pub message: String,
    /// New bookings of a successful sync.
    pub imported: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct SyncLogFilter {
    pub connection_id: Option<i64>,
    /// Only failed syncs.
    pub only_errors: bool,
    /// Words (all must occur) in the connection name or the message.
    pub search: Option<String>,
    /// 0 = all.
    pub limit: u32,
}

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("static pattern"))
}

/// Removes what must not end up in the log (#196): the login name, values
/// that follow a secret-like key (`pin=…`, `"token":"…"`, `Bearer …`),
/// IBANs (kept as first four and last four characters) and any other run of
/// six or more digits (TANs, customer and account numbers). The result is cut
/// to [`MAX_MESSAGE_CHARS`].
pub(crate) fn scrub(message: &str, login: &str) -> String {
    static SECRET: OnceLock<Regex> = OnceLock::new();
    static BEARER: OnceLock<Regex> = OnceLock::new();
    static IBAN: OnceLock<Regex> = OnceLock::new();
    static DIGITS: OnceLock<Regex> = OnceLock::new();
    let mut s = message.trim().to_string();
    let login = login.trim();
    if login.chars().count() >= 4 {
        s = s.replace(login, "•••");
    }
    // before the key rule, or `Authorization: Bearer <token>` would leave the token behind
    s = re(&BEARER, r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}")
        .replace_all(&s, "$1 •••")
        .into_owned();
    s = re(
        &SECRET,
        r#"(?i)("?\b(?:pin|tan|passwort|password|kennwort|token|access_token|refresh_token|secret|client_secret|api[-_ ]?key|authorization)\b"?)\s*[:=]\s*("[^"]*"|'[^']*'|\S+)"#,
    )
    .replace_all(&s, "$1: •••")
    .into_owned();
    s = re(&IBAN, r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}\b")
        .replace_all(&s, |c: &regex::Captures| {
            let compact: String = c[0].chars().filter(|ch| !ch.is_whitespace()).collect();
            let n = compact.chars().count();
            format!(
                "{}…{}",
                compact.chars().take(4).collect::<String>(),
                compact.chars().skip(n - 4).collect::<String>()
            )
        })
        .into_owned();
    s = re(&DIGITS, r"\d{6,}").replace_all(&s, "•••").into_owned();
    if s.chars().count() > MAX_MESSAGE_CHARS {
        s = s.chars().take(MAX_MESSAGE_CHARS).collect::<String>() + "…";
    }
    s
}

/// Drops rows past the retention time, then the oldest rows until the log is
/// within `max_bytes`.
fn prune(conn: &Connection, now: i64, keep_ms: i64, max_bytes: i64) -> CoreResult<()> {
    conn.execute("DELETE FROM sync_log WHERE ts_ms < ?1", [now - keep_ms])?;
    conn.execute(
        "DELETE FROM sync_log WHERE id IN (
             SELECT id FROM (
                 SELECT id, SUM(length(message) + length(connection_name) + ?2)
                            OVER (ORDER BY id DESC) AS cum
                   FROM sync_log)
              WHERE cum > ?1)",
        params![max_bytes, ROW_OVERHEAD],
    )?;
    Ok(())
}

fn entry_from_row(r: &rusqlite::Row) -> rusqlite::Result<SyncLogEntry> {
    Ok(SyncLogEntry {
        id: r.get(0)?,
        timestamp_ms: r.get(1)?,
        connection_id: r.get(2)?,
        connection_name: r.get(3)?,
        source: SyncLogSource::parse(&r.get::<_, String>(4)?),
        outcome: SyncLogOutcome::parse(&r.get::<_, String>(5)?),
        message: r.get(6)?,
        imported: r.get::<_, i64>(7)?.max(0) as u32,
    })
}

impl Vault {
    /// Stores one row. `now`, `keep_ms` and `max_bytes` are parameters so tests can
    /// age the log.
    pub(crate) fn log_sync_at(
        &self,
        entry: (Option<i64>, SyncLogSource, SyncLogOutcome, &str, u32),
        now: i64,
        keep_ms: i64,
        max_bytes: i64,
    ) -> CoreResult<()> {
        let (connection_id, source, outcome, message, imported) = entry;
        let db = self.db()?;
        let (name, login): (String, String) = match connection_id {
            Some(id) => db
                .query_row(
                    "SELECT display_name, login_name FROM bank_connections WHERE id = ?1",
                    [id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?
                .unwrap_or_default(),
            None => Default::default(),
        };
        db.execute(
            "INSERT INTO sync_log(ts_ms, connection_id, connection_name, source, outcome, message, imported)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                now,
                connection_id,
                name,
                source.as_str(),
                outcome.as_str(),
                scrub(message, &login),
                imported
            ],
        )?;
        prune(&db, now, keep_ms, max_bytes)
    }
}

#[uniffi::export]
impl Vault {
    /// Appends a finished sync to the Abrufprotokoll. The text is scrubbed of
    /// logins, PINs, TANs, tokens, IBANs and long numbers first.
    pub fn log_sync(
        &self,
        connection_id: Option<i64>,
        source: SyncLogSource,
        outcome: SyncLogOutcome,
        message: String,
        imported: u32,
    ) -> Result<(), CoreError> {
        self.log_sync_at(
            (connection_id, source, outcome, &message, imported),
            now_ms(),
            KEEP_MS,
            MAX_BYTES,
        )?;
        Ok(())
    }

    /// The log, newest first.
    pub fn list_sync_log(&self, filter: SyncLogFilter) -> Result<Vec<SyncLogEntry>, CoreError> {
        let db = self.db()?;
        let mut wh: Vec<String> = vec!["1 = 1".into()];
        let mut args: Vec<Value> = vec![];
        if let Some(id) = filter.connection_id {
            args.push(Value::Integer(id));
            wh.push(format!("connection_id = ?{}", args.len()));
        }
        if filter.only_errors {
            wh.push("outcome = 'error'".into());
        }
        if let Some(q) = filter.search.as_deref() {
            for term in q.split_whitespace() {
                let like = format!(
                    "%{}%",
                    term.replace('\\', "\\\\")
                        .replace('%', "\\%")
                        .replace('_', "\\_")
                );
                args.push(Value::Text(like));
                let n = args.len();
                wh.push(format!(
                    "(message LIKE ?{n} ESCAPE '\\' OR connection_name LIKE ?{n} ESCAPE '\\')"
                ));
            }
        }
        let limit = if filter.limit == 0 {
            String::new()
        } else {
            format!(" LIMIT {}", filter.limit)
        };
        let sql = format!(
            "SELECT id, ts_ms, connection_id, connection_name, source, outcome, message, imported
               FROM sync_log WHERE {} ORDER BY ts_ms DESC, id DESC{limit}",
            wh.join(" AND ")
        );
        let mut stmt = db.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(args.iter()), entry_from_row)?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Empties the log.
    pub fn clear_sync_log(&self) -> Result<(), CoreError> {
        self.db()?.execute("DELETE FROM sync_log", [])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests;
