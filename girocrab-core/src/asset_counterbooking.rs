//! Counter-bookings on asset accounts (#252).
//!
//! A purchase or sale paid from a bank account (`-250_000` for a purchase, `+250_000` for a sale)
//! has a mirror image on the asset account (property, vehicle, precious metal, …). This module
//! derives that mirror booking deterministically and values an asset against its cost basis.
//! It is pure computation: no vault access and no schema change.

use std::fmt;

use crate::fnv::Fnv1a64;

/// What kind of asset an asset account holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum AssetKind {
    Security,
    RealEstate,
    Vehicle,
    PreciousMetal,
    Collectible,
    Other,
}

impl AssetKind {
    fn tag(self) -> &'static str {
        match self {
            Self::Security => "security",
            Self::RealEstate => "real_estate",
            Self::Vehicle => "vehicle",
            Self::PreciousMetal => "precious_metal",
            Self::Collectible => "collectible",
            Self::Other => "other",
        }
    }
}

/// Why a counter-booking could not be built.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CounterbookingError {
    /// The source booking has amount 0.
    ZeroAmount,
    /// The fee is negative.
    NegativeFee,
    /// For a purchase the fee must stay below the amount paid (the asset leg would be ≤ 0).
    FeeExceedsAmount,
}

impl fmt::Display for CounterbookingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::ZeroAmount => "source booking has amount 0",
            Self::NegativeFee => "fee must not be negative",
            Self::FeeExceedsAmount => "fee exceeds the amount paid",
        })
    }
}

impl std::error::Error for CounterbookingError {}

/// The proposed mirror booking on the asset account, plus the split-off fee.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct CounterbookingProposal {
    /// Deterministic id (same inputs → same id), usable to detect an already created counter-booking.
    pub proposal_id: String,
    /// The bank booking this proposal mirrors.
    pub source_booking_id: String,
    pub asset_account_id: String,
    pub asset_kind: AssetKind,
    pub booking_date: String,
    pub purpose: String,
    /// Signed amount on the asset account: positive for a purchase (asset grows), negative for a sale.
    pub asset_amount_cents: i64,
    /// Fee split off the transaction (≥ 0). Expense on the bank side, not part of the asset leg
    /// of a purchase; for a sale it was deducted from the proceeds.
    pub fee_cents: i64,
    /// `true` when the source booking was a purchase (money out).
    pub is_purchase: bool,
}

/// Builds the counter-booking for a purchase (`source_amount_cents < 0`) or sale (`> 0`) booked on
/// a bank account. `fee_cents` is the part of the booked amount that is a fee (≥ 0).
///
/// - Purchase: the bank paid `|amount|` including the fee, so the asset leg is `|amount| - fee`.
/// - Sale: the bank received `amount` after the fee, so the asset leaves with `amount + fee`
///   (asset leg `-(amount + fee)`).
pub fn build_asset_counterbooking(
    source_booking_id: &str,
    source_amount_cents: i64,
    fee_cents: i64,
    asset_account_id: &str,
    asset_kind: AssetKind,
    booking_date: &str,
    purpose: &str,
) -> Result<CounterbookingProposal, CounterbookingError> {
    if source_amount_cents == 0 {
        return Err(CounterbookingError::ZeroAmount);
    }
    if fee_cents < 0 {
        return Err(CounterbookingError::NegativeFee);
    }
    let is_purchase = source_amount_cents < 0;
    let gross = source_amount_cents.unsigned_abs();
    let fee = fee_cents.unsigned_abs();
    let asset_amount_cents = if is_purchase {
        if fee >= gross {
            return Err(CounterbookingError::FeeExceedsAmount);
        }
        i64::try_from(gross - fee).map_err(|_| CounterbookingError::FeeExceedsAmount)?
    } else {
        -i64::try_from(gross + fee).map_err(|_| CounterbookingError::FeeExceedsAmount)?
    };
    let proposal_id = proposal_id(
        source_booking_id,
        asset_account_id,
        asset_kind,
        source_amount_cents,
        fee_cents,
    );
    Ok(CounterbookingProposal {
        proposal_id,
        source_booking_id: source_booking_id.to_string(),
        asset_account_id: asset_account_id.to_string(),
        asset_kind,
        booking_date: booking_date.to_string(),
        purpose: purpose.to_string(),
        asset_amount_cents,
        fee_cents,
        is_purchase,
    })
}

/// FNV-1a over the identifying inputs; stable across runs and platforms (unlike `DefaultHasher`).
fn proposal_id(
    source_booking_id: &str,
    asset_account_id: &str,
    kind: AssetKind,
    amount_cents: i64,
    fee_cents: i64,
) -> String {
    let hash = Fnv1a64::default()
        .field(source_booking_id)
        .field(asset_account_id)
        .field(kind.tag())
        .field(amount_cents.to_le_bytes())
        .field(fee_cents.to_le_bytes())
        .finish();
    format!("asset-cb-{hash:016x}")
}

/// Valuation of an asset against what was paid for it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct AssetValuation {
    /// Einstandswert: purchase legs plus acquisition fees.
    pub cost_basis_cents: i64,
    /// Current market value.
    pub market_value_cents: i64,
    /// Market value − cost basis.
    pub unrealized_pnl_cents: i64,
    /// Unrealized gain/loss in basis points of the cost basis (1 bp = 0.01 %), rounded half away
    /// from zero; `None` when the cost basis is not positive.
    pub unrealized_pnl_bp: Option<i64>,
}

/// Values an asset: `acquisition_cents` are the (positive) asset legs of its purchases,
/// `acquisition_fees_cents` the fees paid on them (part of the Einstandswert).
pub fn compute_asset_valuation(
    acquisition_cents: &[i64],
    acquisition_fees_cents: i64,
    market_value_cents: i64,
) -> AssetValuation {
    let cost_basis_cents = acquisition_cents
        .iter()
        .fold(acquisition_fees_cents, |acc, c| acc.saturating_add(*c));
    let unrealized_pnl_cents = market_value_cents.saturating_sub(cost_basis_cents);
    let unrealized_pnl_bp = (cost_basis_cents > 0).then(|| {
        let num = i128::from(unrealized_pnl_cents) * 10_000;
        let den = i128::from(cost_basis_cents);
        let half = den / 2;
        let rounded = if num >= 0 {
            (num + half) / den
        } else {
            (num - half) / den
        };
        i64::try_from(rounded).unwrap_or(if rounded > 0 { i64::MAX } else { i64::MIN })
    });
    AssetValuation {
        cost_basis_cents,
        market_value_cents,
        unrealized_pnl_cents,
        unrealized_pnl_bp,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build(amount: i64, fee: i64) -> Result<CounterbookingProposal, CounterbookingError> {
        build_asset_counterbooking(
            "b1",
            amount,
            fee,
            "asset-1",
            AssetKind::PreciousMetal,
            "2026-03-01",
            "Goldbarren",
        )
    }

    #[test]
    fn purchase_splits_fee_off_the_asset_leg() {
        let p = build(-100_000, 1_500).unwrap();
        assert!(p.is_purchase);
        assert_eq!(p.asset_amount_cents, 98_500);
        assert_eq!(p.fee_cents, 1_500);
        assert_eq!(p.asset_account_id, "asset-1");
    }

    #[test]
    fn sale_removes_proceeds_plus_fee_from_the_asset() {
        let p = build(98_000, 2_000).unwrap();
        assert!(!p.is_purchase);
        assert_eq!(p.asset_amount_cents, -100_000);
    }

    #[test]
    fn invalid_inputs_are_rejected() {
        assert_eq!(build(0, 0), Err(CounterbookingError::ZeroAmount));
        assert_eq!(build(-100, -1), Err(CounterbookingError::NegativeFee));
        assert_eq!(build(-100, 100), Err(CounterbookingError::FeeExceedsAmount));
    }

    #[test]
    fn proposal_id_is_deterministic_and_input_sensitive() {
        let a = build(-100_000, 1_500).unwrap();
        let b = build(-100_000, 1_500).unwrap();
        let c = build(-100_000, 1_600).unwrap();
        assert_eq!(a.proposal_id, b.proposal_id);
        assert_ne!(a.proposal_id, c.proposal_id);
        // Stored proposals are recognised by their id: it must never change.
        assert_eq!(a.proposal_id, "asset-cb-20e329b7daf36b22");
    }

    #[test]
    fn valuation_gain_loss_and_basis_points() {
        let gain = compute_asset_valuation(&[90_000, 10_000], 0, 115_000);
        assert_eq!(gain.cost_basis_cents, 100_000);
        assert_eq!(gain.unrealized_pnl_cents, 15_000);
        assert_eq!(gain.unrealized_pnl_bp, Some(1_500));

        let loss = compute_asset_valuation(&[99_000], 1_000, 70_000);
        assert_eq!(loss.cost_basis_cents, 100_000);
        assert_eq!(loss.unrealized_pnl_cents, -30_000);
        assert_eq!(loss.unrealized_pnl_bp, Some(-3_000));

        assert_eq!(compute_asset_valuation(&[], 0, 500).unrealized_pnl_bp, None);
    }
}
