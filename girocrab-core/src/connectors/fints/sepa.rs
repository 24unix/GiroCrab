//! SEPA credit transfer helpers: IBAN / BIC validation (ISO 13616 Mod-97,
//! ISO 9362) and a `pain.001.001.03` generator for single transfers.

use crate::error::{CoreError, CoreResult};
use crate::i18n::tr;

pub const PAIN_DESCRIPTOR: &str = "urn:iso:std:iso:20022:tech:xsd:pain.001.001.03";
/// SEPA Instant Payments (HKIPZ) use `pain.001.001.09`.
pub const PAIN_DESCRIPTOR_INSTANT: &str = "urn:iso:std:iso:20022:tech:xsd:pain.001.001.09";

/// IBAN length per country (SEPA area + common neighbours).
const IBAN_LENGTHS: &[(&str, usize)] = &[
    ("AD", 24),
    ("AT", 20),
    ("BE", 16),
    ("BG", 22),
    ("CH", 21),
    ("CY", 28),
    ("CZ", 24),
    ("DE", 22),
    ("DK", 18),
    ("EE", 20),
    ("ES", 24),
    ("FI", 18),
    ("FR", 27),
    ("GB", 22),
    ("GI", 23),
    ("GR", 27),
    ("HR", 21),
    ("HU", 28),
    ("IE", 22),
    ("IS", 26),
    ("IT", 27),
    ("LI", 21),
    ("LT", 20),
    ("LU", 20),
    ("LV", 21),
    ("MC", 27),
    ("MT", 31),
    ("NL", 18),
    ("NO", 15),
    ("PL", 28),
    ("PT", 25),
    ("RO", 24),
    ("SE", 24),
    ("SI", 19),
    ("SK", 24),
    ("SM", 27),
    ("VA", 22),
];

/// Removes whitespace and upper-cases.
pub fn normalize_iban(iban: &str) -> String {
    iban.chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>()
        .to_uppercase()
}

/// Strict IBAN check: characters, country prefix, length, Mod-97 checksum.
pub fn validate_iban(iban: &str) -> bool {
    let s = normalize_iban(iban);
    if s.len() < 15 || s.len() > 34 || !s.chars().all(|c| c.is_ascii_alphanumeric()) {
        return false;
    }
    let b = s.as_bytes();
    if !(b[0].is_ascii_uppercase()
        && b[1].is_ascii_uppercase()
        && b[2].is_ascii_digit()
        && b[3].is_ascii_digit())
    {
        return false;
    }
    match IBAN_LENGTHS.iter().find(|(c, _)| *c == &s[..2]) {
        Some((_, len)) if *len == s.len() => {}
        _ => return false,
    }
    // Move the first four characters to the end, letters -> 10..35.
    let mut rem: u32 = 0;
    for c in s[4..].chars().chain(s[..4].chars()) {
        let v = c.to_digit(36).unwrap_or(0);
        rem = if v >= 10 {
            (rem * 100 + v) % 97
        } else {
            (rem * 10 + v) % 97
        };
    }
    rem == 1
}

/// BIC: 8 or 11 characters (4 letters bank, 2 letters country, 2 alnum
/// location, optional 3 alnum branch).
pub fn validate_bic(bic: &str) -> bool {
    let s: String = bic
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>()
        .to_uppercase();
    if s.len() != 8 && s.len() != 11 {
        return false;
    }
    let b = s.as_bytes();
    b[..6].iter().all(|c| c.is_ascii_uppercase())
        && b[6..].iter().all(|c| c.is_ascii_alphanumeric())
}

pub fn xml_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            c if c.is_control() => out.push(' '),
            c => out.push(c),
        }
    }
    out
}

/// Reduces text to the DK SEPA character set (`a-z A-Z 0-9 / - ? : ( ) . , ' + space`):
/// umlauts/ß are transliterated, common accents lose their diacritic, anything
/// else becomes a space.
pub fn sanitize_sepa_text(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            'ä' => out.push_str("ae"),
            'ö' => out.push_str("oe"),
            'ü' => out.push_str("ue"),
            'Ä' => out.push_str("Ae"),
            'Ö' => out.push_str("Oe"),
            'Ü' => out.push_str("Ue"),
            'ß' | 'ẞ' => out.push_str("ss"),
            'à' | 'á' | 'â' | 'ã' | 'å' => out.push('a'),
            'À' | 'Á' | 'Â' | 'Ã' | 'Å' => out.push('A'),
            'è' | 'é' | 'ê' | 'ë' => out.push('e'),
            'È' | 'É' | 'Ê' | 'Ë' => out.push('E'),
            'ì' | 'í' | 'î' | 'ï' => out.push('i'),
            'Ì' | 'Í' | 'Î' | 'Ï' => out.push('I'),
            'ò' | 'ó' | 'ô' | 'õ' | 'ø' => out.push('o'),
            'Ò' | 'Ó' | 'Ô' | 'Õ' | 'Ø' => out.push('O'),
            'ù' | 'ú' | 'û' => out.push('u'),
            'Ù' | 'Ú' | 'Û' => out.push('U'),
            'ç' => out.push('c'),
            'Ç' => out.push('C'),
            'ñ' => out.push('n'),
            'Ñ' => out.push('N'),
            'æ' => out.push_str("ae"),
            'Æ' => out.push_str("Ae"),
            c if c.is_ascii_alphanumeric() || "/-?:().,'+ ".contains(c) => out.push(c),
            _ => out.push(' '),
        }
    }
    out
}

fn clip(s: &str, max: usize) -> String {
    sanitize_sepa_text(s)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(max)
        .collect()
}

/// `1234` -> "12.34"
pub fn format_amount(cents: i64) -> String {
    format!("{}.{:02}", cents / 100, cents % 100)
}

pub struct Pain001<'a> {
    pub message_id: &'a str,
    /// ISO date-time, e.g. 2026-11-09T10:15:00
    pub created: &'a str,
    /// ISO date (YYYY-MM-DD)
    pub execution_date: &'a str,
    pub debtor_name: &'a str,
    pub debtor_iban: &'a str,
    pub debtor_bic: &'a str,
    pub creditor_name: &'a str,
    pub creditor_iban: &'a str,
    pub creditor_bic: Option<&'a str>,
    pub amount_cents: i64,
    pub purpose: &'a str,
    /// SEPA Instant Payment (`pain.001.001.09` with `LclInstrm` INST).
    pub instant: bool,
}

/// Builds a single-transfer `pain.001.001.03` document (UTF-8).
pub fn build_pain001(p: &Pain001) -> CoreResult<String> {
    if p.amount_cents <= 0 {
        return Err(CoreError::InvalidInput {
            message: tr("Der Betrag muss größer als 0 sein.").into(),
        });
    }
    if !validate_iban(p.creditor_iban) {
        return Err(CoreError::InvalidInput {
            message: tr("Die Empfänger-IBAN ist ungültig.").into(),
        });
    }
    if p.creditor_name.trim().is_empty() {
        return Err(CoreError::InvalidInput {
            message: tr("Der Empfängername fehlt.").into(),
        });
    }
    let amount = format_amount(p.amount_cents);
    let msg_id = xml_escape(&clip(p.message_id, 35));
    let debtor = xml_escape(&clip(p.debtor_name, 70));
    let creditor = xml_escape(&clip(p.creditor_name, 70));
    let purpose = xml_escape(&clip(p.purpose, 140));
    let d_iban = normalize_iban(p.debtor_iban);
    let c_iban = normalize_iban(p.creditor_iban);
    let bic_tag = if p.instant { "BICFI" } else { "BIC" };
    let (descriptor, pmt_tp, exec_xml) = if p.instant {
        (
            PAIN_DESCRIPTOR_INSTANT,
            "<PmtTpInf><SvcLvl><Cd>SEPA</Cd></SvcLvl><LclInstrm><Cd>INST</Cd></LclInstrm></PmtTpInf>",
            format!("<ReqdExctnDt><Dt>{}</Dt></ReqdExctnDt>", xml_escape(p.execution_date)),
        )
    } else {
        (
            PAIN_DESCRIPTOR,
            "<PmtTpInf><SvcLvl><Cd>SEPA</Cd></SvcLvl></PmtTpInf>",
            format!(
                "<ReqdExctnDt>{}</ReqdExctnDt>",
                xml_escape(p.execution_date)
            ),
        )
    };
    let d_agent = if validate_bic(p.debtor_bic) {
        format!("<{bic_tag}>{}</{bic_tag}>", normalize_iban(p.debtor_bic))
    } else {
        "<Othr><Id>NOTPROVIDED</Id></Othr>".to_string()
    };
    let c_agent = match p.creditor_bic.filter(|b| validate_bic(b)) {
        Some(b) => format!(
            "<CdtrAgt><FinInstnId><{bic_tag}>{}</{bic_tag}></FinInstnId></CdtrAgt>",
            normalize_iban(b)
        ),
        None => String::new(),
    };
    let rmt = if purpose.is_empty() {
        String::new()
    } else {
        format!("<RmtInf><Ustrd>{purpose}</Ustrd></RmtInf>")
    };
    Ok(format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
<Document xmlns=\"{descriptor}\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\
<CstmrCdtTrfInitn>\
<GrpHdr><MsgId>{msg_id}</MsgId><CreDtTm>{created}</CreDtTm><NbOfTxs>1</NbOfTxs><CtrlSum>{amount}</CtrlSum>\
<InitgPty><Nm>{debtor}</Nm></InitgPty></GrpHdr>\
<PmtInf><PmtInfId>{msg_id}</PmtInfId><PmtMtd>TRF</PmtMtd><BtchBookg>false</BtchBookg><NbOfTxs>1</NbOfTxs><CtrlSum>{amount}</CtrlSum>\
{pmt_tp}{exec_xml}\
<Dbtr><Nm>{debtor}</Nm></Dbtr><DbtrAcct><Id><IBAN>{d_iban}</IBAN></Id></DbtrAcct>\
<DbtrAgt><FinInstnId>{d_agent}</FinInstnId></DbtrAgt><ChrgBr>SLEV</ChrgBr>\
<CdtTrfTxInf><PmtId><EndToEndId>NOTPROVIDED</EndToEndId></PmtId>\
<Amt><InstdAmt Ccy=\"EUR\">{amount}</InstdAmt></Amt>{c_agent}\
<Cdtr><Nm>{creditor}</Nm></Cdtr><CdtrAcct><Id><IBAN>{c_iban}</IBAN></Id></CdtrAcct>{rmt}\
</CdtTrfTxInf></PmtInf></CstmrCdtTrfInitn></Document>",
        created = xml_escape(p.created),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_ibans() {
        assert!(validate_iban("DE89370400440532013000"));
        assert!(validate_iban("DE89 3704 0044 0532 0130 00"));
        assert!(validate_iban("  de89370400440532013000 "));
        assert!(validate_iban("GB82 WEST 1234 5698 7654 32"));
        assert!(validate_iban("AT611904300234573201"));
    }

    #[test]
    fn invalid_ibans() {
        assert!(!validate_iban("DE89370400440532013001")); // checksum
        assert!(!validate_iban("DE8937040044053201300")); // too short for DE
        assert!(!validate_iban("XX89370400440532013000")); // unknown country
        assert!(!validate_iban("DE89-3704-0044-0532-0130-00")); // bad characters
        assert!(!validate_iban(""));
        assert!(!validate_iban("1234"));
    }

    #[test]
    fn bic_validation() {
        assert!(validate_bic("COBADEFFXXX"));
        assert!(validate_bic("genodef1ks2"));
        assert!(validate_bic("GENODEF1"));
        assert!(!validate_bic("GENODE"));
        assert!(!validate_bic("1234DEFF"));
    }

    fn sample<'a>(name: &'a str, purpose: &'a str) -> Pain001<'a> {
        Pain001 {
            message_id: "GC-1",
            created: "2026-11-09T10:00:00",
            execution_date: "2026-11-09",
            debtor_name: "Erika Mustermann",
            debtor_iban: "DE02120300000000202051",
            debtor_bic: "BYLADEM1001",
            creditor_name: name,
            creditor_iban: "DE89 3704 0044 0532 0130 00",
            creditor_bic: None,
            amount_cents: 12_345,
            purpose,
            instant: false,
        }
    }

    #[test]
    fn pain001_scheduled_date_and_instant_variant() {
        let mut p = sample("A", "x");
        p.execution_date = "2027-01-15";
        let xml = build_pain001(&p).unwrap();
        assert!(xml.contains("<ReqdExctnDt>2027-01-15</ReqdExctnDt>"));
        assert!(!xml.contains("INST"));
        p.instant = true;
        p.creditor_bic = Some("COBADEFFXXX");
        let xml = build_pain001(&p).unwrap();
        assert!(xml.contains("pain.001.001.09"));
        assert!(xml.contains("<LclInstrm><Cd>INST</Cd></LclInstrm>"));
        assert!(xml.contains("<ReqdExctnDt><Dt>2027-01-15</Dt></ReqdExctnDt>"));
        assert!(xml.contains("<BICFI>BYLADEM1001</BICFI>"));
        assert!(xml.contains("<CdtrAgt><FinInstnId><BICFI>COBADEFFXXX</BICFI>"));
    }

    #[test]
    fn pain001_basics_and_sepa_charset() {
        let xml = build_pain001(&sample("Müller & Söhne <GmbH>", "Rechnung äöüß \"7\"")).unwrap();
        assert!(xml.contains("<Cdtr><Nm>Mueller Soehne GmbH</Nm></Cdtr>"));
        assert!(xml.contains("<Ustrd>Rechnung aeoeuess 7</Ustrd>"));
        assert!(xml.contains("<InstdAmt Ccy=\"EUR\">123.45</InstdAmt>"));
        assert!(xml.contains("<CtrlSum>123.45</CtrlSum>"));
        assert!(xml.contains("<IBAN>DE89370400440532013000</IBAN>"));
        assert!(xml.contains("<BIC>BYLADEM1001</BIC>"));
        assert!(xml.contains("pain.001.001.03"));
        assert!(!xml.contains("CdtrAgt"));
        assert!(xml.is_ascii());
    }

    #[test]
    fn sanitizes_to_dk_charset() {
        assert_eq!(sanitize_sepa_text("Müller"), "Mueller");
        assert_eq!(sanitize_sepa_text("ÄÖÜ äöü ß"), "AeOeUe aeoeue ss");
        assert_eq!(sanitize_sepa_text("René €5 & Co*"), "Rene  5   Co ");
        assert_eq!(
            sanitize_sepa_text("A/B-C?D:E(F).G,H'I+J"),
            "A/B-C?D:E(F).G,H'I+J"
        );
    }

    #[test]
    fn xml_escaping_stays_intact() {
        assert_eq!(xml_escape("a&b<c>\"d'"), "a&amp;b&lt;c&gt;&quot;d&apos;");
        let xml = build_pain001(&sample("O'Brien", "x")).unwrap();
        assert!(xml.contains("<Nm>O&apos;Brien</Nm>"));
    }

    #[test]
    fn pain001_limits_and_rejects() {
        let long = "x".repeat(300);
        let xml = build_pain001(&sample("A", &long)).unwrap();
        let ustrd = xml
            .split("<Ustrd>")
            .nth(1)
            .unwrap()
            .split("</Ustrd>")
            .next()
            .unwrap();
        assert_eq!(ustrd.chars().count(), 140);
        let mut p = sample("A", "x");
        p.amount_cents = 0;
        assert!(build_pain001(&p).is_err());
        let mut p = sample("A", "x");
        p.creditor_iban = "DE00000000000000000000";
        assert!(build_pain001(&p).is_err());
        assert_eq!(format_amount(5), "0.05");
    }

    #[test]
    fn pain001_creditor_bic_and_control_chars() {
        let mut p = sample("Max\nMuster", "a\tb");
        p.creditor_bic = Some("COBADEFFXXX");
        let xml = build_pain001(&p).unwrap();
        assert!(xml.contains("<CdtrAgt><FinInstnId><BIC>COBADEFFXXX</BIC>"));
        assert!(xml.contains("<Nm>Max Muster</Nm>"));
        assert!(xml.contains("<Ustrd>a b</Ustrd>"));
    }
}
