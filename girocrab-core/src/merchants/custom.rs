//! Händlererkennung in den Einstellungen (#1373): the master switch, bundled
//! merchants the user switched off and the user's own merchants.
//!
//! Two small tables that the vault merge joins, so every device names a booking the
//! same way (`settings` is not merged):
//! - `merchant_switches`: a row per bundled merchant the user switched off (or on
//!   again); the key "" is the master switch. The newest change wins.
//! - `custom_merchants`: own merchants by uuid. The newest edit wins, a deleted one
//!   stays deleted. Their bookings carry the merchant key `u:<uuid>`. A copy of a
//!   bundled merchant (`based_on`) replaces it while it lives; that is derived when
//!   loading, never written as a switch.
//!
//! [`MerchantRules`] applies them. The vault keeps its rules while the tables stay
//! the same ([`Vault::merchant_rules`]), so the merchant cache survives other writes
//! and starts afresh after a change, a merge or a restore.

use std::collections::{BTreeSet, HashSet};
use std::sync::{Arc, PoisonError};

use rusqlite::{Connection, OptionalExtension, params};

use super::{
    CustomEntry, CustomSpec, MerchantInfo, MerchantKind, MerchantRules, MerchantSettings,
    custom_key, entries, entry_by_key, normalise_words, to_info,
};
use crate::dates::now_ms;
use crate::error::{CoreError, CoreResult};
use crate::i18n::tr;
use crate::schema::has_table;
use crate::vault::Vault;

#[cfg(test)]
mod tests;

/// Step 35 (#1373).
pub(crate) const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS merchant_switches (
    merchant_key TEXT PRIMARY KEY,           -- bundled merchant key; '' = the whole recognition
    enabled      INTEGER NOT NULL,
    changed_ms   INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS custom_merchants (
    uuid       TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    needles    TEXT NOT NULL,                -- normalised search words, '|'-separated
    based_on   TEXT NOT NULL DEFAULT '',     -- bundled merchant it was copied from
    created_ms INTEGER NOT NULL,
    changed_ms INTEGER NOT NULL,
    deleted_ms INTEGER
);
";

/// Key of the master switch in `merchant_switches`.
const MASTER: &str = "";
const MAX_NAME: usize = 80;
const MAX_NEEDLE: usize = 60;

/// A bundled merchant in the settings list.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct BuiltinMerchant {
    pub key: String,
    pub name: String,
    /// Search words (lower case), matched at the start of a word.
    pub needles: Vec<String>,
    pub kind: MerchantKind,
    /// Not switched off by the user.
    pub enabled: bool,
    /// An own merchant copies it ("Bearbeiten"): while the copy lives, this one is not
    /// recognised, whatever `enabled` says.
    pub replaced: bool,
    /// How its bookings look (signet, colour, logo domain).
    pub merchant: MerchantInfo,
}

/// One of the user's own merchants.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct CustomMerchant {
    pub uuid: String,
    pub name: String,
    /// Search words as matched: lower case, legal forms and separators dropped.
    pub needles: Vec<String>,
    /// Key of the bundled merchant it was copied from (logo, colour, kind), "" for none.
    pub based_on: String,
    /// How its bookings look; `merchant.key` is the key they carry.
    pub merchant: MerchantInfo,
}

/// Einstellungen › Händler (#1373).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct MerchantRecognition {
    /// Master switch. Off, bookings show their counterparty (else the start of the
    /// purpose) without a merchant name or logo.
    pub enabled: bool,
    /// In match order: the first one that matches a booking names it.
    pub builtin: Vec<BuiltinMerchant>,
    /// Oldest first. They come before the bundled ones; among them the longest
    /// matching search word wins.
    pub custom: Vec<CustomMerchant>,
}

/// The stored changes of the vault on `conn`, as the resolver applies them.
pub(crate) fn load_settings(conn: &Connection) -> CoreResult<MerchantSettings> {
    let (enabled, mut disabled) = load_switches(conn)?;
    let custom = load_custom(conn)?;
    // A live copy replaces its original. Derived here, never stored as a switch: a copy
    // made on one device and deleted on another cannot leave the original switched off
    // (or on), and a switch the user set stays as it was.
    disabled.extend(
        custom
            .iter()
            .filter(|c| entry_by_key(&c.based_on).is_some())
            .map(|c| c.based_on.clone()),
    );
    Ok(MerchantSettings {
        enabled,
        disabled,
        custom,
    })
}

/// The master switch and the bundled merchants the user switched off. Only keys the
/// table has: a switch for a merchant a later table dropped changes nothing (and keeps
/// the vault on the shared bundled rules).
fn load_switches(conn: &Connection) -> CoreResult<(bool, BTreeSet<String>)> {
    let (mut enabled, mut disabled) = (true, BTreeSet::new());
    let mut stmt = conn.prepare("SELECT merchant_key, enabled FROM merchant_switches")?;
    let switches = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, bool>(1)?)))?;
    for row in switches {
        match row? {
            (key, on) if key == MASTER => enabled = on,
            (key, false) if entry_by_key(&key).is_some() => {
                disabled.insert(key);
            }
            _ => {}
        }
    }
    Ok((enabled, disabled))
}

/// The live own merchants, oldest first.
fn load_custom(conn: &Connection) -> CoreResult<Vec<CustomSpec>> {
    let mut stmt = conn.prepare(
        "SELECT uuid, name, needles, based_on FROM custom_merchants
          WHERE deleted_ms IS NULL ORDER BY created_ms, uuid",
    )?;
    let custom = stmt
        .query_map([], |r| {
            Ok(CustomSpec {
                uuid: r.get(0)?,
                name: r.get(1)?,
                needles: split_needles(&r.get::<_, String>(2)?),
                based_on: r.get(3)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    Ok(custom)
}

fn split_needles(stored: &str) -> Vec<String> {
    stored
        .split('|')
        .filter(|n| !n.is_empty())
        .map(str::to_string)
        .collect()
}

/// Trimmed name, inner runs of whitespace collapsed; checked for length.
fn clean_name(name: &str) -> CoreResult<String> {
    let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
    if name.is_empty() {
        return Err(CoreError::invalid(tr("Der Name des Händlers fehlt.")));
    }
    if name.chars().count() > MAX_NAME {
        return Err(CoreError::invalid(tr(
            "Der Name des Händlers ist länger als 80 Zeichen.",
        )));
    }
    Ok(name)
}

/// The search words as the resolver compares them: normalised like the booking texts
/// (`normalise_words`: lower case, `*`, `/`, `,` … as spaces, legal forms like "GmbH"
/// dropped, digit runs whole), without
/// duplicates and without words of fewer than two letters or digits (a lone "a" would
/// name half the bookings).
pub(crate) fn clean_needles(needles: &[String]) -> CoreResult<Vec<String>> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for needle in needles {
        let needle = normalise_words(needle).trim().to_string();
        if needle.chars().filter(|c| c.is_alphanumeric()).count() < 2 {
            continue;
        }
        if needle.chars().count() > MAX_NEEDLE {
            return Err(CoreError::invalid(tr(
                "Ein Suchwort ist länger als 60 Zeichen.",
            )));
        }
        if seen.insert(needle.clone()) {
            out.push(needle);
        }
    }
    if out.is_empty() {
        return Err(CoreError::invalid(tr(
            "Mindestens ein Suchwort mit zwei oder mehr Buchstaben oder Ziffern angeben.",
        )));
    }
    Ok(out)
}

fn custom_merchant(spec: CustomSpec) -> CustomMerchant {
    let merchant = CustomEntry {
        key: custom_key(&spec.uuid),
        name: spec.name.clone(),
        needles: spec.needles.clone(),
        base: entry_by_key(&spec.based_on),
    }
    .info();
    CustomMerchant {
        uuid: spec.uuid,
        name: spec.name,
        needles: spec.needles,
        based_on: spec.based_on,
        merchant,
    }
}

/// Stores a switch (`key` "" = master switch). Writes nothing when the state stays the
/// same, so the vault's caches are kept. The stamp moves past the stored one, so the
/// change also wins against a peer whose clock runs ahead.
fn write_switch(conn: &Connection, key: &str, enabled: bool) -> CoreResult<()> {
    let stored: Option<(bool, i64)> = conn
        .query_row(
            "SELECT enabled, changed_ms FROM merchant_switches WHERE merchant_key = ?1",
            [key],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    // a switch never touched is on
    if stored.is_none_or(|(on, _)| on) == enabled {
        return Ok(());
    }
    let stamp = stored.map_or(0, |(_, ms)| ms + 1).max(now_ms());
    conn.execute(
        "INSERT INTO merchant_switches(merchant_key, enabled, changed_ms) VALUES (?1, ?2, ?3)
         ON CONFLICT(merchant_key) DO UPDATE SET enabled = excluded.enabled,
                                                 changed_ms = excluded.changed_ms",
        params![key, enabled, stamp],
    )?;
    Ok(())
}

/// Vault merge (iCloud peer snapshot): switches by key, own merchants by uuid. The
/// newest change wins (a tie: switched off, then the larger values), a deleted
/// merchant stays deleted. Only the rows' own stamps count, never the clock, so
/// both merge orders end in the same state.
pub(crate) fn merge_attached(conn: &Connection) -> CoreResult<()> {
    if !has_table(conn, "other", "merchant_switches")?
        || !has_table(conn, "other", "custom_merchants")?
    {
        return Ok(());
    }
    conn.execute_batch(
        "INSERT INTO merchant_switches(merchant_key, enabled, changed_ms)
         SELECT merchant_key, enabled, changed_ms FROM other.merchant_switches WHERE true
         ON CONFLICT(merchant_key) DO UPDATE SET enabled = excluded.enabled,
                                                 changed_ms = excluded.changed_ms
         WHERE excluded.changed_ms > merchant_switches.changed_ms
            OR (excluded.changed_ms = merchant_switches.changed_ms
                AND excluded.enabled < merchant_switches.enabled);

         INSERT INTO custom_merchants(uuid, name, needles, based_on, created_ms, changed_ms, deleted_ms)
         SELECT uuid, name, needles, based_on, created_ms, changed_ms, deleted_ms
           FROM other.custom_merchants WHERE true
         ON CONFLICT(uuid) DO UPDATE SET name = excluded.name, needles = excluded.needles,
                                         based_on = excluded.based_on,
                                         changed_ms = excluded.changed_ms
         WHERE (excluded.changed_ms, excluded.name, excluded.needles, excluded.based_on)
             > (custom_merchants.changed_ms, custom_merchants.name, custom_merchants.needles,
                custom_merchants.based_on);

         UPDATE custom_merchants
            SET deleted_ms = (SELECT o.deleted_ms FROM other.custom_merchants o
                               WHERE o.uuid = custom_merchants.uuid)
          WHERE coalesce(deleted_ms, 0) < (SELECT coalesce(o.deleted_ms, 0)
                                             FROM other.custom_merchants o
                                            WHERE o.uuid = custom_merchants.uuid);",
    )?;
    Ok(())
}

impl Vault {
    /// The merchant rules of the vault's current tables: the kept ones (with their warm
    /// cache) while the tables are unchanged, else built anew. Reading the two small
    /// tables costs far less than the booking reload that asks for the rules.
    pub(crate) fn merchant_rules(&self, db: &Connection) -> CoreResult<Arc<MerchantRules>> {
        let settings = load_settings(db)?;
        let mut kept = self
            .merchant_rules
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if *kept.settings() != settings {
            *kept = MerchantRules::for_settings(settings);
        }
        Ok(kept.clone())
    }
}

#[uniffi::export]
impl Vault {
    /// Einstellungen › Händler (#1373): master switch, the bundled merchants in match
    /// order with their switches, and the own merchants.
    pub fn merchant_recognition(&self) -> Result<MerchantRecognition, CoreError> {
        let (enabled, disabled, custom) = {
            let db = self.db()?;
            let (enabled, disabled) = load_switches(&db)?;
            (enabled, disabled, load_custom(&db)?)
        };
        let builtin = entries()
            .iter()
            .map(|e| BuiltinMerchant {
                key: e.key.to_string(),
                name: e.name.to_string(),
                needles: e.needles.iter().map(|n| n.trim().to_string()).collect(),
                kind: e.kind,
                enabled: !disabled.contains(e.key),
                replaced: custom.iter().any(|c| c.based_on == e.key),
                merchant: to_info(e),
            })
            .collect();
        Ok(MerchantRecognition {
            enabled,
            builtin,
            custom: custom.into_iter().map(custom_merchant).collect(),
        })
    }

    /// The master switch alone (cheap: one row), for the views that depend on it
    /// (no logo domain to edit while the recognition is off).
    pub fn merchant_recognition_enabled(&self) -> Result<bool, CoreError> {
        let stored: Option<bool> = self
            .db()?
            .query_row(
                "SELECT enabled FROM merchant_switches WHERE merchant_key = ?1",
                [MASTER],
                |r| r.get(0),
            )
            .optional()?;
        Ok(stored.unwrap_or(true))
    }

    /// Master switch of the merchant recognition. Off, bookings show their counterparty
    /// (else the start of the purpose) without a merchant name or logo; their flow
    /// (consumption, investment …) stays as it is.
    pub fn set_merchant_recognition_enabled(&self, enabled: bool) -> Result<(), CoreError> {
        write_switch(&*self.db()?, MASTER, enabled)
    }

    /// Switches a bundled merchant (`BuiltinMerchant::key`) off or on again.
    pub fn set_builtin_merchant_enabled(
        &self,
        key: String,
        enabled: bool,
    ) -> Result<(), CoreError> {
        if key.is_empty() || entry_by_key(&key).is_none() {
            return Err(CoreError::invalid(tr(
                "Diesen Händler gibt es in der eingebauten Liste nicht.",
            )));
        }
        write_switch(&*self.db()?, &key, enabled)
    }

    /// Creates an own merchant (`uuid` None) or changes name and search words of one.
    /// `based_on` (creating only): the key of a bundled merchant the new one copies.
    /// The copy keeps its logo, colour and kind and replaces the original while it lives
    /// (`BuiltinMerchant::replaced`), so the bundled list itself stays as shipped. Own
    /// merchants come before the bundled ones.
    pub fn save_custom_merchant(
        &self,
        uuid: Option<String>,
        name: String,
        needles: Vec<String>,
        based_on: Option<String>,
    ) -> Result<CustomMerchant, CoreError> {
        let name = clean_name(&name)?;
        let needles = clean_needles(&needles)?;
        let joined = needles.join("|");
        let db = self.db()?;
        let tx = db.unchecked_transaction()?;
        let now = now_ms();
        let (uuid, based_on) = match uuid.filter(|u| !u.is_empty()) {
            Some(uuid) => {
                let stored: Option<(String, String, String, i64)> = tx
                    .query_row(
                        "SELECT name, needles, based_on, changed_ms FROM custom_merchants
                          WHERE uuid = ?1 AND deleted_ms IS NULL",
                        [&uuid],
                        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                    )
                    .optional()?;
                let Some((old_name, old_needles, based_on, changed)) = stored else {
                    return Err(CoreError::invalid(tr(
                        "Diesen eigenen Händler gibt es nicht mehr.",
                    )));
                };
                if old_name != name || old_needles != joined {
                    tx.execute(
                        "UPDATE custom_merchants SET name = ?2, needles = ?3, changed_ms = ?4
                          WHERE uuid = ?1",
                        params![uuid, name, joined, now.max(changed + 1)],
                    )?;
                }
                (uuid, based_on)
            }
            None => {
                let based_on = based_on.unwrap_or_default();
                if !based_on.is_empty() && entry_by_key(&based_on).is_none() {
                    return Err(CoreError::invalid(tr(
                        "Diesen Händler gibt es in der eingebauten Liste nicht.",
                    )));
                }
                let uuid = uuid::Uuid::new_v4().to_string();
                // strictly after every merchant made so far: two made within one
                // millisecond keep their order (the older wins a tie on the search word)
                let created: i64 = tx.query_row(
                    "SELECT max(?1, coalesce(max(created_ms) + 1, 0)) FROM custom_merchants",
                    [now],
                    |r| r.get(0),
                )?;
                tx.execute(
                    "INSERT INTO custom_merchants(uuid, name, needles, based_on, created_ms, changed_ms)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
                    params![uuid, name, joined, based_on, created],
                )?;
                (uuid, based_on)
            }
        };
        tx.commit()?;
        Ok(custom_merchant(CustomSpec {
            uuid,
            name,
            needles,
            based_on,
        }))
    }

    /// Deletes an own merchant (a tombstone, so the deletion reaches the other devices).
    /// A bundled merchant it copied is recognised again once no copy is left, unless the
    /// user switched it off.
    pub fn delete_custom_merchant(&self, uuid: String) -> Result<(), CoreError> {
        let db = self.db()?;
        let changed: Option<i64> = db
            .query_row(
                "SELECT changed_ms FROM custom_merchants WHERE uuid = ?1 AND deleted_ms IS NULL",
                [&uuid],
                |r| r.get(0),
            )
            .optional()?;
        let Some(changed) = changed else {
            return Ok(());
        };
        let now = now_ms();
        db.execute(
            "UPDATE custom_merchants SET deleted_ms = ?2, changed_ms = ?3 WHERE uuid = ?1",
            params![uuid, now, now.max(changed + 1)],
        )?;
        Ok(())
    }
}
