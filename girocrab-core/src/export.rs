//! Booking export generators (GitHub #372, #401): Excel CSV and ISO 20022
//! CAMT.053 account statements (`camt.053.001.02` and `.08`).
//!
//! Pure functions without vault access: the app loads bookings and end-of-day
//! balances, prepares rows (order, purpose line, balance column) and the core
//! writes the file. Tests validate the XML against the official XSDs in
//! `tests/fixtures/iso20022/` and read it back with the FinTS CAMT parser.

use crate::models::{Account, Booking};

// MARK: - CSV

/// One CSV line, already in output order.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct ExportCsvRow {
    pub date: String,
    pub account_name: String,
    pub counterparty: String,
    pub purpose: String,
    pub category: String,
    pub note: String,
    pub amount_cents: i64,
    pub currency: String,
    /// End-of-day balance, set on the last row of a day; `None` = empty cell.
    pub day_balance_cents: Option<i64>,
}

/// `# Konto;Saldo;Währung;Datum` line above the header.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct ExportCsvBalanceLine {
    pub name: String,
    pub balance_cents: i64,
    pub currency: String,
    pub date: String,
}

/// Optional CSV columns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct ExportCsvColumns {
    pub category: bool,
    pub note: bool,
    pub daily_balance: bool,
}

/// Excel CSV (UTF-8 BOM, semicolon, decimal comma, CRLF).
#[uniffi::export]
pub fn export_csv(
    rows: Vec<ExportCsvRow>,
    columns: ExportCsvColumns,
    balance_lines: Vec<ExportCsvBalanceLine>,
) -> String {
    let mut out = String::from("\u{FEFF}");
    for l in &balance_lines {
        out.push_str(&format!(
            "# {};{};{};{}\r\n",
            csv_field(&l.name, true),
            csv_amount(l.balance_cents),
            csv_field(&l.currency, false),
            csv_field(&l.date, false)
        ));
    }
    let mut header = vec!["Datum", "Konto", "Name", "Verwendungszweck"];
    if columns.category {
        header.push("Kategorie");
    }
    if columns.note {
        header.push("Notiz");
    }
    header.extend(["Betrag", "Währung"]);
    if columns.daily_balance {
        header.push("Tagessaldo");
    }
    out.push_str(&header.join(";"));
    out.push_str("\r\n");
    for r in &rows {
        let mut cols = vec![
            csv_field(&r.date, false),
            csv_field(&r.account_name, true),
            csv_field(&r.counterparty, true),
            csv_field(&r.purpose, true),
        ];
        if columns.category {
            cols.push(csv_field(&r.category, true));
        }
        if columns.note {
            cols.push(csv_field(&r.note, true));
        }
        cols.push(csv_amount(r.amount_cents));
        cols.push(csv_field(&r.currency, false));
        if columns.daily_balance {
            cols.push(r.day_balance_cents.map(csv_amount).unwrap_or_default());
        }
        out.push_str(&cols.join(";"));
        out.push_str("\r\n");
    }
    out
}

/// Quotes a CSV field (semicolon dialect). `text` fields get the formula guard:
/// a leading `=`, `+`, `-`, `@`, tab or CR makes Excel/Numbers evaluate the
/// cell (`-2+3`, `=HYPERLINK(…)`), so it is prefixed with `'`.
pub(crate) fn csv_field(v: &str, text: bool) -> String {
    let guarded = text && v.starts_with(['=', '+', '-', '@', '\t', '\r']);
    let mut s = v.replace(['\r', '\n'], " ");
    if guarded {
        s.insert(0, '\'');
    }
    if s.contains([';', '"']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s
    }
}

/// Formats cents as `-1234,56` (German decimal comma, no grouping).
pub(crate) fn csv_amount(cents: i64) -> String {
    let sign = if cents < 0 { "-" } else { "" };
    let a = cents.unsigned_abs();
    format!("{sign}{},{:02}", a / 100, a % 100)
}

// MARK: - CAMT.053

/// ISO 20022 message version of a CAMT.053 export.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum CamtVersion {
    /// `camt.053.001.02` – what older programs import.
    V02,
    /// `camt.053.001.08` – current standard.
    V08,
}

/// CAMT.053 account statement for one account.
///
/// `opening_cents` is the balance at the start of `opening_date` (end of the
/// day before). CLBD = OPBD + booked entries; pending entries (`PDNG`) are
/// listed but not part of CLBD, like on a bank statement. `created_at` is an
/// ISO date-time (`2025-03-31T12:00:00+02:00`) for `CreDtTm`.
#[uniffi::export]
pub fn camt053_statement(
    account: Account,
    bookings: Vec<Booking>,
    version: CamtVersion,
    opening_cents: i64,
    opening_date: String,
    created_at: String,
) -> String {
    let v08 = version == CamtVersion::V08;
    let ns = if v08 { "08" } else { "02" };
    let mut ordered: Vec<&Booking> = bookings.iter().collect();
    ordered.sort_by(|a, b| {
        a.booking_date
            .cmp(&b.booking_date)
            .then_with(|| a.id.cmp(&b.id))
    });
    let booked_entries: Vec<&&Booking> = ordered.iter().filter(|b| !b.is_pending).collect();
    let booked: i64 = booked_entries.iter().map(|b| b.amount_cents).sum();
    let closing = opening_cents + booked;
    let acct_ccy = account.currency.trim();
    let currency = if !acct_ccy.is_empty() {
        acct_ccy.to_string()
    } else {
        ordered
            .first()
            .map(|b| b.currency.clone())
            .filter(|c| !c.trim().is_empty())
            .unwrap_or_else(|| "EUR".to_string())
    };
    let from = booked_entries
        .first()
        .map(|b| b.booking_date.clone())
        .or_else(|| ordered.first().map(|b| b.booking_date.clone()))
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| opening_date.clone());
    let to = booked_entries
        .last()
        .map(|b| b.booking_date.clone())
        .or_else(|| ordered.last().map(|b| b.booking_date.clone()))
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| opening_date.clone());
    let stmt_id = truncate(&format!("GC-{}-{from}-{to}", account.id), 35);
    let ts_digits: String = created_at
        .chars()
        .filter(|c| c.is_ascii_digit())
        .take(14)
        .collect();
    let msg_id = if ts_digits.is_empty() {
        truncate(&format!("GC-MSG-{}-{from}-{to}", account.id), 35)
    } else {
        truncate(&format!("GC-MSG-{}-{to}-{ts_digits}", account.id), 35)
    };
    let iban = compact_iban(&account.iban);
    let own_bic = if is_iban(&iban) {
        crate::connectors::fints_directory::bic_for_iban(iban.clone()).unwrap_or_default()
    } else {
        String::new()
    };
    let bic_tag = if v08 { "BICFI" } else { "BIC" };

    let mut out = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    out += &format!("<Document xmlns=\"urn:iso:std:iso:20022:tech:xsd:camt.053.001.{ns}\">\n");
    out += "<BkToCstmrStmt>\n";
    out += &format!(
        "<GrpHdr><MsgId>{}</MsgId><CreDtTm>{}</CreDtTm><MsgPgntn><PgNb>1</PgNb><LastPgInd>true</LastPgInd></MsgPgntn></GrpHdr>\n",
        esc(&msg_id),
        esc(&created_at)
    );
    out += "<Stmt>\n";
    out += &format!(
        "<Id>{}</Id><ElctrncSeqNb>1</ElctrncSeqNb><CreDtTm>{}</CreDtTm>",
        esc(&stmt_id),
        esc(&created_at)
    );
    if from.len() == 10 && to.len() == 10 {
        out += &format!(
            "<FrToDt><FrDtTm>{}T00:00:00</FrDtTm><ToDtTm>{}T23:59:59</ToDtTm></FrToDt>",
            esc(&from),
            esc(&to)
        );
    }
    out += "\n";
    let fallback = format!("GC-{}", account.id);
    out += &format!(
        "<Acct><Id>{}</Id><Ccy>{}</Ccy>",
        account_id_xml(&iban, &account.account_number, &fallback),
        esc(&currency)
    );
    let acct_name = account.name.trim();
    if !acct_name.is_empty() {
        out += &format!("<Nm>{}</Nm>", esc(&truncate(acct_name, 70)));
    }
    let owner = account.owner.trim();
    if !owner.is_empty() {
        out += &format!("<Ownr><Nm>{}</Nm></Ownr>", esc(&truncate(owner, 140)));
    }
    if !own_bic.is_empty() {
        out += &format!(
            "<Svcr><FinInstnId><{bic_tag}>{}</{bic_tag}></FinInstnId></Svcr>",
            esc(&own_bic)
        );
    }
    out += "</Acct>\n";
    let open_date = if opening_date.is_empty() {
        &from
    } else {
        &opening_date
    };
    out += &balance_xml("OPBD", opening_cents, &currency, open_date);
    out += &balance_xml("CLBD", closing, &currency, &to);
    for b in ordered {
        out += &entry_xml(b, v08, &currency);
    }
    out += "</Stmt>\n</BkToCstmrStmt>\n</Document>\n";
    out
}

fn balance_xml(code: &str, cents: i64, currency: &str, date: &str) -> String {
    let ind = if cents < 0 { "DBIT" } else { "CRDT" };
    format!(
        "<Bal><Tp><CdOrPrtry><Cd>{code}</Cd></CdOrPrtry></Tp><Amt Ccy=\"{}\">{}</Amt><CdtDbtInd>{ind}</CdtDbtInd><Dt><Dt>{}</Dt></Dt></Bal>\n",
        esc(currency),
        xml_amount(cents),
        esc(date)
    )
}

fn bk_tx_code(
    gvc: &str,
    debit: bool,
    purpose_code: &str,
) -> (&'static str, &'static str, &'static str) {
    if purpose_code.eq_ignore_ascii_case("SALA") {
        return ("NTRF", if debit { "IRCT" } else { "ICDT" }, "SALA");
    }
    match gvc {
        "004" | "005" | "104" | "105" | "171" | "835" => ("NDDT", "IDDT", "ESDD"),
        "009" | "109" => ("NDDT", "IDDT", "UPDD"),
        "006" | "106" | "108" => ("NCAR", "CCRD", "POSD"),
        "083" | "183" => ("NCAR", "CCRD", "CWDL"),
        "008" | "152" => ("NSTO", if debit { "IRCT" } else { "ICDT" }, "STDO"),
        "805" | "806" | "809" => ("NCHG", "MDOP", "CHRG"),
        "808" | "814" => ("NINT", "MDOP", "INTR"),
        "201" | "202" | "205" | "226" => ("NSEC", "TRAD", "SECU"),
        "020" | "051" | "052" | "053" | "116" | "119" | "151" | "153" | "159" | "166" | "169" => {
            ("NTRF", if debit { "IRCT" } else { "ICDT" }, "ESCT")
        }
        _ if gvc.len() == 3 && gvc.bytes().all(|c| c.is_ascii_digit()) => {
            ("NTRF", if debit { "IRCT" } else { "ICDT" }, "OTHR")
        }
        _ => ("NMSC", if debit { "IRCT" } else { "ICDT" }, "OTHR"),
    }
}

fn raw_remittance_purpose<'a>(purpose: &'a str, e2e: &str, mndt: &str) -> &'a str {
    let mut rest = purpose.trim();
    if !e2e.is_empty() {
        let prefix = format!("EREF+{e2e}");
        if let Some(after) = rest.strip_prefix(&prefix) {
            rest = after.trim_start();
        }
    }
    if !mndt.is_empty() {
        let prefix = format!("MREF+{mndt}");
        if let Some(after) = rest.strip_prefix(&prefix) {
            rest = after.trim_start();
        }
    }
    if let Some(after) = rest.strip_prefix("SVWZ+") {
        return after.trim();
    }
    purpose
}

fn detect_return_reason(b: &Booking) -> Option<&'static str> {
    const CODES: &[&str] = &[
        "AC01", "AC04", "AC06", "AG01", "AG02", "AM04", "AM05", "BE05", "CNOR", "DNOR", "FF01",
        "FOCR", "MD01", "MD02", "MD06", "MD07", "MS02", "MS03", "NARR", "RC01", "RR01", "RR02",
        "RR03", "RR04", "SL01", "TM01",
    ];
    let gvc = b.gvc.trim();
    let is_return_context = matches!(gvc, "009" | "109" | "159")
        || b.booking_text.to_lowercase().contains("rücklastschrift")
        || b.booking_text.to_lowercase().contains("ruecklastschrift")
        || b.purpose.contains("RTRN+")
        || b.purpose.contains("RTCD+");
    for token in b
        .purpose
        .split(|c: char| !c.is_ascii_alphanumeric())
        .chain(b.booking_text.split(|c: char| !c.is_ascii_alphanumeric()))
    {
        if token.len() == 4 {
            let upper = token.to_ascii_uppercase();
            if let Some(&found) = CODES.iter().find(|&&c| c == upper) {
                if is_return_context || matches!(found, "AC04" | "MD01" | "MD06" | "MS03" | "AM04")
                {
                    return Some(found);
                }
            }
        }
    }
    if matches!(gvc, "009" | "109") {
        return Some("NARR");
    }
    None
}

fn entry_xml(b: &Booking, v08: bool, default_ccy: &str) -> String {
    let debit = b.amount_cents < 0;
    let ind = if debit { "DBIT" } else { "CRDT" };
    let status = if b.is_pending { "PDNG" } else { "BOOK" };
    let value = if b.value_date.is_empty() {
        &b.booking_date
    } else {
        &b.value_date
    };
    let name = if !b.counterparty.trim().is_empty() {
        &b.counterparty
    } else {
        &b.merchant.name
    };
    let e2e = b.end_to_end_id.trim();
    let mndt = b.mandate_id.trim();
    let cred_id = b.creditor_id.trim();
    let acct_svcr_ref = b
        .external_id
        .strip_prefix("camt:")
        .map(str::trim)
        .filter(|s| !s.is_empty() && *s != "NONREF");
    let raw_purpose = if !b.purpose.trim().is_empty() {
        raw_remittance_purpose(&b.purpose, e2e, mndt)
    } else {
        &b.clean_purpose
    };
    let peer_iban = compact_iban(&b.counterparty_iban);
    let peer_bic = if is_iban(&peer_iban) {
        crate::connectors::fints_directory::bic_for_iban(peer_iban.clone())
    } else {
        None
    };
    let bic_tag = if v08 { "BICFI" } else { "BIC" };
    let entry_ccy = if b.currency.trim().is_empty() {
        default_ccy
    } else {
        b.currency.trim()
    };

    let mut e = String::from("<Ntry>");
    e += &format!(
        "<Amt Ccy=\"{}\">{}</Amt><CdtDbtInd>{ind}</CdtDbtInd>",
        esc(entry_ccy),
        xml_amount(b.amount_cents)
    );
    e += &if v08 {
        format!("<Sts><Cd>{status}</Cd></Sts>")
    } else {
        format!("<Sts>{status}</Sts>")
    };
    e += &format!(
        "<BookgDt><Dt>{}</Dt></BookgDt><ValDt><Dt>{}</Dt></ValDt>",
        esc(&b.booking_date),
        esc(value)
    );
    if let Some(svcr_ref) = acct_svcr_ref {
        e += &format!(
            "<AcctSvcrRef>{}</AcctSvcrRef>",
            esc(&truncate(svcr_ref, 35))
        );
    }
    let gvc = b.gvc.trim();
    let code = b.purpose_code.trim();
    let (swift_cd, fmly, sub_fmly) = bk_tx_code(gvc, debit, code);
    let domn_xml = format!(
        "<Domn><Cd>PMNT</Cd><Fmly><Cd>{fmly}</Cd><SubFmlyCd>{sub_fmly}</SubFmlyCd></Fmly></Domn>"
    );
    e += &if gvc.len() == 3 && gvc.bytes().all(|c| c.is_ascii_digit()) {
        format!("<BkTxCd>{domn_xml}<Prtry><Cd>{swift_cd}+{gvc}+000</Cd><Issr>DK</Issr></Prtry></BkTxCd>")
    } else if !gvc.is_empty() {
        format!(
            "<BkTxCd>{domn_xml}<Prtry><Cd>{}</Cd></Prtry></BkTxCd>",
            esc(&truncate(gvc, 35))
        )
    } else {
        format!("<BkTxCd>{domn_xml}<Prtry><Cd>{swift_cd}</Cd></Prtry></BkTxCd>")
    };
    e += "<NtryDtls><TxDtls>";
    if acct_svcr_ref.is_some() || !e2e.is_empty() || !mndt.is_empty() {
        e += "<Refs>";
        if let Some(svcr_ref) = acct_svcr_ref {
            e += &format!(
                "<AcctSvcrRef>{}</AcctSvcrRef>",
                esc(&truncate(svcr_ref, 35))
            );
        }
        if !e2e.is_empty() {
            e += &format!("<EndToEndId>{}</EndToEndId>", esc(&truncate(e2e, 35)));
        }
        if !mndt.is_empty() {
            e += &format!("<MndtId>{}</MndtId>", esc(&truncate(mndt, 35)));
        }
        e += "</Refs>";
    }
    if !name.trim().is_empty() || !peer_iban.is_empty() || !cred_id.is_empty() {
        let (party, acct, agent) = if debit {
            ("Cdtr", "CdtrAcct", "CdtrAgt")
        } else {
            ("Dbtr", "DbtrAcct", "DbtrAgt")
        };
        let cred_id_xml = if !cred_id.is_empty() {
            format!(
                "<Id><PrvtId><Othr><Id>{}</Id><SchmeNm><Prtry>SEPA</Prtry></SchmeNm></Othr></PrvtId></Id>",
                esc(&truncate(cred_id, 35))
            )
        } else {
            String::new()
        };
        e += "<RltdPties>";
        if !debit && !cred_id_xml.is_empty() {
            if !name.trim().is_empty() {
                let nm = esc(&truncate(name.trim(), 140));
                e += &if v08 {
                    format!("<Dbtr><Pty><Nm>{nm}</Nm></Pty></Dbtr>")
                } else {
                    format!("<Dbtr><Nm>{nm}</Nm></Dbtr>")
                };
            }
            if !peer_iban.is_empty() {
                e += &format!(
                    "<DbtrAcct><Id>{}</Id></DbtrAcct>",
                    account_id_xml(&peer_iban, &peer_iban, "")
                );
            }
            e += &if v08 {
                format!("<Cdtr><Pty>{cred_id_xml}</Pty></Cdtr>")
            } else {
                format!("<Cdtr>{cred_id_xml}</Cdtr>")
            };
        } else {
            let extra_id = if debit { cred_id_xml.as_str() } else { "" };
            if !name.trim().is_empty() || !extra_id.is_empty() {
                let nm_xml = if !name.trim().is_empty() {
                    format!("<Nm>{}</Nm>", esc(&truncate(name.trim(), 140)))
                } else {
                    String::new()
                };
                e += &if v08 {
                    format!("<{party}><Pty>{nm_xml}{extra_id}</Pty></{party}>")
                } else {
                    format!("<{party}>{nm_xml}{extra_id}</{party}>")
                };
            }
            if !peer_iban.is_empty() {
                e += &format!(
                    "<{acct}><Id>{}</Id></{acct}>",
                    account_id_xml(&peer_iban, &peer_iban, "")
                );
            }
        }
        e += "</RltdPties>";
        if let Some(bic) = peer_bic.filter(|b| !b.is_empty()) {
            e += &format!(
                "<RltdAgts><{agent}><FinInstnId><{bic_tag}>{}</{bic_tag}></FinInstnId></{agent}></RltdAgts>",
                esc(&bic)
            );
        }
    }
    if (1..=4).contains(&code.chars().count()) {
        e += &format!("<Purp><Cd>{}</Cd></Purp>", esc(code));
    }
    let lines = ustrd_lines(raw_purpose);
    if !lines.is_empty() {
        e += "<RmtInf>";
        for l in lines {
            e += &format!("<Ustrd>{}</Ustrd>", esc(&l));
        }
        e += "</RmtInf>";
    }
    if let Some(rsn) = detect_return_reason(b) {
        e += &format!("<RtrInf><Rsn><Cd>{rsn}</Cd></Rsn></RtrInf>");
    }
    let btext = b.booking_text.trim();
    if !btext.is_empty() {
        e += &format!("<AddtlTxInf>{}</AddtlTxInf>", esc(&truncate(btext, 500)));
    }
    e += "</TxDtls></NtryDtls>";
    if !btext.is_empty() {
        e += &format!(
            "<AddtlNtryInf>{}</AddtlNtryInf>",
            esc(&truncate(btext, 500))
        );
    }
    e += "</Ntry>\n";
    e
}

/// `<IBAN>` when `iban` is one, else `<Othr><Id>` (Max34Text): the schema's
/// IBAN pattern rejects account and card numbers.
fn account_id_xml(iban: &str, other: &str, fallback: &str) -> String {
    if is_iban(iban) {
        return format!("<IBAN>{}</IBAN>", esc(iban));
    }
    let other = other.trim();
    let id = if other.is_empty() { fallback } else { other };
    format!("<Othr><Id>{}</Id></Othr>", esc(&truncate(id, 34)))
}

fn compact_iban(s: &str) -> String {
    s.chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>()
        .to_uppercase()
}

/// ISO 20022 IBAN2007Identifier: `[A-Z]{2}[0-9]{2}[a-zA-Z0-9]{1,30}`.
pub fn is_iban(s: &str) -> bool {
    let b = s.as_bytes();
    (5..=34).contains(&b.len())
        && b[..2].iter().all(u8::is_ascii_uppercase)
        && b[2..4].iter().all(u8::is_ascii_digit)
        && b[4..].iter().all(u8::is_ascii_alphanumeric)
}

/// Remittance text as `Ustrd` lines of at most 140 characters (Max140Text).
fn ustrd_lines(text: &str) -> Vec<String> {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let chars: Vec<char> = flat.chars().collect();
    chars
        .chunks(140)
        .map(|c| c.iter().collect::<String>().trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

fn truncate(s: &str, max: usize) -> String {
    s.chars().take(max).collect()
}

fn xml_amount(cents: i64) -> String {
    let a = cents.unsigned_abs();
    format!("{}.{:02}", a / 100, a % 100)
}

/// Escapes XML text and attribute values and drops what XML 1.0 forbids
/// (control characters below U+0020 except tab, LF, CR; U+FFFE, U+FFFF).
pub fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            '\t' | '\n' | '\r' => out.push(c),
            c if (c as u32) < 0x20 || c == '\u{FFFE}' || c == '\u{FFFF}' => {}
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::BookingFilter;
    use crate::vault::Vault;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::sync::Arc;

    fn demo() -> (Arc<Vault>, PathBuf) {
        let p = std::env::temp_dir().join(format!("girocrab-export-{}.db", uuid::Uuid::new_v4()));
        let v = Vault::open(p.to_string_lossy().to_string(), vec![7u8; 32]).unwrap();
        v.seed_demo_data().unwrap();
        (v, p)
    }

    /// Demo bookings of one IBAN account plus edge cases: pending entry, control
    /// characters, a long purpose and name, a non-IBAN counterparty, GVC forms.
    fn fixture() -> (Account, Vec<Booking>) {
        let (v, p) = demo();
        let account = v
            .list_accounts()
            .unwrap()
            .into_iter()
            .find(|a| is_iban(&compact_iban(&a.iban)))
            .expect("demo account with IBAN");
        let filter = BookingFilter {
            account_ids: vec![account.id],
            ..BookingFilter::default()
        };
        let mut bookings: Vec<Booking> = v
            .list_transactions(filter)
            .unwrap()
            .transactions
            .into_iter()
            .take(6)
            .collect();
        drop(v);
        let _ = std::fs::remove_file(p);
        assert!(bookings.len() >= 4, "demo bookings");
        bookings[0].purpose = format!("Rechnung\u{1}Nr. 7 & <Sonder> \u{b}{}", "x".repeat(300));
        bookings[0].clean_purpose.clear();
        bookings[0].gvc.clear();
        bookings[0].purpose_code = "SALA".into();
        bookings[1].is_pending = true;
        bookings[1].counterparty_iban = "1234567890".into();
        bookings[2].counterparty = "N".repeat(200);
        bookings[2].merchant.name = "ShouldNotOverrideCounterparty".into();
        bookings[2].end_to_end_id = "E2E-REF-42".into();
        bookings[2].mandate_id = "MANDAT-99".into();
        bookings[2].creditor_id = "DE98ZZZ09999999999".into();
        bookings[2].external_id = "camt:BANKREF-77".into();
        bookings[2].gvc = "105".into();
        bookings[2].purpose = "Rücklastschrift MD06 Beitrag".into();
        bookings[3].gvc = "153".into();
        (account, bookings)
    }

    fn statement(account: &Account, bookings: &[Booking], version: CamtVersion) -> String {
        camt053_statement(
            account.clone(),
            bookings.to_vec(),
            version,
            100_000,
            "2025-01-01".into(),
            "2025-03-31T12:00:00+02:00".into(),
        )
    }

    /// `xmllint --schema` against the official ISO 20022 XSD; skipped where
    /// xmllint is not installed (it ships with macOS and libxml2-utils).
    fn validate(xml: &str, schema: &str) {
        let xsd = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/iso20022")
            .join(format!("{schema}.xsd"));
        let file = std::env::temp_dir().join(format!("camt-{}.xml", uuid::Uuid::new_v4()));
        std::fs::write(&file, xml).unwrap();
        let run = Command::new("xmllint")
            .args(["--noout", "--schema"])
            .arg(&xsd)
            .arg(&file)
            .output();
        let _ = std::fs::remove_file(&file);
        match run {
            Ok(o) => assert!(
                o.status.success(),
                "{schema}: {}\n{xml}",
                String::from_utf8_lossy(&o.stderr)
            ),
            Err(e) => eprintln!("xmllint not available ({e}); XSD check skipped"),
        }
    }

    #[test]
    fn camt053_validates_against_iso20022_schemas() {
        let (account, bookings) = fixture();
        for (version, schema) in [
            (CamtVersion::V02, "camt.053.001.02"),
            (CamtVersion::V08, "camt.053.001.08"),
        ] {
            let xml = statement(&account, &bookings, version);
            assert!(!xml.contains('\u{1}'));
            validate(&xml, schema);
        }
        // Account without IBAN → <Othr><Id>
        let mut no_iban = account.clone();
        no_iban.iban.clear();
        no_iban.account_number = "4711".into();
        let xml = statement(&no_iban, &bookings, CamtVersion::V08);
        assert!(xml.contains("<Othr><Id>4711</Id></Othr>"), "{xml}");
        validate(&xml, "camt.053.001.08");
    }

    #[test]
    fn camt053_status_order_and_gvc() {
        let (account, bookings) = fixture();
        let v08 = statement(&account, &bookings, CamtVersion::V08);
        let v02 = statement(&account, &bookings, CamtVersion::V02);
        assert!(v08.contains("<Sts><Cd>BOOK</Cd></Sts>"));
        assert!(v08.contains("<Sts><Cd>PDNG</Cd></Sts>"));
        assert!(v02.contains("<Sts>BOOK</Sts>"));
        assert!(v02.contains("<Sts>PDNG</Sts>"));
        assert!(v08.contains("<Prtry><Cd>NTRF+153+000</Cd><Issr>DK</Issr></Prtry>"));
        assert!(v08.contains("<Prtry><Cd>NDDT+105+000</Cd><Issr>DK</Issr></Prtry>"));
        assert!(v08.contains(
            "<Domn><Cd>PMNT</Cd><Fmly><Cd>IDDT</Cd><SubFmlyCd>ESDD</SubFmlyCd></Fmly></Domn>"
        ));
        assert!(v08.contains("<EndToEndId>E2E-REF-42</EndToEndId>"));
        assert!(v08.contains("<MndtId>MANDAT-99</MndtId>"));
        assert!(v08.contains("<AcctSvcrRef>BANKREF-77</AcctSvcrRef>"));
        assert!(v08.contains("<Id>DE98ZZZ09999999999</Id>"));
        assert!(v08.contains("<RtrInf><Rsn><Cd>MD06</Cd></Rsn></RtrInf>"));
        assert!(!v08.contains("ShouldNotOverrideCounterparty"));
        assert!(v08.contains("<MsgPgntn><PgNb>1</PgNb><LastPgInd>true</LastPgInd></MsgPgntn>"));
        assert!(v08.contains("<FrToDt><FrDtTm>"));
        for xml in [&v02, &v08] {
            if let (Some(ownr), Some(svcr)) = (xml.find("<Ownr>"), xml.find("<Svcr>")) {
                assert!(ownr < svcr);
            }
            let entry = xml.split("<Ntry>").find(|e| e.contains("<Purp>")).unwrap();
            assert!(entry.find("<Purp>").unwrap() < entry.find("<RmtInf>").unwrap());
            assert!(entry.matches("<Ustrd>").count() >= 3);
        }
    }

    /// The FinTS CAMT parser reads the export back: booked entries with their
    /// amounts and GVC, pending ones skipped, CLBD = OPBD + booked entries.
    #[test]
    fn camt053_round_trips_through_the_camt_parser() {
        let (account, bookings) = fixture();
        let booked: Vec<&Booking> = bookings.iter().filter(|b| !b.is_pending).collect();
        let sum: i64 = booked.iter().map(|b| b.amount_cents).sum();
        for version in [CamtVersion::V02, CamtVersion::V08] {
            let xml = statement(&account, &bookings, version);
            let (txs, report) = crate::connectors::fints::camt::parse(&xml, "");
            assert_eq!(txs.len(), booked.len(), "{version:?}");
            let mut got: Vec<i64> = txs.iter().map(|t| t.amount_cents).collect();
            let mut want: Vec<i64> = booked.iter().map(|b| b.amount_cents).collect();
            got.sort_unstable();
            want.sort_unstable();
            assert_eq!(got, want, "{version:?}");
            assert_eq!(report.closing_balance_cents, Some(100_000 + sum));
            assert!(txs.iter().any(|t| t.gvc == "153"), "{version:?}");
        }
    }

    #[test]
    fn csv_formula_guard_and_escaping() {
        assert_eq!(csv_field("-2+3", true), "'-2+3");
        assert_eq!(csv_field("=SUM(A1)", true), "'=SUM(A1)");
        assert_eq!(csv_field("@x;y", true), "\"'@x;y\"");
        assert_eq!(csv_field("\tx", true), "'\tx");
        assert_eq!(csv_field("Miete", true), "Miete");
        assert_eq!(csv_field("-12,50", false), "-12,50");
        assert_eq!(csv_amount(-459), "-4,59");
        assert_eq!(csv_amount(250_000), "2500,00");
    }

    #[test]
    fn csv_columns_and_balance_lines() {
        let row = ExportCsvRow {
            date: "2025-03-02".into(),
            account_name: "Giro".into(),
            counterparty: "Supermarkt <Nord>".into(),
            purpose: "Einkauf".into(),
            category: "Lebensmittel".into(),
            note: "Woche".into(),
            amount_cents: -4_599,
            currency: "EUR".into(),
            day_balance_cents: Some(1_000_000),
        };
        let line = ExportCsvBalanceLine {
            name: "=HYPERLINK(\"x\")".into(),
            balance_cents: 1_000_000,
            currency: "EUR".into(),
            date: "2025-03-31".into(),
        };
        let all = ExportCsvColumns {
            category: true,
            note: true,
            daily_balance: true,
        };
        let csv = export_csv(vec![row.clone()], all, vec![line]);
        assert!(csv.starts_with('\u{FEFF}'));
        assert!(csv.contains("# \"'=HYPERLINK(\"\"x\"\")\";10000,00;EUR;2025-03-31\r\n"));
        assert!(csv.contains(
            "Datum;Konto;Name;Verwendungszweck;Kategorie;Notiz;Betrag;Währung;Tagessaldo\r\n"
        ));
        assert!(csv.contains(
            "2025-03-02;Giro;Supermarkt <Nord>;Einkauf;Lebensmittel;Woche;-45,99;EUR;10000,00\r\n"
        ));
        let lean = export_csv(vec![row], ExportCsvColumns::default(), vec![]);
        assert!(lean.contains("Datum;Konto;Name;Verwendungszweck;Betrag;Währung\r\n"));
        assert!(!lean.contains("Woche"));
    }

    #[test]
    fn balance_history_ignores_pending_and_supports_single_foreign_currency_account() {
        let (v, path) = demo();
        let accounts = v.list_accounts().unwrap();
        let acct = accounts
            .iter()
            .find(|a| is_iban(&compact_iban(&a.iban)))
            .unwrap();
        let base_hist = v.balance_history(vec![acct.id], 5).unwrap();
        let today_bal = base_hist.last().unwrap().balance_cents;

        // Insert a pending booking on today: must NOT shift earlier daily balances (#483 point 1).
        let today_str = base_hist.last().unwrap().date.clone();
        {
            let db = v.db().unwrap();
            db.execute(
                "INSERT INTO transactions (account_id, external_id, booking_date, value_date, amount_cents, currency, counterparty, purpose) VALUES (?1, 'pending-test-483', ?2, ?2, -50000, 'EUR', 'Test', 'Pending')",
                rusqlite::params![acct.id, today_str],
            )
            .unwrap();
        }
        let after_pending = v.balance_history(vec![acct.id], 5).unwrap();
        assert_eq!(
            after_pending.first().unwrap().balance_cents,
            base_hist.first().unwrap().balance_cents
        );
        assert_eq!(after_pending.last().unwrap().balance_cents, today_bal);

        // Single foreign-currency account is included when queried explicitly (#483 point 5).
        {
            let db = v.db().unwrap();
            db.execute(
                "UPDATE accounts SET currency = 'USD' WHERE id = ?1",
                [acct.id],
            )
            .unwrap();
        }
        let usd_hist = v.balance_history(vec![acct.id], 5).unwrap();
        assert_eq!(usd_hist.last().unwrap().balance_cents, today_bal);

        drop(v);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn esc_drops_xml_forbidden_characters() {
        assert_eq!(esc("a\u{0}b\u{1f}c\u{fffe}"), "abc");
        assert_eq!(esc("a\tb\nc\r\nd"), "a\tb\nc\r\nd");
        assert_eq!(esc("<&>\"'"), "&lt;&amp;&gt;&quot;&#39;");
        assert!(is_iban("DE02120300000000202051"));
        assert!(!is_iban("1234567890"));
        assert!(!is_iban("de02120300000000202051"));
    }
}
