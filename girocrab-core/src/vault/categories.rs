//! The category tree: listing with period totals, create, edit, delete.

use std::collections::HashMap;

use rusqlite::{params, Connection, OptionalExtension};

use super::Vault;
use crate::error::{CoreError, CoreResult};
use crate::i18n::{display_name, display_path, tr};
use crate::models::*;

impl Vault {
    fn category_rows(
        conn: &Connection,
    ) -> CoreResult<Vec<(i64, Option<i64>, String, String, String, i32, Option<i64>)>> {
        let mut stmt = conn.prepare("SELECT id, parent_id, name, sf_symbol, color_hex, sort_order, budget_cents FROM categories WHERE deleted_ms IS NULL")?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                    r.get(6)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub(super) fn category_paths(
        conn: &Connection,
    ) -> CoreResult<HashMap<i64, (String, String, String, String)>> {
        // id -> (name, path, color, symbol)
        let rows = Self::category_rows(conn)?;
        let by_id: HashMap<i64, &(i64, Option<i64>, String, String, String, i32, Option<i64>)> =
            rows.iter().map(|r| (r.0, r)).collect();
        let mut out = HashMap::new();
        for r in &rows {
            let mut parts = vec![r.2.clone()];
            let mut cur = r.1;
            let mut guard = 0;
            while let Some(pid) = cur {
                guard += 1;
                if guard > 32 {
                    break;
                }
                if let Some(p) = by_id.get(&pid) {
                    parts.push(p.2.clone());
                    cur = p.1;
                } else {
                    break;
                }
            }
            parts.reverse();
            out.insert(
                r.0,
                (r.2.clone(), parts.join(" › "), r.4.clone(), r.3.clone()),
            );
        }
        Ok(out)
    }
}

#[uniffi::export]
impl Vault {
    /// All categories in tree order (depth-first, siblings by sort order) with
    /// totals for the optional period.
    pub fn list_categories(
        &self,
        date_from: Option<String>,
        date_to: Option<String>,
    ) -> Result<Vec<Category>, CoreError> {
        let db = self.db()?;
        let rows = Self::category_rows(&db)?;
        let mut totals: HashMap<Option<i64>, (i64, u32)> = HashMap::new();
        {
            let mut stmt = db.prepare(&format!(
                "SELECT category_id, SUM(amount_cents), COUNT(*) FROM {}
                 WHERE (?1 IS NULL OR booking_date >= ?1) AND (?2 IS NULL OR booking_date <= ?2)
                 GROUP BY category_id",
                crate::planning::EFFECTIVE_SQL
            ))?;
            let it = stmt.query_map(params![date_from, date_to], |r| {
                Ok((
                    r.get::<_, Option<i64>>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)? as u32,
                ))
            })?;
            for row in it {
                let (c, s, n) = row?;
                totals.insert(c, (s, n));
            }
        }
        let mut children: HashMap<
            Option<i64>,
            Vec<&(i64, Option<i64>, String, String, String, i32, Option<i64>)>,
        > = HashMap::new();
        for r in &rows {
            children.entry(r.1).or_default().push(r);
        }
        for list in children.values_mut() {
            list.sort_by(|a, b| {
                a.5.cmp(&b.5)
                    .then_with(|| a.2.to_lowercase().cmp(&b.2.to_lowercase()))
            });
        }
        fn subtotal(
            id: i64,
            children: &HashMap<
                Option<i64>,
                Vec<&(i64, Option<i64>, String, String, String, i32, Option<i64>)>,
            >,
            totals: &HashMap<Option<i64>, (i64, u32)>,
            depth: u32,
        ) -> (i64, u32) {
            let own = totals.get(&Some(id)).copied().unwrap_or((0, 0));
            if depth > 32 {
                return own;
            }
            let mut sum = own;
            if let Some(kids) = children.get(&Some(id)) {
                for k in kids {
                    let (s, n) = subtotal(k.0, children, totals, depth + 1);
                    sum.0 += s;
                    sum.1 += n;
                }
            }
            sum
        }
        let mut out = Vec::with_capacity(rows.len());
        fn walk(
            parent: Option<i64>,
            depth: u32,
            prefix: &str,
            children: &HashMap<
                Option<i64>,
                Vec<&(i64, Option<i64>, String, String, String, i32, Option<i64>)>,
            >,
            totals: &HashMap<Option<i64>, (i64, u32)>,
            out: &mut Vec<Category>,
        ) {
            if depth > 32 {
                return;
            }
            if let Some(kids) = children.get(&parent) {
                for k in kids {
                    let path = if prefix.is_empty() {
                        k.2.clone()
                    } else {
                        format!("{prefix} › {}", k.2)
                    };
                    let own = totals.get(&Some(k.0)).copied().unwrap_or((0, 0));
                    let (total, count) = subtotal(k.0, children, totals, 0);
                    out.push(Category {
                        id: k.0,
                        parent_id: k.1,
                        name: display_name(&k.2),
                        sf_symbol: k.3.clone(),
                        color_hex: k.4.clone(),
                        sort_order: k.5,
                        depth,
                        path: display_path(&path),
                        own_total_cents: own.0,
                        total_cents: total,
                        transaction_count: count,
                        budget_cents: k.6,
                    });
                    walk(Some(k.0), depth + 1, &path, children, totals, out);
                }
            }
        }
        walk(None, 0, "", &children, &totals, &mut out);
        Ok(out)
    }

    pub fn create_category(
        &self,
        name: String,
        parent_id: Option<i64>,
        sf_symbol: String,
        color_hex: String,
    ) -> Result<i64, CoreError> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err(CoreError::InvalidInput {
                message: tr("Der Kategoriename ist leer.").into(),
            });
        }
        let db = self.db()?;
        let order: i32 = db.query_row(
            "SELECT IFNULL(MAX(sort_order), 0) + 1 FROM categories WHERE parent_id IS ?1",
            [parent_id],
            |r| r.get(0),
        )?;
        db.execute(
            "INSERT INTO categories(parent_id, name, sf_symbol, color_hex, sort_order,
                    name_ms, parent_ms, symbol_ms, color_ms, order_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, ?6, ?6, ?6)",
            params![
                parent_id,
                name,
                if sf_symbol.is_empty() {
                    "tag".to_string()
                } else {
                    sf_symbol
                },
                color_hex,
                order,
                crate::user_groups::now_ms()
            ],
        )?;
        let id = db.last_insert_rowid();
        crate::sync_merge::fill_missing_uuids(&db)?;
        Ok(id)
    }

    pub fn update_category(
        &self,
        id: i64,
        name: String,
        parent_id: Option<i64>,
        sf_symbol: String,
        color_hex: String,
    ) -> Result<(), CoreError> {
        let db = self.db()?;
        // Refuse moving a category below itself.
        if let Some(mut p) = parent_id {
            let mut guard = 0;
            loop {
                if p == id {
                    return Err(CoreError::InvalidInput {
                        message: tr("Eine Kategorie kann nicht in sich selbst verschoben werden.")
                            .into(),
                    });
                }
                guard += 1;
                match db
                    .query_row("SELECT parent_id FROM categories WHERE id = ?1", [p], |r| {
                        r.get::<_, Option<i64>>(0)
                    })
                    .optional()?
                {
                    Some(Some(next)) if guard < 32 => p = next,
                    _ => break,
                }
            }
        }
        // The UI shows built-in names translated; saving that unchanged
        // display name keeps the stored German default (and its logic).
        let stored: Option<(String, Option<i64>, String, String)> = db
            .query_row(
                "SELECT name, parent_id, sf_symbol, color_hex FROM categories WHERE id = ?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()?;
        let name = match &stored {
            Some((stored, ..)) if *stored != name && display_name(stored) == name => stored.clone(),
            _ => name,
        };
        // only fields that really change get a stamp (newest edit wins per field)
        let now = crate::user_groups::now_ms();
        let (old_name, old_parent, old_symbol, old_color) = stored.unwrap_or_default();
        db.execute(
            "UPDATE categories SET name = ?1, parent_id = ?2, sf_symbol = ?3, color_hex = ?4,
                    name_ms = CASE WHEN ?6 THEN ?10 ELSE name_ms END,
                    parent_ms = CASE WHEN ?7 THEN ?10 ELSE parent_ms END,
                    symbol_ms = CASE WHEN ?8 THEN ?10 ELSE symbol_ms END,
                    color_ms = CASE WHEN ?9 THEN ?10 ELSE color_ms END
             WHERE id = ?5",
            params![
                name,
                parent_id,
                sf_symbol,
                color_hex,
                id,
                name != old_name,
                parent_id != old_parent,
                sf_symbol != old_symbol,
                color_hex != old_color,
                now
            ],
        )?;
        Ok(())
    }

    /// Deletes a category and its sub-categories (soft: the rows stay with a
    /// deletion stamp, so a sync does not bring them back); their rules go
    /// too and their transactions and splits become uncategorised. The
    /// uncategorising is derived, so it carries no `category_ms` stamp.
    pub fn delete_category(&self, id: i64) -> Result<(), CoreError> {
        let mut db = self.db()?;
        let tx = db.transaction()?;
        crate::sync_merge::soft_delete_categories(&tx, id)?;
        tx.commit()?;
        Ok(())
    }
}
