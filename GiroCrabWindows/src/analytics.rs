//! Inline analytics over the filtered booking rows: category breakdown and tag evaluation.

use crate::daily::Row;

/// One bar of a breakdown: name, summed cents, booking count, share of the total (0..=1).
pub struct Slice {
    pub name: String,
    pub color_hex: String,
    pub cents: i64,
    pub count: usize,
    pub share: f32,
}

fn finish(mut v: Vec<Slice>, n: usize) -> Vec<Slice> {
    v.sort_by_key(|s| std::cmp::Reverse(s.cents));
    let total: i64 = v.iter().map(|s| s.cents).sum();
    v.truncate(n);
    for s in &mut v {
        s.share = if total > 0 {
            s.cents as f32 / total as f32
        } else {
            0.0
        };
    }
    v
}

fn add(v: &mut Vec<Slice>, name: &str, color: &str, cents: i64) {
    match v.iter_mut().find(|s| s.name == name) {
        Some(s) => {
            s.cents += cents;
            s.count += 1;
        }
        None => v.push(Slice {
            name: name.to_string(),
            color_hex: color.to_string(),
            cents,
            count: 1,
            share: 0.0,
        }),
    }
}

/// Top categories of expenses (`expenses`) or income, internal transfers excluded.
pub fn categories(rows: &[&Row], expenses: bool, n: usize) -> Vec<Slice> {
    let mut v = Vec::new();
    for r in rows.iter().filter(|r| !r.transfer) {
        if (r.amount_cents < 0) != expenses || r.amount_cents == 0 {
            continue;
        }
        let name = if r.category_name.is_empty() {
            "Ohne Kategorie"
        } else {
            &r.category_name
        };
        add(&mut v, name, &r.category_color_hex, r.amount_cents.abs());
    }
    finish(v, n)
}

/// Net sum (income − expenses, in cents) per tag; share is relative to the sum of absolute values.
pub fn tags(rows: &[&Row], n: usize) -> Vec<Slice> {
    let mut v = Vec::new();
    for r in rows.iter().filter(|r| !r.transfer) {
        for t in &r.tags {
            add(&mut v, &t.name, &t.color_hex, r.amount_cents);
        }
    }
    let total: i64 = v.iter().map(|s| s.cents.abs()).sum();
    v.sort_by_key(|s| std::cmp::Reverse(s.cents.abs()));
    v.truncate(n);
    for s in &mut v {
        s.share = if total > 0 {
            s.cents.abs() as f32 / total as f32
        } else {
            0.0
        };
    }
    v
}

/// (income, expenses, net) cents of the rows, transfers excluded.
pub fn totals(rows: &[&Row]) -> (i64, i64, i64) {
    let inc: i64 = rows
        .iter()
        .filter(|r| !r.transfer && r.amount_cents > 0)
        .map(|r| r.amount_cents)
        .sum();
    let exp: i64 = rows
        .iter()
        .filter(|r| !r.transfer && r.amount_cents < 0)
        .map(|r| -r.amount_cents)
        .sum();
    (inc, exp, inc - exp)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(cents: i64, cat: &str, tags: &[&str]) -> Row {
        let mut r = crate::cockpit::tests::row("2026-11-01", cents, cat);
        r.tags = tags
            .iter()
            .enumerate()
            .map(|(i, n)| girocrab_core::tags::BookingTag {
                id: i as i64,
                name: n.to_string(),
                color_hex: "#00ff00".into(),
            })
            .collect();
        r
    }

    #[test]
    fn breakdown_and_tags() {
        let rows = [
            row(-300, "A", &["x"]),
            row(-100, "B", &["x", "y"]),
            row(500, "A", &[]),
        ];
        let refs: Vec<&Row> = rows.iter().collect();
        let c = categories(&refs, true, 5);
        assert_eq!(c[0].name, "A");
        assert!((c[0].share - 0.75).abs() < 1e-6);
        let t = tags(&refs, 5);
        assert_eq!(t[0].name, "x");
        assert_eq!(t[0].count, 2);
        assert_eq!(t[0].cents, -400);
        assert_eq!(totals(&refs), (500, 400, 100));
    }
}
