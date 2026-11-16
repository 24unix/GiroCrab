//! The "PayPal" payment method belongs to PayPal accounts only, not to every
//! payment service account (Uberspace, Amazon orders).

use crate::connectors::*;
use crate::models::{AccountKind, BookingFilter, ConnectorKind};
use crate::vault::Vault;

fn fetch(external_ref: &str, purpose: &str, cents: i64) -> FetchResult {
    FetchResult {
        accounts: vec![RemoteAccount {
            external_ref: external_ref.into(),
            name: external_ref.into(),
            owner: String::new(),
            iban: String::new(),
            account_number: String::new(),
            currency: "EUR".into(),
            kind: AccountKind::PaymentService,
            balance_cents: 0,
            balance_date: "2026-11-10".into(),
        }],
        transactions: vec![RemoteTransaction {
            account_ref: external_ref.into(),
            external_id: format!("{external_ref}-1"),
            booking_date: "2026-11-01".into(),
            value_date: "2026-11-01".into(),
            amount_cents: cents,
            currency: "EUR".into(),
            purpose: purpose.into(),
            ..Default::default()
        }],
        ..Default::default()
    }
}

/// Payment method of every booking, by purpose.
fn methods(v: &Vault) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = v
        .list_transactions(BookingFilter {
            limit: 100,
            ..Default::default()
        })
        .unwrap()
        .transactions
        .into_iter()
        .map(|b| (b.purpose, b.payment_method))
        .collect();
    out.sort();
    out
}

#[test]
fn only_paypal_accounts_read_paypal() {
    let dir = crate::test_support::TempDir::new("girocrab-payment-method");
    let p = dir.join("v.db");
    let v = Vault::open(p.to_string_lossy().to_string(), vec![5u8; 32]).unwrap();
    let paypal = v
        .add_bank_connection(ConnectorKind::PayPal, String::new(), "login".into())
        .unwrap();
    let uberspace = v
        .add_bank_connection(ConnectorKind::Uberspace, String::new(), "login".into())
        .unwrap();
    store_fetch(
        &v,
        ConnectorKind::PayPal,
        paypal,
        fetch("paypal:me", "Zahlung an Händler", -1999),
    )
    .unwrap();
    store_fetch(
        &v,
        ConnectorKind::Uberspace,
        uberspace,
        fetch("uberspace:alpha", "Monatsbeitrag alpha", -500),
    )
    .unwrap();
    let mut deposit = fetch("uberspace:alpha", "Einzahlung", 1000);
    deposit.transactions[0].external_id = "uberspace:alpha-2".into();
    store_fetch(&v, ConnectorKind::Uberspace, uberspace, deposit).unwrap();

    assert_eq!(
        methods(&v),
        vec![
            ("Einzahlung".to_string(), "Gutschrift".to_string()),
            ("Monatsbeitrag alpha".to_string(), "Buchung".to_string()),
            ("Zahlung an Händler".to_string(), "PayPal".to_string()),
        ]
    );
}
