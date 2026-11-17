//! Sparer-Pauschbetrag and Freistellungsaufträge (#616).
//!
//! All amounts are integer cents. The allowance is `100_000` (1.000 €) for single
//! filers and `200_000` (2.000 €) for joint filers; it can be split across banks
//! with one [`BankExemptionOrder`] each.

use std::fmt;

/// Sparer-Pauschbetrag for single filers, in cents.
pub const ALLOWANCE_SINGLE_CENTS: i64 = 100_000;
/// Sparer-Pauschbetrag for joint filers, in cents.
pub const ALLOWANCE_JOINT_CENTS: i64 = 200_000;
/// Teilfreistellung for equity funds, in percent (the rest stays taxable).
pub const EQUITY_PARTIAL_EXEMPTION_PERCENT: i64 = 30;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FilingStatus {
    Single,
    Joint,
}

impl FilingStatus {
    pub fn allowance_cents(self) -> i64 {
        match self {
            FilingStatus::Single => ALLOWANCE_SINGLE_CENTS,
            FilingStatus::Joint => ALLOWANCE_JOINT_CENTS,
        }
    }
}

/// Freistellungsauftrag at one bank.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BankExemptionOrder {
    pub bank_name: String,
    pub allocated_cents: i64,
    pub used_cents: i64,
}

impl BankExemptionOrder {
    /// Part of this order that is not yet used (never negative).
    pub fn remaining_cents(&self) -> i64 {
        (self.allocated_cents - self.used_cents).max(0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapitalIncomeKind {
    /// Interest.
    Zinsen,
    /// Dividends.
    Dividenden,
    /// Fund distributions.
    Ausschuettung,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapitalIncome {
    pub kind: CapitalIncomeKind,
    pub amount_cents: i64,
    /// Equity fund/ETF: 30 % Teilfreistellung applies (not to `Zinsen`).
    pub equity_fund: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CapitalIncomeSummary {
    pub zinsen_cents: i64,
    pub dividenden_cents: i64,
    pub ausschuettung_cents: i64,
    /// Sum of all gross amounts.
    pub gross_cents: i64,
    /// Part freed by Teilfreistellung.
    pub partial_exemption_cents: i64,
    /// Gross minus Teilfreistellung; basis for the Sparer-Pauschbetrag.
    pub taxable_cents: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaxAllowanceError {
    NegativeAmount,
    /// The orders would exceed the total allowance.
    ExceedsAllowance {
        available_cents: i64,
    },
    UnknownBank(String),
}

impl fmt::Display for TaxAllowanceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NegativeAmount => write!(f, "amount must not be negative"),
            Self::ExceedsAllowance { available_cents } => {
                write!(f, "exceeds unallocated allowance ({available_cents} cents)")
            }
            Self::UnknownBank(b) => write!(f, "no exemption order for bank {b}"),
        }
    }
}

impl std::error::Error for TaxAllowanceError {}

#[derive(Debug, Clone)]
pub struct TaxAllowanceManager {
    status: FilingStatus,
    orders: Vec<BankExemptionOrder>,
}

impl TaxAllowanceManager {
    pub fn new(status: FilingStatus) -> Self {
        Self {
            status,
            orders: Vec::new(),
        }
    }

    pub fn status(&self) -> FilingStatus {
        self.status
    }

    pub fn orders(&self) -> &[BankExemptionOrder] {
        &self.orders
    }

    pub fn total_allowance_cents(&self) -> i64 {
        self.status.allowance_cents()
    }

    pub fn allocated_cents(&self) -> i64 {
        self.orders.iter().map(|o| o.allocated_cents).sum()
    }

    /// Allowance not yet assigned to a bank. Can be negative after switching
    /// from joint to single with orders that no longer fit.
    pub fn unallocated_cents(&self) -> i64 {
        self.total_allowance_cents() - self.allocated_cents()
    }

    /// Change the filing status; existing orders are kept (see `unallocated_cents`).
    pub fn set_status(&mut self, status: FilingStatus) {
        self.status = status;
    }

    /// Set (or replace) the order of a bank (case-insensitive name match).
    pub fn set_order(
        &mut self,
        bank_name: &str,
        allocated_cents: i64,
    ) -> Result<(), TaxAllowanceError> {
        if allocated_cents < 0 {
            return Err(TaxAllowanceError::NegativeAmount);
        }
        let name = bank_name.trim();
        let idx = self.find(name);
        let current = idx.map_or(0, |i| self.orders[i].allocated_cents);
        let available = self.unallocated_cents() + current;
        if allocated_cents > available {
            return Err(TaxAllowanceError::ExceedsAllowance {
                available_cents: available.max(0),
            });
        }
        match idx {
            Some(i) => self.orders[i].allocated_cents = allocated_cents,
            None => self.orders.push(BankExemptionOrder {
                bank_name: name.to_string(),
                allocated_cents,
                used_cents: 0,
            }),
        }
        Ok(())
    }

    /// Record capital income that a bank offset against its order.
    pub fn record_usage(&mut self, bank_name: &str, cents: i64) -> Result<(), TaxAllowanceError> {
        if cents < 0 {
            return Err(TaxAllowanceError::NegativeAmount);
        }
        let i = self
            .find(bank_name.trim())
            .ok_or_else(|| TaxAllowanceError::UnknownBank(bank_name.to_string()))?;
        self.orders[i].used_cents += cents;
        Ok(())
    }

    /// Unused part of one bank's order, if it has one.
    pub fn bank_remaining_cents(&self, bank_name: &str) -> Option<i64> {
        self.find(bank_name.trim())
            .map(|i| self.orders[i].remaining_cents())
    }

    fn find(&self, name: &str) -> Option<usize> {
        self.orders
            .iter()
            .position(|o| o.bank_name.eq_ignore_ascii_case(name))
    }

    /// Aggregate capital income, applying Teilfreistellung to equity funds.
    pub fn aggregate_income(incomes: &[CapitalIncome]) -> CapitalIncomeSummary {
        let mut s = CapitalIncomeSummary::default();
        for inc in incomes {
            match inc.kind {
                CapitalIncomeKind::Zinsen => s.zinsen_cents += inc.amount_cents,
                CapitalIncomeKind::Dividenden => s.dividenden_cents += inc.amount_cents,
                CapitalIncomeKind::Ausschuettung => s.ausschuettung_cents += inc.amount_cents,
            }
            s.gross_cents += inc.amount_cents;
            if inc.equity_fund && inc.kind != CapitalIncomeKind::Zinsen {
                // Round half away from zero, in cents.
                let exempt =
                    (inc.amount_cents * EQUITY_PARTIAL_EXEMPTION_PERCENT + 50).div_euclid(100);
                s.partial_exemption_cents += exempt;
            }
        }
        s.taxable_cents = s.gross_cents - s.partial_exemption_cents;
        s
    }

    /// Taxable income exceeding the total allowance (0 if fully covered).
    pub fn taxable_after_allowance_cents(&self, summary: &CapitalIncomeSummary) -> i64 {
        (summary.taxable_cents - self.total_allowance_cents()).max(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inc(kind: CapitalIncomeKind, cents: i64, equity: bool) -> CapitalIncome {
        CapitalIncome {
            kind,
            amount_cents: cents,
            equity_fund: equity,
        }
    }

    #[test]
    fn allowance_amounts() {
        assert_eq!(
            TaxAllowanceManager::new(FilingStatus::Single).total_allowance_cents(),
            100_000
        );
        assert_eq!(
            TaxAllowanceManager::new(FilingStatus::Joint).total_allowance_cents(),
            200_000
        );
    }

    #[test]
    fn unallocated_and_replace() {
        let mut m = TaxAllowanceManager::new(FilingStatus::Single);
        m.set_order("Bank A", 60_000).unwrap();
        m.set_order("Bank B", 30_000).unwrap();
        assert_eq!(m.unallocated_cents(), 10_000);
        m.set_order("bank a", 70_000).unwrap();
        assert_eq!(m.orders().len(), 2);
        assert_eq!(m.unallocated_cents(), 0);
    }

    #[test]
    fn rejects_over_allocation_and_negative() {
        let mut m = TaxAllowanceManager::new(FilingStatus::Single);
        m.set_order("A", 90_000).unwrap();
        assert_eq!(
            m.set_order("B", 20_000),
            Err(TaxAllowanceError::ExceedsAllowance {
                available_cents: 10_000
            })
        );
        assert_eq!(m.set_order("B", -1), Err(TaxAllowanceError::NegativeAmount));
        assert_eq!(m.orders().len(), 1);
    }

    #[test]
    fn usage_and_remaining() {
        let mut m = TaxAllowanceManager::new(FilingStatus::Joint);
        m.set_order("A", 50_000).unwrap();
        m.record_usage("A", 20_000).unwrap();
        assert_eq!(m.bank_remaining_cents("A"), Some(30_000));
        m.record_usage("A", 40_000).unwrap();
        assert_eq!(m.bank_remaining_cents("A"), Some(0));
        assert_eq!(m.bank_remaining_cents("X"), None);
        assert_eq!(
            m.record_usage("X", 1),
            Err(TaxAllowanceError::UnknownBank("X".into()))
        );
    }

    #[test]
    fn switching_to_single_can_go_negative() {
        let mut m = TaxAllowanceManager::new(FilingStatus::Joint);
        m.set_order("A", 150_000).unwrap();
        m.set_status(FilingStatus::Single);
        assert_eq!(m.unallocated_cents(), -50_000);
    }

    #[test]
    fn aggregates_income_with_teilfreistellung() {
        let s = TaxAllowanceManager::aggregate_income(&[
            inc(CapitalIncomeKind::Zinsen, 10_000, true), // no exemption on interest
            inc(CapitalIncomeKind::Dividenden, 20_000, false),
            inc(CapitalIncomeKind::Ausschuettung, 10_000, true),
        ]);
        assert_eq!(s.zinsen_cents, 10_000);
        assert_eq!(s.dividenden_cents, 20_000);
        assert_eq!(s.ausschuettung_cents, 10_000);
        assert_eq!(s.gross_cents, 40_000);
        assert_eq!(s.partial_exemption_cents, 3_000);
        assert_eq!(s.taxable_cents, 37_000);
    }

    #[test]
    fn teilfreistellung_rounds_to_cents() {
        let s =
            TaxAllowanceManager::aggregate_income(&[inc(CapitalIncomeKind::Dividenden, 105, true)]);
        assert_eq!(s.partial_exemption_cents, 32); // 31.5 -> 32
    }

    #[test]
    fn taxable_after_allowance() {
        let m = TaxAllowanceManager::new(FilingStatus::Single);
        let s = TaxAllowanceManager::aggregate_income(&[inc(
            CapitalIncomeKind::Zinsen,
            130_000,
            false,
        )]);
        assert_eq!(m.taxable_after_allowance_cents(&s), 30_000);
        let s = TaxAllowanceManager::aggregate_income(&[]);
        assert_eq!(m.taxable_after_allowance_cents(&s), 0);
    }
}
