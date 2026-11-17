//! Tag totals (#228, part 3): bookings and sums per tag under the booking
//! list's filter, and a tag's bookings per account. SQL aggregates only; the
//! filters that need the enriched booking take one enriched pass, like
//! `count_transactions`.

use std::collections::HashMap;

use rusqlite::params_from_iter;

use crate::error::CoreError;
use crate::models::BookingFilter;
use crate::vault::bookings::needs_enrichment;
use crate::vault::Vault;

/// Bookings and their sum for one tag (or for the untagged bookings).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct TagTotal {
    /// `None` = bookings without any tag.
    pub tag_id: Option<i64>,
    pub booking_count: u32,
    /// Net sum (negative = outflow); with a category filter only the split
    /// parts of that category, like the list's sums.
    pub sum_cents: i64,
}

/// A tag's live bookings on one account.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct TagAccountCount {
    pub account_id: i64,
    pub booking_count: u32,
    /// A loan whose view also shows these bookings of other accounts (rates
    /// linked to it, #36); they are counted at their own account already.
    pub linked: bool,
}

const FROM_SQL: &str = "FROM transactions t JOIN accounts a ON a.id = t.account_id \
     LEFT JOIN categories cat ON cat.id = t.category_id AND cat.deleted_ms IS NULL";

const UNTAGGED_SQL: &str = "NOT EXISTS (SELECT 1 FROM transaction_tags x JOIN tags g \
     ON g.id = x.tag_id AND g.deleted_ms IS NULL WHERE x.transaction_id = t.id)";

#[uniffi::export]
impl Vault {
    /// Per tag: the bookings `filter` keeps and their net sum, with the
    /// filter's own tag choice (`tag_ids`, `untagged_only`) left out, so every
    /// tag shows what ticking it would add up to. One row with `tag_id = None`
    /// counts the untagged bookings. A booking with several tags counts for
    /// each of them; tags without matching bookings have no row. Rows are
    /// ordered by tag id, the untagged row last.
    pub fn tag_totals(&self, filter: BookingFilter) -> Result<Vec<TagTotal>, CoreError> {
        let filter = BookingFilter {
            tag_ids: Vec::new(),
            untagged_only: false,
            limit: 0,
            offset: 0,
            whole_days: false,
            ..filter
        };
        let db = self.db()?;
        if needs_enrichment(&filter) {
            return enriched_totals(&db, &filter);
        }
        let (cte, where_sql, args, share_sql) = Vault::filter_clauses(&db, &filter)?;
        let mut out: Vec<TagTotal> = Vec::new();
        let mut stmt = db.prepare(&format!(
            "{cte}SELECT x.tag_id, COUNT(*), IFNULL(SUM({share_sql}), 0) {FROM_SQL} \
             JOIN transaction_tags x ON x.transaction_id = t.id \
             JOIN tags g ON g.id = x.tag_id AND g.deleted_ms IS NULL \
             WHERE {where_sql} GROUP BY x.tag_id ORDER BY x.tag_id"
        ))?;
        let rows = stmt.query_map(params_from_iter(args.iter().map(|b| b.as_ref())), |r| {
            Ok(TagTotal {
                tag_id: Some(r.get(0)?),
                booking_count: r.get::<_, i64>(1)? as u32,
                sum_cents: r.get(2)?,
            })
        })?;
        for row in rows {
            out.push(row?);
        }
        let (count, sum): (i64, i64) = db.query_row(
            &format!(
                "{cte}SELECT COUNT(*), IFNULL(SUM({share_sql}), 0) {FROM_SQL} \
                 WHERE {where_sql} AND {UNTAGGED_SQL}"
            ),
            params_from_iter(args.iter().map(|b| b.as_ref())),
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        if count > 0 {
            out.push(TagTotal {
                tag_id: None,
                booking_count: count as u32,
                sum_cents: sum,
            });
        }
        Ok(out)
    }

    /// The live bookings of tag `tag_id` per account, most bookings first; these
    /// counts add up to the tag's `booking_count`. Then, marked `linked`, every
    /// loan whose view also shows tagged bookings of other accounts (its rates
    /// from the Girokonto): the same bookings once more, as the loan's booking
    /// list with this tag shows them.
    pub fn tag_account_counts(&self, tag_id: i64) -> Result<Vec<TagAccountCount>, CoreError> {
        let db = self.db()?;
        let mut stmt = db.prepare(
            "SELECT t.account_id, COUNT(*) FROM transaction_tags x \
             JOIN transactions t ON t.id = x.transaction_id \
             WHERE x.tag_id = ?1 AND t.deleted_ms IS NULL \
             GROUP BY t.account_id ORDER BY COUNT(*) DESC, t.account_id",
        )?;
        let rows = stmt.query_map([tag_id], |r| {
            Ok(TagAccountCount {
                account_id: r.get(0)?,
                booking_count: r.get::<_, i64>(1)? as u32,
                linked: false,
            })
        })?;
        let mut out: Vec<TagAccountCount> = rows.collect::<Result<_, _>>()?;
        // A loan's view takes the bookings of other accounts that reference or are
        // linked to it (`filter_clauses`); a handful of loans, one count each.
        let loans: Vec<i64> = db
            .prepare(
                "SELECT id FROM accounts WHERE kind = 'loan' AND deleted_ms IS NULL \
                 ORDER BY sort_order, id",
            )?
            .query_map([], |r| r.get(0))?
            .collect::<Result<_, _>>()?;
        for loan in loans {
            let filter = BookingFilter {
                account_ids: vec![loan],
                tag_ids: vec![tag_id],
                ..Default::default()
            };
            let (cte, where_sql, mut args, _) = Vault::filter_clauses(&db, &filter)?;
            args.push(Box::new(loan));
            let n: i64 = db.query_row(
                &format!(
                    "{cte}SELECT COUNT(*) {FROM_SQL} WHERE {where_sql} AND t.account_id != ?{}",
                    args.len()
                ),
                params_from_iter(args.iter().map(|b| b.as_ref())),
                |r| r.get(0),
            )?;
            if n > 0 {
                out.push(TagAccountCount {
                    account_id: loan,
                    booking_count: n as u32,
                    linked: true,
                });
            }
        }
        Ok(out)
    }
}

/// `tag_totals` for filters that need the enriched booking (scope, merchant,
/// "Ohne Kategorie"): one enriched pass, then one pass over the tag links.
fn enriched_totals(
    db: &rusqlite::Connection,
    filter: &BookingFilter,
) -> Result<Vec<TagTotal>, CoreError> {
    let kept = Vault::kept_shares(db, filter)?;
    let mut links: HashMap<i64, Vec<i64>> = HashMap::new();
    let mut stmt = db.prepare(
        "SELECT x.transaction_id, x.tag_id FROM transaction_tags x \
         JOIN tags g ON g.id = x.tag_id AND g.deleted_ms IS NULL",
    )?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))? {
        let (booking, tag) = row?;
        links.entry(booking).or_default().push(tag);
    }
    let mut per_tag: HashMap<i64, (u32, i64)> = HashMap::new();
    let (mut untagged_count, mut untagged_sum) = (0u32, 0i64);
    for (id, share) in kept {
        match links.get(&id) {
            Some(tags) => {
                for tag in tags {
                    let e = per_tag.entry(*tag).or_default();
                    e.0 += 1;
                    e.1 += share;
                }
            }
            None => {
                untagged_count += 1;
                untagged_sum += share;
            }
        }
    }
    let mut out: Vec<TagTotal> = per_tag
        .into_iter()
        .map(|(tag, (count, sum))| TagTotal {
            tag_id: Some(tag),
            booking_count: count,
            sum_cents: sum,
        })
        .collect();
    out.sort_by_key(|t| t.tag_id);
    if untagged_count > 0 {
        out.push(TagTotal {
            tag_id: None,
            booking_count: untagged_count,
            sum_cents: untagged_sum,
        });
    }
    Ok(out)
}
