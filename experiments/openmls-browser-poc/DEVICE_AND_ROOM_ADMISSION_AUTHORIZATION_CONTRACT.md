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

## Authoritative per-room device roster

The server must maintain a projection of admitted MLS devices for each mapped room. It is separate from `space_memberships`: the latter authorizes an account to participate in the BaddieLink room, while the MLS roster records the exact devices/credentials currently admitted to that room.

Each roster entry binds `space_id`, registered `device_id`, `user_id`, a stable SHA-256 hash of the serialized MLS BasicCredential identity, and the exact MLS signature public key. The raw credential identity is not used as a database key. The roster does not store a leaf index. MLS leaf indexes are tree-local and can change; the worker resolves a Remove proposal's leaf index against the current authenticated MLS group and returns the corresponding credential hash/key for comparison with the server-authorized target.

The initial device registry treats a device's identifier, credential hash, and signature key as immutable. A revoked device identifier cannot be registered again for the same account. An MLS Update that retains the registered credential/key binding can be authorized; a key or credential rotation is rejected until a separate proof-of-possession rotation flow exists. A device can instead be replaced by registering a new device, admitting it with Add, then removing the old device. Account deletion is also blocked while device/roster/audit records remain; an explicit MLS cleanup and audit-retention workflow must run first so deletion cannot silently orphan a live MLS leaf.

Existing rooms cannot be backfilled from account membership alone. Their MLS device roster starts empty until a separately authorized bootstrap/reconciliation procedure proves the device-to-leaf bindings. Do not infer those bindings from profiles, room membership, or browser-supplied leaf indexes.

The current authorization record represents exactly one membership proposal per Commit. Until a batch-authorization schema is designed and tested, the worker must reject a Commit containing more than one Add/Update/Remove proposal. This prevents a single-target authorization from being misapplied to a compound Commit.

## Reservation and finalization protocol

Authorization consumption is a reservation, not the final roster update. Under a transaction, the server locks the mapped room, checks the current roster version, verifies that no other authorization is pending, verifies that the actor has an active owner membership and an admitted active device, and checks the operation-specific target against the current device roster. It then records the single pending authorization for that room. This matches the existing BaddieLink owner-only membership-management policy; moderators are not granted MLS membership authority until a separate permission policy exists. The server must also prevent removal of the final registered owner device from a room.

The browser then merges the already-authorized staged Commit into its candidate group and durably journals the candidate. Only after that succeeds does it call `POST /api/mls/rooms/{groupId}/membership-authorizations/{authorizationId}/finalize`. The server applies the corresponding add/update/remove to the device roster, increments the roster version, clears the pending authorization, and marks the authorization applied in one transaction.

An exact consume retry is accepted only while that authorization still owns the room reservation, or after it has been finalized. A different authorization is rejected while a reservation is pending. If the worker crashes after consume, it must recover the same authorization and exact Commit; it must not request a new authorization for a different digest. If finalization cannot complete because the roster version changed, room/account membership changed, or an authorization invariant no longer holds, the room remains fail-closed and requires an explicit server-side reconciliation procedure. Device revocation is blocked while a consumed authorization is pending so the in-flight operation cannot be invalidated halfway through. Never silently clear a pending reservation.

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

Consumption must be idempotent for a retry of the same request and authorization ID, but must not authorize a different Commit or target. A room-level pending-authorization reservation must prevent two concurrent membership operations from consuming the same roster version.

After the worker merges the staged Commit and durably journals the candidate, it calls:

`POST /api/mls/rooms/{groupId}/membership-authorizations/{authorizationId}/finalize`

Finalization applies the exact operation to the server-maintained device roster, increments the roster version, clears the pending reservation, and marks the authorization applied atomically. The server must not update the roster at consume time because local persistence can still fail.

The browser must not treat a successful local verification as proof that the server has not since revoked the device. The consume step is the authoritative reservation decision. The MLS mutation must only be published after consume succeeds, and the new roster version must not be used until finalization succeeds.

## Worker processing sequence

1. Clone the committed provider/group state.
2. Parse and cryptographically process the incoming MLS message.
3. Retain the staged Commit without merging it.
4. Inspect all Add, Update, and Remove proposals from that staged Commit.
5. Reject unsupported proposal types, ambiguous target bindings, or more than one membership proposal (until batch authorization exists).
6. Obtain a room-scoped server authorization bound to the exact Commit digest and current roster version.
7. Verify the assertion using the internal trust store.
8. Consume the authorization through the authenticated server endpoint.
9. Merge the staged Commit into the candidate group.
10. Persist the candidate snapshot through the OPFS journal.
11. Finalize the same authorization so the server atomically advances its device roster and roster version.
12. Publish the candidate in worker memory only after journal recovery and server finalization confirm the exact committed generation.

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
- A production-backed authoritative per-room device roster and permission service (the experimental SQL draft now describes the schema and reservation/finalization primitives, but has not been validated or applied).
- A production issuer/private key or trust distribution/rotation process.
- A room-scoped authorization assertion and atomic consume endpoint.
- Worker integration with those server decisions.

Until those components exist and the rejection matrix passes, production membership admission must remain disabled.
