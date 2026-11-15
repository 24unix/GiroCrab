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
    let booked: i64 = ordered
        .iter()
        .filter(|b| !b.is_pending)
        .map(|b| b.amount_cents)
        .sum();
    let closing = opening_cents + booked;
    let currency = ordered
        .first()
        .map(|b| b.currency.clone())
        .unwrap_or_else(|| account.currency.clone());
    let from = ordered
        .first()
        .map(|b| b.booking_date.clone())
        .unwrap_or_else(|| opening_date.clone());
    let to = ordered
        .last()
        .map(|b| b.booking_date.clone())
        .unwrap_or_else(|| opening_date.clone());
    let stmt_id = truncate(&format!("GC-{}-{from}-{to}", account.id), 35);
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
        "<GrpHdr><MsgId>{}</MsgId><CreDtTm>{}</CreDtTm></GrpHdr>\n",
        esc(&stmt_id),
        esc(&created_at)
    );
    out += "<Stmt>\n";
    out += &format!(
        "<Id>{}</Id><ElctrncSeqNb>1</ElctrncSeqNb><CreDtTm>{}</CreDtTm>\n",
        esc(&stmt_id),
        esc(&created_at)
    );
    // Acct: Id, Ccy, Ownr, Svcr – schema order.
    let fallback = format!("GC-{}", account.id);
    out += &format!(
        "<Acct><Id>{}</Id><Ccy>{}</Ccy>",
        account_id_xml(&iban, &account.account_number, &fallback),
        esc(&currency)
    );
    let owner = if account.owner.trim().is_empty() {
        &account.name
    } else {
        &account.owner
    };
    if !owner.trim().is_empty() {
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
        out += &entry_xml(b, v08);
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

fn entry_xml(b: &Booking, v08: bool) -> String {
    let debit = b.amount_cents < 0;
    let ind = if debit { "DBIT" } else { "CRDT" };
    let status = if b.is_pending { "PDNG" } else { "BOOK" };
    let value = if b.value_date.is_empty() {
        &b.booking_date
    } else {
        &b.value_date
    };
    let name = if b.merchant.name.is_empty() {
        &b.counterparty
    } else {
        &b.merchant.name
    };
    let purpose = if b.clean_purpose.is_empty() {
        &b.purpose
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

    let mut e = String::from("<Ntry>");
    e += &format!(
        "<Amt Ccy=\"{}\">{}</Amt><CdtDbtInd>{ind}</CdtDbtInd>",
        esc(&b.currency),
        xml_amount(b.amount_cents)
    );
    // .08: Sts is a choice (ExternalEntryStatus1Code), .02: a plain code.
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
    // BkTxCd is mandatory in both versions. A German GVC goes in the DK form
    // `NTRF+<GVC>+000` (issuer DK) that German banks and importers read.
    let gvc = b.gvc.trim();
    e += &if gvc.len() == 3 && gvc.bytes().all(|c| c.is_ascii_digit()) {
        format!("<BkTxCd><Prtry><Cd>NTRF+{gvc}+000</Cd><Issr>DK</Issr></Prtry></BkTxCd>")
    } else if !gvc.is_empty() {
        format!(
            "<BkTxCd><Prtry><Cd>{}</Cd></Prtry></BkTxCd>",
            esc(&truncate(gvc, 35))
        )
    } else {
        "<BkTxCd/>".to_string()
    };
    e += "<NtryDtls><TxDtls>";
    // TxDtls order: RltdPties, RltdAgts, Purp, RmtInf.
    if !name.trim().is_empty() || !peer_iban.is_empty() {
        // Credit → the peer is the debtor; debit → the creditor.
        let (party, acct, agent) = if debit {
            ("Cdtr", "CdtrAcct", "CdtrAgt")
        } else {
            ("Dbtr", "DbtrAcct", "DbtrAgt")
        };
        e += "<RltdPties>";
        if !name.trim().is_empty() {
            let nm = esc(&truncate(name.trim(), 140));
            e += &if v08 {
                format!("<{party}><Pty><Nm>{nm}</Nm></Pty></{party}>")
            } else {
                format!("<{party}><Nm>{nm}</Nm></{party}>")
            };
        }
        if !peer_iban.is_empty() {
            e += &format!(
                "<{acct}><Id>{}</Id></{acct}>",
                account_id_xml(&peer_iban, &peer_iban, "")
            );
        }
        e += "</RltdPties>";
        if let Some(bic) = peer_bic.filter(|b| !b.is_empty()) {
            e += &format!(
                "<RltdAgts><{agent}><FinInstnId><{bic_tag}>{}</{bic_tag}></FinInstnId></{agent}></RltdAgts>",
                esc(&bic)
            );
        }
    }
    // ExternalPurpose1Code: 1–4 characters.
    let code = b.purpose_code.trim();
    if (1..=4).contains(&code.chars().count()) {
        e += &format!("<Purp><Cd>{}</Cd></Purp>", esc(code));
    }
    let lines = ustrd_lines(purpose);
    if !lines.is_empty() {
        e += "<RmtInf>";
        for l in lines {
            e += &format!("<Ustrd>{}</Ustrd>", esc(&l));
        }
        e += "</RmtInf>";
    }
    e += "</TxDtls></NtryDtls></Ntry>\n";
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
        bookings[2].merchant.name.clear();
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
        for xml in [&v02, &v08] {
            if let Some(svcr) = xml.find("<Svcr>") {
                assert!(xml.find("<Ownr>").unwrap() < svcr);
            }
            let entry = xml.split("<Ntry>").find(|e| e.contains("<Purp>")).unwrap();
            assert!(entry.find("<Purp>").unwrap() < entry.find("<RmtInf>").unwrap());
            // 300+ character purpose → several Ustrd lines of ≤ 140
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
    fn esc_drops_xml_forbidden_characters() {
        assert_eq!(esc("a\u{0}b\u{1f}c\u{fffe}"), "abc");
        assert_eq!(esc("a\tb\nc\r\nd"), "a\tb\nc\r\nd");
        assert_eq!(esc("<&>\"'"), "&lt;&amp;&gt;&quot;&#39;");
        assert!(is_iban("DE02120300000000202051"));
        assert!(!is_iban("1234567890"));
        assert!(!is_iban("de02120300000000202051"));
    }
}
