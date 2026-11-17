//! Selective partner sync (#585): two partners with separate vaults exchange
//! only the records of designated joint accounts via a shared folder.

use std::collections::HashSet;

/// Which accounts are shared with the partner.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PartnerSyncScope {
    pub shared_account_uuids: Vec<String>,
}

impl PartnerSyncScope {
    /// True when the account is one of the designated joint accounts.
    pub fn includes_account(&self, account_uuid: &str) -> bool {
        self.shared_account_uuids.iter().any(|u| u == account_uuid)
    }

    /// Keeps only the items whose account UUID (from `acct_fn`) is shared.
    /// Order is preserved.
    pub fn filter_shared_records<T, F: Fn(&T) -> &str>(&self, items: Vec<T>, acct_fn: F) -> Vec<T> {
        if self.shared_account_uuids.is_empty() {
            return Vec::new();
        }
        let shared: HashSet<&str> = self
            .shared_account_uuids
            .iter()
            .map(String::as_str)
            .collect();
        items
            .into_iter()
            .filter(|item| shared.contains(acct_fn(item)))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scope(ids: &[&str]) -> PartnerSyncScope {
        PartnerSyncScope {
            shared_account_uuids: ids.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn includes_only_listed_accounts() {
        let s = scope(&["a", "b"]);
        assert!(s.includes_account("a"));
        assert!(s.includes_account("b"));
        assert!(!s.includes_account("c"));
        assert!(!s.includes_account(""));
    }

    #[test]
    fn empty_scope_shares_nothing() {
        let s = PartnerSyncScope::default();
        assert!(!s.includes_account("a"));
        let items = vec![("a", 1), ("b", 2)];
        assert!(s.filter_shared_records(items, |i| i.0).is_empty());
    }

    #[test]
    fn filter_keeps_shared_records_in_order() {
        let s = scope(&["joint", "other"]);
        let items = vec![
            ("joint", 1),
            ("private", 2),
            ("other", 3),
            ("joint", 4),
            ("private", 5),
        ];
        let out = s.filter_shared_records(items, |i| i.0);
        assert_eq!(out, vec![("joint", 1), ("other", 3), ("joint", 4)]);
    }

    #[test]
    fn filter_works_with_owned_strings() {
        struct Rec {
            account: String,
        }
        let s = scope(&["x"]);
        let items = vec![
            Rec {
                account: "x".into(),
            },
            Rec {
                account: "y".into(),
            },
        ];
        let out = s.filter_shared_records(items, |r| r.account.as_str());
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].account, "x");
    }
}
