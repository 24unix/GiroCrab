//! Categorisation rules (pattern and expression rules): storage, preview and application.

use std::collections::HashSet;

use rusqlite::{params, params_from_iter, Connection};

use super::{Vault, LIVE_BOOKINGS_SQL};
use crate::error::{CoreError, CoreResult};
use crate::i18n::{tr, trf};
use crate::models::*;
use crate::rules::{RuleRow, RuleSet};

impl Vault {
    pub(crate) fn rule_set(conn: &Connection) -> CoreResult<RuleSet> {
        // Disabled rules never match; skipping them also keeps a switched-off
        // rule with an invalid pattern (e.g. imported) from breaking the set.
        let mut rules = Self::load_rules(conn)?;
        rules.retain(|r| r.enabled);
        RuleSet::new(rules)
    }

    fn load_rules(conn: &Connection) -> CoreResult<Vec<Rule>> {
        let mut stmt = conn.prepare(&format!(
            "SELECT r.id, r.name, r.category_id, r.field, r.match_kind, r.pattern, r.case_sensitive,
                    r.min_amount_cents, r.max_amount_cents, {acc}, r.priority, r.enabled,
                    (SELECT count(*) FROM transactions t WHERE t.rule_id = r.id AND t.deleted_ms IS NULL)
             FROM rules r WHERE r.deleted_ms IS NULL
             ORDER BY r.priority, r.id",
            acc = crate::rules::ACCOUNT_SET_SQL
        ))?;
        let live: std::collections::HashSet<i64> = conn
            .prepare("SELECT id FROM accounts WHERE deleted_ms IS NULL")?
            .query_map([], |r| r.get(0))?
            .collect::<Result<_, _>>()?;
        let rows = stmt.query_map([], |r| {
            let stored = crate::rules::parse_account_ids(&r.get::<_, rusqlite::types::Value>(9)?);
            Ok((
                stored.clone(),
                Rule {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    category_id: r.get(2)?,
                    field: RuleField::from_str(&r.get::<_, String>(3)?),
                    match_kind: match r.get::<_, String>(4)?.as_str() {
                        "regex" => MatchKind::Regex,
                        "expression" => MatchKind::Expression,
                        _ => MatchKind::Keyword,
                    },
                    pattern: r.get(5)?,
                    case_sensitive: r.get::<_, i64>(6)? != 0,
                    min_amount_cents: r.get(7)?,
                    max_amount_cents: r.get(8)?,
                    account_ids: stored,
                    priority: r.get(10)?,
                    enabled: r.get::<_, i64>(11)? != 0,
                    match_count: r.get::<_, i64>(12)? as u32,
                },
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (stored, mut rule) = row?;
            // Deleted accounts drop out of the restriction; a rule whose
            // accounts are all gone is hidden (as before).
            rule.account_ids.retain(|a| live.contains(a));
            if !stored.is_empty() && rule.account_ids.is_empty() {
                continue;
            }
            out.push(rule);
        }
        Ok(out)
    }

    /// Re-runs rules over transactions that are not manually categorised.
    /// Returns the number of transactions whose category changed.
    /// Bookings of archived accounts are left alone (GiroCrab/GiroCrab#43).
    pub(crate) fn apply_rules_inner(
        conn: &Connection,
        only_uncategorised: bool,
    ) -> CoreResult<u32> {
        let changed = Self::categorise_by_rules(conn, only_uncategorised, None)?;
        // manual loans (#36): link new bookings by expression, refresh balances
        crate::loans::apply_loan_rules(conn)?;
        // opening balances (#212): balance = opening + bookings since
        crate::opening_balance::refresh_all(conn)?;
        Ok(changed)
    }

    /// Runs the rules over the uncategorised bookings in `ids` (a merge lets
    /// rules refill the bookings whose category it cleared).
    pub(crate) fn apply_rules_to(conn: &Connection, ids: &HashSet<i64>) -> CoreResult<u32> {
        Self::categorise_by_rules(conn, true, Some(ids))
    }

    /// `only`: restricts the run to these bookings.
    fn categorise_by_rules(
        conn: &Connection,
        only_uncategorised: bool,
        only: Option<&HashSet<i64>>,
    ) -> CoreResult<u32> {
        let set = Self::rule_set(conn)?;
        let source_sql = if only_uncategorised {
            "t.category_source = 'none'"
        } else {
            "t.category_source != 'manual'"
        };
        // Bound as one JSON array, so a large id set can't exceed SQLite's
        // variable limit.
        let ids_json = only.map(serde_json::to_string).transpose()?;
        let ids_sql = if ids_json.is_some() {
            " AND t.id IN (SELECT value FROM json_each(?1))"
        } else {
            ""
        };
        let mut stmt = conn.prepare(&format!(
            "SELECT {}
             FROM transactions t LEFT JOIN accounts a ON a.id = t.account_id
             WHERE a.archived_unix IS NULL AND a.deleted_ms IS NULL AND t.deleted_ms IS NULL AND {source_sql}{ids_sql}",
            RuleRow::COLUMNS
        ))?;
        let rows: Vec<RuleRow> = stmt
            .query_map(params_from_iter(ids_json), RuleRow::read)?
            .collect::<Result<_, _>>()?;
        let mut changed = 0u32;
        let mut upd_rule = conn.prepare("UPDATE transactions SET category_id = ?1, rule_id = ?2, category_source = 'rule' WHERE id = ?3")?;
        let mut upd_none = conn.prepare("UPDATE transactions SET category_id = NULL, rule_id = NULL, category_source = 'none' WHERE id = ?1")?;
        for row in rows {
            match set.categorise(&row.input()) {
                Some((rule_id, cat_id)) => {
                    if row.category_id != Some(cat_id) || row.rule_id != Some(rule_id) {
                        upd_rule.execute(params![cat_id, rule_id, row.id])?;
                        changed += 1;
                    }
                }
                None => {
                    if row.rule_id.is_some() {
                        upd_none.execute(params![row.id])?;
                        changed += 1;
                    }
                }
            }
        }
        Ok(changed)
    }
}

#[uniffi::export]
impl Vault {
    pub fn list_rules(&self) -> Result<Vec<Rule>, CoreError> {
        let db = self.db()?;
        Self::load_rules(&db)
    }

    /// Creates (id == 0) or updates a rule. Validates the pattern first.
    pub fn save_rule(&self, rule: Rule) -> Result<i64, CoreError> {
        if rule.pattern.len() > crate::rules::MAX_PATTERN_LEN {
            return Err(CoreError::InvalidInput {
                message: tr("Das Suchmuster ist zu lang.").into(),
            });
        }
        crate::rules::CompiledRule::compile(rule.clone())?;
        if rule.pattern.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: tr("Das Suchmuster ist leer.").into(),
            });
        }
        let db = self.db()?;
        let kind = match rule.match_kind {
            MatchKind::Keyword => "keyword",
            MatchKind::Regex => "regex",
            MatchKind::Expression => {
                let expr = crate::search_expr::SearchExpr::parse(&rule.pattern)
                    .map_err(|message| CoreError::InvalidInput { message })?;
                if let Some(f) = expr.unsupported_fields().first() {
                    return Err(CoreError::InvalidInput {
                        message: trf("Das Feld „{0}“ wird nicht unterstützt.", &[f]),
                    });
                }
                "expression"
            }
        };
        if rule.id == 0 {
            db.execute(
                "INSERT INTO rules(name, category_id, field, match_kind, pattern, case_sensitive, min_amount_cents, max_amount_cents, account_id, priority, enabled, updated_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                params![rule.name, rule.category_id, rule.field.as_str(), kind, rule.pattern, rule.case_sensitive as i64,
                        rule.min_amount_cents, rule.max_amount_cents, rule.account_ids.iter().min(), rule.priority, rule.enabled as i64,
                        crate::user_groups::now_ms()],
            )?;
            let id = db.last_insert_rowid();
            crate::rules::store_rule_accounts(&db, id, &rule.account_ids)?;
            crate::sync_merge::fill_missing_uuids(&db)?;
            Ok(id)
        } else {
            db.execute(
                "UPDATE rules SET name=?1, category_id=?2, field=?3, match_kind=?4, pattern=?5, case_sensitive=?6, min_amount_cents=?7,
                        max_amount_cents=?8, account_id=?9, priority=?10, enabled=?11, updated_ms=?13 WHERE id=?12",
                params![rule.name, rule.category_id, rule.field.as_str(), kind, rule.pattern, rule.case_sensitive as i64,
                        rule.min_amount_cents, rule.max_amount_cents, rule.account_ids.iter().min(), rule.priority, rule.enabled as i64, rule.id,
                        crate::user_groups::now_ms()],
            )?;
            crate::rules::store_rule_accounts(&db, rule.id, &rule.account_ids)?;
            Ok(rule.id)
        }
    }

    pub fn delete_rule(&self, rule_id: i64) -> Result<(), CoreError> {
        let db = self.db()?;
        let tx = db.unchecked_transaction()?;
        tx.execute("UPDATE transactions SET category_id = NULL, category_source = 'none', rule_id = NULL WHERE rule_id = ?1", [rule_id])?;
        tx.execute(
            "UPDATE rules SET deleted_ms = ?2 WHERE id = ?1 AND deleted_ms IS NULL",
            params![rule_id, crate::user_groups::now_ms()],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Newest transactions (at most `limit`) the (unsaved) rule would match, for
    /// the live preview in the rule editor. Matches on the raw rows and stops at
    /// `limit`; only the hits are enriched.
    pub fn preview_rule(&self, rule: Rule, limit: u32) -> Result<Vec<Booking>, CoreError> {
        let compiled = crate::rules::CompiledRule::compile(Rule {
            enabled: true,
            ..rule
        })?;
        let db = self.db()?;
        let mut stmt = db.prepare(&format!(
            "SELECT {} FROM transactions t JOIN accounts a ON a.id = t.account_id
             WHERE {LIVE_BOOKINGS_SQL} ORDER BY t.booking_date DESC, t.id DESC",
            RuleRow::COLUMNS
        ))?;
        let n = limit.max(1) as usize;
        let mut ids = Vec::new();
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            if compiled.matches(&RuleRow::borrowed_input(row)?) {
                ids.push(row.get(0)?);
                if ids.len() == n {
                    break;
                }
            }
        }
        self.bookings_by_ids(&db, &ids)
    }

    /// Runs all rules. `only_uncategorized = false` also re-evaluates
    /// transactions previously categorised by a rule (never manual ones).
    pub fn apply_rules(&self, only_uncategorized: bool) -> Result<u32, CoreError> {
        let db = self.db()?;
        let tx = db.unchecked_transaction()?;
        let n = Self::apply_rules_inner(&tx, only_uncategorized)?;
        tx.commit()?;
        Ok(n)
    }
}

#[cfg(test)]
mod expression_rule_tests {
    use super::*;

    #[test]
    fn expression_rules_round_trip_and_apply() {
        let p_dir = crate::test_support::TempDir::new("girocrab-expr");
        let p = p_dir.join("v.db");
        let v = Vault::open(p.to_string_lossy().to_string(), vec![5u8; 32]).unwrap();
        let cat = {
            let c = v.db().unwrap();
            c.execute(
                "INSERT OR IGNORE INTO account_groups(name) VALUES ('G')",
                [],
            )
            .unwrap();
            c.execute(
                "INSERT INTO accounts(group_id, external_ref, name, iban) \
                 VALUES ((SELECT id FROM account_groups LIMIT 1), 'A1', 'Konto', 'DE02120300000000202051')",
                [],
            )
            .unwrap();
            c.execute("INSERT INTO categories(name) VALUES ('Lebensmittel')", [])
                .unwrap();
            for (ext, cp, amount) in [
                ("T1", "REWE Markt", -2350),
                ("T2", "REWE Markt", 500),
                ("T3", "Lidl", -100),
            ] {
                c.execute(
                    "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, counterparty) \
                     VALUES ((SELECT id FROM accounts LIMIT 1), ?1, '2026-01-02', ?2, ?3)",
                    params![ext, amount, cp],
                )
                .unwrap();
            }
            c.query_row(
                "SELECT id FROM categories WHERE name = 'Lebensmittel'",
                [],
                |r| r.get::<_, i64>(0),
            )
            .unwrap()
        };
        let rule = Rule {
            id: 0,
            name: "REWE".into(),
            category_id: cat,
            field: RuleField::Any,
            match_kind: MatchKind::Expression,
            pattern: "name:REWE AND amount<0 AND local_account:DE02*".into(),
            case_sensitive: false,
            min_amount_cents: None,
            max_amount_cents: None,
            account_ids: Vec::new(),
            priority: 0,
            enabled: true,
            match_count: 0,
        };
        let id = v.save_rule(rule.clone()).unwrap();
        let listed = v.list_rules().unwrap();
        let saved = listed.iter().find(|r| r.id == id).unwrap();
        assert_eq!(saved.match_kind, MatchKind::Expression);
        assert_eq!(v.preview_rule(rule.clone(), 10).unwrap().len(), 1);
        v.apply_rules(true).unwrap();
        let hits: i64 = v
            .db()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM transactions WHERE rule_id = ?1",
                [id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(hits, 1, "only the REWE debit");
        let err = v.save_rule(Rule {
            pattern: "reference:X".into(),
            ..rule
        });
        assert!(err.is_err(), "unsupported field can't be saved");
        let _ = std::fs::remove_file(p);
    }
}

#[cfg(test)]
mod multi_account_rule_tests {
    use super::*;

    #[test]
    fn rule_restricted_to_several_accounts_round_trips_and_applies() {
        let dir = crate::test_support::TempDir::new("girocrab-multi-acc");
        let p = dir.join("v.db");
        let v = Vault::open(p.to_string_lossy().to_string(), vec![6u8; 32]).unwrap();
        let (accs, cat) = {
            let c = v.db().unwrap();
            c.execute(
                "INSERT OR IGNORE INTO account_groups(name) VALUES ('G')",
                [],
            )
            .unwrap();
            let mut accs = Vec::new();
            for r in ["A1", "A2", "A3"] {
                c.execute(
                    "INSERT INTO accounts(group_id, external_ref, name) \
                     VALUES ((SELECT id FROM account_groups LIMIT 1), ?1, ?1)",
                    [r],
                )
                .unwrap();
                let id = c.last_insert_rowid();
                c.execute(
                    "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, counterparty) \
                     VALUES (?1, 'T', '2026-01-02', -100, 'REWE')",
                    [id],
                )
                .unwrap();
                accs.push(id);
            }
            c.execute("INSERT INTO categories(name) VALUES ('Lebensmittel')", [])
                .unwrap();
            (accs, c.last_insert_rowid())
        };
        let rule = Rule {
            id: 0,
            name: "REWE".into(),
            category_id: cat,
            field: RuleField::Any,
            match_kind: MatchKind::Keyword,
            pattern: "REWE".into(),
            case_sensitive: false,
            min_amount_cents: None,
            max_amount_cents: None,
            account_ids: vec![accs[1], accs[0]],
            priority: 0,
            enabled: true,
            match_count: 0,
        };
        let id = v.save_rule(rule).unwrap();
        let saved = v
            .list_rules()
            .unwrap()
            .into_iter()
            .find(|r| r.id == id)
            .unwrap();
        assert_eq!(saved.account_ids, vec![accs[0], accs[1]]);
        v.apply_rules(true).unwrap();
        let hit_accounts: Vec<i64> = {
            let c = v.db().unwrap();
            let mut st = c
                .prepare(
                    "SELECT account_id FROM transactions WHERE rule_id = ?1 ORDER BY account_id",
                )
                .unwrap();
            st.query_map([id], |r| r.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        };
        assert_eq!(
            hit_accounts,
            vec![accs[0], accs[1]],
            "third account excluded"
        );
        // The column mirrors the lowest id (foreign key); the table is the truth.
        v.save_rule(Rule {
            id,
            account_ids: vec![accs[2], accs[1]],
            ..saved
        })
        .unwrap();
        let raw: i64 = v
            .db()
            .unwrap()
            .query_row("SELECT account_id FROM rules WHERE id = ?1", [id], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(raw, accs[1]);
        let listed = v.list_rules().unwrap();
        assert_eq!(listed[0].account_ids, vec![accs[1], accs[2]]);
        v.save_rule(Rule {
            account_ids: Vec::new(),
            ..listed[0].clone()
        })
        .unwrap();
        assert!(v.list_rules().unwrap()[0].account_ids.is_empty());
    }
}

#[cfg(test)]
mod preview_tests {
    use super::*;

    #[test]
    fn preview_lists_the_newest_matches_up_to_the_limit() {
        let p_dir = crate::test_support::TempDir::new("girocrab-preview");
        let p = p_dir.join("v.db");
        let v = Vault::open(p.to_string_lossy().to_string(), vec![5u8; 32]).unwrap();
        v.seed_demo_data().unwrap();
        let rule = Rule {
            id: 0,
            name: "Ausgaben".into(),
            category_id: 0,
            field: RuleField::Any,
            match_kind: MatchKind::Expression,
            pattern: "amount<0".into(),
            case_sensitive: false,
            min_amount_cents: None,
            max_amount_cents: None,
            account_ids: Vec::new(),
            priority: 0,
            enabled: false,
            match_count: 0,
        };
        // Read like the booking list, newest first.
        let expenses: Vec<String> = v
            .list_transactions(BookingFilter::default())
            .unwrap()
            .transactions
            .iter()
            .filter(|b| b.amount_cents < 0)
            .map(|b| format!("{b:?}"))
            .collect();
        assert!(expenses.len() > 5);
        let preview = |limit| -> Vec<String> {
            let found = v.preview_rule(rule.clone(), limit).unwrap();
            found.iter().map(|b| format!("{b:?}")).collect()
        };
        assert_eq!(preview(5), expenses[..5]);
        assert_eq!(preview(0), expenses[..1], "limit 0 still shows one");
        assert_eq!(preview(10_000), expenses);
    }
}

#[cfg(test)]
mod apply_rules_to_tests {
    use super::*;

    #[test]
    fn categorises_only_the_given_live_uncategorised_bookings() {
        let dir = crate::test_support::TempDir::new("girocrab-apply-to");
        let p = dir.join("v.db");
        let v = Vault::open(p.to_string_lossy().to_string(), vec![7u8; 32]).unwrap();
        let c = v.db().unwrap();
        c.execute_batch(
            "INSERT INTO account_groups(name) VALUES ('G');
             INSERT INTO accounts(group_id, external_ref, name) VALUES (1, 'A1', 'Konto');
             INSERT INTO accounts(group_id, external_ref, name, archived_unix) VALUES (1, 'A2', 'Archiv', 1);
             INSERT INTO categories(name) VALUES ('Lebensmittel');
             INSERT INTO rules(name, category_id, field, match_kind, pattern)
                 VALUES ('REWE', 1, 'any', 'keyword', 'REWE');
             INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, counterparty,
                                      category_source, deleted_ms)
             VALUES (1, 'hit', '2026-01-02', -100, 'REWE Markt', 'none', NULL),
                    (1, 'manual', '2026-01-02', -100, 'REWE Markt', 'manual', NULL),
                    (1, 'deleted', '2026-01-02', -100, 'REWE Markt', 'none', 1),
                    (2, 'archived', '2026-01-02', -100, 'REWE Markt', 'none', NULL),
                    (1, 'outside', '2026-01-02', -100, 'REWE Markt', 'none', NULL);",
        )
        .unwrap();
        // Every booking but 'outside' (rowids follow the insert order).
        let ids = HashSet::from([1, 2, 3, 4]);

        assert_eq!(Vault::apply_rules_to(&c, &HashSet::new()).unwrap(), 0);
        assert_eq!(Vault::apply_rules_to(&c, &ids).unwrap(), 1);
        let source = |ext: &str| -> String {
            c.query_row(
                "SELECT category_source FROM transactions WHERE external_id = ?1",
                [ext],
                |r| r.get(0),
            )
            .unwrap()
        };
        assert_eq!(source("hit"), "rule");
        assert_eq!(source("manual"), "manual");
        assert_eq!(source("deleted"), "none");
        assert_eq!(source("archived"), "none");
        assert_eq!(source("outside"), "none", "not in the set");
    }
}
