# Device Registration Assertion v1

> **Superseded design:** This earlier proposal used EdDSA and an integer-keyed assertion payload. It is not compatible with the implemented verifier and is no longer the selected prototype profile. The canonical profile is documented in [DEVICE_REGISTRATION_ATTESTATION.md](./DEVICE_REGISTRATION_ATTESTATION.md): COSE_Sign1 ES256, deterministic CBOR, and the 12 named claims. Do not implement or issue this superseded format. A future protocol change must be versioned and update both verifier and fixtures together.

**Status:** Proposed protocol contract for the isolated E2EE prototype. Not implemented. Not approved for production.

## 1. Security objective

Bind one MLS leaf's opaque BasicCredential identity and Ed25519 signature public key to one authenticated BaddieLink account device, without exposing account PII or a globally stable account identifier to every private-room participant.

The assertion is an application Authentication Service artifact. It does not replace MLS signature verification, KeyPackage validation, authorization checks, or membership Commit validation.

## 2. Privacy model

Use a different random 128-bit account subject pseudonym for each private group. Devices belonging to the same account receive the same subject pseudonym only within that group. The same account must receive unrelated pseudonyms in different groups.

Each device registration receives:
- A random 256-bit opaque device credential identifier.
- A device-specific Ed25519 MLS signing key pair.
- A random registration serial.
- A group-scoped signed assertion binding the device credential identifier, signing public key, and group-scoped account subject.

Do not place a username, email, phone number, raw account ID, global account pseudonym, or device label in the MLS BasicCredential identity or group-visible assertion.

The registration authority retains the private mapping from authenticated account/device records to group-scoped pseudonyms. Other group members can identify devices belonging to the same account inside that group, but cannot correlate that account across groups from the assertion alone.

## 3. Credential binding

The MLS BasicCredential identity is the base64url-no-padding encoding of the 32-byte random device credential identifier. The signing public key is the exact Ed25519 public key used by the MLS credential.

The assertion binds both values. The verifier must compare:
- assertion.device_credential_id to the exact BasicCredential identity bytes;
- assertion.mls_signature_key to the exact credential signature public key;
- assertion.group_id to the current MLS group ID;
- assertion.group_account_subject to the authenticated roster's expected account subject;
- assertion.registration_serial and validity window to the current registration status.

No normalization, case folding, Unicode conversion, or display-name fallback is permitted.

## 4. Signed envelope

Use COSE_Sign1 (RFC 9052) with EdDSA (Ed25519) and deterministic CBOR encoding (RFC 8949). The protected COSE headers must contain:
- alg = EdDSA (-8)
- kid = opaque issuer key identifier
- content type = application/baddielink-device-registration+cbor

The payload is a deterministic CBOR map with integer keys to avoid ambiguous field naming:

| Key | Field | Type | Requirement |
|---:|---|---|---|
| 1 | version | uint | exactly 1 |
| 2 | issuer | bstr | opaque issuer identifier |
| 3 | group_id | bstr | exact MLS GroupId bytes |
| 4 | group_account_subject | bstr | random 16-byte group-scoped pseudonym |
| 5 | device_credential_id | bstr | random 32-byte device credential identifier |
| 6 | mls_signature_key | bstr | 32-byte Ed25519 public key |
| 7 | registration_serial | bstr | random 16-byte serial |
| 8 | issued_at | uint | Unix seconds |
| 9 | not_before | uint | Unix seconds |
| 10 | expires_at | uint | Unix seconds |
| 11 | policy | uint | exactly 1 for active-member admission |

Reject unknown critical protected headers, duplicate map keys, non-deterministic encodings, wrong lengths, unsupported versions/algorithms, invalid time ranges, and trailing bytes. COSE verification must use the issuer public key selected by protected kid from a locally trusted issuer-key set. Never trust a public key supplied inside the assertion itself.

### Signing context

The COSE_Sign1 payload is the deterministic CBOR map above. The COSE protected header is included in the standard COSE Sig_structure. Do not create a second custom signature preimage or sign reserialized, non-canonical data.

The registration service signs only after authenticating the account session, validating device registration, and proving possession of the device signing key. The client must not be able to request an assertion for an arbitrary credential ID or public key without that proof.

## 5. Revocation and expiry

An assertion is immutable. Do not mutate a signed assertion from active to revoked.

For v1:
- Assertions have a short bounded lifetime; proposed maximum is 24 hours.
- The authority publishes signed, monotonically versioned revocation snapshots scoped to a group. Each snapshot contains revoked registration_serial values, an issued_at, expires_at, version, and group_id.
- Clients reject stale, expired, rollback, wrong-group, or invalidly signed revocation snapshots.
- Membership additions and commits that introduce/update a credential must be checked against the newest accepted revocation snapshot.
- When a device is revoked, the authority issues a new snapshot and authorized group members create an MLS removal Commit. Revocation of the registration assertion alone does not rotate the MLS epoch or evict a leaf.
- Offline clients must fail closed for membership-changing operations when their revocation snapshot has expired. Existing members may continue local decryption according to the product's offline policy, but must not accept new membership changes using stale authorization data.

The 24-hour maximum and refresh policy are proposed defaults, not a production decision. They require threat-model and availability review.

## 6. Distribution and atomic state

MLS BasicCredential does not carry this assertion. The application must distribute and persist the assertion as authenticated sidecar metadata.

Required behavior:
- A KeyPackage invitation includes the exact assertion for the credential/key in that KeyPackage.
- A joining device receives assertions for the Welcome sender and every member in the staged ratchet tree before accepting the Welcome.
- A Commit delivery includes assertions for every newly added or updated credential, plus the revocation snapshot version used for authorization.
- Each client stores the assertion roster keyed by group ID and MLS leaf index, and cross-checks the credential ID and signature key against the current MLS tree.
- Sidecar roster changes and the MLS provider snapshot must be committed as one logical transaction. If either side fails, neither new roster nor new MLS state may become visible.
- On restore, verify the sidecar assertions and compare them to the restored MLS tree before enabling send/receive.
- Missing, duplicate, stale, or mismatched sidecar data fails closed for group activation and membership mutation. Never infer a binding from a username.

This sidecar distribution is part of the application protocol and still needs a concrete transport/envelope design. It is not present in the current worker.

## 7. Authorization rules

- Device addition: validate the KeyPackage and its assertion before creating the Add Commit.
- Welcome join: validate the sender and all staged tree members against their assertions and current revocation snapshot before into_group.
- Incoming Add/Update proposal: validate the proposal's credential against the assertion before storing it.
- Incoming Commit: validate all Add/Update proposals and removal policy before merge_staged_commit.
- Device revocation: remove only the leaf whose device_credential_id and registration_serial match the authorized revocation request.
- Account removal: resolve all leaves sharing the group_account_subject and remove them in one coherent membership transition.
- Any roster-to-tree mismatch, duplicate device ID, duplicate registration serial, or ambiguous account mapping is a hard error.

A server-issued assertion proves the registration authority's binding decision. It does not prove the authority made a correct account authorization decision; issuer compromise remains a trust-root risk.

## 8. Required negative tests

1. Invalid COSE signature.
2. Unknown issuer kid.
3. Wrong algorithm or content type.
4. Wrong group ID.
5. Wrong credential ID.
6. Wrong MLS signature public key.
7. Expired and not-yet-valid assertion.
8. Duplicate assertion serial or device ID.
9. Revoked registration serial.
10. Stale/expired/rollback revocation snapshot.
11. Assertion missing for one existing Welcome member.
12. Assertion roster mismatched with a staged Commit.
13. Reuse of an assertion with a different KeyPackage key.
14. Same account in two groups receives unrelated group_account_subject values.
15. Two devices in one group share group_account_subject but have distinct device IDs and signing keys.

## 9. Open decisions before implementation

- Select and pin a Rust COSE/CBOR verification implementation compatible with wasm32; audit canonical-encoding enforcement and duplicate-key rejection.
- Confirm browser and Rust support for Ed25519 verification in the project's supported browser matrix.
- Define issuer key provisioning, rotation, overlap, emergency revocation, and recovery.
- Define how signed assertions and revocation snapshots are transported alongside Welcome, Commit, and KeyPackage messages.
- Define how clients obtain fresh revocation snapshots and how offline membership changes are handled.
- Define the transaction boundary that atomically commits the MLS provider snapshot and sidecar assertion roster.
- Define authorization for a client to request account removal or device revocation.

Do not add a cryptographic dependency or implement the envelope until these library and browser compatibility checks are completed.

## 10. Non-goals and current limitations

- No Supabase schema, API, Render service, registration endpoint, or production integration.
- No server-held MLS private keys or message decryption.
- No claim that same-origin JavaScript compromise is prevented by the dedicated worker.
- No production guarantee from IndexedDB/OPFS snapshot persistence.
- No historical message sharing to newly registered devices.
- No account-wide correlation across groups.
