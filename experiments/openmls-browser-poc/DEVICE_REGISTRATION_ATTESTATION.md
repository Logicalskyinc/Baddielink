# Device Registration Attestation and Trust Model

**Status:** Proposed protocol contract for the isolated `feat/e2ee-browser-validation` branch. This document defines the next implementation gate; it does not implement registration or authorize production use.

## 1. Security objective

An MLS signature proves that a message was signed by the private key corresponding to an MLS credential. It does not, by itself, prove that the credential belongs to an authenticated BaddieLink account, that the device is registered, or that the device is still authorized.

Every admission or credential update must therefore carry an independently verifiable registration attestation. Every client making an authorization decision must verify it against a configured trust anchor and current-enough device status.

The registration authority authenticates accounts and device registrations. It does not receive MLS private keys, group secrets, or message plaintext.

## 2. Cryptographic profile for the prototype

Use a standard signed container rather than signing ad hoc JSON:

- **Container:** COSE_Sign1 (RFC 9052).
- **Payload encoding:** deterministic CBOR (RFC 8949 deterministic encoding rules).
- **Attestation signature:** ES256 (ECDSA over P-256 with SHA-256), COSE algorithm identifier `-7`.
- **Signature representation:** COSE's fixed-width raw `r || s` representation, 32 bytes each, not ASN.1 DER.
- **Key identifier:** protected COSE `kid`, resolved only against the locally configured issuer trust store.
- **External AAD:** a fixed protocol context string and version, for example `BaddieLink-MLS-Device-Attestation-v1`.

Why ES256 for the issuer: Web Crypto has broad browser support for P-256 ECDSA verification. The MLS device signing key remains the OpenMLS ED25519 key and is bound as payload data. Do not conflate the issuer signature algorithm with the MLS credential signature algorithm.

This profile is a prototype choice, not a claim that an issuer key or signing service already exists. Before implementation, verify exact COSE library behavior and Web Crypto signature encoding in the pinned Chromium CI environment and supported Safari versions. Do not implement COSE by hand.

## 3. Attestation payload

The COSE_Sign1 payload is a deterministic-CBOR map with this version-1 claim set:

| Claim | Type | Requirement |
|---|---|---|
| `v` | unsigned integer | Must equal `1`. |
| `iss` | text | Stable registration-authority issuer identifier. |
| `sub` | byte string | Opaque, non-PII account subject. Must be pseudonymous in the attestation audience/scope. |
| `aud` | text or byte string | Exact BaddieLink MLS service/environment audience. Test and production audiences must differ. |
| `cred` | byte string | 32 random bytes; exact BasicCredential identity for this device registration. |
| `device` | byte string | Opaque device-registration identifier, not a username or human-readable device name. |
| `sig` | byte string | Exact 32-byte OpenMLS ED25519 signature public key represented by the KeyPackage/LeafNode. |
| `iat` | unsigned integer | Issued-at Unix seconds. |
| `exp` | unsigned integer | Expiration Unix seconds; short-lived registration assertions are preferred. |
| `status` | text | Must equal `active` for admission/update. |
| `rv` | unsigned integer | Monotonically increasing account/device roster or revocation version. |
| `jti` | byte string | Unique random attestation identifier to prevent accidental token reuse and support audit/revocation. |

No email, phone number, display name, or raw account ID may appear in the BasicCredential identity or attestation payload.

The `sub` value must not be a globally stable public account identifier. Prefer a server-generated pseudonym scoped to the MLS service audience. If later requirements demand unlinkability between different private rooms, move to group-scoped pseudonyms and attestations; that requires a separate versioned design because it changes account-to-device roster resolution.

The attestation is visible to clients that receive it. Treat every claim as group-visible metadata, not secret data. The registration service retains the authoritative mapping from account to device registrations.

## 4. Proof of possession during registration

A client must not be able to register an arbitrary public key merely by submitting it with an authenticated account session.

Registration sequence:

1. Client generates its device-specific OpenMLS ED25519 signing key pair locally.
2. Client requests a one-time registration challenge from the authenticated registration service.
3. The service returns a cryptographically random nonce, a short expiry, and a challenge identifier bound server-side to the authenticated account/session and intended device-registration operation.
4. Client signs a domain-separated challenge transcript with the exact ED25519 private key that will be used by OpenMLS. The transcript includes protocol version, challenge ID, nonce, audience, credential ID, and the public-key fingerprint.
5. Service verifies the signature against the submitted OpenMLS ED25519 public key, checks the nonce is unused and unexpired, and consumes the challenge atomically.
6. Only then does the authority issue a COSE_Sign1 attestation binding that credential ID and exact ED25519 public key to the account/device registration.
7. The client stores the attestation with the KeyPackage metadata and presents it to peers when admission is proposed.

The challenge is single-use. Challenge consumption and device registration must be atomic or idempotently reconciled. Replaying a valid proof must not create a second registration.

The signing key used for proof of possession must be the same key whose public bytes are in the attestation and MLS KeyPackage. A separate unrelated key is not sufficient.

## 5. Verification policy

Every verifier must:

1. Decode COSE_Sign1 using a maintained implementation and reject malformed or non-canonical payloads.
2. Require the expected protected algorithm (`ES256`) and a known `kid`; reject algorithm substitution and untrusted issuer keys.
3. Verify the COSE signature over the exact encoded Sig_structure and configured external AAD.
4. Decode deterministic CBOR and validate all required fields, types, lengths, version, issuer, and audience.
5. Require `iat <= now < exp`, with a small explicitly configured clock-skew allowance. Reject excessive token lifetime.
6. Require `status == active`.
7. Compare `cred` byte-for-byte with the BasicCredential identity.
8. Compare `sig` byte-for-byte with the exact KeyPackage or LeafNode signature public key.
9. Check `rv` and device status against a sufficiently fresh authenticated roster/revocation source. A valid signature over an expired or revoked device is not authorization.
10. Reject unknown, duplicate, mismatched, revoked, or ambiguous account/device/credential bindings. Fail closed when the status source is unavailable or too stale for the operation.

A successful local signature check is necessary but not sufficient. Authorization requires both a valid attestation and a policy/status decision.

## 6. Trust anchors, rotation, and revocation

- The client has a small, versioned trust store of issuer public keys. Private issuer keys remain server-side and are never shipped to clients.
- Each key has a `kid`, activation time, retirement time, and explicit status. Unknown `kid` values fail closed.
- Rotation is an authenticated trust-store update signed by an already trusted root or delivered through a separately reviewed application update mechanism. Do not trust a new key merely because it arrived beside an attestation.
- Old issuer public keys remain available only as long as required to verify still-valid attestations. Retirement and emergency compromise procedures must be explicit.
- Attestation expiry bounds how long an offline verifier can rely on an old status assertion. High-risk operations (new member admission, device revocation, account removal, and credential updates) require an online or otherwise strongly fresh status check.
- If revocation/status cannot be checked within the policy freshness window, reject the operation rather than silently accepting stale authorization.
- Revocation records identify the opaque device registration and increment the authoritative roster/revocation version. Clients must not infer revocation solely from a user-facing account label.
- A server-signed attestation does not prove the server is honest. It establishes the configured registration authority as the account/device authorization authority. That trust assumption must be documented to users and reviewed operationally.

## 7. Binding the attestation to MLS objects

The attestation must be supplied alongside each relevant KeyPackage or credential update. The application must compare it with the exact credential and signature key extracted from the MLS object; never trust a detached client-supplied identity string.

Required gates:

| MLS boundary | Required validation |
|---|---|
| Local Add | Validate the candidate KeyPackage credential and signature key against its attestation and current status before calling `MlsGroup::add_members`. |
| Welcome | Stage the Welcome; validate sender, every roster member, and the joining device's own leaf before `into_group`. |
| Standalone Add proposal | Inspect the verified proposal and its KeyPackage; validate before storing it in the proposal queue. |
| Standalone Update proposal | Inspect the replacement LeafNode; validate before storing it in the proposal queue. |
| Incoming Commit | Retain StagedCommit; validate every Add/Update and the authorization policy for removals before merging. |
| Own pending Commit | Apply the same policy to locally initiated membership changes before finalizing/publishing the new epoch. |

For a Commit referencing previously queued proposals, the verifier must resolve and validate the exact proposal objects referenced by that Commit, not just proposals supplied in the current network message.

A removal is not authorized merely because the Commit is cryptographically valid. The application must check that the committer is permitted to remove the target device/account and that the target leaf maps to the intended registration(s).

## 8. Account and device lifecycle semantics

- One account may have multiple registered devices. Each device has a distinct credential ID and independent MLS signing key.
- Revoking one device removes only that device's leaf from each relevant group. Other devices for the account remain members.
- Removing an account from a private group resolves the account's complete active device roster and removes every matching leaf in one coherent membership transition. A partial roster/group mismatch fails closed and requires reconciliation.
- A newly registered device joins at the current epoch. It receives no prior group history by default.
- Account-to-device mapping is resolved by the authenticated registration/authorization service. Do not derive it from display names or user-controlled worker arguments.
- Stable credential IDs and public signing keys are visible to group members and can enable correlation across groups. The current design accepts opaque per-device identifiers for the prototype; production privacy review must decide whether group-scoped credentials/keys are required.

## 9. Failure behavior

All authorization failures are fail-closed:

- No unauthorized proposal is inserted into the pending proposal store.
- No unauthorized staged Commit is merged.
- No unauthorized Welcome is converted into a live group.
- No candidate provider/group state is persisted or installed after a failed check.
- No Welcome, Commit, membership event, plaintext, or successful send result is published before the authorized candidate state is durably committed.
- If a durable commit result is ambiguous, recover and verify the committed generation before publishing any output.
- Do not log attestation payloads, account subjects, device IDs, private keys, challenge secrets, or plaintext. Log only non-sensitive error categories and correlation IDs.

## 10. Implementation and test sequence

1. Add a pure format/validation specification and deterministic test vectors for valid, malformed, tampered, expired, wrong-audience, unknown-issuer, unknown-key, revoked, stale-version, wrong-credential, and wrong-signing-key cases.
2. Select and pin maintained COSE and deterministic-CBOR libraries; verify their exact serialization and signature semantics in Chromium.
3. Implement a worker-side verifier with deterministic test issuer keys. Keep test private keys in test fixtures only; never bundle them in runtime assets.
4. Implement a test registration issuer that validates one-time ED25519 proof-of-possession challenges and emits ES256 COSE_Sign1 attestations.
5. Refactor the Rust/WASM wrapper to expose staged Welcome, verified proposals, and staged Commits without merging or storing them prematurely.
6. Enforce the verifier at every gate in section 7, including local Add and locally initiated removal.
7. Add browser tests for two devices on one account, single-device revocation, account-wide room removal, replayed/expired/revoked attestations, stale status, and new-device no-history behavior.
8. Run the complete existing Rust/WASM/Chromium/OPFS validation workflow.

## 11. Current implementation status and admission gate

The current branch has implemented the following pieces:

- A COSE_Sign1 ES256 verifier with a caller-supplied trusted-issuer list at the Rust-module level.
- Strict version-1 payload claim-set validation: exactly the 12 required claims, text claim names only, and no duplicate or unknown claims.
- OpenMLS KeyPackage deserialization with trailing-byte rejection.
- Extraction of the BasicCredential identity and signature public key from the same parsed KeyPackage object.
- OpenMLS cryptographic validation of the KeyPackage before the extracted binding is returned.
- Native tests for KeyPackage tampering/trailing bytes and attestation signature, claim, audience, credential, key, expiry, status, and roster-version failures.

These pieces are **not yet connected into an admission authorization decision**. In particular:

- The browser worker's `add-member` path currently calls `KeyPackage.from_bytes()` and then `Group.propose_and_commit_add()`. The first call validates MLS cryptographic structure and signatures; it does not validate a device-registration attestation.
- The worker does not yet obtain an authenticated roster version or device-status response.
- No production issuer key, trust-store distribution mechanism, or registration service exists.
- The verifier's current trusted-issuer argument is not an acceptable browser-facing configuration interface. A caller must never be allowed to supply the keys that establish its own trust.
- Therefore, a KeyPackage accepted by the current experimental `add-member` path is **not proven to belong to an authorized BaddieLink account/device**.

Do not treat the current path as production-safe or enable it for real private-group admission. The next implementation gate is to connect the internal trust store to an authoritative registration/roster service and enforce attestation plus fresh roster authorization before any MLS membership mutation or persistence. The browser worker still does not enforce this gate.



### 12.1 Build-controlled issuer trust-store foundation

The branch now has an internal `trusted_issuers` module. It is not exported through wasm-bindgen and accepts no page/worker message configuration. The default Cargo build returns an empty issuer list, so a valid signature from the test fixture is rejected as an unknown issuer. The isolated `attestation-test-issuer` Cargo feature pins the deterministic test issuer public key for explicitly opted-in test artifacts only; it must never be enabled for production WASM.

A native test exercises both build configurations: default builds reject the test issuer, while builds compiled with `--features attestation-test-issuer` recognize that exact issuer. This is a trust-store foundation only. It does not create a production issuer, does not authenticate a roster, and is not yet called by the browser worker's `add-member` path. The feature is a build-time control, not a cryptographic guarantee against a maintainer intentionally shipping a test-feature artifact, so release automation must explicitly build without it and later add an artifact audit.

## 13. Explicit non-goals and current state

This specification does not create a production registration service, issuer key store, trust-store distribution mechanism, revocation API, Supabase schema, or Render service. It does not implement a production OpenMLS StorageProvider or resolve same-origin XSS risk. The dedicated worker remains an execution-isolation mechanism, not a security boundary against malicious same-origin JavaScript.

No production database, service, deployment, or live user identity has been changed. Do not mark device identity or authorization complete until the staged-object gates, trust distribution, revocation freshness, negative tests, and multi-device lifecycle tests are implemented and reviewed.
