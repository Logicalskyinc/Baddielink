//! Strict verifier for room-scoped MLS membership authorization assertions.
//!
//! This module is intentionally not wired into the worker admission path yet.
//! The default trust store is empty. Do not add a page-facing issuer-key API.

use ciborium::value::Value;
use coset::{iana, CborSerializable, CoseSign1};
use p256::ecdsa::{signature::Verifier, Signature, VerifyingKey};

const EXTERNAL_AAD: &[u8] = b"BaddieLink-MLS-Room-Authorization-v1";
const AUDIENCE: &str = "baddielink-mls-membership";
const MAX_LIFETIME_SECS: u64 = 120;
const CLOCK_SKEW_SECS: u64 = 60;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoomAuthorizationClaims {
    pub issuer: String,
    pub group_id: [u8; 16],
    pub operation: String,
    pub actor_user_id: [u8; 16],
    pub actor_device_id: [u8; 16],
    pub target_user_id: [u8; 16],
    pub target_device_id: [u8; 16],
    pub target_credential_id: [u8; 32],
    pub target_signature_key: [u8; 32],
    pub roster_version: u64,
    pub authorization_id: [u8; 16],
    pub commit_digest: [u8; 32],
    pub issued_at: u64,
    pub expires_at: u64,
}

#[derive(Clone, Debug)]
pub struct RoomAuthorizationIssuerKey {
    pub key_id: Vec<u8>,
    pub public_key: Vec<u8>,
    pub issuer: String,
}

fn canonical_value(value: Value) -> Result<Value, String> {
    match value {
        Value::Array(items) => Ok(Value::Array(
            items.into_iter().map(canonical_value).collect::<Result<Vec<_>, _>>()?,
        )),
        Value::Map(entries) => {
            let mut normalized = Vec::with_capacity(entries.len());
            for (key, value) in entries {
                let key = canonical_value(key)?;
                let value = canonical_value(value)?;
                let mut encoded = Vec::new();
                ciborium::ser::into_writer(&key, &mut encoded)
                    .map_err(|_| "Invalid CBOR map key.".to_owned())?;
                normalized.push((encoded, key, value));
            }
            normalized.sort_by(|a, b| a.0.len().cmp(&b.0.len()).then_with(|| a.0.cmp(&b.0)));
            if normalized.windows(2).any(|pair| pair[0].0 == pair[1].0) {
                return Err("Duplicate CBOR map key.".into());
            }
            Ok(Value::Map(normalized.into_iter().map(|(_, k, v)| (k, v)).collect()))
        }
        Value::Tag(tag, inner) => Ok(Value::Tag(tag, Box::new(canonical_value(*inner)?))),
        other => Ok(other),
    }
}

fn canonical_bytes(value: &Value) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    ciborium::ser::into_writer(&canonical_value(value.clone())?, &mut bytes)
        .map_err(|_| "Could not encode deterministic CBOR.".to_owned())?;
    Ok(bytes)
}

fn claim<'a>(value: &'a Value, name: &str) -> Result<&'a Value, String> {
    let entries = match value {
        Value::Map(entries) => entries,
        _ => return Err("Room authorization payload must be a CBOR map.".into()),
    };
    entries.iter().find_map(|(key, value)| match key {
        Value::Text(key) if key == name => Some(value),
        _ => None,
    }).ok_or_else(|| format!("Missing room authorization claim: {name}."))
}

fn text(value: &Value, name: &str) -> Result<String, String> {
    match claim(value, name)? {
        Value::Text(v) => Ok(v.clone()),
        _ => Err(format!("Claim {name} must be text.")),
    }
}

fn uint(value: &Value, name: &str) -> Result<u64, String> {
    match claim(value, name)? {
        Value::Integer(v) => u64::try_from(*v).map_err(|_| format!("Claim {name} must be an unsigned integer.")),
        _ => Err(format!("Claim {name} must be an unsigned integer.")),
    }
}

fn fixed<const N: usize>(value: &Value, name: &str) -> Result<[u8; N], String> {
    match claim(value, name)? {
        Value::Bytes(v) if v.len() == N => {
            let mut result = [0u8; N];
            result.copy_from_slice(v);
            Ok(result)
        }
        _ => Err(format!("Claim {name} must be a {N}-byte byte string.")),
    }
}

fn validate_exact_claims(value: &Value) -> Result<(), String> {
    const NAMES: [&str; 16] = [
        "v", "iss", "aud", "group", "op", "actor_sub", "actor_device",
        "target_sub", "target_device", "target_cred", "target_sig", "rv",
        "jti", "digest", "iat", "exp",
    ];
    let entries = match value {
        Value::Map(entries) => entries,
        _ => return Err("Room authorization payload must be a CBOR map.".into()),
    };
    if entries.len() != NAMES.len() {
        return Err("Room authorization payload has missing or unexpected claims.".into());
    }
    let mut seen = std::collections::HashSet::with_capacity(NAMES.len());
    for (key, _) in entries {
        let name = match key {
            Value::Text(name) => name.as_str(),
            _ => return Err("Room authorization claim names must be text.".into()),
        };
        if !NAMES.contains(&name) || !seen.insert(name) {
            return Err("Room authorization payload has an unknown or duplicate claim.".into());
        }
    }
    if NAMES.iter().any(|name| !seen.contains(name)) {
        return Err("Room authorization payload is missing a required claim.".into());
    }
    Ok(())
}

/// Verify an attached COSE_Sign1 assertion. Expected actor, group, operation,
/// target binding, roster version and Commit digest must come from trusted
/// local/session state and the exact staged MLS Commit, never UI labels.
pub fn verify_room_authorization(
    envelope: &[u8],
    trusted_issuers: &[RoomAuthorizationIssuerKey],
    expected_group: &[u8; 16],
    expected_operation: &str,
    expected_actor_user: &[u8; 16],
    expected_actor_device: &[u8; 16],
    expected_target_user: &[u8; 16],
    expected_target_device: &[u8; 16],
    expected_target_credential: &[u8; 32],
    expected_target_signature_key: &[u8; 32],
    expected_roster_version: u64,
    expected_commit_digest: &[u8; 32],
    now_unix_secs: u64,
) -> Result<RoomAuthorizationClaims, String> {
    let cose = CoseSign1::from_slice(envelope)
        .map_err(|_| "Malformed room authorization COSE_Sign1.".to_owned())?;
    if cose.payload.is_none() {
        return Err("Detached room authorization payloads are not accepted.".into());
    }
    let protected = &cose.protected.header;
    if protected.alg != Some(coset::RegisteredLabelWithPrivate::Assigned(iana::Algorithm::ES256)) {
        return Err("Room authorization must use protected ES256.".into());
    }
    if protected.key_id.is_empty() || cose.unprotected != coset::Header::default() || !protected.rest.is_empty() {
        return Err("Room authorization requires protected kid and empty unprotected headers.".into());
    }
    let issuer_key = trusted_issuers.iter().find(|key| key.key_id == protected.key_id)
        .ok_or_else(|| "Unknown room authorization issuer key identifier.".to_owned())?;
    let verifying_key = VerifyingKey::from_sec1_bytes(&issuer_key.public_key)
        .map_err(|_| "Configured room authorization issuer key is invalid.".to_owned())?;
    cose.verify_signature(EXTERNAL_AAD, |signature_bytes, signed_bytes| {
        let signature = Signature::from_slice(signature_bytes)
            .map_err(|_| "Room authorization ES256 signature must be 64-byte r||s.".to_owned())?;
        verifying_key.verify(signed_bytes, &signature)
            .map_err(|_| "Room authorization signature verification failed.".to_owned())
    })?;

    let payload = cose.payload.as_ref().ok_or_else(|| "Missing room authorization payload.".to_owned())?;
    let decoded: Value = ciborium::de::from_reader(payload.as_slice())
        .map_err(|_| "Room authorization payload is invalid CBOR.".to_owned())?;
    if canonical_bytes(&decoded)?.as_slice() != payload.as_slice() {
        return Err("Room authorization payload is not deterministic CBOR.".into());
    }
    validate_exact_claims(&decoded)?;

    if uint(&decoded, "v")? != 1 {
        return Err("Unsupported room authorization version.".into());
    }
    let issuer = text(&decoded, "iss")?;
    if issuer != issuer_key.issuer {
        return Err("Room authorization issuer does not match trusted key.".into());
    }
    if text(&decoded, "aud")? != AUDIENCE {
        return Err("Room authorization audience mismatch.".into());
    }
    let group_id = fixed::<16>(&decoded, "group")?;
    let operation = text(&decoded, "op")?;
    let actor_user_id = fixed::<16>(&decoded, "actor_sub")?;
    let actor_device_id = fixed::<16>(&decoded, "actor_device")?;
    let target_user_id = fixed::<16>(&decoded, "target_sub")?;
    let target_device_id = fixed::<16>(&decoded, "target_device")?;
    let target_credential_id = fixed::<32>(&decoded, "target_cred")?;
    let target_signature_key = fixed::<32>(&decoded, "target_sig")?;
    let roster_version = uint(&decoded, "rv")?;
    let authorization_id = fixed::<16>(&decoded, "jti")?;
    let commit_digest = fixed::<32>(&decoded, "digest")?;
    let issued_at = uint(&decoded, "iat")?;
    let expires_at = uint(&decoded, "exp")?;

    if !["add", "update", "remove"].contains(&operation.as_str()) {
        return Err("Unsupported room membership operation.".into());
    }
    if &group_id != expected_group || operation != expected_operation
        || &actor_user_id != expected_actor_user || &actor_device_id != expected_actor_device
        || &target_user_id != expected_target_user || &target_device_id != expected_target_device
        || &target_credential_id != expected_target_credential
        || &target_signature_key != expected_target_signature_key
        || roster_version != expected_roster_version || &commit_digest != expected_commit_digest {
        return Err("Room authorization does not match the staged Commit or trusted context.".into());
    }
    if roster_version == 0 || issued_at > now_unix_secs.saturating_add(CLOCK_SKEW_SECS)
        || expires_at <= now_unix_secs || expires_at <= issued_at
        || expires_at.saturating_sub(issued_at) > MAX_LIFETIME_SECS
        || now_unix_secs.saturating_sub(issued_at) > MAX_LIFETIME_SECS {
        return Err("Room authorization is expired or has an invalid time window.".into());
    }

    Ok(RoomAuthorizationClaims {
        issuer, group_id, operation, actor_user_id, actor_device_id,
        target_user_id, target_device_id, target_credential_id,
        target_signature_key, roster_version, authorization_id,
        commit_digest, issued_at, expires_at,
    })
}


#[cfg(test)]
mod tests {
    use super::*;

    fn valid_claims() -> Value {
        let values = [
            ("v", Value::Integer(1.into())),
            ("iss", Value::Text("baddielink-test-issuer".into())),
            ("aud", Value::Text(AUDIENCE.into())),
            ("group", Value::Bytes(vec![1; 16])),
            ("op", Value::Text("add".into())),
            ("actor_sub", Value::Bytes(vec![2; 16])),
            ("actor_device", Value::Bytes(vec![3; 16])),
            ("target_sub", Value::Bytes(vec![4; 16])),
            ("target_device", Value::Bytes(vec![5; 16])),
            ("target_cred", Value::Bytes(vec![6; 32])),
            ("target_sig", Value::Bytes(vec![7; 32])),
            ("rv", Value::Integer(9.into())),
            ("jti", Value::Bytes(vec![8; 16])),
            ("digest", Value::Bytes(vec![10; 32])),
            ("iat", Value::Integer(1_800_000_000u64.into())),
            ("exp", Value::Integer(1_800_000_090u64.into())),
        ];
        Value::Map(values.into_iter().map(|(k, v)| (Value::Text(k.into()), v)).collect())
    }

    use coset::{CoseSign1Builder, HeaderBuilder};
    use p256::ecdsa::SigningKey;

    const TEST_NOW: u64 = 1_800_000_100;

    fn signed_fixture(aad: &[u8]) -> (Vec<u8>, Vec<RoomAuthorizationIssuerKey>) {
        let signing_key = SigningKey::from_bytes((&[11u8; 32]).into()).expect("test issuer key");
        let public_key = signing_key.verifying_key().to_encoded_point(false).as_bytes().to_vec();
        let key_id = b"room-auth-test-key".to_vec();
        let mut value = valid_claims();
        if let Value::Map(entries) = &mut value {
            for (key, claim) in entries {
                match key {
                    Value::Text(name) if name == "iat" => *claim = Value::Integer(1_800_000_090u64.into()),
                    Value::Text(name) if name == "exp" => *claim = Value::Integer(1_800_000_180u64.into()),
                    _ => {}
                }
            }
        }
        let payload = canonical_bytes(&value).expect("canonical claims");
        let envelope = CoseSign1Builder::new()
            .protected(HeaderBuilder::new()
                .algorithm(iana::Algorithm::ES256)
                .key_id(key_id.clone())
                .build())
            .payload(payload)
            .create_signature(aad, |data| {
                use p256::ecdsa::signature::Signer;
                let signature: Signature = signing_key.sign(data);
                signature.to_bytes().to_vec()
            })
            .build()
            .to_vec()
            .expect("COSE room authorization");
        (envelope, vec![RoomAuthorizationIssuerKey {
            key_id, public_key, issuer: "baddielink-test-issuer".into(),
        }])
    }

    fn verify_fixture(
        envelope: &[u8], issuers: &[RoomAuthorizationIssuerKey], now: u64,
    ) -> Result<RoomAuthorizationClaims, String> {
        verify_room_authorization(
            envelope, issuers, &[1; 16], "add", &[2; 16], &[3; 16], &[4; 16],
            &[5; 16], &[6; 32], &[7; 32], 9, &[10; 32], now,
        )
    }

    #[test]
    fn accepts_exact_v1_claim_set() {
        assert!(validate_exact_claims(&valid_claims()).is_ok());
    }

    #[test]
    fn rejects_missing_claim() {
        let mut value = valid_claims();
        if let Value::Map(entries) = &mut value {
            entries.retain(|(key, _)| key != &Value::Text("digest".into()));
        }
        assert!(validate_exact_claims(&value).is_err());
    }

    #[test]
    fn rejects_unknown_claim_even_when_count_is_correct() {
        let mut value = valid_claims();
        if let Value::Map(entries) = &mut value {
            entries[0].0 = Value::Text("unexpected".into());
        }
        assert!(validate_exact_claims(&value).is_err());
    }

    #[test]
    fn rejects_duplicate_claim_names() {
        let mut value = valid_claims();
        if let Value::Map(entries) = &mut value {
            entries[1].0 = Value::Text("v".into());
        }
        assert!(validate_exact_claims(&value).is_err());
    }

    #[test]
    fn rejects_non_text_claim_names() {
        let mut value = valid_claims();
        if let Value::Map(entries) = &mut value {
            entries[0].0 = Value::Integer(0.into());
        }
        assert!(validate_exact_claims(&value).is_err());
    }

    #[test]
    fn canonical_encoding_is_stable_and_order_independent() {
        let first = valid_claims();
        let mut second = valid_claims();
        if let (Value::Map(a), Value::Map(b)) = (&mut second, &first) {
            a.reverse();
            assert_eq!(canonical_bytes(&Value::Map(a.clone())).unwrap(), canonical_bytes(&Value::Map(b.clone())).unwrap());
        } else {
            panic!("test claims must be maps");
        }
    }

    #[test]
    fn rejects_duplicate_cbor_map_keys_during_canonicalization() {
        let duplicate = Value::Map(vec![
            (Value::Text("v".into()), Value::Integer(1.into())),
            (Value::Text("v".into()), Value::Integer(1.into())),
        ]);
        assert!(canonical_bytes(&duplicate).is_err());
    }

    #[test]
    fn rejects_wrong_claim_types_and_fixed_lengths() {
        let mut wrong_type = valid_claims();
        if let Value::Map(entries) = &mut wrong_type {
            let entry = entries.iter_mut().find(|(k, _)| k == &Value::Text("rv".into())).unwrap();
            entry.1 = Value::Text("9".into());
        }
        assert!(uint(&wrong_type, "rv").is_err());

        let mut wrong_length = valid_claims();
        if let Value::Map(entries) = &mut wrong_length {
            let entry = entries.iter_mut().find(|(k, _)| k == &Value::Text("group".into())).unwrap();
            entry.1 = Value::Bytes(vec![1; 15]);
        }
        assert!(fixed::<16>(&wrong_length, "group").is_err());
    }
    #[test]
    fn accepts_valid_signed_room_authorization() {
        let (envelope, issuers) = signed_fixture(EXTERNAL_AAD);
        let claims = verify_fixture(&envelope, &issuers, TEST_NOW).expect("valid assertion");
        assert_eq!(claims.operation, "add");
        assert_eq!(claims.roster_version, 9);
        assert_eq!(claims.issued_at, 1_800_000_090);
        assert_eq!(claims.expires_at, 1_800_000_180);
    }

    #[test]
    fn rejects_tampered_signature_and_unknown_issuer_key() {
        let (mut envelope, issuers) = signed_fixture(EXTERNAL_AAD);
        let last = envelope.len() - 1;
        envelope[last] ^= 1;
        assert!(verify_fixture(&envelope, &issuers, TEST_NOW).is_err());
        let (envelope, _) = signed_fixture(EXTERNAL_AAD);
        assert!(verify_fixture(&envelope, &[], TEST_NOW).is_err());
    }

    #[test]
    fn rejects_signature_created_with_wrong_external_aad() {
        let (envelope, issuers) = signed_fixture(b"incorrect-external-aad");
        assert!(verify_fixture(&envelope, &issuers, TEST_NOW).is_err());
    }

    #[test]
    fn rejects_expired_and_future_issued_assertions() {
        let (envelope, issuers) = signed_fixture(EXTERNAL_AAD);
        assert!(verify_fixture(&envelope, &issuers, 1_800_000_181).is_err());
        assert!(verify_fixture(&envelope, &issuers, 1_800_000_000).is_err());
    }

    #[test]
    fn rejects_mismatched_group_actor_target_roster_and_commit_digest() {
        let (envelope, issuers) = signed_fixture(EXTERNAL_AAD);
        assert!(verify_room_authorization(
            &envelope, &issuers, &[99; 16], "add", &[2; 16], &[3; 16], &[4; 16],
            &[5; 16], &[6; 32], &[7; 32], 9, &[10; 32], TEST_NOW,
        ).is_err());
        assert!(verify_room_authorization(
            &envelope, &issuers, &[1; 16], "remove", &[2; 16], &[3; 16], &[4; 16],
            &[5; 16], &[6; 32], &[7; 32], 9, &[10; 32], TEST_NOW,
        ).is_err());
        assert!(verify_room_authorization(
            &envelope, &issuers, &[1; 16], "add", &[99; 16], &[3; 16], &[4; 16],
            &[5; 16], &[6; 32], &[7; 32], 9, &[10; 32], TEST_NOW,
        ).is_err());
        assert!(verify_room_authorization(
            &envelope, &issuers, &[1; 16], "add", &[2; 16], &[3; 16], &[4; 16],
            &[5; 16], &[6; 32], &[7; 32], 10, &[10; 32], TEST_NOW,
        ).is_err());
        assert!(verify_room_authorization(
            &envelope, &issuers, &[1; 16], "add", &[2; 16], &[3; 16], &[4; 16],
            &[5; 16], &[6; 32], &[7; 32], 9, &[77; 32], TEST_NOW,
        ).is_err());
    }


}
