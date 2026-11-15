use super::*;
use crate::test_support::TempDir;

fn vault() -> (std::sync::Arc<Vault>, TempDir) {
    let dir = TempDir::new("girocrab-mandates");
    let v = Vault::open(
        dir.join("v.db").to_string_lossy().to_string(),
        vec![5u8; 32],
    )
    .unwrap();
    v.seed_demo_data().unwrap();
    // the demo has mandates of its own; the tests start from nothing
    for m in v.list_mandates(None).unwrap() {
        v.delete_mandate(m.id).unwrap();
    }
    for a in v.list_accounts().unwrap() {
        v.set_creditor_id(a.id, String::new()).unwrap();
    }
    (v, dir)
}

fn input(account_id: i64, reference: &str) -> MandateInput {
    MandateInput {
        account_id,
        debtor_name: "Mia Beispiel".into(),
        debtor_iban: "DE89 3704 0044 0532 0130 00".into(),
        debtor_bic: "".into(),
        reference: reference.into(),
        signed_date: "2025-01-15".into(),
        scheme: MandateScheme::Core,
        one_off: false,
        default_amount_cents: 1500,
        default_purpose: "Beitrag".into(),
        note: String::new(),
        active: true,
    }
}

#[test]
fn sequence_follows_the_mandate() {
    assert_eq!(next_sequence(false, None), SequenceType::First);
    assert_eq!(next_sequence(false, Some("")), SequenceType::First);
    assert_eq!(
        next_sequence(false, Some("2026-10-01")),
        SequenceType::Recurring
    );
    assert_eq!(next_sequence(true, None), SequenceType::OneOff);
    assert_eq!(
        next_sequence(true, Some("2026-10-01")),
        SequenceType::OneOff
    );
}

#[test]
fn mandates_are_saved_listed_changed_and_deleted() {
    let (v, _dir) = vault();
    let acc = v.list_accounts().unwrap()[0].id;
    let m = v.save_mandate(None, input(acc, "M-1")).unwrap();
    assert_eq!(m.debtor_iban, "DE89370400440532013000"); // normalised
    assert_eq!(m.next_sequence, "FRST");
    assert_eq!(v.list_mandates(Some(acc)).unwrap().len(), 1);
    assert!(v.list_mandates(Some(acc + 9999)).unwrap().is_empty());

    let mut changed = input(acc, "M-1");
    changed.scheme = MandateScheme::B2b;
    changed.active = false;
    let m2 = v.save_mandate(Some(m.id), changed).unwrap();
    assert_eq!(m2.scheme, MandateScheme::B2b);
    assert!(!m2.active);

    v.delete_mandate(m.id).unwrap();
    assert!(v.list_mandates(None).unwrap().is_empty());
}

#[test]
fn reference_is_unique_per_account_and_input_is_checked() {
    let (v, _dir) = vault();
    let accounts = v.list_accounts().unwrap();
    let (a, b) = (accounts[0].id, accounts[1].id);
    let first = v.save_mandate(None, input(a, "M-1")).unwrap();
    assert!(v.save_mandate(None, input(a, "M-1")).is_err());
    assert!(v.save_mandate(None, input(b, "M-1")).is_ok()); // other creditor account
    assert!(v.save_mandate(Some(first.id), input(a, "M-1")).is_ok()); // itself

    let mut bad = input(a, "M-2");
    bad.debtor_iban = "DE00".into();
    assert!(v.save_mandate(None, bad).is_err());
    let mut bad = input(a, "M-2");
    bad.signed_date = "15.01.2025".into();
    assert!(v.save_mandate(None, bad).is_err());
    let mut bad = input(a, "");
    bad.reference = "  ".into();
    assert!(v.save_mandate(None, bad).is_err());
    let mut bad = input(a, "Müller_2");
    assert!(v.save_mandate(None, bad.clone()).is_err()); // umlaut and underscore
    bad.reference = "/M-2".into();
    assert!(v.save_mandate(None, bad.clone()).is_err());
    let mut bad = input(a, "M-2");
    bad.debtor_bic = "XX".into();
    assert!(v.save_mandate(None, bad).is_err());
}

#[test]
fn creditor_id_is_per_account_with_a_suggestion() {
    let (v, _dir) = vault();
    let accounts = v.list_accounts().unwrap();
    let (a, b) = (accounts[0].id, accounts[1].id);
    assert_eq!(v.creditor_id(a).unwrap(), "");
    assert_eq!(v.suggested_creditor_id().unwrap(), "");
    v.set_creditor_id(a, " de98zzz09999999999 ".into()).unwrap();
    assert_eq!(v.creditor_id(a).unwrap(), "DE98ZZZ09999999999");
    assert_eq!(v.creditor_id(b).unwrap(), "");
    assert_eq!(v.suggested_creditor_id().unwrap(), "DE98ZZZ09999999999");
    assert!(v.set_creditor_id(b, "DE00ZZZ00000000000".into()).is_err());
    v.set_creditor_id(a, "".into()).unwrap();
    assert_eq!(v.creditor_id(a).unwrap(), "");
}

#[test]
fn csv_import_reads_a_member_list_and_reports_faulty_lines() {
    let text = "\u{feff}Name;IBAN;Mandatsreferenz;Datum;Art;Betrag;Zweck;Einmalig\n\
Mia Beispiel;DE89 3704 0044 0532 0130 00;M-1;15.01.2025;CORE;12,50;Beitrag;nein\n\
Jan Muster;DE00;M-2;2025-02-01;;;;\n\
Eva Probe;DE02120300000000202051;M-3;2025-03-01;B2B;;;ja\n";
    let imp = parse_mandate_csv(text.into());
    assert!(imp.problems.is_empty(), "{:?}", imp.problems);
    assert_eq!(imp.rows.len(), 3);
    let a = &imp.rows[0];
    assert_eq!(
        (a.signed_date.as_str(), a.default_amount_cents),
        ("2025-01-15", 1250)
    );
    assert!(a.errors.is_empty());
    assert!(!imp.rows[1].errors.is_empty()); // IBAN
    assert_eq!(imp.rows[2].scheme, MandateScheme::B2b);
    assert!(imp.rows[2].one_off);

    let (v, _dir) = vault();
    let acc = v.list_accounts().unwrap()[0].id;
    let r = v.import_mandate_rows(acc, imp.rows.clone()).unwrap();
    assert_eq!((r.created, r.updated, r.failed.len()), (2, 0, 1));
    assert!(r.failed[0].starts_with("3:"), "{:?}", r.failed);
    // importing again updates by reference
    let r = v.import_mandate_rows(acc, imp.rows).unwrap();
    assert_eq!((r.created, r.updated), (0, 2));
    assert_eq!(v.list_mandates(Some(acc)).unwrap().len(), 2);
}

#[test]
fn csv_without_header_uses_the_default_order_and_flags_a_missing_file() {
    let imp = parse_mandate_csv("Mia;DE89370400440532013000;M-1;2025-01-15".into());
    assert_eq!(imp.rows.len(), 1);
    assert!(imp.rows[0].errors.is_empty());
    assert!(!parse_mandate_csv(String::new()).problems.is_empty());
    let bad = parse_mandate_csv("Name;IBAN\nMia;DE89370400440532013000".into());
    assert!(!bad.problems.is_empty());
}

#[test]
fn collection_files_are_grouped_by_scheme_and_sequence() {
    let (v, _dir) = vault();
    let acc = v.list_accounts().unwrap()[0].id;
    let a = v.save_mandate(None, input(acc, "M-A")).unwrap();
    let b = v.save_mandate(None, input(acc, "M-B")).unwrap();
    let mut oneoff = input(acc, "M-C");
    oneoff.one_off = true;
    let c = v.save_mandate(None, oneoff).unwrap();
    let items = |ids: &[i64]| {
        ids.iter()
            .map(|&mandate_id| CollectionItem {
                mandate_id,
                amount_cents: 1500,
                purpose: String::new(),
                last_collection: false,
            })
            .collect::<Vec<_>>()
    };

    // no creditor ID yet
    assert!(v
        .build_collection_files(acc, items(&[a.id]), "2026-12-01".into())
        .is_err());
    v.set_creditor_id(acc, "DE98ZZZ09999999999".into()).unwrap();
    assert!(v
        .build_collection_files(acc, vec![], "2026-12-01".into())
        .is_err());
    assert!(v
        .build_collection_files(acc, items(&[a.id]), "01.12.2026".into())
        .is_err());

    let files = v
        .build_collection_files(acc, items(&[a.id, b.id, c.id]), "2026-12-01".into())
        .unwrap();
    assert_eq!(files.len(), 2); // CORE/FRST (a, b) and CORE/OOFF (c)
    let frst = files.iter().find(|f| f.sequence == "FRST").unwrap();
    assert_eq!((frst.count, frst.total_cents), (2, 3000));
    assert!(frst.xml.contains("<SeqTp>FRST</SeqTp>") && frst.xml.contains("<MndtId>M-A</MndtId>"));
    assert!(frst.xml.contains("<EndToEndId>M-A-20261201</EndToEndId>"));
    assert_eq!(frst.file_name, "lastschrift-CORE-FRST-2026-12-01.xml");
    assert!(files.iter().any(|f| f.sequence == "OOFF" && f.count == 1));

    // after the run the next collection of a recurring mandate is RCUR
    v.mark_collected(frst.mandate_ids.clone(), "2026-12-01".into())
        .unwrap();
    assert_eq!(v.mandate(a.id).unwrap().unwrap().next_sequence, "RCUR");
    assert_eq!(v.mandate(c.id).unwrap().unwrap().next_sequence, "OOFF");
    let again = v
        .build_collection_files(acc, items(&[a.id]), "2027-01-02".into())
        .unwrap();
    assert_eq!(again[0].sequence, "RCUR");
    // an earlier due date never moves the last collection back
    v.mark_collected(vec![a.id], "2026-06-01".into()).unwrap();
    assert_eq!(
        v.mandate(a.id).unwrap().unwrap().last_collected.as_deref(),
        Some("2026-12-01")
    );

    // inactive and foreign mandates are refused
    let mut off = input(acc, "M-D");
    off.active = false;
    let d = v.save_mandate(None, off).unwrap();
    assert!(v
        .build_collection_files(acc, items(&[d.id]), "2027-01-02".into())
        .is_err());
    assert!(v
        .build_collection_files(acc + 1, items(&[a.id]), "2027-01-02".into())
        .is_err());
}

#[test]
fn a_pain008_file_is_imported_as_mandates_with_their_sequence() {
    let (v, _dir) = vault();
    let acc = v.list_accounts().unwrap()[0].clone();
    let iban = acc.iban.clone();
    let acc = acc.id;
    let xml = |seq: &str, iban: &str| {
        format!(
            "<Document><CstmrDrctDbtInitn><PmtInf><PmtTpInf><LclInstrm><Cd>CORE</Cd></LclInstrm><SeqTp>{seq}</SeqTp></PmtTpInf>\
<ReqdColltnDt>2026-11-30</ReqdColltnDt><CdtrAcct><Id><IBAN>{iban}</IBAN></Id></CdtrAcct>\
<CdtrSchmeId><Id><PrvtId><Othr><Id>DE98ZZZ09999999999</Id></Othr></PrvtId></Id></CdtrSchmeId>\
<DrctDbtTxInf><PmtId><EndToEndId>E1</EndToEndId></PmtId><InstdAmt Ccy=\"EUR\">12.50</InstdAmt>\
<DrctDbtTx><MndtRltdInf><MndtId>M-IMP</MndtId><DtOfSgntr>2024-03-01</DtOfSgntr></MndtRltdInf></DrctDbtTx>\
<Dbtr><Nm>Mia Beispiel</Nm></Dbtr><DbtrAcct><Id><IBAN>DE89370400440532013000</IBAN></Id></DbtrAcct>\
<RmtInf><Ustrd>Beitrag</Ustrd></RmtInf></DrctDbtTxInf></PmtInf></CstmrDrctDbtInitn></Document>"
        )
    };
    // a file of another creditor account is refused
    assert!(v
        .import_pain008(acc, xml("RCUR", "DE02120300000000202051"))
        .is_err());
    assert!(v.import_pain008(acc, "<Document/>".into()).is_err());

    let r = v.import_pain008(acc, xml("RCUR", &iban)).unwrap();
    assert_eq!(
        (r.created, r.updated, r.failed.len()),
        (1, 0, 0),
        "{:?}",
        r.failed
    );
    let m = &v.list_mandates(Some(acc)).unwrap()[0];
    assert_eq!(
        (m.reference.as_str(), m.default_amount_cents),
        ("M-IMP", 1250)
    );
    assert_eq!(m.next_sequence, "RCUR"); // taken over from the file
    assert_eq!(v.creditor_id(acc).unwrap(), "DE98ZZZ09999999999");
    // importing it again updates the mandate
    let r = v.import_pain008(acc, xml("RCUR", &iban)).unwrap();
    assert_eq!((r.created, r.updated), (0, 1));
    // a first collection stays FRST
    v.delete_mandate(m.id).unwrap();
    v.import_pain008(acc, xml("FRST", &iban)).unwrap();
    assert_eq!(v.list_mandates(Some(acc)).unwrap()[0].next_sequence, "FRST");
}

#[test]
fn csv_export_is_read_back_by_the_import() {
    let (v, _dir) = vault();
    let acc = v.list_accounts().unwrap()[0].id;
    let mut tricky = input(acc, "M-1");
    tricky.debtor_name = "Muster; \"Bau\" GmbH".into();
    tricky.active = false;
    v.save_mandate(None, tricky).unwrap();
    let mut b2b = input(acc, "M-2");
    b2b.scheme = MandateScheme::B2b;
    b2b.one_off = true;
    v.save_mandate(None, b2b).unwrap();
    let csv = v.export_mandates_csv(acc).unwrap();
    let back = parse_mandate_csv(csv);
    assert!(back.problems.is_empty(), "{:?}", back.problems);
    assert!(
        back.rows.iter().all(|r| r.errors.is_empty()),
        "{:?}",
        back.rows
    );
    let m1 = back.rows.iter().find(|r| r.reference == "M-1").unwrap();
    assert_eq!(m1.debtor_name, "Muster; \"Bau\" GmbH");
    assert!(!m1.active);
    let m2 = back.rows.iter().find(|r| r.reference == "M-2").unwrap();
    assert!(m2.one_off && m2.scheme == MandateScheme::B2b && m2.active);
    assert_eq!(m2.default_amount_cents, 1500);
}

#[test]
fn the_last_collection_is_final() {
    let (v, _dir) = vault();
    let acc = v.list_accounts().unwrap()[0].id;
    v.set_creditor_id(acc, "DE98ZZZ09999999999".into()).unwrap();
    let m = v.save_mandate(None, input(acc, "M-F")).unwrap();
    v.mark_collected(vec![m.id], "2026-10-01".into()).unwrap();
    let item = |last| {
        vec![CollectionItem {
            mandate_id: m.id,
            amount_cents: 1500,
            purpose: String::new(),
            last_collection: last,
        }]
    };
    let f = v
        .build_collection_files(acc, item(true), "2026-12-01".into())
        .unwrap();
    assert_eq!(f[0].sequence, "FNAL");
    assert!(f[0].xml.contains("<SeqTp>FNAL</SeqTp>"));
    // a first collection cannot be final
    let m2 = v.save_mandate(None, input(acc, "M-G")).unwrap();
    let it = vec![CollectionItem {
        mandate_id: m2.id,
        amount_cents: 1500,
        purpose: String::new(),
        last_collection: true,
    }];
    assert_eq!(
        v.build_collection_files(acc, it, "2026-12-01".into())
            .unwrap()[0]
            .sequence,
        "FRST"
    );
}
