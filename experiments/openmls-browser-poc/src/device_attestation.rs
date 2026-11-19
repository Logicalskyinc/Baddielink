//! Experimental verifier for signed device-registration attestations.
//!
//! COSE and signature verification are implemented in Rust so native tests and
//! the browser WASM runtime exercise the same code. This module is not wired into
//! MLS admission until staged-object authorization is implemented.

use ciborium::value::Value;
use coset::{iana, CborSerializable, CoseSign1};
use p256::ecdsa::{signature::Verifier, Signature, VerifyingKey};

const EXTERNAL_AAD: &[u8] = b"BaddieLink-MLS-Device-Attestation-v1";
const MAX_ATTESTATION_LIFETIME_SECS: u64 = 7 * 24 * 60 * 60;
const CLOCK_SKEW_SECS: u64 = 60;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceAttestationClaims {
    pub issuer: String,
    pub subject: Vec<u8>,
    pub audience: String,
    pub credential_id: Vec<u8>,
    pub device_id: Vec<u8>,
    pub signature_key: Vec<u8>,
    pub issued_at: u64,
    pub expires_at: u64,
    pub roster_version: u64,
    pub token_id: Vec<u8>,
}

#[derive(Clone, Debug)]
pub struct TrustedIssuerKey {
    pub key_id: Vec<u8>,
    /// SEC1 encoded P-256 public key (compressed or uncompressed).
    pub public_key: Vec<u8>,
    pub issuer: String,
}

fn fail(message: &str) -> String {
    message.to_owned()
}

fn canonical_cbor(value: &Value) -> Result<Vec<u8>, String> {
    let normalized = canonical_value(value.clone())?;
    let mut output = Vec::new();
    ciborium::ser::into_writer(&normalized, &mut output)
        .map_err(|_| fail("Could not encode canonical attestation CBOR."))?;
    Ok(output)
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
                let encoded_key = canonical_cbor_key(&key)?;
                normalized.push((encoded_key, key, value));
            }
            normalized.sort_by(|a, b| {
                a.0.len().cmp(&b.0.len()).then_with(|| a.0.cmp(&b.0))
            });
            for pair in normalized.windows(2) {
                if pair[0].0 == pair[1].0 {
                    return Err(fail("Duplicate CBOR map key."));
                }
            }
            Ok(Value::Map(normalized.into_iter().map(|(_, k, v)| (k, v)).collect()))
        }
        Value::Tag(tag, inner) => Ok(Value::Tag(tag, Box::new(canonical_value(*inner)?))),
        other => Ok(other),
    }
}

fn canonical_cbor_key(value: &Value) -> Result<Vec<u8>, String> {
    let mut output = Vec::new();
    ciborium::ser::into_writer(value, &mut output)
        .map_err(|_| fail("Could not encode CBOR map key."))?;
    Ok(output)
}

fn map_claim<'a>(value: &'a Value, name: &str) -> Result<&'a Value, String> {
    let entries = match value {
        Value::Map(entries) => entries,
        _ => return Err(fail("Attestation payload must be a CBOR map.")),
    };
    entries.iter()
        .find_map(|(key, value)| match key {
            Value::Text(key) if key == name => Some(value),
            _ => None,
        })
        .ok_or_else(|| format!("Missing attestation claim: {name}."))
}

fn validate_claim_set(value: &Value) -> Result<(), String> {
    const REQUIRED: [&str; 12] = [
        "v", "iss", "sub", "aud", "cred", "device",
        "sig", "iat", "exp", "status", "rv", "jti",
    ];
    let entries = match value {
        Value::Map(entries) => entries,
        _ => return Err(fail("Attestation payload must be a CBOR map.")),
    };
    if entries.len() != REQUIRED.len() {
        return Err(fail("Attestation payload contains missing or unexpected claims."));
    }

    let mut seen = std::collections::HashSet::with_capacity(entries.len());
    for (key, _) in entries {
        let name = match key {
            Value::Text(name) => name.as_str(),
            _ => return Err(fail("Attestation claim names must be text strings.")),
        };
        if !REQUIRED.contains(&name) {
            return Err(fail("Attestation payload contains an unknown claim."));
        }
        if !seen.insert(name) {
            return Err(fail("Attestation payload contains a duplicate claim."));
        }
    }
    if REQUIRED.iter().any(|name| !seen.contains(name)) {
        return Err(fail("Attestation payload is missing a required claim."));
    }
    Ok(())
}

fn text_claim(value: &Value, name: &str) -> Result<String, String> {
    match map_claim(value, name)? {
        Value::Text(text) => Ok(text.clone()),
        _ => Err(format!("Attestation claim {name} must be text.")),
    }
}

fn bytes_claim(value: &Value, name: &str, min: usize, max: usize) -> Result<Vec<u8>, String> {
    match map_claim(value, name)? {
        Value::Bytes(bytes) if (min..=max).contains(&bytes.len()) => Ok(bytes.clone()),
        _ => Err(format!("Attestation claim {name} has an invalid byte-string length.")),
    }
}

fn uint_claim(value: &Value, name: &str) -> Result<u64, String> {
    match map_claim(value, name)? {
        Value::Integer(number) => u64::try_from(*number)
            .map_err(|_| format!("Attestation claim {name} must be an unsigned integer.")),
        _ => Err(format!("Attestation claim {name} must be an unsigned integer.")),
    }
}

/// Verify a complete attached COSE_Sign1 envelope and its version-1 payload.
///
/// `expected_credential_id` and `expected_signature_key` must be extracted
/// from the exact MLS KeyPackage or LeafNode being authorized, not supplied as
/// independent user-controlled identity labels.
pub fn verify_device_attestation(
    envelope: &[u8],
    trusted_issuers: &[TrustedIssuerKey],
    expected_audience: &str,
    expected_credential_id: &[u8],
    expected_signature_key: &[u8],
    expected_roster_version: u64,
    now_unix_secs: u64,
) -> Result<DeviceAttestationClaims, String> {
    let cose = CoseSign1::from_slice(envelope)
        .map_err(|_| fail("Malformed COSE_Sign1 attestation."))?;
    if cose.payload.is_none() {
        return Err(fail("Detached COSE payloads are not accepted."));
    }
    let protected = &cose.protected.header;
    if protected.alg != Some(coset::RegisteredLabelWithPrivate::Assigned(iana::Algorithm::ES256)) {
        return Err(fail("Attestation must use protected ES256 algorithm."));
    }
    if protected.key_id.is_empty() || cose.unprotected != coset::Header::default() || !protected.rest.is_empty() {
        return Err(fail("COSE key identifier must be protected and unprotected headers must be empty."));
    }
    let issuer_key = trusted_issuers.iter()
        .find(|key| key.key_id == protected.key_id)
        .ok_or_else(|| fail("Unknown attestation issuer key identifier."))?;
    let verifying_key = VerifyingKey::from_sec1_bytes(&issuer_key.public_key)
        .map_err(|_| fail("Configured issuer public key is invalid."))?;

    cose.verify_signature(EXTERNAL_AAD, |signature_bytes, signed_bytes| {
        let signature = Signature::from_slice(signature_bytes)
            .map_err(|_| fail("ES256 signature must be 64-byte COSE r||s."))?;
        verifying_key.verify(signed_bytes, &signature)
            .map_err(|_| fail("Attestation signature verification failed."))
    })?;

    let payload = cose.payload.as_ref()
        .ok_or_else(|| fail("Detached COSE payloads are not accepted."))?;
    let decoded: Value = ciborium::de::from_reader(payload.as_slice())
        .map_err(|_| fail("Attestation payload is not valid CBOR."))?;
    if canonical_cbor(&decoded)?.as_slice() != payload.as_slice() {
        return Err(fail("Attestation payload is not deterministic CBOR."));
    }

    validate_claim_set(&decoded)?;

    let version = uint_claim(&decoded, "v")?;
    if version != 1 {
        return Err(fail("Unsupported device attestation version."));
    }
    let issuer = text_claim(&decoded, "iss")?;
    if issuer != issuer_key.issuer {
        return Err(fail("Attestation issuer claim does not match trusted key."));
    }
    let audience = text_claim(&decoded, "aud")?;
    if audience != expected_audience {
        return Err(fail("Attestation audience mismatch."));
    }
    let subject = bytes_claim(&decoded, "sub", 16, 64)?;
    let credential_id = bytes_claim(&decoded, "cred", 32, 32)?;
    let device_id = bytes_claim(&decoded, "device", 16, 64)?;
    let signature_key = bytes_claim(&decoded, "sig", 32, 32)?;
    let token_id = bytes_claim(&decoded, "jti", 16, 64)?;
    let issued_at = uint_claim(&decoded, "iat")?;
    let expires_at = uint_claim(&decoded, "exp")?;
    let roster_version = uint_claim(&decoded, "rv")?;
    let status = text_claim(&decoded, "status")?;

    if credential_id != expected_credential_id {
        return Err(fail("Attested credential identifier does not match MLS credential."));
    }
    if signature_key != expected_signature_key {
        return Err(fail("Attested signing key does not match MLS credential key."));
    }
    if status != "active" {
        return Err(fail("Device registration is not active."));
    }
    if roster_version != expected_roster_version {
        return Err(fail("Attestation roster version is stale or does not match the trusted current roster."));
    }
    if issued_at > now_unix_secs.saturating_add(CLOCK_SKEW_SECS)
        || expires_at <= now_unix_secs.saturating_sub(CLOCK_SKEW_SECS)
        || expires_at <= issued_at
        || expires_at.saturating_sub(issued_at) > MAX_ATTESTATION_LIFETIME_SECS
    {
        return Err(fail("Attestation is expired, not yet valid, or has an invalid lifetime."));
    }

    Ok(DeviceAttestationClaims {
        issuer,
        subject,
        audience,
        credential_id,
        device_id,
        signature_key,
        issued_at,
        expires_at,
        roster_version,
        token_id,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use coset::{CoseSign1Builder, HeaderBuilder};
    use p256::ecdsa::SigningKey;

    fn payload(status: &str, audience: &str, credential: &[u8], device_key: &[u8]) -> Vec<u8> {
        let value = Value::Map(vec![
            (Value::Text("v".into()), Value::Integer(1.into())),
            (Value::Text("iss".into()), Value::Text("baddielink-test-issuer".into())),
            (Value::Text("sub".into()), Value::Bytes(vec![1; 16])),
            (Value::Text("aud".into()), Value::Text(audience.into())),
            (Value::Text("cred".into()), Value::Bytes(credential.to_vec())),
            (Value::Text("device".into()), Value::Bytes(vec![2; 16])),
            (Value::Text("sig".into()), Value::Bytes(device_key.to_vec())),
            (Value::Text("iat".into()), Value::Integer(1_800_000_000u64.into())),
            (Value::Text("exp".into()), Value::Integer(1_800_003_600u64.into())),
            (Value::Text("status".into()), Value::Text(status.into())),
            (Value::Text("rv".into()), Value::Integer(7u64.into())),
            (Value::Text("jti".into()), Value::Bytes(vec![3; 16])),
        ]);
        canonical_cbor(&value).expect("canonical payload")
    }

    fn fixture(status: &str, audience: &str, credential: &[u8], device_key: &[u8]) -> (Vec<u8>, Vec<TrustedIssuerKey>, Vec<u8>) {
        let signing_key = SigningKey::from_bytes((&[9u8; 32]).into()).expect("issuer signing key");
        let public_key = signing_key.verifying_key().to_sec1_point(false).as_bytes().to_vec();
        let key_id = b"test-issuer-key-1".to_vec();
        let envelope = CoseSign1Builder::new()
            .protected(HeaderBuilder::new()
                .algorithm(iana::Algorithm::ES256)
                .key_id(key_id.clone())
                .build())
            .payload(payload(status, audience, credential, device_key))
            .create_signature(EXTERNAL_AAD, |data| {
                use p256::ecdsa::signature::Signer;
                let signature: Signature = signing_key.sign(data);
                signature.to_bytes().to_vec()
            })
            .build()
            .to_vec()
            .expect("COSE envelope");
        (envelope, vec![TrustedIssuerKey {
            key_id,
            public_key,
            issuer: "baddielink-test-issuer".into(),
        }], credential.to_vec())
    }

    #[test]
    fn rejects_unknown_duplicate_and_non_text_claim_names() {
        let unknown = Value::Map(vec![
            (Value::Text("v".into()), Value::Integer(1.into())),
            (Value::Text("unexpected".into()), Value::Integer(2.into())),
        ]);
        assert!(validate_claim_set(&unknown).is_err());

        let duplicate = Value::Map(vec![
            (Value::Text("v".into()), Value::Integer(1.into())),
            (Value::Text("v".into()), Value::Integer(1.into())),
        ]);
        assert!(validate_claim_set(&duplicate).is_err());

        let non_text = Value::Map(vec![
            (Value::Integer(1.into()), Value::Integer(1.into())),
        ]);
        assert!(validate_claim_set(&non_text).is_err());
    }

    #[test]
    fn accepts_valid_signed_attestation_and_binds_credential_and_key() {
        let credential = vec![4; 32];
        let device_key = vec![5; 32];
        let (envelope, issuers, _) = fixture("active", "baddielink-test", &credential, &device_key);
        let claims = verify_device_attestation(
            &envelope, &issuers, "baddielink-test", &credential, &device_key, 7, 1_800_000_100,
        ).expect("valid attestation");
        assert_eq!(claims.credential_id, credential);
        assert_eq!(claims.signature_key, device_key);
        assert_eq!(claims.roster_version, 7);
    }

    #[test]
    fn build_configured_trust_store_controls_test_issuer_acceptance() {
        let credential = vec![4; 32];
        let device_key = vec![5; 32];
        let (envelope, _fixture_issuers, _) =
            fixture("active", "baddielink-test", &credential, &device_key);
        let configured = crate::trusted_issuers::configured_issuers();
        let result = verify_device_attestation(
            &envelope,
            &configured,
            "baddielink-test",
            &credential,
            &device_key,
            7,
            1_800_000_100,
        );

        #[cfg(feature = "attestation-test-issuer")]
        assert!(result.is_ok(), "explicit test build should pin its test issuer");

        #[cfg(not(feature = "attestation-test-issuer"))]
        assert_eq!(
            result.unwrap_err(),
            "Unknown attestation issuer key identifier.",
            "default build must not trust the test issuer"
        );
    }

    #[test]
    fn rejects_tampered_signature() {
        let credential = vec![4; 32];
        let device_key = vec![5; 32];
        let (mut envelope, issuers, _) = fixture("active", "baddielink-test", &credential, &device_key);
        let last = envelope.len() - 1;
        envelope[last] ^= 1;
        assert!(verify_device_attestation(
            &envelope, &issuers, "baddielink-test", &credential, &device_key, 7, 1_800_000_100,
        ).is_err());
    }

    #[test]
    fn rejects_wrong_audience_and_credential_binding() {
        let credential = vec![4; 32];
        let device_key = vec![5; 32];
        let (envelope, issuers, _) = fixture("active", "baddielink-test", &credential, &device_key);
        assert!(verify_device_attestation(
            &envelope, &issuers, "production", &credential, &device_key, 7, 1_800_000_100,
        ).is_err());
        assert!(verify_device_attestation(
            &envelope, &issuers, "baddielink-test", &[8; 32], &device_key, 7, 1_800_000_100,
        ).is_err());
    }

    #[test]
    fn rejects_stale_roster_version() {
        let credential = vec![4; 32];
        let device_key = vec![5; 32];
        let (envelope, issuers, _) = fixture("active", "baddielink-test", &credential, &device_key);
        assert!(verify_device_attestation(
            &envelope, &issuers, "baddielink-test", &credential, &device_key, 8, 1_800_000_100,
        ).is_err());
    }

    #[test]
    fn rejects_inactive_expired_and_mismatched_key_attestations() {
        let credential = vec![4; 32];
        let device_key = vec![5; 32];
        let (revoked, issuers, _) = fixture("revoked", "baddielink-test", &credential, &device_key);
        assert!(verify_device_attestation(
            &revoked, &issuers, "baddielink-test", &credential, &device_key, 7, 1_800_000_100,
        ).is_err());
        let (expired, issuers, _) = fixture("active", "baddielink-test", &credential, &device_key);
        assert!(verify_device_attestation(
            &expired, &issuers, "baddielink-test", &credential, &device_key, 7, 1_800_010_000,
        ).is_err());
        assert!(verify_device_attestation(
            &expired, &issuers, "baddielink-test", &credential, &[6; 32], 7, 1_800_000_100,
        ).is_err());
    }
}
