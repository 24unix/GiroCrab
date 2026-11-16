//! Daily-driver logic of the Windows app without Slint: booking filter, inspector selection,
//! privacy masking and SEPA transfer input validation. Everything here is pure so it can be
//! unit-tested; `main.rs` only wires it to the window.

use girocrab_core::{Booking, SepaTransferRequest};

/// Shown instead of amounts, balances, IBANs and other personal texts in privacy mode.
pub const MASK: &str = "••••••";

/// Privacy applies when the user switched it on or while the vault is locked.
pub fn effective_privacy(toggle: bool, unlocked: bool) -> bool {
    toggle || !unlocked
}

pub fn mask(text: &str, privacy: bool) -> String {
    if privacy && !text.is_empty() {
        MASK.to_string()
    } else {
        text.to_string()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum StatusFilter {
    #[default]
    All,
    Unchecked,
    Checked,
    Expenses,
    Income,
}

impl StatusFilter {
    pub fn from_index(i: i32) -> Self {
        match i {
            1 => Self::Unchecked,
            2 => Self::Checked,
            3 => Self::Expenses,
            4 => Self::Income,
            _ => Self::All,
        }
    }
}

/// Filter bar state. Applied in memory to the loaded rows, so typing never hits the vault.
#[derive(Debug, Clone, Default)]
pub struct Filter {
    pub search: String,
    pub uncategorized_only: bool,
    pub status: StatusFilter,
}

/// The booking fields the list and the inspector need (copied once per load).
#[derive(Debug, Clone, PartialEq)]
pub struct Row {
    pub id: i64,
    pub account_name: String,
    pub booking_date: String,
    pub value_date: String,
    pub counterparty: String,
    pub counterparty_iban: String,
    pub purpose: String,
    pub category_id: Option<i64>,
    pub category_name: String,
    pub category_color_hex: String,
    pub amount_cents: i64,
    pub currency: String,
    pub checked: bool,
    pub note: String,
    /// Bank booking type ("Lastschrift", "Kartenzahlung"); the list shows it before the purpose.
    pub booking_text: String,
    /// Domains to try for the logo, best first (empty for private persons and unknown names).
    pub logo_domains: Vec<String>,
    pub monogram: String,
    pub tint_hex: String,
    pub recurring: bool,
}

impl From<&Booking> for Row {
    fn from(b: &Booking) -> Self {
        Row {
            id: b.id,
            account_name: b.account_name.clone(),
            booking_date: b.booking_date.clone(),
            value_date: b.value_date.clone(),
            counterparty: if b.merchant_name.is_empty() {
                b.counterparty.clone()
            } else {
                b.merchant_name.clone()
            },
            counterparty_iban: b.counterparty_iban.clone(),
            purpose: b.purpose.clone(),
            category_id: b.category_id,
            category_name: b.category_name.clone(),
            category_color_hex: b.category_color_hex.clone(),
            amount_cents: b.amount_cents,
            currency: b.currency.clone(),
            checked: b.checked,
            note: b.note.clone(),
            booking_text: b.booking_text.clone(),
            logo_domains: if b.merchant.is_person {
                Vec::new()
            } else if b.merchant.domain_candidates.is_empty() && !b.merchant.domain.is_empty() {
                vec![b.merchant.domain.clone()]
            } else {
                b.merchant.domain_candidates.clone()
            },
            monogram: b.merchant.monogram.clone(),
            tint_hex: b.merchant.color_hex.clone(),
            recurring: !b.recurrence_key.is_empty(),
        }
    }
}

impl Filter {
    pub fn matches(&self, r: &Row) -> bool {
        if self.uncategorized_only && r.category_id.is_some() {
            return false;
        }
        let status_ok = match self.status {
            StatusFilter::All => true,
            StatusFilter::Unchecked => !r.checked,
            StatusFilter::Checked => r.checked,
            StatusFilter::Expenses => r.amount_cents < 0,
            StatusFilter::Income => r.amount_cents > 0,
        };
        if !status_ok {
            return false;
        }
        let hay = format!(
            "{} {} {} {}",
            r.counterparty, r.purpose, r.note, r.counterparty_iban
        )
        .to_lowercase();
        self.search
            .to_lowercase()
            .split_whitespace()
            .all(|t| hay.contains(t))
    }
}

/// Indices of the rows that pass the filter, in list order.
pub fn visible(rows: &[Row], f: &Filter) -> Vec<usize> {
    rows.iter()
        .enumerate()
        .filter(|(_, r)| f.matches(r))
        .map(|(i, _)| i)
        .collect()
}

/// The selection survives a filter change or reload only while its booking is still shown.
pub fn keep_selection(rows: &[Row], shown: &[usize], selected: Option<i64>) -> Option<i64> {
    let id = selected?;
    shown.iter().any(|&i| rows[i].id == id).then_some(id)
}

/// What the inspector shows for a booking, already masked.
#[derive(Debug, Clone, PartialEq)]
pub struct Inspector {
    pub id: i64,
    pub counterparty: String,
    pub iban: String,
    pub purpose: String,
    pub booking_date: String,
    pub value_date: String,
    pub account: String,
    pub amount: String,
    pub note: String,
    pub checked: bool,
    pub category_id: Option<i64>,
    /// Personal data hidden: the inspector is read-only.
    pub read_only: bool,
    pub recurring: bool,
}

pub fn inspect(r: &Row, privacy: bool, money: impl Fn(i64, &str) -> String) -> Inspector {
    Inspector {
        id: r.id,
        counterparty: mask(&r.counterparty, privacy),
        iban: mask(&r.counterparty_iban, privacy),
        purpose: mask(&r.purpose, privacy),
        booking_date: r.booking_date.clone(),
        value_date: if r.value_date.is_empty() {
            r.booking_date.clone()
        } else {
            r.value_date.clone()
        },
        account: r.account_name.clone(),
        amount: mask(&money(r.amount_cents, &r.currency), privacy),
        note: mask(&r.note, privacy),
        checked: r.checked,
        category_id: r.category_id,
        read_only: privacy,
        recurring: r.recurring,
    }
}

/// Raw form input of the transfer dialog.
#[derive(Debug, Clone, Default)]
pub struct TransferInput {
    pub account_id: i64,
    pub name: String,
    pub iban: String,
    pub amount: String,
    pub purpose: String,
}

/// Checks the form like the core does, but with messages next to the right field and without
/// contacting anything. Returns the request for `begin_transfer`.
pub fn validate_transfer(i: &TransferInput) -> Result<SepaTransferRequest, String> {
    if i.account_id <= 0 {
        return Err("Bitte ein Absenderkonto wählen.".into());
    }
    let name = i.name.trim();
    if name.is_empty() {
        return Err("Der Empfängername fehlt.".into());
    }
    if name.chars().count() > 70 {
        return Err("Der Empfängername darf höchstens 70 Zeichen lang sein.".into());
    }
    if !girocrab_core::connectors::validate_iban(i.iban.clone()) {
        return Err("Die Empfänger-IBAN ist ungültig.".into());
    }
    let cents = girocrab_core::parse_amount_to_cents(i.amount.clone())
        .map_err(|_| "Der Betrag ist ungültig (z. B. 12,50).".to_string())?;
    if cents <= 0 {
        return Err("Der Betrag muss größer als 0 sein.".into());
    }
    let purpose = i.purpose.trim();
    if purpose.chars().count() > 140 {
        return Err("Der Verwendungszweck darf höchstens 140 Zeichen lang sein.".into());
    }
    Ok(SepaTransferRequest {
        account_id: i.account_id,
        recipient_name: name.to_string(),
        recipient_iban: i.iban.split_whitespace().collect::<String>().to_uppercase(),
        recipient_bic: None,
        amount_cents: cents,
        purpose: purpose.to_string(),
        instant: false,
        execution_date: None,
    })
}

/// Import kind by file extension.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImportKind {
    /// Encrypted MoneyMoney database (needs its password).
    MoneyMoneyDb,
    /// CSV / CAMT XML / MT940 export.
    Statement,
}

pub fn import_kind(path: &std::path::Path) -> Option<ImportKind> {
    match path.extension()?.to_str()?.to_lowercase().as_str() {
        "moneymoney" => Some(ImportKind::MoneyMoneyDb),
        "csv" | "xml" | "sta" | "mt940" | "txt" => Some(ImportKind::Statement),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: i64, who: &str, purpose: &str, cents: i64, cat: Option<i64>, checked: bool) -> Row {
        Row {
            id,
            account_name: "Giro".into(),
            booking_date: "2026-11-01".into(),
            value_date: String::new(),
            counterparty: who.into(),
            counterparty_iban: "DE89370400440532013000".into(),
            purpose: purpose.into(),
            category_id: cat,
            category_name: String::new(),
            category_color_hex: String::new(),
            amount_cents: cents,
            currency: "EUR".into(),
            checked,
            note: String::new(),
            booking_text: String::new(),
            logo_domains: Vec::new(),
            monogram: String::new(),
            tint_hex: String::new(),
            recurring: false,
        }
    }

    fn sample() -> Vec<Row> {
        vec![
            row(
                1,
                "REWE Markt",
                "Einkauf Lebensmittel",
                -2350,
                Some(5),
                true,
            ),
            row(
                2,
                "Arbeitgeber GmbH",
                "Gehalt November",
                300000,
                None,
                false,
            ),
            row(3, "Stadtwerke", "Strom Abschlag", -8900, None, false),
        ]
    }

    #[test]
    fn search_matches_all_tokens_case_insensitive() {
        let rows = sample();
        let f = Filter {
            search: "rewe LEBENS".into(),
            ..Default::default()
        };
        assert_eq!(visible(&rows, &f), vec![0]);
        let f = Filter {
            search: "rewe gehalt".into(),
            ..Default::default()
        };
        assert!(visible(&rows, &f).is_empty());
    }

    #[test]
    fn uncategorized_and_status_filters_combine() {
        let rows = sample();
        let f = Filter {
            uncategorized_only: true,
            status: StatusFilter::Expenses,
            ..Default::default()
        };
        assert_eq!(visible(&rows, &f), vec![2]);
        let f = Filter {
            status: StatusFilter::Unchecked,
            ..Default::default()
        };
        assert_eq!(visible(&rows, &f), vec![1, 2]);
        assert_eq!(StatusFilter::from_index(4), StatusFilter::Income);
        assert_eq!(StatusFilter::from_index(99), StatusFilter::All);
    }

    #[test]
    fn selection_is_dropped_when_filtered_out() {
        let rows = sample();
        let f = Filter {
            search: "strom".into(),
            ..Default::default()
        };
        let shown = visible(&rows, &f);
        assert_eq!(keep_selection(&rows, &shown, Some(3)), Some(3));
        assert_eq!(keep_selection(&rows, &shown, Some(1)), None);
        assert_eq!(keep_selection(&rows, &shown, None), None);
    }

    #[test]
    fn privacy_masks_inspector_and_makes_it_read_only() {
        let mut r = row(2, "Arbeitgeber GmbH", "Gehalt", 300000, None, false);
        r.note = "privat".into();
        let money = |c: i64, cur: &str| format!("{c} {cur}");
        let open = inspect(&r, false, money);
        assert_eq!(open.amount, "300000 EUR");
        assert_eq!(open.value_date, "2026-11-01");
        assert!(!open.read_only);
        let hidden = inspect(&r, true, money);
        for s in [
            &hidden.amount,
            &hidden.counterparty,
            &hidden.iban,
            &hidden.purpose,
            &hidden.note,
        ] {
            assert_eq!(s, MASK);
        }
        assert!(hidden.read_only);
        // Dates stay visible; empty values are not turned into a mask.
        assert_eq!(hidden.booking_date, "2026-11-01");
        assert_eq!(mask("", true), "");
    }

    #[test]
    fn privacy_is_on_while_locked() {
        assert!(effective_privacy(false, false));
        assert!(effective_privacy(true, true));
        assert!(!effective_privacy(false, true));
    }

    fn input() -> TransferInput {
        TransferInput {
            account_id: 1,
            name: " Erika Muster ".into(),
            iban: "de89 3704 0044 0532 0130 00".into(),
            amount: "12,50".into(),
            purpose: "Miete".into(),
        }
    }

    #[test]
    fn valid_transfer_is_normalised() {
        let r = validate_transfer(&input()).unwrap();
        assert_eq!(r.recipient_name, "Erika Muster");
        assert_eq!(r.recipient_iban, "DE89370400440532013000");
        assert_eq!(r.amount_cents, 1250);
        assert!(!r.instant && r.execution_date.is_none());
    }

    #[test]
    fn invalid_transfer_inputs_are_rejected() {
        let bad = |f: &dyn Fn(&mut TransferInput)| {
            let mut i = input();
            f(&mut i);
            validate_transfer(&i).unwrap_err()
        };
        assert!(bad(&|i| i.account_id = 0).contains("Absender"));
        assert!(bad(&|i| i.name = "  ".into()).contains("Empfängername"));
        assert!(bad(&|i| i.iban = "DE89 3704 0044 0532 0130 01".into()).contains("IBAN"));
        assert!(bad(&|i| i.amount = "abc".into()).contains("Betrag"));
        assert!(bad(&|i| i.amount = "0,00".into()).contains("größer als 0"));
        assert!(bad(&|i| i.amount = "-5".into()).contains("größer als 0"));
        assert!(bad(&|i| i.purpose = "x".repeat(141)).contains("140"));
    }

    #[test]
    fn import_kind_by_extension() {
        use std::path::Path;
        assert_eq!(
            import_kind(Path::new("a.MoneyMoney")),
            Some(ImportKind::MoneyMoneyDb)
        );
        assert_eq!(
            import_kind(Path::new("x/umsaetze.csv")),
            Some(ImportKind::Statement)
        );
        assert_eq!(
            import_kind(Path::new("camt.xml")),
            Some(ImportKind::Statement)
        );
        assert_eq!(import_kind(Path::new("photo.png")), None);
        assert_eq!(import_kind(Path::new("noext")), None);
    }
}
