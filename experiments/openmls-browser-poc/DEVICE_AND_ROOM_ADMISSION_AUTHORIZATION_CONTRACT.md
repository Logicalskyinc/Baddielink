# MLS Device and Room Admission Authorization Contract

Status: design contract only. No production endpoint, issuer, authenticated roster, or authorization service is implemented by this document.

This contract defines the server-side authority required before the browser worker may merge or persist MLS membership changes. The browser worker and page are clients, not authorization authorities.

## Security boundary

MLS proves protocol-level facts: message authenticity, KeyPackage validity, epoch consistency, and membership-tree consistency. It does not prove that a BaddieLink account is allowed to enter a particular room.

The server must independently authorize the account, device, room, and requested membership operation. The client must never supply or override trusted issuer keys, account ownership, role, roster version, or authorization outcome.

## Separate the two decisions

### 1. Device registration

A device registration assertion binds one authenticated BaddieLink account and registered device to the exact MLS credential and signature public key.

The issuer must:
- Derive the account from the authenticated server session, not request JSON.
- Verify that the device is registered, active, and not revoked for that account.
- Verify that the requested credential and signature key were registered for that device.
- Issue a short-lived signed assertion with a unique token identifier.
- Record issuance and revocation state server-side.

A device assertion alone does not grant access to any room.

### 2. Room-scoped membership authorization

Before a membership-changing MLS Commit is merged, the server must authorize the exact room and operation.

The authorization must bind:
- Opaque MLS group identifier.
- Authenticated acting account and device.
- Operation: add, update, or remove.
- Target device/account and exact credential/signature-key binding for add/update.
- Target leaf identity/index binding for remove, resolved against the authoritative current roster rather than trusted from the browser.
- Current server-side roster version.
- A unique, single-use authorization identifier.
- Short issuance and expiry times.

Do not reuse the existing generic device-attestation audience as the only room binding. The current 12-claim verifier schema has no explicit group identifier or operation claim. A room authorization assertion therefore requires a separately versioned schema or an explicitly room-scoped audience with equivalent exact binding. Do not silently change the existing v1 claim set.

## Proposed API contract

These are interface requirements, not live routes.

### Request authorization

`POST /api/mls/rooms/{groupId}/membership-authorizations`

Authenticated session required. CSRF protection applies when cookie authentication is used.

Example request:

```json
{
  "operation": "add",
  "target": {
    "accountReference": "opaque-server-issued-reference",
    "deviceReference": "opaque-server-issued-reference",
    "credentialId": "base64url-credential-bytes",
    "signatureKey": "base64url-public-key-bytes"
  },
  "expectedRosterVersion": 42,
  "mlsCommitDigest": "base64url-sha256-digest"
}
```

The server must not trust the account/device references as proof of identity. It resolves them against the authenticated account and authoritative registration database. The exact MLS target binding must be compared with the validated KeyPackage/LeafNode binding extracted from the MLS object, never with separately supplied client metadata.

For remove, the server resolves the target from the current room roster and verifies the acting account's room-management permission. It must not accept a caller-selected leaf index as authoritative.

### Response

Return a signed, short-lived room authorization assertion containing at minimum:

- Schema version.
- Issuer and exact audience.
- Group identifier.
- Operation.
- Actor account/device binding.
- Target binding (or server-resolved target for remove).
- Roster version.
- MLS Commit digest.
- Issued-at and expiry.
- Unique authorization ID.

The signature must use a server-held private key. The browser must verify it against an issuer trust anchor compiled/configured outside page-controlled messages. Production trust configuration remains empty until a real issuer and key-rotation process exist.

### Consume authorization

`POST /api/mls/rooms/{groupId}/membership-authorizations/{authorizationId}/consume`

The server atomically checks:
- Assertion signature and expiry.
- Authorization ID has not already been consumed.
- Roster version is still current.
- Account, device, room, operation, target, and Commit digest still match.
- Device and room permissions remain active.

Consumption must be idempotent for a retry of the same request and authorization ID, but must not authorize a different Commit or target. A compare-and-swap or transaction must prevent two concurrent membership operations from consuming the same roster version.

The browser must not treat a successful local verification as proof that the server has not since revoked the device. The consume step is the authoritative one-time decision. The MLS mutation must only be published after the consume decision succeeds.

## Worker processing sequence

1. Clone the committed provider/group state.
2. Parse and cryptographically process the incoming MLS message.
3. Retain the staged Commit without merging it.
4. Inspect all Add, Update, and Remove proposals from that staged Commit.
5. Reject unsupported proposal types or ambiguous target bindings.
6. Obtain a room-scoped server authorization bound to the exact Commit digest and current roster version.
7. Verify the assertion using the internal trust store.
8. Consume the authorization through the authenticated server endpoint.
9. Merge the staged Commit into the candidate group.
10. Persist the candidate snapshot through the OPFS journal.
11. Publish the candidate in worker memory only after journal recovery confirms the exact committed generation.

Any failure before step 9 discards the candidate. Any persistence failure must leave the previously committed snapshot authoritative. If server consumption succeeds but local persistence fails, recovery must use the same authorization ID and idempotent consume result; it must not mint a different authorization for a different Commit.

## Required rejection cases

The integration suite must prove that each case rejects before group merge and before durable snapshot publication:

- Missing assertion.
- Unknown issuer or key ID.
- Invalid signature.
- Wrong audience or group identifier.
- Wrong operation.
- Wrong actor account/device.
- Wrong target credential or signature key.
- Unknown or revoked device.
- Insufficient room role.
- Stale roster version.
- Commit digest mismatch.
- Expired assertion.
- Replayed authorization ID.
- Concurrent operation that already advanced the roster.
- Server timeout or unavailable authorization service.

For every rejected case, assert that:
- MLS epoch is unchanged.
- Group membership is unchanged.
- OPFS generation and committed bytes are unchanged.
- No Welcome or membership Commit is returned to the caller.
- The failure is observable without logging assertion secrets or private key material.

## Non-goals and prohibited shortcuts

- No page-supplied trusted issuer keys.
- No page-supplied `authorized: true` flag.
- No browser-test feature in production WASM.
- No generic device assertion treated as room membership permission.
- No trust in client-provided role, roster version, leaf index, account ID, or device ID.
- No merge-before-authorization followed by rollback.
- No production enablement while issuer provisioning, key rotation, authenticated roster storage, revocation, and atomic authorization consumption are absent.

## Current implementation boundary

The experimental branch currently has:
- A strict COSE_Sign1 ES256 device-attestation verifier.
- An internal build-controlled issuer trust store with an empty default production configuration.
- Staged MLS Commit inspection for Add, Update, and Remove.
- Production/default worker behavior that rejects membership-changing incoming Commits.
- A separately compiled browser-test admission path for lifecycle tests.

It does not yet have:
- An authenticated registration endpoint.
- An authoritative room roster and permission service.
- A production issuer/private key or trust distribution/rotation process.
- A room-scoped authorization assertion and atomic consume endpoint.
- Worker integration with those server decisions.

Until those components exist and the rejection matrix passes, production membership admission must remain disabled.
