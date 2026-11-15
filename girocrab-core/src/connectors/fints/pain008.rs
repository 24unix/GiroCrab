//! SEPA direct debit (`pain.008`) generator for HKDSE / HKDME (CORE, COR1) and
//! HKBSE / HKBME (B2B), plus Creditor Identifier validation (GitHub #143).
//!
//! Like the credit transfer builder it emits one `PmtInf` per message: one
//! scheme (`LclInstrm`), one sequence type, one collection date. A caller that
//! mixes sequence types or schemes builds one message per group.

use super::sepa::{
    format_amount, normalize_iban, sanitize_sepa_text, validate_bic, validate_iban, xml_escape,
};
use crate::error::{CoreError, CoreResult};
use crate::i18n::{tr, trf};

pub const PAIN008_02_DESCRIPTOR: &str = "urn:iso:std:iso:20022:tech:xsd:pain.008.003.02";
pub const PAIN008_08_DESCRIPTOR: &str = "urn:iso:std:iso:20022:tech:xsd:pain.008.001.08";

/// pain.008 schema version a bank accepts (BPD lists the descriptors).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DebitVersion {
    /// `pain.008.003.02`, the long-standing DK format.
    V02,
    /// `pain.008.001.08`.
    V08,
}

impl DebitVersion {
    pub fn descriptor(self) -> &'static str {
        match self {
            DebitVersion::V02 => PAIN008_02_DESCRIPTOR,
            DebitVersion::V08 => PAIN008_08_DESCRIPTOR,
        }
    }

    /// Picks from the descriptors a bank advertises; prefers `.003.02` (the
    /// one every bank knows), an empty list (unknown) also means `.003.02`.
    pub fn pick(advertised: &[String]) -> Option<Self> {
        let has = |d: &str| advertised.iter().any(|a| a == d);
        if advertised.is_empty() || has(PAIN008_02_DESCRIPTOR) {
            Some(DebitVersion::V02)
        } else if has(PAIN008_08_DESCRIPTOR) {
            Some(DebitVersion::V08)
        } else {
            None
        }
    }
}

/// Direct debit scheme (`LclInstrm`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DebitScheme {
    Core,
    Cor1,
    B2b,
}

impl DebitScheme {
    pub fn code(self) -> &'static str {
        match self {
            DebitScheme::Core => "CORE",
            DebitScheme::Cor1 => "COR1",
            DebitScheme::B2b => "B2B",
        }
    }

    pub fn from_code(code: &str) -> Option<Self> {
        match code {
            "CORE" => Some(DebitScheme::Core),
            "COR1" => Some(DebitScheme::Cor1),
            "B2B" => Some(DebitScheme::B2b),
            _ => None,
        }
    }
}

/// Sequence type (`SeqTp`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SequenceType {
    First,
    Recurring,
    OneOff,
    Final,
}

impl SequenceType {
    pub fn code(self) -> &'static str {
        match self {
            SequenceType::First => "FRST",
            SequenceType::Recurring => "RCUR",
            SequenceType::OneOff => "OOFF",
            SequenceType::Final => "FNAL",
        }
    }

    pub fn from_code(code: &str) -> Option<Self> {
        match code {
            "FRST" => Some(SequenceType::First),
            "RCUR" => Some(SequenceType::Recurring),
            "OOFF" => Some(SequenceType::OneOff),
            "FNAL" => Some(SequenceType::Final),
            _ => None,
        }
    }
}

/// One collection from a debtor under a mandate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Collection {
    pub debtor_name: String,
    pub debtor_iban: String,
    pub debtor_bic: Option<String>,
    pub amount_cents: i64,
    pub purpose: String,
    /// EndToEndId, unique per collection (`NOTPROVIDED` when empty).
    pub end_to_end_id: String,
    pub mandate_id: String,
    /// Date the mandate was signed, `YYYY-MM-DD`.
    pub mandate_date: String,
}

pub struct Pain008<'a> {
    pub message_id: &'a str,
    /// ISO date-time, e.g. 2026-11-09T10:15:00
    pub created: &'a str,
    /// Due date of the collection, `YYYY-MM-DD`.
    pub collection_date: &'a str,
    pub creditor_name: &'a str,
    pub creditor_iban: &'a str,
    pub creditor_bic: &'a str,
    pub creditor_id: &'a str,
    pub scheme: DebitScheme,
    pub sequence: SequenceType,
    pub collections: &'a [Collection],
    pub version: DebitVersion,
    /// `true` = one booking for the whole message (`BtchBookg` true).
    pub batch_booking: bool,
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

/// Creditor Identifier (Gläubiger-ID, e.g. `DE98ZZZ09999999999`): country,
/// two check digits, three business-code characters, then the national part.
/// The check digits follow ISO 7064 mod 97-10 over the identifier without the
/// business code.
pub fn validate_creditor_id(id: &str) -> bool {
    let id = id.trim().to_ascii_uppercase();
    let b = id.as_bytes();
    if !(8..=35).contains(&b.len())
        || !b[..2].iter().all(u8::is_ascii_uppercase)
        || !b[2..4].iter().all(u8::is_ascii_digit)
        || !b[4..].iter().all(u8::is_ascii_alphanumeric)
    {
        return false;
    }
    // national part + country + check digits, letters A=10 … Z=35
    let rearranged: String = id[7..].chars().chain(id[..4].chars()).collect();
    let mut rem: u32 = 0;
    for c in rearranged.chars() {
        let v = c.to_digit(36).unwrap_or(0);
        rem = if v >= 10 {
            (rem * 100 + v) % 97
        } else {
            (rem * 10 + v) % 97
        };
    }
    rem == 1
}

/// Sum of all collections in cents; `None` on overflow.
pub fn collections_total_cents(collections: &[Collection]) -> Option<i64> {
    collections
        .iter()
        .try_fold(0i64, |acc, c| acc.checked_add(c.amount_cents))
}

/// Checks one collection; the message names the 1-based position.
pub fn validate_collection(position: usize, c: &Collection) -> CoreResult<()> {
    let fail = |msg: &str| CoreError::InvalidInput {
        message: trf("Lastschrift {0}: {1}", &[&position, &msg]),
    };
    if c.debtor_name.trim().is_empty() {
        return Err(fail(tr("Der Name des Zahlungspflichtigen fehlt.")));
    }
    if !validate_iban(&c.debtor_iban) {
        return Err(fail(tr("Die IBAN des Zahlungspflichtigen ist ungültig.")));
    }
    if c.amount_cents <= 0 {
        return Err(fail(tr("Der Betrag muss größer als 0 sein.")));
    }
    if c.mandate_id.trim().is_empty() || c.mandate_id.trim().chars().count() > 35 {
        return Err(fail(tr(
            "Die Mandatsreferenz fehlt oder ist länger als 35 Zeichen.",
        )));
    }
    if c.mandate_date.len() != 10 {
        return Err(fail(tr("Das Datum der Mandatsunterschrift fehlt.")));
    }
    Ok(())
}

/// Builds a `pain.008` document (UTF-8) with one `PmtInf` and one
/// `DrctDbtTxInf` per collection; `NbOfTxs` and `CtrlSum` in header and block.
pub fn build_pain008(p: &Pain008) -> CoreResult<String> {
    if p.collections.is_empty() {
        return Err(CoreError::InvalidInput {
            message: tr("Der Einzug enthält keine Lastschrift.").into(),
        });
    }
    if !validate_creditor_id(p.creditor_id) {
        return Err(CoreError::InvalidInput {
            message: tr("Die Gläubiger-ID ist ungültig.").into(),
        });
    }
    if !validate_iban(p.creditor_iban) {
        return Err(CoreError::InvalidInput {
            message: tr("Die IBAN des Gläubigers ist ungültig.").into(),
        });
    }
    for (i, c) in p.collections.iter().enumerate() {
        validate_collection(i + 1, c)?;
    }
    let total = collections_total_cents(p.collections).ok_or_else(|| CoreError::InvalidInput {
        message: tr("Die Summe des Einzugs ist zu groß.").into(),
    })?;
    let sum = format_amount(total);
    let count = p.collections.len();
    let msg_id = xml_escape(&clip(p.message_id, 35));
    let creditor = xml_escape(&clip(p.creditor_name, 70));
    let c_iban = normalize_iban(p.creditor_iban);
    let bic_tag = match p.version {
        DebitVersion::V02 => "BIC",
        DebitVersion::V08 => "BICFI",
    };
    let agent = |bic: &str| {
        if validate_bic(bic) {
            format!("<{bic_tag}>{}</{bic_tag}>", normalize_iban(bic))
        } else {
            "<Othr><Id>NOTPROVIDED</Id></Othr>".to_string()
        }
    };
    let mut txs = String::new();
    for c in p.collections {
        let e2e = if c.end_to_end_id.trim().is_empty() {
            "NOTPROVIDED".to_string()
        } else {
            xml_escape(&clip(&c.end_to_end_id, 35))
        };
        let purpose = xml_escape(&clip(&c.purpose, 140));
        let rmt = if purpose.is_empty() {
            String::new()
        } else {
            format!("<RmtInf><Ustrd>{purpose}</Ustrd></RmtInf>")
        };
        txs.push_str(&format!(
            "<DrctDbtTxInf><PmtId><EndToEndId>{e2e}</EndToEndId></PmtId>\
<InstdAmt Ccy=\"EUR\">{amount}</InstdAmt>\
<DrctDbtTx><MndtRltdInf><MndtId>{mandate}</MndtId><DtOfSgntr>{signed}</DtOfSgntr></MndtRltdInf></DrctDbtTx>\
<DbtrAgt><FinInstnId>{d_agent}</FinInstnId></DbtrAgt>\
<Dbtr><Nm>{name}</Nm></Dbtr><DbtrAcct><Id><IBAN>{iban}</IBAN></Id></DbtrAcct>{rmt}</DrctDbtTxInf>",
            amount = format_amount(c.amount_cents),
            mandate = xml_escape(c.mandate_id.trim()),
            signed = xml_escape(&c.mandate_date),
            d_agent = agent(c.debtor_bic.as_deref().unwrap_or("")),
            name = xml_escape(&clip(&c.debtor_name, 70)),
            iban = normalize_iban(&c.debtor_iban),
        ));
    }
    // 001.08 wraps nothing extra here; the two versions differ in the BIC tag.
    let ns = p.version.descriptor();
    Ok(format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
<Document xmlns=\"{ns}\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\
<CstmrDrctDbtInitn>\
<GrpHdr><MsgId>{msg_id}</MsgId><CreDtTm>{created}</CreDtTm><NbOfTxs>{count}</NbOfTxs><CtrlSum>{sum}</CtrlSum>\
<InitgPty><Nm>{creditor}</Nm></InitgPty></GrpHdr>\
<PmtInf><PmtInfId>{msg_id}</PmtInfId><PmtMtd>DD</PmtMtd><BtchBookg>{batch}</BtchBookg><NbOfTxs>{count}</NbOfTxs><CtrlSum>{sum}</CtrlSum>\
<PmtTpInf><SvcLvl><Cd>SEPA</Cd></SvcLvl><LclInstrm><Cd>{scheme}</Cd></LclInstrm><SeqTp>{seq}</SeqTp></PmtTpInf>\
<ReqdColltnDt>{due}</ReqdColltnDt>\
<Cdtr><Nm>{creditor}</Nm></Cdtr><CdtrAcct><Id><IBAN>{c_iban}</IBAN></Id></CdtrAcct>\
<CdtrAgt><FinInstnId>{c_agent}</FinInstnId></CdtrAgt><ChrgBr>SLEV</ChrgBr>\
<CdtrSchmeId><Id><PrvtId><Othr><Id>{cid}</Id><SchmeNm><Prtry>SEPA</Prtry></SchmeNm></Othr></PrvtId></Id></CdtrSchmeId>\
{txs}</PmtInf></CstmrDrctDbtInitn></Document>",
        created = xml_escape(p.created),
        batch = p.batch_booking,
        scheme = p.scheme.code(),
        seq = p.sequence.code(),
        due = xml_escape(p.collection_date),
        c_agent = agent(p.creditor_bic),
        cid = xml_escape(&p.creditor_id.trim().to_ascii_uppercase()),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn collection(n: u32) -> Collection {
        Collection {
            debtor_name: format!("Mitglied {n} Müller"),
            debtor_iban: "DE89370400440532013000".into(),
            debtor_bic: None,
            amount_cents: 1250 + i64::from(n),
            purpose: "Mitgliedsbeitrag 2026".into(),
            end_to_end_id: format!("BEITRAG-{n}"),
            mandate_id: format!("M-{n:04}"),
            mandate_date: "2024-03-01".into(),
        }
    }

    fn base<'a>(cs: &'a [Collection]) -> Pain008<'a> {
        Pain008 {
            message_id: "MSG-1",
            created: "2026-11-15T10:00:00",
            collection_date: "2026-11-30",
            creditor_name: "Sportverein Nord e.V.",
            creditor_iban: "DE02120300000000202051",
            creditor_bic: "BYLADEM1001",
            creditor_id: "DE98ZZZ09999999999",
            scheme: DebitScheme::Core,
            sequence: SequenceType::Recurring,
            collections: cs,
            version: DebitVersion::V02,
            batch_booking: true,
        }
    }

    #[test]
    fn creditor_id_check_digits() {
        assert!(validate_creditor_id("DE98ZZZ09999999999")); // the Bundesbank sample
        assert!(validate_creditor_id(" de98zzz09999999999 "));
        assert!(!validate_creditor_id("DE99ZZZ09999999999")); // wrong check digits
        assert!(!validate_creditor_id("DE98ZZZ0999999999")); // one character short
        assert!(!validate_creditor_id("98DEZZZ09999999999"));
        assert!(!validate_creditor_id(""));
    }

    #[test]
    fn builds_header_block_and_every_collection() {
        let cs = [collection(1), collection(2)];
        let xml = build_pain008(&base(&cs)).unwrap();
        assert!(xml.contains(PAIN008_02_DESCRIPTOR));
        assert!(xml.contains("<NbOfTxs>2</NbOfTxs>"));
        assert!(xml.contains("<CtrlSum>25.03</CtrlSum>")); // 12.51 + 12.52
        assert!(xml.contains("<PmtMtd>DD</PmtMtd>"));
        assert!(xml.contains("<LclInstrm><Cd>CORE</Cd></LclInstrm><SeqTp>RCUR</SeqTp>"));
        assert!(xml.contains("<ReqdColltnDt>2026-11-30</ReqdColltnDt>"));
        assert!(xml.contains("<Id>DE98ZZZ09999999999</Id><SchmeNm><Prtry>SEPA</Prtry>"));
        assert_eq!(xml.matches("<DrctDbtTxInf>").count(), 2);
        assert!(xml.contains("<MndtId>M-0001</MndtId><DtOfSgntr>2024-03-01</DtOfSgntr>"));
        assert!(xml.contains("<Nm>Mitglied 1 Mueller</Nm>")); // SEPA character set
        assert!(xml.contains("<BIC>BYLADEM1001</BIC>"));
        // debtor without BIC: IBAN only
        assert!(xml.contains("<DbtrAgt><FinInstnId><Othr><Id>NOTPROVIDED</Id>"));
    }

    #[test]
    fn scheme_sequence_and_version_are_switchable() {
        let cs = [collection(1)];
        let mut p = base(&cs);
        p.scheme = DebitScheme::B2b;
        p.sequence = SequenceType::First;
        p.version = DebitVersion::V08;
        let xml = build_pain008(&p).unwrap();
        assert!(xml.contains("<LclInstrm><Cd>B2B</Cd></LclInstrm><SeqTp>FRST</SeqTp>"));
        assert!(xml.contains(PAIN008_08_DESCRIPTOR));
        assert!(xml.contains("<BICFI>BYLADEM1001</BICFI>"));
    }

    #[test]
    fn rejects_bad_input_with_position() {
        let mut cs = [collection(1), collection(2)];
        cs[1].debtor_iban = "DE00".into();
        let err = build_pain008(&base(&cs)).unwrap_err().to_string();
        assert!(err.contains('2'), "{err}");
        let cs = [collection(1)];
        let mut p = base(&cs);
        p.creditor_id = "DE00ZZZ00000000000";
        assert!(build_pain008(&p).is_err());
        let none: [Collection; 0] = [];
        assert!(build_pain008(&base(&none)).is_err());
        let mut cs = [collection(1)];
        cs[0].mandate_id = String::new();
        assert!(build_pain008(&base(&cs)).is_err());
        cs[0].mandate_id = "M-1".into();
        cs[0].amount_cents = 0;
        assert!(build_pain008(&base(&cs)).is_err());
    }

    #[test]
    fn picks_the_version_from_the_bpd() {
        let d = |s: &str| s.to_string();
        assert_eq!(DebitVersion::pick(&[]), Some(DebitVersion::V02));
        assert_eq!(
            DebitVersion::pick(&[d(PAIN008_08_DESCRIPTOR)]),
            Some(DebitVersion::V08)
        );
        assert_eq!(
            DebitVersion::pick(&[d(PAIN008_08_DESCRIPTOR), d(PAIN008_02_DESCRIPTOR)]),
            Some(DebitVersion::V02)
        );
        assert_eq!(DebitVersion::pick(&[d("urn:other")]), None);
    }
}
