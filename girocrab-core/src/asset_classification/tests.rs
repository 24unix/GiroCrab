use super::*;
use AssetClass as A;
use ClassificationSource as S;
use InstrumentKind as I;
fn h(isin: &str, name: &str) -> Holding {
    Holding {
        isin: isin.into(),
        name: name.into(),
        ..Default::default()
    }
}
fn classify(isin: &str, name: &str) -> AssetClassification {
    classify_asset(
        h(isin, name),
        ClassificationValues::default(),
        ClassificationValues::default(),
        false,
    )
}
#[test]
fn normalizes_and_checks_identifiers_without_inventing_identity() {
    assert_eq!(
        normalized_isin(" us0378331005 ").as_deref(),
        Some("US0378331005")
    );
    for invalid in [
        "",
        "US0378331006",
        "US0378 31005",
        "DE000000000A",
        "123456789012",
        "💶0378331005",
    ] {
        assert_eq!(normalized_isin(invalid), None, "{invalid}");
    }
    assert_eq!(classify("", "Some fund").security_key, None);
    assert_eq!(classify("BROKEN", "Some fund").security_key, None);
    assert_eq!(
        classify("US0378331005", "").security_key.as_deref(),
        Some("isin:US0378331005")
    );
}
#[test]
fn exact_examples_cover_shares_bonds_equity_etfs_multiasset_and_gold() {
    for (isin, asset, instrument) in [
        ("US0378331005", A::Equity, I::SingleSecurity),
        ("DE0008404005", A::Equity, I::SingleSecurity),
        ("DE0001102580", A::Bond, I::SingleSecurity),
        ("IE00B4L5Y983", A::Equity, I::Etf),
        ("IE00BKM4GZ66", A::Equity, I::Etf),
        ("IE00BK5BQT80", A::Equity, I::Etf),
        ("LU0360863863", A::MultiAsset, I::Fund),
        ("DE000A0S9GB0", A::Commodity, I::EtcEtn),
    ] {
        assert!(normalized_isin(isin).is_some(), "{isin}");
        let c = classify(isin, "");
        assert_eq!((c.asset_class, c.instrument), (asset, instrument));
        assert_eq!(
            (c.asset_class_source, c.instrument_source),
            (S::Rule, S::Rule)
        );
    }
}
#[test]
fn wrappers_and_exposure_are_independent_and_ambiguous_names_stay_unknown() {
    for (name, asset, instrument) in [
        ("Unbekannter UCITS ETF", A::Unclassified, I::Etf),
        ("Amundi UCITS", A::Unclassified, I::Unclassified),
        ("Gold Mining UCITS ETF", A::Equity, I::Etf),
        ("Gold Producers Fund", A::Equity, I::Fund),
        ("Euro Government Bond UCITS ETF", A::Bond, I::Etf),
        ("Money Market UCITS ETF", A::Cash, I::Etf),
        ("Offener Immobilienfonds", A::RealEstate, I::Fund),
        ("Real Estate UCITS ETF", A::Equity, I::Etf),
        ("Bitcoin ETN", A::Crypto, I::EtcEtn),
        ("Gold ETC", A::Commodity, I::EtcEtn),
        ("Multi Asset Equity Bond Fund", A::MultiAsset, I::Fund),
        ("Equity Bond Fund", A::Unclassified, I::Fund),
        ("ETF ETN", A::Unclassified, I::Unclassified),
        ("Bitcoin Warrant", A::Unclassified, I::Derivative),
        ("Gold 3x Leveraged ETN", A::Unclassified, I::EtcEtn),
    ] {
        let c = classify("", name);
        assert_eq!((c.asset_class, c.instrument), (asset, instrument), "{name}");
    }
}
#[test]
fn each_axis_respects_user_import_rules_precedence_and_reset() {
    let holding = h("IE00B4L5Y983", "MSCI World ETF");
    let imported = ClassificationValues {
        asset_class: Some(A::Bond),
        instrument: Some(I::Fund),
    };
    let user = ClassificationValues {
        asset_class: Some(A::Other),
        instrument: None,
    };
    let c = classify_asset(holding.clone(), imported.clone(), user, false);
    assert_eq!((c.asset_class, c.asset_class_source), (A::Other, S::User));
    assert_eq!((c.instrument, c.instrument_source), (I::Fund, S::Import));
    let reset = classify_asset(
        holding.clone(),
        imported,
        ClassificationValues::default(),
        false,
    );
    assert_eq!(
        (reset.asset_class, reset.asset_class_source),
        (A::Bond, S::Import)
    );
    let only_wrapper = classify_asset(
        h("", "Generic ETF"),
        ClassificationValues {
            asset_class: None,
            instrument: Some(I::Etf),
        },
        ClassificationValues::default(),
        false,
    );
    assert_eq!(
        (only_wrapper.asset_class, only_wrapper.instrument),
        (A::Unclassified, I::Etf)
    );
    let unknown_import = ClassificationValues {
        asset_class: Some(A::Unclassified),
        instrument: Some(I::Unclassified),
    };
    assert_eq!(
        classify_asset(
            holding,
            unknown_import,
            ClassificationValues::default(),
            false
        )
        .asset_class,
        A::Equity
    );
}
#[test]
fn direct_crypto_requires_connector_confirmation_and_supported_identity() {
    let mut holding = h("", "Bitcoin");
    holding.wkn = " btc ".into();
    let c = classify_asset(
        holding.clone(),
        ClassificationValues::default(),
        ClassificationValues::default(),
        true,
    );
    assert_eq!(c.security_key.as_deref(), Some("crypto:BTC"));
    assert_eq!((c.asset_class, c.instrument), (A::Crypto, I::DirectHolding));
    let untrusted = classify_asset(
        holding.clone(),
        ClassificationValues::default(),
        ClassificationValues::default(),
        false,
    );
    assert_eq!(untrusted.security_key, None);
    assert_eq!(untrusted.asset_class, A::Unclassified);
    holding.wkn = "UNKNOWN".into();
    assert_eq!(
        classify_asset(
            holding.clone(),
            ClassificationValues::default(),
            ClassificationValues::default(),
            true
        )
        .security_key,
        None
    );
    holding.isin = "DE000A0S9GB0".into();
    holding.wkn = "BTC".into();
    assert_eq!(
        classify_asset(
            holding,
            ClassificationValues::default(),
            ClassificationValues::default(),
            true
        )
        .instrument,
        I::EtcEtn
    );
}
#[test]
fn stable_keys_and_other_are_distinct_from_unclassified() {
    for a in [
        A::Unclassified,
        A::Equity,
        A::Bond,
        A::RealEstate,
        A::Commodity,
        A::Crypto,
        A::Cash,
        A::MultiAsset,
        A::Other,
    ] {
        assert_eq!(A::from_db(a.as_str()), a);
    }
    for i in [
        I::Unclassified,
        I::SingleSecurity,
        I::Etf,
        I::Fund,
        I::EtcEtn,
        I::Derivative,
        I::DirectHolding,
        I::Other,
    ] {
        assert_eq!(I::from_db(i.as_str()), i);
    }
    assert_eq!(A::from_db("future"), A::Unclassified);
    assert_eq!(I::from_db("future"), I::Unclassified);
    assert_ne!(A::Other, A::Unclassified);
}

#[cfg(feature = "serde")]
#[test]
fn serde_uses_the_stable_classification_keys() {
    assert_eq!(
        serde_json::to_string(&A::MultiAsset).unwrap(),
        "\"multi_asset\""
    );
    assert_eq!(
        serde_json::to_string(&I::SingleSecurity).unwrap(),
        "\"single\""
    );
    let input = ClassificationValues {
        asset_class: Some(A::Bond),
        instrument: None,
    };
    let json = serde_json::to_string(&input).unwrap();
    assert_eq!(
        serde_json::from_str::<ClassificationValues>(&json).unwrap(),
        input
    );
}
