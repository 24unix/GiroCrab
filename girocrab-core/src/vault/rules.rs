//! Categorisation rules (pattern and expression rules): storage, preview and application.

use std::collections::{HashMap, HashSet};

use rusqlite::{params, Connection};

use super::Vault;
use crate::error::{CoreError, CoreResult};
use crate::i18n::{tr, trf};
use crate::models::*;
use crate::rules::{RuleInput, RuleSet};

impl Vault {
    pub(crate) fn rule_set(conn: &Connection) -> CoreResult<RuleSet> {
        // Disabled rules never match; skipping them also keeps a switched-off
        // rule with an invalid pattern (e.g. imported) from breaking the set.
        let mut rules = Self::load_rules(conn)?;
        rules.retain(|r| r.enabled);
        RuleSet::new(rules)
    }

    fn load_rules(conn: &Connection) -> CoreResult<Vec<Rule>> {
        let mut stmt = conn.prepare(
            "SELECT r.id, r.name, r.category_id, r.field, r.match_kind, r.pattern, r.case_sensitive,
                    r.min_amount_cents, r.max_amount_cents, r.account_id, r.priority, r.enabled,
                    (SELECT count(*) FROM transactions t WHERE t.rule_id = r.id AND t.deleted_ms IS NULL)
             FROM rules r WHERE r.deleted_ms IS NULL
               AND (r.account_id IS NULL OR EXISTS (SELECT 1 FROM accounts a WHERE a.id = r.account_id AND a.deleted_ms IS NULL))
             ORDER BY r.priority, r.id",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(Rule {
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
                account_id: r.get(9)?,
                priority: r.get(10)?,
                enabled: r.get::<_, i64>(11)? != 0,
                match_count: r.get::<_, i64>(12)? as u32,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
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
        let sql = if only_uncategorised {
            "SELECT t.id, t.account_id, t.amount_cents, t.counterparty, t.counterparty_iban, t.purpose, t.booking_text, t.category_id, t.rule_id,
                    t.note, t.currency, IFNULL(a.iban, '')
             FROM transactions t LEFT JOIN accounts a ON a.id = t.account_id WHERE a.archived_unix IS NULL AND a.deleted_ms IS NULL AND t.deleted_ms IS NULL AND t.category_source = 'none'"
        } else {
            "SELECT t.id, t.account_id, t.amount_cents, t.counterparty, t.counterparty_iban, t.purpose, t.booking_text, t.category_id, t.rule_id,
                    t.note, t.currency, IFNULL(a.iban, '')
             FROM transactions t LEFT JOIN accounts a ON a.id = t.account_id WHERE a.archived_unix IS NULL AND a.deleted_ms IS NULL AND t.deleted_ms IS NULL AND t.category_source != 'manual'"
        };
        let mut stmt = conn.prepare(sql)?;
        // (note, currency, own account IBAN) ride along for search expressions
        #[allow(clippy::type_complexity)]
        let rows: Vec<(
            (
                i64,
                i64,
                i64,
                String,
                String,
                String,
                String,
                Option<i64>,
                Option<i64>,
            ),
            (String, String, String),
        )> = stmt
            .query_map([], |r| {
                Ok((
                    (
                        r.get(0)?,
                        r.get(1)?,
                        r.get(2)?,
                        r.get(3)?,
                        r.get(4)?,
                        r.get(5)?,
                        r.get(6)?,
                        r.get(7)?,
                        r.get(8)?,
                    ),
                    (r.get(9)?, r.get(10)?, r.get(11)?),
                ))
            })?
            .collect::<Result<_, _>>()?;
        let rows = rows
            .into_iter()
            .filter(|r| only.is_none_or(|ids| ids.contains(&r.0 .0)));
        let mut changed = 0u32;
        let mut upd_rule = conn.prepare("UPDATE transactions SET category_id = ?1, rule_id = ?2, category_source = 'rule' WHERE id = ?3")?;
        let mut upd_none = conn.prepare("UPDATE transactions SET category_id = NULL, rule_id = NULL, category_source = 'none' WHERE id = ?1")?;
        for (
            (id, account_id, amount, cp, iban, purpose, bt, cat, rule),
            (note, currency, own_iban),
        ) in rows
        {
            let input = RuleInput {
                account_id,
                amount_cents: amount,
                counterparty: &cp,
                counterparty_iban: &iban,
                purpose: &purpose,
                booking_text: &bt,
                note: &note,
                currency: &currency,
                account_iban: &own_iban,
            };
            match set.categorise(&input) {
                Some((rule_id, cat_id)) => {
                    if cat != Some(cat_id) || rule != Some(rule_id) {
                        upd_rule.execute(params![cat_id, rule_id, id])?;
                        changed += 1;
                    }
                }
                None => {
                    if rule.is_some() {
                        upd_none.execute(params![id])?;
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
                        rule.min_amount_cents, rule.max_amount_cents, rule.account_id, rule.priority, rule.enabled as i64,
                        crate::user_groups::now_ms()],
            )?;
            let id = db.last_insert_rowid();
            crate::sync_merge::fill_missing_uuids(&db)?;
            Ok(id)
        } else {
            db.execute(
                "UPDATE rules SET name=?1, category_id=?2, field=?3, match_kind=?4, pattern=?5, case_sensitive=?6, min_amount_cents=?7,
                        max_amount_cents=?8, account_id=?9, priority=?10, enabled=?11, updated_ms=?13 WHERE id=?12",
                params![rule.name, rule.category_id, rule.field.as_str(), kind, rule.pattern, rule.case_sensitive as i64,
                        rule.min_amount_cents, rule.max_amount_cents, rule.account_id, rule.priority, rule.enabled as i64, rule.id,
                        crate::user_groups::now_ms()],
            )?;
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

    /// Transactions the (unsaved) rule would match, for the live preview in the
    /// rule editor.
    pub fn preview_rule(&self, rule: Rule, limit: u32) -> Result<Vec<Booking>, CoreError> {
        let compiled = crate::rules::CompiledRule::compile(Rule {
            enabled: true,
            ..rule
        })?;
        let page = self.list_transactions(BookingFilter {
            limit: 20000,
            ..Default::default()
        })?;
        let ibans: HashMap<i64, String> = {
            let db = self.db()?;
            let mut st = db.prepare("SELECT id, iban FROM accounts WHERE deleted_ms IS NULL")?;
            let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect::<Result<_, _>>()?
        };
        Ok(page
            .transactions
            .into_iter()
            .filter(|t| {
                compiled.matches(&RuleInput {
                    account_id: t.account_id,
                    amount_cents: t.amount_cents,
                    counterparty: &t.counterparty,
                    counterparty_iban: &t.counterparty_iban,
                    purpose: &t.purpose,
                    booking_text: &t.booking_text,
                    note: &t.note,
                    currency: &t.currency,
                    account_iban: ibans.get(&t.account_id).map_or("", String::as_str),
                })
            })
            .take(limit.max(1) as usize)
            .collect())
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
            account_id: None,
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
