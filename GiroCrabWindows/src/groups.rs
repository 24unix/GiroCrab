//! Pure logic of the Windows front end for account groups and account settings: kind list,
//! parent / merge candidates, sibling ordering, opening-balance texts and the history summary.
//! No Slint and no vault access here, so everything is unit-tested on every platform.

use girocrab_core::opening_balance::OpeningBalancePreview;
use girocrab_core::{AccountGroup, AccountKind, DailyBalance, UserGroup};

use crate::planning::euro;

/// Symbol a group gets when the field is left empty.
pub const DEFAULT_GROUP_SYMBOL: &str = "folder";

/// Account kinds in the order of the picker.
pub const KINDS: [(AccountKind, &str); 7] = [
    (AccountKind::Checking, "Girokonto"),
    (AccountKind::Savings, "Sparkonto"),
    (AccountKind::CreditCard, "Kreditkarte"),
    (AccountKind::PaymentService, "Zahlungsdienst"),
    (AccountKind::Brokerage, "Depot"),
    (AccountKind::Cash, "Bargeld"),
    (AccountKind::Loan, "Darlehen"),
];

pub fn kind_labels() -> Vec<&'static str> {
    KINDS.iter().map(|k| k.1).collect()
}

pub fn kind_index(kind: &AccountKind) -> i32 {
    KINDS.iter().position(|k| k.0 == *kind).unwrap_or(0) as i32
}

pub fn kind_at(index: i32) -> Option<AccountKind> {
    usize::try_from(index)
        .ok()
        .and_then(|i| KINDS.get(i))
        .map(|k| k.0)
}

/// Symbol text of the form: trimmed, a single token, empty = default.
pub fn clean_symbol(text: &str) -> Result<String, String> {
    let t = text.trim();
    if t.is_empty() {
        return Ok(DEFAULT_GROUP_SYMBOL.to_string());
    }
    if t.chars().count() > 60 || t.contains(char::is_whitespace) {
        return Err("Das Symbol darf keine Leerzeichen enthalten (höchstens 60 Zeichen).".into());
    }
    Ok(t.to_string())
}

/// Entry of a flattened group tree, indented by depth.
pub fn group_label(g: &UserGroup) -> String {
    format!("{}{}", "    ".repeat(g.depth as usize), g.name)
}

/// Index range of the group at `i` and all its subgroups (the list is a flattened tree).
fn block(groups: &[UserGroup], i: usize) -> std::ops::Range<usize> {
    let depth = groups[i].depth;
    let end = groups[i + 1..]
        .iter()
        .position(|g| g.depth <= depth)
        .map_or(groups.len(), |p| i + 1 + p);
    i..end
}

/// Groups `index` can become a subgroup of: not itself and not one of its own subgroups.
pub fn parent_candidates(groups: &[UserGroup], index: usize) -> Vec<usize> {
    if index >= groups.len() {
        return (0..groups.len()).collect();
    }
    let own = block(groups, index);
    (0..groups.len()).filter(|i| !own.contains(i)).collect()
}

/// Groups `index` can be merged into: every other one.
pub fn merge_candidates(count: usize, index: usize) -> Vec<usize> {
    (0..count).filter(|i| *i != index).collect()
}

/// Position of the parent in the picker (0 = top level, n = candidate n-1).
pub fn parent_choice(groups: &[UserGroup], index: usize, candidates: &[usize]) -> i32 {
    let parent = groups[index].parent_uuid.as_deref();
    parent
        .and_then(|p| candidates.iter().position(|c| groups[*c].uuid == p))
        .map_or(0, |p| p as i32 + 1)
}

/// New order of all group uuids after moving the group at `index` (with its subgroups) one
/// place up (`delta < 0`) or down among its siblings; `None` at the end of the row.
pub fn move_group(groups: &[UserGroup], index: usize, delta: i32) -> Option<Vec<String>> {
    if index >= groups.len() || delta == 0 {
        return None;
    }
    let me = block(groups, index);
    let parent = groups[index].parent_uuid.as_ref();
    let depth = groups[index].depth;
    let sibling = if delta < 0 {
        (0..index)
            .rev()
            .find(|i| groups[*i].depth == depth && groups[*i].parent_uuid.as_ref() == parent)?
    } else {
        (me.end..groups.len()).find(|i| groups[*i].depth == depth)?
    };
    // A sibling past a different parent is not a sibling.
    if groups[sibling].parent_uuid.as_ref() != parent {
        return None;
    }
    let other = block(groups, sibling);
    let (first, second) = if other.start < me.start {
        (other, me)
    } else {
        (me, other)
    };
    let uuids = |r: std::ops::Range<usize>| groups[r].iter().map(|g| g.uuid.clone());
    let mut order: Vec<String> = uuids(0..first.start).collect();
    order.extend(uuids(second.clone()));
    order.extend(uuids(first.end..second.start));
    order.extend(uuids(first.clone()));
    order.extend(uuids(second.end..groups.len()));
    Some(order)
}

/// New order of `ids` after moving the one at `index` by `delta`; `None` at the end of the row.
pub fn move_id(ids: &[i64], index: usize, delta: i32) -> Option<Vec<i64>> {
    let target = index.checked_add_signed(delta as isize)?;
    if index >= ids.len() || target >= ids.len() || delta == 0 {
        return None;
    }
    let mut out = ids.to_vec();
    out.swap(index, target);
    Some(out)
}

/// `YYYY-MM-DD` or empty ("before the first booking").
pub fn validate_date(text: &str) -> Result<String, String> {
    let t = text.trim();
    if t.is_empty() {
        return Ok(String::new());
    }
    match crate::cockpit::parse_iso(t) {
        Some((_, m, d)) if t.len() == 10 && (1..=12).contains(&m) && (1..=31).contains(&d) => {
            Ok(t.to_string())
        }
        _ => Err("Bitte das Datum als JJJJ-MM-TT eingeben (oder leer lassen).".into()),
    }
}

/// "12 Buchungen ab dem Datum zählen (Summe 40,00 €), 3 ältere sind abgedeckt. Neuer Saldo: …".
pub fn preview_text(p: &OpeningBalancePreview, opening_cents: i64) -> String {
    let counted = if p.counted == 1 {
        "1 Buchung zählt".to_string()
    } else {
        format!("{} Buchungen zählen", p.counted)
    };
    let older = if p.older == 1 {
        "1 ältere ist".to_string()
    } else {
        format!("{} ältere sind", p.older)
    };
    format!(
        "{counted} (Summe {}), {older} abgedeckt. Neuer Saldo: {}.",
        euro(p.sum_cents),
        euro(opening_cents.saturating_add(p.sum_cents))
    )
}

/// One line for the balance history: span, start, end, lowest and highest balance.
pub fn history_summary(history: &[DailyBalance]) -> String {
    let (Some(first), Some(last)) = (history.first(), history.last()) else {
        return "Kein Saldenverlauf.".into();
    };
    let low = history.iter().map(|d| d.balance_cents).min().unwrap_or(0);
    let high = history.iter().map(|d| d.balance_cents).max().unwrap_or(0);
    format!(
        "Saldo {} bis {}: {} → {} (niedrigster {}, höchster {})",
        first.date,
        last.date,
        euro(first.balance_cents),
        euro(last.balance_cents),
        euro(low),
        euro(high)
    )
}

/// "Girokonten 1.000,00 € · Depots 500,00 €" – the automatic groups by account type.
pub fn type_summary(groups: &[AccountGroup]) -> String {
    groups
        .iter()
        .filter(|g| !g.accounts.is_empty())
        .map(|g| format!("{} {}", g.name, euro(g.balance_cents)))
        .collect::<Vec<_>>()
        .join(" · ")
}

/// Label of the connector key line in the account form.
pub fn connection_line(key: &str) -> String {
    format!("Bankzugang: {key}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn g(uuid: &str, parent: Option<&str>, depth: u32) -> UserGroup {
        UserGroup {
            uuid: uuid.into(),
            name: uuid.to_uppercase(),
            sf_symbol: String::new(),
            color_hex: String::new(),
            sort_order: 0,
            include_in_total: true,
            in_total: true,
            is_ungrouped: false,
            parent_uuid: parent.map(String::from),
            depth,
            balance_cents: 0,
            accounts: Vec::new(),
        }
    }

    /// a (a1, a2), b, c (c1)
    fn tree() -> Vec<UserGroup> {
        vec![
            g("a", None, 0),
            g("a1", Some("a"), 1),
            g("a2", Some("a"), 1),
            g("b", None, 0),
            g("c", None, 0),
            g("c1", Some("c"), 1),
        ]
    }

    #[test]
    fn kinds_round_trip() {
        for (i, (k, _)) in KINDS.iter().enumerate() {
            assert_eq!(kind_index(k), i as i32);
            assert_eq!(kind_at(i as i32), Some(*k));
        }
        assert_eq!(kind_at(-1), None);
        assert_eq!(kind_at(7), None);
        assert_eq!(kind_labels().len(), 7);
    }

    #[test]
    fn symbol_is_trimmed_defaulted_and_single_token() {
        assert_eq!(clean_symbol("  star  ").unwrap(), "star");
        assert_eq!(clean_symbol("").unwrap(), DEFAULT_GROUP_SYMBOL);
        assert!(clean_symbol("two words").is_err());
        assert!(clean_symbol(&"x".repeat(61)).is_err());
    }

    #[test]
    fn labels_are_indented() {
        let t = tree();
        assert_eq!(group_label(&t[0]), "A");
        assert_eq!(group_label(&t[1]), "    A1");
    }

    #[test]
    fn parent_candidates_exclude_own_subtree() {
        let t = tree();
        assert_eq!(parent_candidates(&t, 0), vec![3, 4, 5]);
        assert_eq!(parent_candidates(&t, 1), vec![0, 2, 3, 4, 5]);
        assert_eq!(parent_candidates(&t, 5), vec![0, 1, 2, 3, 4]);
        assert_eq!(merge_candidates(3, 1), vec![0, 2]);
    }

    #[test]
    fn parent_choice_points_at_the_candidate() {
        let t = tree();
        let c = parent_candidates(&t, 1);
        assert_eq!(parent_choice(&t, 1, &c), 1);
        let c = parent_candidates(&t, 3);
        assert_eq!(parent_choice(&t, 3, &c), 0);
    }

    #[test]
    fn moving_a_group_takes_its_subgroups_along() {
        let t = tree();
        assert_eq!(
            move_group(&t, 0, 1).unwrap(),
            ["b", "a", "a1", "a2", "c", "c1"]
        );
        assert_eq!(
            move_group(&t, 4, -1).unwrap(),
            ["a", "a1", "a2", "c", "c1", "b"]
        );
        assert_eq!(
            move_group(&t, 2, -1).unwrap(),
            ["a", "a2", "a1", "b", "c", "c1"]
        );
    }

    #[test]
    fn moving_stops_at_the_ends_and_between_parents() {
        let t = tree();
        assert!(move_group(&t, 0, -1).is_none());
        assert!(move_group(&t, 4, 1).is_none());
        // a2 is the last child of a: b is not its sibling
        assert!(move_group(&t, 2, 1).is_none());
        assert!(move_group(&t, 9, 1).is_none());
        assert!(move_group(&t, 0, 0).is_none());
    }

    #[test]
    fn moving_ids() {
        assert_eq!(move_id(&[1, 2, 3], 0, 1).unwrap(), [2, 1, 3]);
        assert_eq!(move_id(&[1, 2, 3], 2, -1).unwrap(), [1, 3, 2]);
        assert!(move_id(&[1, 2, 3], 0, -1).is_none());
        assert!(move_id(&[1, 2, 3], 2, 1).is_none());
        assert!(move_id(&[1], 4, -1).is_none());
    }

    #[test]
    fn dates() {
        assert_eq!(validate_date(" 2024-03-01 ").unwrap(), "2024-03-01");
        assert_eq!(validate_date("").unwrap(), "");
        assert!(validate_date("01.03.2024").is_err());
        assert!(validate_date("2024-13-01").is_err());
        assert!(validate_date("2024-3-1").is_err());
    }

    #[test]
    fn opening_balance_arithmetic_and_text() {
        let p = OpeningBalancePreview {
            sum_cents: 4000,
            counted: 12,
            older: 1,
        };
        assert_eq!(
            preview_text(&p, 6000),
            "12 Buchungen zählen (Summe 40,00 €), 1 ältere ist abgedeckt. Neuer Saldo: 100,00 €."
        );
        let p = OpeningBalancePreview {
            sum_cents: 0,
            counted: 1,
            older: 3,
        };
        assert!(preview_text(&p, 0).starts_with("1 Buchung zählt"));
        assert!(preview_text(&p, 0).contains("3 ältere sind"));
    }

    #[test]
    fn history_line() {
        assert_eq!(history_summary(&[]), "Kein Saldenverlauf.");
        let h = |d: &str, c| DailyBalance {
            date: d.into(),
            balance_cents: c,
        };
        let s = history_summary(&[
            h("2024-01-01", 1000),
            h("2024-01-02", 500),
            h("2024-01-03", 2000),
        ]);
        assert!(s.contains("2024-01-01 bis 2024-01-03"));
        assert!(s.contains("10,00 € → 20,00 €"));
        assert!(s.contains("niedrigster 5,00 €, höchster 20,00 €"));
    }

    #[test]
    fn type_summary_skips_empty_groups() {
        let g = |name: &str, cents, accounts| AccountGroup {
            id: 0,
            name: name.into(),
            sf_symbol: String::new(),
            sort_order: 0,
            balance_cents: cents,
            accounts,
        };
        assert_eq!(type_summary(&[]), "");
        assert_eq!(type_summary(&[g("Leer", 0, Vec::new())]), "");
    }

    #[test]
    fn connection_text() {
        assert_eq!(connection_line("fints:12345"), "Bankzugang: fints:12345");
    }
}
