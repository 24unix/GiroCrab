//! Vermögensoptimierung (#553): Einlagensicherung und Zinsgewinn bei Umschichtung.
//!
//! Reine Rechenfunktionen ohne Vault-Zugriff; alle Beträge in Cent.

/// Gesetzliche Einlagensicherung je Kunde und Bank: 100.000,00 € in Cent.
pub const DEPOSIT_INSURANCE_LIMIT_CENTS: i64 = 10_000_000;

/// Prüft je Bank, ob die Einlagensicherung überschritten ist.
///
/// `bank_balances` enthält `(Bankname, Guthaben in Cent)`; mehrere Einträge
/// derselben Bank werden summiert. Rückgabe: `(Bankname, Betrag über dem Limit
/// in Cent)` für jede Bank oberhalb von [`DEPOSIT_INSURANCE_LIMIT_CENTS`], in
/// der Reihenfolge des ersten Auftretens. Ein Guthaben genau am Limit gilt
/// als gedeckt.
pub fn check_deposit_insurance_exceeded(bank_balances: &[(String, i64)]) -> Vec<(String, i64)> {
    let mut totals: Vec<(String, i64)> = Vec::new();
    for (bank, balance) in bank_balances {
        match totals.iter_mut().find(|(name, _)| name == bank) {
            Some((_, sum)) => *sum = sum.saturating_add(*balance),
            None => totals.push((bank.clone(), *balance)),
        }
    }
    totals
        .into_iter()
        .filter(|(_, sum)| *sum > DEPOSIT_INSURANCE_LIMIT_CENTS)
        .map(|(bank, sum)| (bank, sum - DEPOSIT_INSURANCE_LIMIT_CENTS))
        .collect()
}

/// Jährlicher Zinsgewinn in Cent, wenn `shift_cents` von einem Konto mit
/// `current_bps` Zins (Basispunkte, 100 bps = 1 %) auf eins mit `best_bps`
/// umgeschichtet werden. Kaufmännisch gerundet; 0, wenn der neue Zins nicht
/// höher ist oder nichts verschoben wird.
pub fn calculate_annual_interest_gain_cents(
    shift_cents: i64,
    current_bps: u32,
    best_bps: u32,
) -> i64 {
    if shift_cents <= 0 || best_bps <= current_bps {
        return 0;
    }
    let diff = i128::from(best_bps - current_bps);
    let gain = i128::from(shift_cents) * diff;
    let rounded = (gain + 5_000) / 10_000;
    i64::try_from(rounded).unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b(name: &str, cents: i64) -> (String, i64) {
        (name.to_string(), cents)
    }

    #[test]
    fn limit_is_100k_euro() {
        assert_eq!(DEPOSIT_INSURANCE_LIMIT_CENTS, 10_000_000);
    }

    #[test]
    fn insurance_empty_input() {
        assert!(check_deposit_insurance_exceeded(&[]).is_empty());
    }

    #[test]
    fn insurance_at_limit_is_covered() {
        let r = check_deposit_insurance_exceeded(&[b("A", DEPOSIT_INSURANCE_LIMIT_CENTS)]);
        assert!(r.is_empty());
    }

    #[test]
    fn insurance_reports_excess() {
        let r = check_deposit_insurance_exceeded(&[
            b("A", 12_000_000),
            b("B", 5_000_000),
            b("C", 10_000_001),
        ]);
        assert_eq!(r, vec![b("A", 2_000_000), b("C", 1)]);
    }

    #[test]
    fn insurance_sums_same_bank() {
        let r = check_deposit_insurance_exceeded(&[
            b("A", 6_000_000),
            b("B", 1_000),
            b("A", 5_000_000),
        ]);
        assert_eq!(r, vec![b("A", 1_000_000)]);
    }

    #[test]
    fn insurance_ignores_negative_balances() {
        let r = check_deposit_insurance_exceeded(&[b("A", -20_000_000)]);
        assert!(r.is_empty());
    }

    #[test]
    fn gain_shifting_15000_euro_yields_about_112_euro() {
        // 15.000 € von 0,00 % auf 0,75 % = 112,50 € pro Jahr.
        let gain = calculate_annual_interest_gain_cents(1_500_000, 0, 75);
        assert_eq!(gain, 11_250);
        assert_eq!(gain / 100, 112);
    }

    #[test]
    fn gain_uses_rate_difference() {
        // 10.000 € von 1,00 % auf 3,00 % = 200 €.
        assert_eq!(
            calculate_annual_interest_gain_cents(1_000_000, 100, 300),
            20_000
        );
    }

    #[test]
    fn gain_is_zero_without_improvement_or_shift() {
        assert_eq!(calculate_annual_interest_gain_cents(1_000_000, 300, 300), 0);
        assert_eq!(calculate_annual_interest_gain_cents(1_000_000, 300, 100), 0);
        assert_eq!(calculate_annual_interest_gain_cents(0, 0, 300), 0);
        assert_eq!(calculate_annual_interest_gain_cents(-5, 0, 300), 0);
    }

    #[test]
    fn gain_rounds_half_up_and_does_not_overflow() {
        // 1 Cent * 5000 bps = 0,5 Cent -> 1
        assert_eq!(calculate_annual_interest_gain_cents(1, 0, 5_000), 1);
        assert_eq!(
            calculate_annual_interest_gain_cents(i64::MAX, 0, u32::MAX),
            i64::MAX
        );
    }
}
