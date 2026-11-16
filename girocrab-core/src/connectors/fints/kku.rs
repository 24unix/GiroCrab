//! Credit card transactions (HKKKU / HIKKU version 1, the DK successor of the
//! proprietary DKKKU). Banks serve card accounts through it when the card has
//! no statement access via HKKAZ/HKCAZ (Deutsche Bank: Miles & More cards).
//!
//! HIKKU: card number, account id, balance (C|D : amount : currency : date),
//! last statement date, next statement date, then one data element group per
//! booking. Components of a booking (0-based):
//!
//! | 0 | card number | 9 | booked amount (account currency) |
//! | 1 | receipt date | 10 | booked currency |
//! | 2 | booking date | 11 | booked C/D mark |
//! | 3 | statement date | 12–19 | description lines |
//! | 4 | value date | 20 | country |
//! | 5 | original amount | 21 | merchant name |
//! | 6 | original currency | 22 | terminal |
//! | 7 | original C/D mark | 23 | billed (J/N) |
//! | 8 | exchange rate | 24 | booking reference |
//!
//! Original amount, currency and rate are empty for payments in the account
//! currency.

use super::syntax::{Segment, Value};
use crate::connectors::RemoteTransaction;
use crate::money::parse_cents;

/// Booked balance of the card account.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CardBalance {
    pub cents: i64,
    pub currency: String,
    /// `YYYY-MM-DD`, "" if the bank sent none.
    pub date: String,
}

fn iso_date(d: &str) -> Option<String> {
    (d.len() == 8 && d.bytes().all(|b| b.is_ascii_digit()))
        .then(|| format!("{}-{}-{}", &d[..4], &d[4..6], &d[6..]))
}

/// Splits a group at unescaped ':' and removes the '?' escapes.
fn split_group(raw: &str) -> Vec<String> {
    let mut out = vec![String::new()];
    let mut chars = raw.chars();
    while let Some(c) = chars.next() {
        match c {
            '?' => {
                if let Some(n) = chars.next() {
                    out.last_mut().unwrap().push(n);
                }
            }
            ':' => out.push(String::new()),
            c => out.last_mut().unwrap().push(c),
        }
    }
    out
}

/// Components of one booking: a regular data element group, or the same group
/// wrapped in a binary element.
fn components(el: &[Value]) -> Vec<String> {
    match el {
        [Value::Binary(b)] => split_group(&crate::text::decode_bank_bytes(b)),
        _ => el.iter().map(|v| v.text().to_string()).collect(),
    }
}

fn signed(amount: &str, mark: &str) -> Option<i64> {
    let cents = parse_cents(amount).ok()?;
    Some(if mark == "D" { -cents } else { cents })
}

fn booking(c: &[String], account_ref: &str, fallback_currency: &str) -> Option<RemoteTransaction> {
    let get = |i: usize| c.get(i).map(|s| s.trim()).unwrap_or("");
    // Booked amount in the account currency; some banks only fill the original.
    let (amount, currency) = match signed(get(9), get(11)) {
        Some(a) => (a, get(10)),
        None => (signed(get(5), get(7))?, get(6)),
    };
    let booking_date = iso_date(get(2)).or_else(|| iso_date(get(1)))?;
    let value_date = iso_date(get(4)).unwrap_or_else(|| booking_date.clone());
    let lines: Vec<&str> = (12..=19).map(get).filter(|l| !l.is_empty()).collect();
    let merchant = get(21);
    let counterparty = if merchant.is_empty() {
        lines.first().copied().unwrap_or("")
    } else {
        merchant
    };
    let mut purpose: Vec<String> = lines
        .iter()
        .filter(|l| !l.eq_ignore_ascii_case(counterparty))
        .map(|l| l.to_string())
        .collect();
    // Foreign currency: keep what was actually charged abroad.
    let (orig_amount, orig_currency) = (get(5), get(6));
    if !orig_amount.is_empty() && !orig_currency.is_empty() && orig_currency != currency {
        let rate = get(8);
        purpose.push(if rate.is_empty() {
            format!("{orig_amount} {orig_currency}")
        } else {
            format!("{orig_amount} {orig_currency}, Kurs {rate}")
        });
    }
    Some(RemoteTransaction {
        account_ref: account_ref.to_string(),
        booking_date,
        value_date,
        amount_cents: amount,
        currency: if currency.is_empty() {
            fallback_currency.to_string()
        } else {
            currency.to_string()
        },
        counterparty: counterparty.to_string(),
        purpose: purpose.join(" "),
        booking_text: "Kartenumsatz".into(),
        ..Default::default()
    })
}

/// Bookings and balance of all HIKKU segments of one reply. The balance is
/// taken from the first segment that carries one.
pub fn parse<'a>(
    segments: impl Iterator<Item = &'a Segment>,
    account_ref: &str,
    fallback_currency: &str,
) -> (Vec<RemoteTransaction>, Option<CardBalance>) {
    let mut txs = Vec::new();
    let mut balance = None;
    for s in segments {
        if balance.is_none() {
            if let Some(cents) = signed(s.get(3, 1), s.get(3, 0)) {
                balance = Some(CardBalance {
                    cents,
                    currency: s.get(3, 2).to_string(),
                    date: iso_date(s.get(3, 3)).unwrap_or_default(),
                });
            }
        }
        for el in s.elements.iter().skip(6) {
            let c = components(el);
            if let Some(t) = booking(&c, account_ref, fallback_currency) {
                txs.push(t);
            }
        }
    }
    (txs, balance)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::fints::syntax::parse_response;

    fn parsed(raw: &str) -> (Vec<RemoteTransaction>, Option<CardBalance>) {
        let segs = parse_response(raw.as_bytes()).unwrap();
        parse(segs.iter().filter(|s| s.id() == "HIKKU"), "card", "EUR")
    }

    /// One booking group of 25 components from (position, value) pairs.
    fn group(fields: &[(usize, &str)]) -> String {
        let mut c = vec![String::new(); 25];
        for (i, v) in fields {
            c[*i] = v.replace(':', "?:");
        }
        c.join(":")
    }

    // Invented data.
    const CARD: &str = "5232000011112222";

    fn purchase() -> String {
        group(&[
            (0, CARD),
            (1, "20261001"),
            (2, "20261002"),
            (4, "20261002"),
            (9, "12,50"),
            (10, "EUR"),
            (11, "D"),
            (12, "KAFFEEBAR AM MARKT"),
            (13, "Filiale: Mitte"),
            (20, "DE"),
            (21, "KAFFEEBAR"),
            (23, "N"),
            (24, "REF0001"),
        ])
    }

    fn foreign() -> String {
        group(&[
            (0, CARD),
            (1, "20261003"),
            (2, "20261004"),
            (4, "20261004"),
            (5, "20,00"),
            (6, "USD"),
            (7, "D"),
            (8, "1,0852"),
            (9, "18,43"),
            (10, "EUR"),
            (11, "D"),
            (12, "ONLINE SHOP"),
            (20, "US"),
            (21, "ONLINE SHOP"),
            (23, "J"),
            (24, "REF0002"),
        ])
    }

    fn refund() -> String {
        group(&[
            (0, CARD),
            (2, "20261005"),
            (9, "1.234,00"),
            (10, "EUR"),
            (11, "C"),
            (12, "GUTSCHRIFT"),
            (23, "J"),
            (24, "REF0003"),
        ])
    }

    #[test]
    fn parses_balance_and_bookings() {
        let raw = format!(
            "HIKKU:4:1:3+{CARD}++D:655,56:EUR:20261004+20261003+20261103+{}+{}+{}'",
            purchase(),
            foreign(),
            refund()
        );
        let (txs, balance) = parsed(&raw);
        assert_eq!(
            balance,
            Some(CardBalance {
                cents: -65_556,
                currency: "EUR".into(),
                date: "2026-10-04".into()
            })
        );
        assert_eq!(txs.len(), 3);

        let t = &txs[0];
        assert_eq!((t.amount_cents, t.currency.as_str()), (-1_250, "EUR"));
        assert_eq!(
            (t.booking_date.as_str(), t.value_date.as_str()),
            ("2026-10-02", "2026-10-02")
        );
        assert_eq!(t.counterparty, "KAFFEEBAR");
        assert_eq!(t.purpose, "KAFFEEBAR AM MARKT Filiale: Mitte");
        assert_eq!(t.account_ref, "card");

        // foreign currency: booked amount counts, the original goes into the purpose
        let t = &txs[1];
        assert_eq!(t.amount_cents, -1_843);
        assert_eq!(t.counterparty, "ONLINE SHOP");
        assert_eq!(t.purpose, "20,00 USD, Kurs 1,0852");

        // refund: credit, no receipt/value date, no merchant name
        let t = &txs[2];
        assert_eq!(t.amount_cents, 123_400);
        assert_eq!(t.value_date, "2026-10-05");
        assert_eq!(t.counterparty, "GUTSCHRIFT");
        assert_eq!(t.purpose, "");
    }

    #[test]
    fn no_bookings_and_no_balance() {
        let (txs, balance) = parsed("HIKKU:4:1:3+5232000011112222'");
        assert!(txs.is_empty());
        assert_eq!(balance, None);
    }

    #[test]
    fn several_segments_are_merged_balance_from_the_first() {
        let raw = format!(
            "HIKKU:4:1:3+{CARD}++D:10,00:EUR:20261004+++{}'HIKKU:5:1:3+{CARD}++D:99,00:EUR:20261004+++{}'",
            purchase(),
            refund()
        );
        let (txs, balance) = parsed(&raw);
        assert_eq!(txs.len(), 2);
        assert_eq!(balance.unwrap().cents, -1_000);
    }

    #[test]
    fn booking_wrapped_in_a_binary_element() {
        let p = purchase();
        let raw = format!("HIKKU:4:1:3+{CARD}+++++@{}@{p}'", p.len());
        let (txs, _) = parsed(&raw);
        assert_eq!(txs.len(), 1);
        assert_eq!(txs[0].purpose, "KAFFEEBAR AM MARKT Filiale: Mitte");
    }

    #[test]
    fn incomplete_groups_are_skipped() {
        let (txs, _) = parsed("HIKKU:4:1:3+5232000011112222+++++5232000011112222:20261001'");
        assert!(txs.is_empty());
    }
}
