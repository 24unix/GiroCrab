//! FirstKeyReq / HIISA bootstrap. Downloaded keys remain untrusted until an
//! independently obtained fingerprint is supplied and checked by the core.
//! Wire layout and hash convention: HBCI4Java hbci-300.xml and INILetter.
use std::sync::Arc;

use rsa::{
    pkcs8::{DecodePublicKey, EncodePublicKey},
    traits::PublicKeyParts,
    BoxedUint, PublicKey,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use super::{
    keyfile::{BankKey, KeyFile},
    product_id, rah10,
    syntax::{self, SegmentBuilder, Value},
};
use crate::{
    error::{CoreError, CoreResult},
    Vault,
};

pub const KEY_SOURCE: &str = "https://www.commerzbank.de/service/kommunikationsadressen-ports-und-oeffentlicher-bankschluessel-fuer-hbci/";

#[derive(Clone, Serialize, Deserialize, uniffi::Record)]
pub struct Rah10BankKeyCandidate {
    pub blz: String,
    pub user_id: String,
    pub key_type: String,
    pub number: u16,
    pub version: u16,
    pub public_key_der: Vec<u8>,
    pub fingerprint: String,
    pub bits: u32,
}

#[derive(uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Rah10KeyfileInfo {
    pub blz: String,
    pub needs_bank_keys: bool,
}

fn invalid(message: &str) -> CoreError {
    CoreError::InvalidInput {
        message: message.into(),
    }
}

fn public_key(candidate: &Rah10BankKeyCandidate) -> CoreResult<BankKey> {
    if candidate.public_key_der.len() > 2048
        || candidate.user_id.is_empty()
        || candidate.user_id.len() > 30
        || !candidate.user_id.is_ascii()
        || candidate.blz.len() != 8
        || !candidate.blz.bytes().all(|b| b.is_ascii_digit())
    {
        return Err(invalid("Bankschlüssel-Metadaten ungültig."));
    }
    let kind = match candidate.key_type.as_str() {
        "S" => 0,
        "V" => 1,
        _ => return Err(invalid("Unbekannte Bankschlüsselart.")),
    };
    let key = PublicKey::from_public_key_der(&candidate.public_key_der)
        .map_err(|_| invalid("Öffentlicher RSA-Bankschlüssel ungültig."))?;
    if key.n().bit_width() < 1984
        || key.n().bit_width() > 8192
        || key.e().bit_width() > 32
        || key.e().bit_width() < 2
    {
        return Err(invalid(
            "RSA-Parameter des Bankschlüssels werden nicht unterstützt.",
        ));
    }
    Ok(BankKey {
        blz: candidate.blz.clone(),
        user_id: candidate.user_id.clone(),
        kind,
        number: candidate.number,
        version: candidate.version,
        key,
    })
}

/// INI-letter fingerprint: SHA-256(padded big-endian exponent || modulus).
fn fingerprint(key: &BankKey) -> CoreResult<String> {
    let modulus = key.key.n_bytes();
    let exponent = key.key.e_bytes();
    let size = modulus.len().max(128);
    if exponent.len() > size {
        return Err(invalid("RSA-Exponent ungültig."));
    }
    let mut data = vec![0u8; 2 * size];
    data[size - exponent.len()..size].copy_from_slice(&exponent);
    data[2 * size - modulus.len()..].copy_from_slice(&modulus);
    Ok(hex::encode_upper(Sha256::digest(&data)))
}

pub(crate) fn key_candidate(key: &BankKey) -> CoreResult<Rah10BankKeyCandidate> {
    Ok(Rah10BankKeyCandidate {
        blz: key.blz.clone(),
        user_id: key.user_id.clone(),
        key_type: if key.kind == 0 {
            "S".into()
        } else {
            "V".into()
        },
        number: key.number,
        version: key.version,
        public_key_der: key
            .key
            .to_public_key_der()
            .map_err(|_| invalid("RSA-Schlüssel ungültig."))?
            .as_bytes()
            .to_vec(),
        fingerprint: fingerprint(key)?,
        bits: key.key.n().bit_width(),
    })
}

fn normalized_hash(value: &str) -> CoreResult<String> {
    let value: String = value
        .chars()
        .filter(|c| !c.is_whitespace() && *c != ':')
        .collect();
    if value.len() != 64 || !value.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err(invalid("Bitte den vollständigen SHA-256-Prüfwert (64 Hex-Zeichen) aus einer unabhängigen Commerzbank-Quelle eingeben."));
    }
    Ok(value.to_ascii_uppercase())
}

/// Also called when reading saved pins: no UI-computed value is trusted.
pub(crate) fn confirmed_keys(
    blz: &str,
    candidates: &[Rah10BankKeyCandidate],
    expected: &[String],
) -> CoreResult<Vec<BankKey>> {
    if candidates.len() != 2 || expected.len() != 2 {
        return Err(invalid(
            "Signatur- und Verschlüsselungsschlüssel müssen separat bestätigt werden.",
        ));
    }
    let mut result = Vec::new();
    for (candidate, expected) in candidates.iter().zip(expected) {
        if candidate.blz != blz {
            return Err(invalid(
                "Bankschlüssel gehört zu einer anderen Bankleitzahl.",
            ));
        }
        let key = public_key(candidate)?;
        let actual = fingerprint(&key)?;
        if normalized_hash(expected)? != actual || candidate.fingerprint != actual {
            return Err(invalid("Der Bankschlüssel stimmt nicht mit dem unabhängig bestätigten Prüfwert überein. Keine Übernahme."));
        }
        if result.iter().any(|k: &BankKey| k.kind == key.kind) {
            return Err(invalid("Bankschlüsselart doppelt vorhanden."));
        }
        result.push(key);
    }
    Ok(result)
}

#[derive(Serialize, Deserialize)]
pub(crate) struct SavedBankKeys {
    pub candidates: Vec<Rah10BankKeyCandidate>,
    pub expected: Vec<String>,
}

#[uniffi::export]
pub fn inspect_rah10_keyfile(bytes: Vec<u8>, password: String) -> CoreResult<Rah10KeyfileInfo> {
    let bytes = Zeroizing::new(bytes);
    let password = Zeroizing::new(password);
    let file = KeyFile::open(&bytes, password.as_bytes())?;
    if file.identities.len() != 1 {
        return Err(invalid(
            "Bitte eine Schlüsseldatei mit genau einem Bankzugang verwenden.",
        ));
    }
    let identity = &file.identities[0];
    if !matches!(
        identity.host.as_str(),
        "hbci.commerzbank.de" | "fints.commerzbank.de"
    ) {
        return Err(invalid(
            "Die Schlüsseldatei enthält keinen unterstützten Commerzbank-Zugang.",
        ));
    }
    let needs_bank_keys = [0, 1].iter().any(|kind| {
        !file
            .bank_keys
            .iter()
            .any(|k| k.blz == identity.blz && k.kind == *kind)
    });
    Ok(Rah10KeyfileInfo {
        blz: identity.blz.clone(),
        needs_bank_keys,
    })
}

fn message(payload: &[Vec<u8>], dialog: &str, number: u32) -> Vec<u8> {
    let build = |size| {
        let mut bytes = SegmentBuilder::new("HNHBK", 1, 3)
            .raw(&format!("{size:012}"))
            .raw("300")
            .de(&[dialog])
            .raw(&number.to_string())
            .build();
        for segment in payload {
            bytes.extend_from_slice(segment);
        }
        bytes.extend(
            SegmentBuilder::new("HNHBS", payload.len() as u32 + 2, 1)
                .raw(&number.to_string())
                .build(),
        );
        bytes
    };
    build(build(0).len())
}

fn request(blz: &str, product: &str, version: &str) -> Vec<u8> {
    message(
        &[
            SegmentBuilder::new("HKIDN", 2, 2)
                .raw(&format!("280:{blz}"))
                .raw("9999999999")
                .raw("0")
                .raw("0")
                .build(),
            SegmentBuilder::new("HKVVB", 3, 3)
                .raw("0")
                .raw("0")
                .raw("0")
                .de(&[product])
                .de(&[version])
                .build(),
            SegmentBuilder::new("HKISA", 4, 3)
                .raw("2")
                .raw("124")
                .raw("RAH:10")
                .raw(&format!("280:{blz}:999:V:999:999"))
                .build(),
            SegmentBuilder::new("HKISA", 5, 3)
                .raw("2")
                .raw("124")
                .raw("RAH:10")
                .raw(&format!("280:{blz}:999:S:999:999"))
                .build(),
        ],
        "0",
        1,
    )
}

fn parse_candidates(raw: &[u8], blz: &str) -> CoreResult<(String, Vec<Rah10BankKeyCandidate>)> {
    let segments = syntax::parse(raw)?;
    let head = segments
        .first()
        .filter(|s| s.id() == "HNHBK")
        .ok_or_else(|| invalid("Unvollständige Antwort beim Bankschlüsselabruf."))?;
    if head.get(1, 0).parse::<usize>().ok() != Some(raw.len())
        || head.get(4, 0) != "1"
        || segments
            .last()
            .is_none_or(|s| s.id() != "HNHBS" || s.get(1, 0) != "1")
    {
        return Err(invalid(
            "Ungültige Nachrichtenhülle beim Bankschlüsselabruf.",
        ));
    }
    // Unauthenticated error text is not forwarded; never accept accounts or keys on error.
    if segments
        .iter()
        .filter(|s| matches!(s.id(), "HIRMG" | "HIRMS"))
        .any(|s| {
            s.elements
                .iter()
                .skip(1)
                .any(|e| e.first().is_some_and(|v| v.text().starts_with('9')))
        })
    {
        return Err(invalid(
            "Der Bankschlüsselabruf wurde abgelehnt. Die Antwort ist noch nicht authentifiziert.",
        ));
    }
    let mut result = Vec::new();
    for segment in segments.iter().filter(|s| s.id() == "HIISA") {
        if segment.version() != 3
            || segment.get(1, 0) != "1"
            || segment.get(4, 0) != "224"
            || segment.get(5, 0) != "280"
            || segment.get(5, 1) != blz
            || segment.get(6, 2) != "10"
        {
            return Err(invalid("Unerwartete Bankschlüssel-Antwort."));
        }
        let component = |index| match segment.element(6).get(index) {
            Some(Value::Binary(b)) if !b.is_empty() && b.len() <= 1024 => Ok(b.as_slice()),
            _ => Err(invalid("RSA-Schlüsselmaterial fehlt.")),
        };
        let rsa = PublicKey::new_with_size_limits(
            BoxedUint::from_be_slice_vartime(component(3)?),
            BoxedUint::from_be_slice_vartime(component(5)?),
            1984..=8192,
        )
        .map_err(|_| invalid("RSA-Schlüssel ungültig."))?;
        let mut candidate = Rah10BankKeyCandidate {
            blz: blz.into(),
            user_id: segment.get(5, 2).into(),
            key_type: segment.get(5, 3).into(),
            number: segment
                .get(5, 4)
                .parse()
                .map_err(|_| invalid("Schlüsselnummer ungültig."))?,
            version: segment
                .get(5, 5)
                .parse()
                .map_err(|_| invalid("Schlüsselversion ungültig."))?,
            public_key_der: rsa
                .to_public_key_der()
                .map_err(|_| invalid("RSA-Schlüssel ungültig."))?
                .as_bytes()
                .to_vec(),
            fingerprint: String::new(),
            bits: 0,
        };
        let key = public_key(&candidate)?;
        candidate = key_candidate(&key)?;
        if result
            .iter()
            .any(|k: &Rah10BankKeyCandidate| k.key_type == candidate.key_type)
        {
            return Err(invalid(
                "Mehrere Bankschlüssel derselben Art empfangen; keine automatische Auswahl.",
            ));
        }
        result.push(candidate);
    }
    if result.len() != 2
        || !result.iter().any(|k| k.key_type == "S")
        || !result.iter().any(|k| k.key_type == "V")
    {
        return Err(invalid(
            "Signatur- und Verschlüsselungsschlüssel wurden nicht vollständig geliefert.",
        ));
    }
    Ok((head.get(3, 0).into(), result))
}

#[uniffi::export(async_runtime = "tokio")]
impl Vault {
    /// Anonymous first-key request: only BLZ and registered software ID are sent.
    /// Returns candidates without storing or trusting them. No user keys or PINs.
    pub async fn rah10_bank_key_candidates(
        self: Arc<Self>,
        blz: String,
    ) -> CoreResult<Vec<Rah10BankKeyCandidate>> {
        if blz.len() != 8 || !blz.bytes().all(|b| b.is_ascii_digit()) {
            return Err(invalid("Ungültige Bankleitzahl."));
        }
        crate::banking_gate::check_connector(&format!("fints:{blz}:rah10"))?;
        let mode = self
            .get_setting(product_id::MODE_KEY.into())?
            .unwrap_or_default();
        let own = Zeroizing::new(
            self.get_setting(product_id::OWN_KEY.into())?
                .unwrap_or_default(),
        );
        let (_, id) =
            product_id::resolve(&mode, &own).ok_or_else(|| CoreError::MissingSetting {
                key: product_id::OWN_KEY.into(),
            })?;
        let id = Zeroizing::new(id);
        let version = self
            .get_setting("fints.product_version".into())?
            .unwrap_or_else(|| "0.1".into());
        let mut stream = None;
        let raw = rah10::exchange(&mut stream, &request(&blz, &id, &version)).await?;
        let (dialog, keys) = parse_candidates(&raw, &blz)?;
        if !dialog.is_empty() && dialog != "0" && dialog.len() <= 30 {
            let end = message(
                &[SegmentBuilder::new("HKEND", 2, 1).de(&[&dialog]).build()],
                &dialog,
                2,
            );
            let _ = rah10::exchange(&mut stream, &end).await;
        }
        Ok(keys)
    }
}

#[cfg(test)]
mod tests;
