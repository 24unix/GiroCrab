//! Own transfers between a bank account and a payment-service account without
//! IBAN (PayPal top-up / withdrawal, #302 part 2). Without an IBAN the counter
//! booking cannot be matched by account number, so a pair is recognised by
//! opposite amount, a date window and PayPal wording.

use std::collections::{HashMap, HashSet};

use super::Vault;
use crate::error::CoreError;

/// Days between the two legs (bank vs. payment service).
const WINDOW_DAYS: i64 = 3;

/// Wording of the payment-service leg that names a funding / payout.
const PAYOUT_WORDS: [&str; 10] = [
    "bankeinzug",
    "bankgutschrift",
    "banküberweisung",
    "bankuberweisung",
    "auszahlung",
    "aufladung",
    "bank deposit",
    "withdraw",
    "transfer to bank",
    "überweisung auf",
];

fn has_indicator(bank_text: &str, pp_text: &str) -> bool {
    let b = bank_text.to_lowercase();
    let p = pp_text.to_lowercase();
    b.contains("paypal") || PAYOUT_WORDS.iter().any(|w| p.contains(w))
}

/// Candidate pairs: every uncategorised payment-service booking with each
/// bank booking of the opposite amount in the window. CROSS JOIN keeps the
/// payment-service accounts outermost, so `p` is read by account.
fn pairs_sql() -> String {
    format!(
        "SELECT p.id, b.id, b.counterparty || ' ' || b.purpose, p.counterparty || ' ' || p.purpose \
         FROM accounts pa CROSS JOIN transactions p ON p.account_id = pa.id \
         JOIN transactions b ON b.account_id != p.account_id AND {b} \
         JOIN accounts ba ON ba.id = b.account_id AND ba.deleted_ms IS NULL \
              AND ba.kind NOT IN ('loan', 'brokerage') \
         WHERE pa.kind = 'payment_service' AND pa.iban = '' AND pa.deleted_ms IS NULL \
           AND p.deleted_ms IS NULL AND b.deleted_ms IS NULL \
           AND p.category_id IS NULL AND b.category_id IS NULL \
           AND p.amount_cents != 0 \
           AND NOT (ba.kind = 'payment_service' AND ba.iban = '' AND b.id < p.id) \
           AND NOT EXISTS (SELECT 1 FROM transactions m WHERE m.account_id = p.account_id \
                AND m.id != p.id AND m.deleted_ms IS NULL AND {m})",
        b = opposite_near_p("b"),
        m = opposite_near_p("m"),
    )
}

/// Booking `t` has the opposite amount of `p` within `WINDOW_DAYS`. The BETWEEN
/// bounds, a day wider than the window, let `tx_amount_date` find the
/// candidates; the julianday test still decides.
fn opposite_near_p(t: &'static str) -> String {
    let (w, wide) = (WINDOW_DAYS, WINDOW_DAYS + 1);
    format!(
        "{t}.amount_cents = -p.amount_cents \
         AND {t}.booking_date BETWEEN date(p.booking_date, '-{wide} days') AND date(p.booking_date, '+{wide} days') \
         AND abs(julianday({t}.booking_date) - julianday(p.booking_date)) <= {w}"
    )
}

impl Vault {
    /// Ids of both legs of every unambiguous, uncategorised bank ↔ payment-service
    /// transfer. Safeguards against plain purchases: a payment-service leg that
    /// has a second booking of the opposite amount in the window (the merchant
    /// debit next to the bank funding) is a funding leg, not a transfer; and a
    /// leg with more than one possible counterpart is left alone.
    pub(super) fn payment_service_transfer_ids(
        db: &rusqlite::Connection,
    ) -> Result<HashSet<i64>, CoreError> {
        let has_pp: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE kind = 'payment_service' \
             AND iban = '' AND deleted_ms IS NULL)",
            [],
            |r| r.get(0),
        )?;
        if !has_pp {
            return Ok(HashSet::new());
        }
        // (payment-service booking, bank booking, texts)
        let mut st = db.prepare(&pairs_sql())?;
        let rows: Vec<(i64, i64, String, String)> = st
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
            .collect::<Result<_, _>>()?;
        let mut by_p: HashMap<i64, Vec<i64>> = HashMap::new();
        let mut by_b: HashMap<i64, Vec<i64>> = HashMap::new();
        let mut ok = Vec::new();
        for (p, b, bt, pt) in &rows {
            by_p.entry(*p).or_default().push(*b);
            by_b.entry(*b).or_default().push(*p);
            if has_indicator(bt, pt) {
                ok.push((*p, *b));
            }
        }
        let mut ids = HashSet::new();
        for (p, b) in ok {
            if by_p[&p].len() == 1 && by_b[&b].len() == 1 {
                ids.insert(p);
                ids.insert(b);
            }
        }
        Ok(ids)
    }
}

#[cfg(test)]
mod tests {
    use crate::merchants::FlowKind;
    use crate::models::*;
    use crate::test_support::TempDir;
    use crate::vault::Vault;
    use rusqlite::params;
    use std::sync::Arc;

    const GIRO_IBAN: &str = "DE89370400440532013000";

    /// The pairing runs on every booking list: it must look up the counter
    /// bookings by amount and date, never scan the table per booking.
    #[test]
    fn pairing_uses_the_amount_index() {
        let f = fx();
        let db = f.v.db().unwrap();
        let plan: Vec<String> = db
            .prepare(&format!("EXPLAIN QUERY PLAN {}", super::pairs_sql()))
            .unwrap()
            .query_map([], |r| r.get(3))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        let by_amount = plan
            .iter()
            .filter(|l| l.contains("USING INDEX tx_amount_date (amount_cents=?"))
            .count();
        assert_eq!(by_amount, 2, "{plan:#?}");
    }

    struct Fx {
        _d: TempDir,
        v: Arc<Vault>,
        giro: i64,
        pp: i64,
    }

    fn fx() -> Fx {
        let d = TempDir::new("pp-transfer");
        let v = Vault::open(d.join("v.db").to_string_lossy().into(), vec![7u8; 32]).unwrap();
        let db = v.db().unwrap();
        db.execute(
            "INSERT INTO bank_connections(connector, display_name, login_name) VALUES ('fints:1', 'Bank', 'me')",
            [],
        )
        .unwrap();
        let con = db.last_insert_rowid();
        db.execute("INSERT INTO account_groups(name) VALUES ('G')", [])
            .unwrap();
        let group = db.last_insert_rowid();
        let mut ids = vec![];
        for (ext, name, iban, kind) in [
            ("A1", "Giro", GIRO_IBAN, "checking"),
            ("A2", "PayPal", "", "payment_service"),
        ] {
            db.execute(
                "INSERT INTO accounts(connection_id, group_id, external_ref, name, kind, iban) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![con, group, ext, name, kind, iban],
            )
            .unwrap();
            ids.push(db.last_insert_rowid());
        }
        drop(db);
        Fx {
            _d: d,
            v,
            giro: ids[0],
            pp: ids[1],
        }
    }

    fn add(f: &Fx, acc: i64, ext: &str, date: &str, cents: i64, cp: &str, purpose: &str) -> i64 {
        let db = f.v.db().unwrap();
        db.execute(
            "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, counterparty, purpose, category_source) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'none')",
            params![acc, ext, date, cents, cp, purpose],
        )
        .unwrap();
        db.last_insert_rowid()
    }

    fn flow(f: &Fx, id: i64) -> FlowKind {
        f.v.list_transactions(BookingFilter::default())
            .unwrap()
            .transactions
            .into_iter()
            .find(|b| b.id == id)
            .unwrap()
            .flow
    }

    fn open_ids(f: &Fx) -> Vec<i64> {
        f.v.list_transactions(BookingFilter {
            uncategorized_only: true,
            ..Default::default()
        })
        .unwrap()
        .transactions
        .into_iter()
        .map(|b| b.id)
        .collect()
    }

    #[test]
    fn paypal_top_up_and_withdrawal_are_transfers() {
        let f = fx();
        let bank_out = add(
            &f,
            f.giro,
            "g1",
            "2024-03-05",
            -50_00,
            "PayPal (Europe) S.a.r.l.",
            "Aufladung",
        );
        let pp_in = add(
            &f,
            f.pp,
            "p1",
            "2024-03-06",
            50_00,
            "Bankgutschrift",
            "Bankgutschrift",
        );
        let pp_out = add(
            &f,
            f.pp,
            "p2",
            "2024-04-10",
            -20_00,
            "Auszahlung",
            "Auszahlung auf Bankkonto",
        );
        let bank_in = add(
            &f,
            f.giro,
            "g2",
            "2024-04-12",
            20_00,
            "PayPal (Europe) S.a.r.l.",
            "Auszahlung",
        );
        for id in [bank_out, pp_in, pp_out, bank_in] {
            assert_eq!(flow(&f, id), FlowKind::Transfer);
            assert!(!open_ids(&f).contains(&id));
        }
    }

    #[test]
    fn paypal_purchase_is_not_a_transfer() {
        let f = fx();
        // Bank funds the payment; PayPal shows funding plus the merchant debit.
        let bank = add(
            &f,
            f.giro,
            "g1",
            "2024-03-05",
            -30_00,
            "PayPal (Europe) S.a.r.l.",
            "Shop 1234",
        );
        let fund = add(
            &f,
            f.pp,
            "p1",
            "2024-03-05",
            30_00,
            "Bankgutschrift",
            "Bankgutschrift",
        );
        let shop = add(
            &f,
            f.pp,
            "p2",
            "2024-03-05",
            -30_00,
            "Shop GmbH",
            "Bestellung",
        );
        for id in [bank, fund, shop] {
            assert_ne!(flow(&f, id), FlowKind::Transfer);
            assert!(open_ids(&f).contains(&id));
        }
    }

    #[test]
    fn explicit_category_is_kept() {
        let f = fx();
        let bank = add(
            &f,
            f.giro,
            "g1",
            "2024-03-05",
            -50_00,
            "PayPal (Europe) S.a.r.l.",
            "Aufladung",
        );
        let pp = add(
            &f,
            f.pp,
            "p1",
            "2024-03-06",
            50_00,
            "Bankgutschrift",
            "Bankgutschrift",
        );
        let db = f.v.db().unwrap();
        db.execute("INSERT INTO categories(name) VALUES ('Hobby')", [])
            .unwrap();
        let cat = db.last_insert_rowid();
        db.execute(
            "UPDATE transactions SET category_id = ?1, category_source = 'manual' WHERE id = ?2",
            params![cat, bank],
        )
        .unwrap();
        drop(db);
        assert_ne!(flow(&f, bank), FlowKind::Transfer);
        assert_ne!(flow(&f, pp), FlowKind::Transfer);
    }
}
