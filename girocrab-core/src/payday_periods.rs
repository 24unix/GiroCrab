//! Salary-period evaluation (#565): income against living expenses per period
//! that starts on the payday instead of the first of the month.
//!
//! Someone paid on the 15th sees `15.10. – 14.11.` as one period. The
//! evaluation only reads `(date, amount, flag)` triples, so booking categories
//! stay untouched.

/// One payday period with its income and living expenses (all in cents).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaydayPeriod {
    /// First day of the period, `YYYY-MM-DD`.
    pub start_ymd: String,
    /// Last day of the period (inclusive), `YYYY-MM-DD`.
    pub end_ymd: String,
    /// Sum of all positive amounts.
    pub income_cents: i64,
    /// Sum of negative amounts flagged as living expense, as a positive number.
    pub expense_cents: i64,
    /// `income_cents - expense_cents`.
    pub surplus_cents: i64,
}

fn days_in_month(y: i32, m: u32) -> u32 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
        _ => 28,
    }
}

fn parse_ymd(s: &str) -> Option<(i32, u32, u32)> {
    let mut it = s.get(..10)?.split('-');
    let y: i32 = it.next()?.parse().ok()?;
    let m: u32 = it.next()?.parse().ok()?;
    let d: u32 = it.next()?.parse().ok()?;
    if it.next().is_some() || !(1..=12).contains(&m) || d == 0 || d > days_in_month(y, m) {
        return None;
    }
    Some((y, m, d))
}

fn next_month(y: i32, m: u32) -> (i32, u32) {
    if m == 12 {
        (y + 1, 1)
    } else {
        (y, m + 1)
    }
}

/// Month in which the period containing `(y, m, d)` starts.
fn period_month(payday: u32, y: i32, m: u32, d: u32) -> (i32, u32) {
    if d >= payday.min(days_in_month(y, m)) {
        (y, m)
    } else if m == 1 {
        (y - 1, 12)
    } else {
        (y, m - 1)
    }
}

fn start_day(payday: u32, y: i32, m: u32) -> u32 {
    payday.min(days_in_month(y, m))
}

/// Day before `(y, m, d)`.
fn day_before(y: i32, m: u32, d: u32) -> (i32, u32, u32) {
    if d > 1 {
        (y, m, d - 1)
    } else if m == 1 {
        (y - 1, 12, 31)
    } else {
        (y, m - 1, days_in_month(y, m - 1))
    }
}

fn fmt(y: i32, m: u32, d: u32) -> String {
    format!("{y:04}-{m:02}-{d:02}")
}

/// Groups bookings into consecutive payday periods, oldest first.
///
/// `bookings` are `(date YYYY-MM-DD, amount_cents, is_living_expense)`:
/// positive amounts count as income; negative amounts count as expense only
/// when the flag is set (so transfers, savings or one-off items can be left
/// out). Entries with an unparsable date are ignored. `payday_day` is clamped
/// to 1..=31; in shorter months the period starts on the month's last day.
/// Periods without bookings between the first and last one are included
/// with zeros, so consecutive periods can be compared.
pub fn evaluate_payday_periods(
    payday_day: u8,
    bookings: &[(String, i64, bool)],
) -> Vec<PaydayPeriod> {
    let payday = u32::from(payday_day.clamp(1, 31));
    let mut sums: std::collections::BTreeMap<(i32, u32), (i64, i64)> = Default::default();
    for (date, cents, living) in bookings {
        let Some((y, m, d)) = parse_ymd(date) else {
            continue;
        };
        let entry = sums.entry(period_month(payday, y, m, d)).or_default();
        if *cents > 0 {
            entry.0 += cents;
        } else if *cents < 0 && *living {
            entry.1 -= cents;
        }
    }
    let (Some(&first), Some(&last)) = (sums.keys().next(), sums.keys().next_back()) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut cur = first;
    loop {
        let (income, expense) = sums.get(&cur).copied().unwrap_or((0, 0));
        let next = next_month(cur.0, cur.1);
        let end = day_before(next.0, next.1, start_day(payday, next.0, next.1));
        out.push(PaydayPeriod {
            start_ymd: fmt(cur.0, cur.1, start_day(payday, cur.0, cur.1)),
            end_ymd: fmt(end.0, end.1, end.2),
            income_cents: income,
            expense_cents: expense,
            surplus_cents: income - expense,
        });
        if cur == last {
            break;
        }
        cur = next;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b(d: &str, c: i64, l: bool) -> (String, i64, bool) {
        (d.to_string(), c, l)
    }

    #[test]
    fn mid_month_payday_period() {
        let r = evaluate_payday_periods(
            15,
            &[
                b("2026-10-15", 300_000, false),
                b("2026-10-20", -80_000, true),
                b("2026-11-14", -20_000, true),
                b("2026-11-15", 300_000, false),
            ],
        );
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].start_ymd, "2026-10-15");
        assert_eq!(r[0].end_ymd, "2026-11-14");
        assert_eq!(r[0].income_cents, 300_000);
        assert_eq!(r[0].expense_cents, 100_000);
        assert_eq!(r[0].surplus_cents, 200_000);
        assert_eq!(r[1].start_ymd, "2026-11-15");
        assert_eq!(r[1].end_ymd, "2026-12-14");
        assert_eq!(r[1].surplus_cents, 300_000);
    }

    #[test]
    fn payday_one_is_calendar_month() {
        let r = evaluate_payday_periods(1, &[b("2026-02-10", 5, false)]);
        assert_eq!(
            (r[0].start_ymd.as_str(), r[0].end_ymd.as_str()),
            ("2026-02-01", "2026-02-28")
        );
    }

    #[test]
    fn year_boundary() {
        let r = evaluate_payday_periods(15, &[b("2027-01-03", 100, false)]);
        assert_eq!(
            (r[0].start_ymd.as_str(), r[0].end_ymd.as_str()),
            ("2026-12-15", "2027-01-14")
        );
    }

    #[test]
    fn short_month_clamps_payday() {
        let r = evaluate_payday_periods(
            31,
            &[b("2026-02-28", 100, false), b("2026-03-31", 1, false)],
        );
        assert_eq!(r[0].start_ymd, "2026-02-28");
        assert_eq!(r[0].end_ymd, "2026-03-30");
        assert_eq!(r[1].start_ymd, "2026-03-31");
        assert_eq!(r[1].end_ymd, "2026-04-29");
    }

    #[test]
    fn gaps_are_filled_and_flag_excludes_expenses() {
        let r = evaluate_payday_periods(
            10,
            &[
                b("2026-01-10", 100, false),
                b("2026-03-12", -50, false),
                b("2026-03-12", -7, true),
            ],
        );
        assert_eq!(r.len(), 3);
        assert_eq!(r[1].income_cents, 0);
        assert_eq!(r[1].expense_cents, 0);
        assert_eq!(r[2].expense_cents, 7);
        assert_eq!(r[2].surplus_cents, -7);
    }

    #[test]
    fn empty_and_invalid_input() {
        assert!(evaluate_payday_periods(15, &[]).is_empty());
        assert!(
            evaluate_payday_periods(15, &[b("garbage", 1, true), b("2026-02-30", 1, true)])
                .is_empty()
        );
    }
}
