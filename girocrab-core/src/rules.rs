//! Keyword / regex / search-expression auto-categorisation.
//!
//! Rules are evaluated in ascending `priority` (then id); the first enabled
//! rule that matches wins. Manually categorised transactions are never
//! touched by rules.

use regex::{Regex, RegexBuilder};

use crate::error::{CoreError, CoreResult};
use crate::models::{MatchKind, Rule, RuleField};
use crate::search_expr::{ExprInput, Prepared, SearchExpr};

/// The text fields of a transaction a rule can look at.
pub struct RuleInput<'a> {
    pub account_id: i64,
    pub amount_cents: i64,
    pub counterparty: &'a str,
    pub counterparty_iban: &'a str,
    pub purpose: &'a str,
    pub booking_text: &'a str,
    /// The user's note on the booking.
    pub note: &'a str,
    pub currency: &'a str,
    /// IBAN of the booking's own account.
    pub account_iban: &'a str,
}

enum Matcher {
    Regex(Regex),
    Expr(SearchExpr),
}

pub struct CompiledRule {
    pub rule: Rule,
    matcher: Matcher,
}

impl CompiledRule {
    pub fn compile(rule: Rule) -> CoreResult<Self> {
        if rule.match_kind == MatchKind::Expression {
            let expr = SearchExpr::parse(&rule.pattern)
                .map_err(|message| CoreError::InvalidInput { message })?;
            return Ok(CompiledRule {
                rule,
                matcher: Matcher::Expr(expr),
            });
        }
        let source = match rule.match_kind {
            MatchKind::Regex | MatchKind::Expression => rule.pattern.clone(),
            MatchKind::Keyword => {
                let words: Vec<String> = rule
                    .pattern
                    .split(['|', ','])
                    .map(|w| w.trim())
                    .filter(|w| !w.is_empty())
                    .map(regex::escape)
                    .collect();
                if words.is_empty() {
                    // never matches
                    "$^".to_string()
                } else {
                    format!("(?:{})", words.join("|"))
                }
            }
        };
        let matcher = RegexBuilder::new(&source)
            .case_insensitive(!rule.case_sensitive)
            .size_limit(1 << 20)
            .build()?;
        Ok(CompiledRule {
            rule,
            matcher: Matcher::Regex(matcher),
        })
    }

    pub fn matches(&self, t: &RuleInput) -> bool {
        self.matches_in(t, &Prepared::new(expr_input(t)))
    }

    /// [`matches`](Self::matches) with the booking already prepared for
    /// search expressions (shared by all rules of a [`RuleSet`]).
    fn matches_in(&self, t: &RuleInput, prepared: &Prepared) -> bool {
        let r = &self.rule;
        if !r.enabled {
            return false;
        }
        if let Some(acc) = r.account_id {
            if acc != t.account_id {
                return false;
            }
        }
        if let Some(min) = r.min_amount_cents {
            if t.amount_cents < min {
                return false;
            }
        }
        if let Some(max) = r.max_amount_cents {
            if t.amount_cents > max {
                return false;
            }
        }
        let matcher = match &self.matcher {
            Matcher::Expr(expr) => return expr.matches_prepared(prepared),
            Matcher::Regex(re) => re,
        };
        match r.field {
            RuleField::Any => {
                matcher.is_match(t.counterparty)
                    || matcher.is_match(t.purpose)
                    || matcher.is_match(t.booking_text)
            }
            RuleField::Counterparty => matcher.is_match(t.counterparty),
            RuleField::Purpose => matcher.is_match(t.purpose),
            RuleField::BookingText => matcher.is_match(t.booking_text),
            RuleField::CounterpartyIban => {
                let compact: String = t
                    .counterparty_iban
                    .chars()
                    .filter(|c| !c.is_whitespace())
                    .collect();
                matcher.is_match(&compact)
            }
        }
    }
}

fn expr_input<'a>(t: &RuleInput<'a>) -> ExprInput<'a> {
    ExprInput {
        amount_cents: t.amount_cents,
        name: t.counterparty,
        purpose: t.purpose,
        booking_text: t.booking_text,
        remote_account: t.counterparty_iban,
        local_account: t.account_iban,
        comment: t.note,
        currency: t.currency,
    }
}

pub struct RuleSet {
    rules: Vec<CompiledRule>,
}

impl RuleSet {
    pub fn new(mut rules: Vec<Rule>) -> CoreResult<Self> {
        rules.sort_by_key(|r| (r.priority, r.id));
        let compiled = rules
            .into_iter()
            .map(CompiledRule::compile)
            .collect::<CoreResult<Vec<_>>>()?;
        Ok(RuleSet { rules: compiled })
    }

    /// Returns (rule id, category id) of the first matching rule.
    pub fn categorise(&self, t: &RuleInput) -> Option<(i64, i64)> {
        let prepared = Prepared::new(expr_input(t));
        self.rules
            .iter()
            .find(|r| r.matches_in(t, &prepared))
            .map(|r| (r.rule.id, r.rule.category_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(pattern: &str, kind: MatchKind) -> Rule {
        Rule {
            id: 1,
            name: "t".into(),
            category_id: 7,
            field: RuleField::Any,
            match_kind: kind,
            pattern: pattern.into(),
            case_sensitive: false,
            min_amount_cents: None,
            max_amount_cents: Some(0),
            account_id: None,
            priority: 0,
            enabled: true,
            match_count: 0,
        }
    }

    fn input<'a>(cp: &'a str, amount: i64) -> RuleInput<'a> {
        RuleInput {
            account_id: 1,
            amount_cents: amount,
            counterparty: cp,
            counterparty_iban: "",
            purpose: "",
            booking_text: "",
            note: "",
            currency: "EUR",
            account_iban: "",
        }
    }

    #[test]
    fn keyword_rules() {
        let set = RuleSet::new(vec![rule("REWE|edeka", MatchKind::Keyword)]).unwrap();
        assert_eq!(
            set.categorise(&input("Edeka Center Kassel", -2350)),
            Some((1, 7))
        );
        assert_eq!(
            set.categorise(&input("REWE Markt", 500)),
            None,
            "max amount 0 excludes income"
        );
        assert_eq!(set.categorise(&input("Lidl", -100)), None);
    }

    #[test]
    fn regex_rules() {
        let set = RuleSet::new(vec![rule(
            r"^DB\s+(Fernverkehr|Vertrieb)",
            MatchKind::Regex,
        )])
        .unwrap();
        assert!(set.categorise(&input("DB Vertrieb GmbH", -4990)).is_some());
        assert!(set.categorise(&input("ADB Vertrieb", -4990)).is_none());
    }

    #[test]
    fn expression_rule_uses_note_and_amount_range() {
        let set = RuleSet::new(vec![rule("comment:Urlaub", MatchKind::Expression)]).unwrap();
        let mut t = input("", -500);
        t.note = "Urlaub Kroatien";
        assert_eq!(set.categorise(&t), Some((1, 7)));
        t.amount_cents = 500;
        assert_eq!(set.categorise(&t), None, "max amount 0 still applies");
        assert!(RuleSet::new(vec![rule("(REWE", MatchKind::Expression)]).is_err());
    }
}
