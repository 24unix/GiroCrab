use super::*;

fn candidate(kind: &str) -> Rah10BankKeyCandidate {
    let key = rsa::PrivateKey::new(&mut getrandom::SysRng, 2048)
        .unwrap()
        .to_public_key();
    let mut c = Rah10BankKeyCandidate {
        blz: "12345678".into(),
        user_id: "bank".into(),
        key_type: kind.into(),
        number: 1,
        version: 1,
        public_key_der: key.to_public_key_der().unwrap().as_bytes().to_vec(),
        fingerprint: String::new(),
        bits: 2048,
    };
    c.fingerprint = fingerprint(&public_key(&c).unwrap()).unwrap();
    c
}

fn key_segment(c: &Rah10BankKeyCandidate, number: u32) -> Vec<u8> {
    let key = public_key(c).unwrap().key;
    let n = key.n_bytes();
    let e = key.e_bytes();
    let mut segment = SegmentBuilder::new("HIISA", number, 3)
        .raw("1")
        .raw("dialog")
        .raw("1")
        .raw("224")
        .raw(&format!(
            "280:{}:{}:{}:{}:{}",
            c.blz, c.user_id, c.key_type, c.number, c.version
        ))
        .build();
    segment.pop();
    segment.extend_from_slice(format!("+6:19:10:@{}@", n.len()).as_bytes());
    segment.extend(n);
    segment.extend_from_slice(format!(":12:@{}@", e.len()).as_bytes());
    segment.extend(e);
    segment.extend_from_slice(b":13'");
    segment
}

#[test]
fn bootstrap_is_anonymous_and_returns_only_untrusted_candidates() {
    let request = request("12345678", "test-product", "0.1");
    let parsed = syntax::parse(&request).unwrap();
    assert_eq!(parsed.iter().filter(|s| s.id() == "HKISA").count(), 2);
    assert_eq!(parsed[1].get(2, 0), "9999999999");
    assert!(!parsed
        .iter()
        .any(|s| matches!(s.id(), "HNSHK" | "HNSHA" | "HNVSD")));
    let a = candidate("S");
    let b = candidate("V");
    let raw = message(&[key_segment(&a, 2), key_segment(&b, 3)], "dialog", 1);
    let (_, result) = parse_candidates(&raw, "12345678").unwrap();
    assert_eq!(result[0].fingerprint, a.fingerprint);
    assert_eq!(result[1].public_key_der, b.public_key_der);
    assert!(parse_candidates(&raw, "87654321").is_err());
    for end in 0..raw.len() {
        assert!(parse_candidates(&raw[..end], "12345678").is_err());
    }
    assert!(parse_candidates(&message(&[key_segment(&a, 2)], "dialog", 1), "12345678").is_err());
    assert!(parse_candidates(
        &message(&[key_segment(&a, 2), key_segment(&a, 3)], "dialog", 1),
        "12345678"
    )
    .is_err());
}

#[test]
fn only_independently_confirmed_fingerprints_can_be_pinned() {
    let keys = vec![candidate("S"), candidate("V")];
    let expected: Vec<_> = keys.iter().map(|k| k.fingerprint.clone()).collect();
    assert!(confirmed_keys("12345678", &keys, &expected).is_ok());
    assert!(confirmed_keys("12345678", &keys, &[]).is_err());
    assert!(confirmed_keys("12345678", &keys, &["00".repeat(32), expected[1].clone()]).is_err());
    let mut tampered = keys.clone();
    tampered[0].public_key_der = candidate("S").public_key_der;
    assert!(confirmed_keys("12345678", &tampered, &expected).is_err());
    let mut tampered = keys.clone();
    tampered[1].key_type = "S".into();
    assert!(confirmed_keys("12345678", &tampered, &expected).is_err());
    assert!(confirmed_keys("87654321", &keys, &expected).is_err());
    let spaced: Vec<_> = expected
        .iter()
        .map(|s| {
            s.as_bytes()
                .chunks(2)
                .map(|p| std::str::from_utf8(p).unwrap().to_lowercase())
                .collect::<Vec<_>>()
                .join(" ")
        })
        .collect();
    assert!(confirmed_keys("12345678", &keys, &spaced).is_ok());
    // Revalidate after persistence; an edited or corrupted pin must fail closed.
    let json = serde_json::to_string(&SavedBankKeys {
        candidates: keys,
        expected,
    })
    .unwrap();
    let mut restored: SavedBankKeys = serde_json::from_str(&json).unwrap();
    assert!(confirmed_keys("12345678", &restored.candidates, &restored.expected).is_ok());
    restored.expected[0] = "00".repeat(32);
    assert!(confirmed_keys("12345678", &restored.candidates, &restored.expected).is_err());
}

#[test]
fn ini_fingerprint_matches_fixed_padded_big_endian_vector() {
    // Public, invented numbers; reference SHA-256 independently calculated with hashlib.
    let rsa = PublicKey::new(
        BoxedUint::from_be_slice_vartime(&[0x81; 256]),
        BoxedUint::from(65537u64),
    )
    .unwrap();
    let key = BankKey {
        blz: "12345678".into(),
        user_id: "bank".into(),
        kind: 0,
        number: 1,
        version: 1,
        key: rsa,
    };
    assert_eq!(
        fingerprint(&key).unwrap(),
        "F26C6259E5CDFC2717EBFF4ADB6D60BB6A607531E0B0BE41F7A8FF014FA6754B"
    );
}
