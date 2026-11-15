//! Standing orders (Daueraufträge, #239): what the bank reports is stored per
//! account, replaced on every complete fetch, and expanded into the coming
//! executions for the "Geplant" page. Read-only; nothing is sent from here.

use chrono::{Datelike, Duration, NaiveDate};
use rusqlite::{params, Connection};

use crate::connectors::RemoteStandingOrder;
use crate::error::CoreResult;
use crate::planned::{PlannedKind, PlannedPayment};

/// Without an end date a period shows at most this many executions per order
/// (a weekly order would otherwise fill the page).
const MAX_OPEN_EXECUTIONS: usize = 12;
/// How far ahead the search for those executions goes.
const MAX_AHEAD_DAYS: i64 = 366;

const STANDING_ORDERS: &str = "
CREATE TABLE IF NOT EXISTS standing_orders (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id      INTEGER NOT NULL REFERENCES accounts(id),
    key             TEXT    NOT NULL,                 -- bank order id, else the content
    order_id        TEXT    NOT NULL DEFAULT '',
    recipient_name  TEXT    NOT NULL DEFAULT '',
    recipient_iban  TEXT    NOT NULL DEFAULT '',
    amount_cents    INTEGER NOT NULL,                 -- positive = outgoing
    purpose         TEXT    NOT NULL DEFAULT '',
    first_date      TEXT    NOT NULL,
    last_date       TEXT,
    time_unit       TEXT    NOT NULL,                 -- M | W
    interval        INTEGER NOT NULL,
    exec_day        INTEGER NOT NULL,
    can_change      INTEGER NOT NULL DEFAULT 0,
    can_delete      INTEGER NOT NULL DEFAULT 0,
    fetched_ms      INTEGER NOT NULL,
    UNIQUE(account_id, key)
);
";

/// Step 18: the table (guarded like step 17: old vaults are rebuilt from the current schema).
pub(crate) fn standing_orders_table(conn: &Connection) -> CoreResult<()> {
    conn.execute_batch(STANDING_ORDERS)?;
    Ok(())
}

fn key_of(o: &RemoteStandingOrder) -> String {
    if o.order_id.is_empty() {
        format!(
            "{}|{}|{}|{}|{}{}|{}",
            o.recipient_iban,
            o.amount_cents,
            o.first_date,
            o.time_unit,
            o.interval,
            o.exec_day,
            o.purpose
        )
    } else {
        o.order_id.clone()
    }
}

/// Replaces the stored standing orders of `account_id` with `orders`.
pub(crate) fn replace_for_account(
    conn: &Connection,
    account_id: i64,
    orders: &[&RemoteStandingOrder],
) -> CoreResult<()> {
    conn.execute(
        "DELETE FROM standing_orders WHERE account_id = ?1",
        [account_id],
    )?;
    for o in orders {
        conn.execute(
            "INSERT OR REPLACE INTO standing_orders(account_id, key, order_id, recipient_name,
                    recipient_iban, amount_cents, purpose, first_date, last_date, time_unit,
                    interval, exec_day, can_change, can_delete, fetched_ms)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)",
            params![
                account_id,
                key_of(o),
                o.order_id,
                o.recipient_name,
                o.recipient_iban,
                o.amount_cents,
                o.purpose,
                o.first_date,
                o.last_date,
                o.time_unit,
                o.interval,
                o.exec_day,
                o.can_change,
                o.can_delete,
                crate::user_groups::now_ms()
            ],
        )?;
    }
    Ok(())
}

struct Row {
    id: i64,
    account_id: i64,
    account_name: String,
    name: String,
    iban: String,
    cents: i64,
    purpose: String,
    first: NaiveDate,
    last: Option<NaiveDate>,
    unit: String,
    interval: u32,
    exec_day: u32,
}

/// Executions of the stored standing orders within `[from, to]`
/// (`to` = `None`: the next [`MAX_OPEN_EXECUTIONS`] of each order), for the given
/// accounts (empty = all).
pub(crate) fn planned_executions(
    conn: &Connection,
    from: NaiveDate,
    to: Option<NaiveDate>,
    account_ids: &[i64],
) -> CoreResult<Vec<PlannedPayment>> {
    let open_ended = to.is_none();
    let to = to.unwrap_or(from + Duration::days(MAX_AHEAD_DAYS));
    let mut q = conn.prepare(
        "SELECT s.id, s.account_id, a.name, s.recipient_name, s.recipient_iban, s.amount_cents,
                s.purpose, s.first_date, s.last_date, s.time_unit, s.interval, s.exec_day
         FROM standing_orders s JOIN accounts a ON a.id = s.account_id
         WHERE a.deleted_ms IS NULL",
    )?;
    let rows = q.query_map([], |r| {
        let date = |s: String| NaiveDate::parse_from_str(&s, "%Y-%m-%d").ok();
        Ok((
            Row {
                id: r.get(0)?,
                account_id: r.get(1)?,
                account_name: r.get(2)?,
                name: r.get(3)?,
                iban: r.get(4)?,
                cents: r.get(5)?,
                purpose: r.get(6)?,
                first: NaiveDate::MIN,
                last: None,
                unit: r.get(9)?,
                interval: r.get(10)?,
                exec_day: r.get(11)?,
            },
            date(r.get(7)?),
            r.get::<_, Option<String>>(8)?.and_then(date),
        ))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (mut o, first, last) = row?;
        let Some(first) = first else { continue };
        o.first = first;
        o.last = last;
        if !account_ids.is_empty() && !account_ids.contains(&o.account_id) {
            continue;
        }
        let mut dates = occurrences(&o, from, to);
        if open_ended {
            dates.truncate(MAX_OPEN_EXECUTIONS);
        }
        for d in dates {
            out.push(PlannedPayment {
                id: format!("standing-{}-{d}", o.id),
                kind: PlannedKind::StandingOrder,
                account_id: o.account_id,
                account_name: o.account_name.clone(),
                date: d.to_string(),
                counterparty: o.name.clone(),
                counterparty_iban: o.iban.clone(),
                amount_cents: -o.cents,
                purpose: o.purpose.clone(),
                rhythm_unit: o.unit.clone(),
                rhythm_interval: o.interval,
            });
        }
    }
    Ok(out)
}

/// Execution dates of one order within `[from, to]`. Month orders run on the
/// execution day (31 = last day; days a month lacks fall on its last day),
/// week orders on that weekday (1 = Monday); never before the first date or
/// after the last one.
fn occurrences(o: &Row, from: NaiveDate, to: NaiveDate) -> Vec<NaiveDate> {
    let end = o.last.map_or(to, |l| l.min(to));
    let step = o.interval.max(1) as i64;
    let mut out = Vec::new();
    if o.unit == "W" {
        let monday = o.first - Duration::days(o.first.weekday().num_days_from_monday() as i64);
        let day = Duration::days(o.exec_day.clamp(1, 7) as i64 - 1);
        // start just before `from`: an old order must not run out of the 1000-step cap
        let k0 = ((from - monday).num_days() / (7 * step) - 1).max(0);
        for k in k0..k0 + 1000 {
            let d = monday + Duration::days(7 * step * k) + day;
            if d > end {
                break;
            }
            if d >= o.first && d >= from {
                out.push(d);
            }
        }
    } else {
        let first_months = o.first.year() as i64 * 12 + o.first.month0() as i64;
        let from_months = from.year() as i64 * 12 + from.month0() as i64;
        let k0 = ((from_months - first_months) / step - 1).max(0);
        for k in k0..k0 + 1000 {
            let months = first_months + step * k;
            let (y, m) = ((months / 12) as i32, (months % 12) as u32 + 1);
            let last_day = last_day_of_month(y, m);
            let day = o.exec_day.clamp(1, 31).min(last_day);
            let Some(d) = NaiveDate::from_ymd_opt(y, m, day) else {
                continue;
            };
            if d > end {
                break;
            }
            if d >= o.first && d >= from {
                out.push(d);
            }
        }
    }
    out
}

fn last_day_of_month(y: i32, m: u32) -> u32 {
    let (ny, nm) = if m == 12 { (y + 1, 1) } else { (y, m + 1) };
    NaiveDate::from_ymd_opt(ny, nm, 1)
        .and_then(|d| d.pred_opt())
        .map_or(28, |d| d.day())
}

#[cfg(test)]
mod tests;
