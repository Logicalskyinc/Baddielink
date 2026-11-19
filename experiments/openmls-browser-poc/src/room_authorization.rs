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
