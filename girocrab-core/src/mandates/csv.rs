//! CSV import of mandates (club member lists). Like the batch transfer
//! import it never fails as a whole: every line becomes a row, faulty ones carry
//! their errors. Dates may be `YYYY-MM-DD` or `DD.MM.YYYY`.

use crate::batch_csv::{detect_delimiter, is_blank, split_records};
use crate::connectors::fints::sepa::{is_sepa_identifier, validate_bic};
use crate::dates::{iso, parse_de_or_iso};
use crate::i18n::{tr, trf};
use crate::iban::{normalize_iban, validate_iban};
use crate::money::parse_cents;
use crate::text::parse_bool_loose;

use super::{MandateInput, MandateScheme};

#[derive(Debug, Clone, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct MandateCsvRow {
    /// 1-based line in the file.
    pub line: u32,
    pub debtor_name: String,
    pub debtor_iban: String,
    pub debtor_bic: String,
    pub reference: String,
    /// `YYYY-MM-DD`, "" when missing or unreadable.
    pub signed_date: String,
    pub scheme: MandateScheme,
    pub one_off: bool,
    /// `false` only when the file says so (column "Aktiv").
    pub active: bool,
    pub default_amount_cents: i64,
    pub default_purpose: String,
    /// Empty = the row is fine.
    pub errors: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct MandateCsvImport {
    pub rows: Vec<MandateCsvRow>,
    /// Problems with the file as a whole.
    pub problems: Vec<String>,
}

impl MandateCsvRow {
    /// The mandate this row stands for, for the creditor account `account_id`.
    pub fn to_input(&self, account_id: i64) -> MandateInput {
        MandateInput {
            account_id,
            debtor_name: self.debtor_name.clone(),
            debtor_iban: self.debtor_iban.clone(),
            debtor_bic: self.debtor_bic.clone(),
            reference: self.reference.clone(),
            signed_date: self.signed_date.clone(),
            scheme: self.scheme,
            one_off: self.one_off,
            default_amount_cents: self.default_amount_cents,
            default_purpose: self.default_purpose.clone(),
            note: String::new(),
            active: self.active,
        }
    }
}

#[derive(Clone, Copy, Default)]
struct Columns {
    name: Option<usize>,
    iban: Option<usize>,
    bic: Option<usize>,
    reference: Option<usize>,
    date: Option<usize>,
    scheme: Option<usize>,
    one_off: Option<usize>,
    active: Option<usize>,
    amount: Option<usize>,
    purpose: Option<usize>,
}

fn columns(header: &[String]) -> Option<Columns> {
    let mut cols = Columns::default();
    let mut known = false;
    for (i, cell) in header.iter().enumerate() {
        let key = cell.trim().to_lowercase();
        let slot = match key.as_str() {
            "name" | "mitglied" | "zahlungspflichtiger" | "kontoinhaber" | "debtor" => {
                &mut cols.name
            }
            "iban" => &mut cols.iban,
            "bic" => &mut cols.bic,
            "mandatsreferenz" | "mandat" | "referenz" | "reference" | "mandate" => {
                &mut cols.reference
            }
            "datum" | "unterschrift" | "unterschriftsdatum" | "mandatsdatum" | "signed"
            | "date" => &mut cols.date,
            "art" | "schema" | "scheme" | "verfahren" => &mut cols.scheme,
            "einmalig" | "einmal" | "oneoff" | "one-off" => &mut cols.one_off,
            "aktiv" | "active" => &mut cols.active,
            "betrag" | "amount" | "beitrag" => &mut cols.amount,
            "zweck" | "verwendungszweck" | "purpose" => &mut cols.purpose,
            _ => continue,
        };
        if slot.is_none() {
            *slot = Some(i);
            known = true;
        }
    }
    known.then_some(cols)
}

/// Undoes the export's formula guard (see `field`).
fn unguard(s: String) -> String {
    match s.strip_prefix('\'') {
        Some(rest) if rest.starts_with(['=', '+', '-', '@', '\t', '\r']) => rest.to_string(),
        _ => s,
    }
}

fn to_row(line: u32, f: &[String], cols: Columns) -> MandateCsvRow {
    let get = |i: Option<usize>| {
        i.and_then(|i| f.get(i))
            .map(|s| s.trim().to_string())
            .unwrap_or_default()
    };
    let mut errors = Vec::new();
    let name = unguard(get(cols.name));
    if name.is_empty() {
        errors.push(tr("Der Name des Zahlungspflichtigen fehlt.").to_string());
    }
    let iban_raw = get(cols.iban);
    let valid_iban = validate_iban(&iban_raw);
    if !valid_iban {
        errors.push(tr("Die IBAN des Zahlungspflichtigen ist ungültig.").to_string());
    }
    let bic = get(cols.bic);
    if !bic.is_empty() && !validate_bic(&bic) {
        errors.push(tr("Die BIC ist ungültig.").to_string());
    }
    let reference = unguard(get(cols.reference));
    if reference.is_empty() || reference.chars().count() > 35 {
        errors.push(tr("Die Mandatsreferenz fehlt oder ist länger als 35 Zeichen.").to_string());
    }
    if !reference.is_empty() && !is_sepa_identifier(&reference) {
        errors.push(
            tr("Die Mandatsreferenz enthält Zeichen, die SEPA nicht erlaubt (nur Buchstaben ohne Umlaute, Ziffern und / - ? : ( ) . , ' + Leerzeichen).")
                .to_string(),
        );
    }
    let signed_date = match parse_de_or_iso(&get(cols.date)).map(iso) {
        Some(d) => d,
        None => {
            errors.push(tr("Das Datum der Mandatsunterschrift fehlt.").to_string());
            String::new()
        }
    };
    let scheme = match get(cols.scheme).to_uppercase().as_str() {
        "" | "CORE" | "BASIS" => MandateScheme::Core,
        "COR1" => MandateScheme::Cor1,
        "B2B" | "FIRMEN" => MandateScheme::B2b,
        other => {
            errors.push(trf("Unbekannte Lastschriftart „{0}“.", &[&other]));
            MandateScheme::Core
        }
    };
    let amount_text = get(cols.amount);
    let default_amount_cents = if amount_text.is_empty() {
        0
    } else {
        match parse_cents(&amount_text) {
            Ok(c) if c > 0 => c,
            _ => {
                errors.push(tr("Der Betrag ist ungültig oder fehlt.").to_string());
                0
            }
        }
    };
    MandateCsvRow {
        line,
        debtor_name: name,
        debtor_iban: if valid_iban {
            normalize_iban(&iban_raw)
        } else {
            iban_raw
        },
        debtor_bic: bic,
        reference,
        signed_date,
        scheme,
        one_off: parse_bool_loose(&get(cols.one_off)),
        active: cols.active.is_none() || parse_bool_loose(&get(cols.active)),
        default_amount_cents,
        default_purpose: unguard(get(cols.purpose)),
        errors,
    }
}

/// Parses `text` (UTF-8, optional BOM). Without a header line the order is
/// name, IBAN, reference, date.
pub fn parse_mandate_csv(text: String) -> MandateCsvImport {
    let text = text.trim_start_matches('\u{feff}');
    let delim = detect_delimiter(text);
    let mut records = split_records(text, delim)
        .into_iter()
        .filter(|(_, f)| !is_blank(f))
        .peekable();
    let mut problems = Vec::new();
    let cols = match records.peek().and_then(|(_, f)| columns(f)) {
        Some(c) => {
            records.next();
            c
        }
        None => Columns {
            name: Some(0),
            iban: Some(1),
            reference: Some(2),
            date: Some(3),
            ..Columns::default()
        },
    };
    if cols.name.is_none() || cols.iban.is_none() || cols.reference.is_none() || cols.date.is_none()
    {
        problems.push(
            tr("Es fehlen Spalten (nötig: Name, IBAN, Mandatsreferenz, Datum der Unterschrift).")
                .to_string(),
        );
    }
    let rows: Vec<_> = records.map(|(line, f)| to_row(line, &f, cols)).collect();
    if rows.is_empty() {
        problems.push(tr("Die Datei enthält keine Mandate.").to_string());
    }
    MandateCsvImport { rows, problems }
}

/// Outcome of saving imported rows.
#[derive(Debug, Clone, Default, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct MandateImportResult {
    pub created: u32,
    pub updated: u32,
    /// "line N: reason" for rows that could not be saved.
    pub failed: Vec<String>,
}

/// A cell that starts with `= + - @` (or tab/CR) is read as a formula by
/// spreadsheets: the export prefixes `'`, the import takes a `'` before such a
/// character off again.
fn field(s: &str) -> String {
    let guarded;
    let s = if s.starts_with(['=', '+', '-', '@', '\t', '\r']) {
        guarded = format!("'{s}");
        guarded.as_str()
    } else {
        s
    };
    if s.contains([';', '"', '\n', '\r']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

/// The mandates as CSV (`;`, UTF-8) in the layout the import reads back.
pub(super) fn mandates_to_csv(mandates: &[super::Mandate]) -> String {
    let mut out =
        String::from("Name;IBAN;BIC;Mandatsreferenz;Datum;Art;Betrag;Zweck;Einmalig;Aktiv\n");
    for m in mandates {
        let amount = if m.default_amount_cents > 0 {
            format!(
                "{},{:02}",
                m.default_amount_cents / 100,
                m.default_amount_cents % 100
            )
        } else {
            String::new()
        };
        let row = [
            field(&m.debtor_name),
            m.debtor_iban.clone(),
            m.debtor_bic.clone(),
            field(&m.reference),
            m.signed_date.clone(),
            m.scheme.debit().code().to_string(),
            amount,
            field(&m.default_purpose),
            if m.one_off { "ja" } else { "nein" }.to_string(),
            if m.active { "ja" } else { "nein" }.to_string(),
        ];
        out.push_str(&row.join(";"));
        out.push('\n');
    }
    out
}
