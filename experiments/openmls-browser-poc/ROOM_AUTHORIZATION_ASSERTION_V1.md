# MLS Room Authorization Assertion v1

Status: implementation contract only. Not implemented, not trusted by production WASM, and not approved for production.

## Purpose

This assertion authorizes exactly one membership-changing MLS Commit in exactly one BaddieLink room. It is separate from device registration attestation. Device registration binds an account device to an MLS credential; room authorization binds an actor, target, operation, room, roster version, and exact Commit.

## Envelope

- COSE_Sign1, protected ES256 (`alg = -7`).
- Protected `kid` selects a P-256 issuer key from the verifier's internal trust store.
- No detached payload, unprotected headers, or unknown protected parameters.
- Deterministic CBOR payload with exactly the claims below.
- COSE external AAD: `BaddieLink-MLS-Room-Authorization-v1`.
- Signature is 64-byte COSE `r || s`.
- Private issuer key is server-only. Never store it in Postgres or send it to the browser.

## Exact v1 claims

The payload contains exactly 16 unique text-keyed claims. Reject missing, duplicate, unknown, wrong-type, wrong-length, or non-canonical claims.

| Claim | Type | Validation |
|---|---|---|
| v | uint | exactly 1 |
| iss | text | matches trusted key issuer |
| aud | text | exactly `baddielink-mls-membership` |
| group | bstr | 16-byte server-created group UUID |
| op | text | add, update, or remove |
| actor_sub | bstr | 16-byte authenticated account UUID |
| actor_device | bstr | 16-byte registered device-row UUID |
| target_sub | bstr | 16-byte target account UUID |
| target_device | bstr | 16-byte target device-row UUID |
| target_cred | bstr | 32-byte exact MLS credential identity |
| target_sig | bstr | 32-byte exact MLS signature public key |
| rv | uint | positive authoritative roster version |
| jti | bstr | 16-byte authorization UUID |
| digest | bstr | 32-byte SHA-256 of exact serialized MLS Commit bytes |
| iat | uint | Unix seconds, at most 60 seconds in future |
| exp | uint | after iat, at most 120 seconds after iat |

UUID bytes use RFC 4122 network byte order. No textual UUID or alternate byte representation is accepted.

For remove, target binding is resolved from the authoritative server roster; never trust a browser-supplied leaf index. For add/update, server resolves the registered target device and compares its exact credential/key binding with the staged MLS proposal. Until batch authorization is implemented, reject a Commit with more than one membership proposal.

## Digest

`digest = SHA-256(exact serialized MLS Commit message bytes)`.

Do not hash JSON, a decoded object, a re-serialized Commit, or transport metadata. Store the same digest in the authorization row and pass it unchanged to consume/finalize.

## Lifecycle

1. Authenticated issue endpoint independently resolves actor, active owner membership, active actor device, room mapping, roster version, operation target, and exact credential/key binding. It inserts an immutable authorization row and signs the assertion.
2. Browser verifies the signature with an internal trust store and checks every claim against the exact staged Commit and expected context.
3. Consume endpoint revalidates the authenticated session and atomically reserves the room authorization using server-derived actor IDs and the exact digest.
4. Worker merges only the authorized staged Commit into candidate state and durably journals the candidate.
5. Finalize endpoint applies the exact device-roster projection, increments roster version, clears reservation, and marks authorization applied atomically.
6. Worker publishes candidate state only after local journal recovery and successful server finalization.

Consume is a reservation, not finalization. If local persistence fails after consume, recover the same authorization ID and digest. Never mint a different authorization while the room reservation is pending. If finalization fails after local persistence, remain fail-closed and reconcile explicitly; do not silently clear the reservation or publish the new state.

## Proposed Edge Function routes

- `POST /functions/v1/mls-membership-authorization/issue`
- `POST /functions/v1/mls-membership-authorization/consume`
- `POST /functions/v1/mls-membership-authorization/finalize`

All require a valid Supabase access token. Resolve actor identity from a verified Supabase user lookup, never request JSON. Do not use user-editable metadata for authorization. Service-role credentials and issuer private keys remain server-side. Validate content type, request size, UUID/base64url formats, reject unknown JSON fields, rate-limit issuance, and do not log assertions, credentials, or private key material.

## Failure behavior

Fail closed for invalid JWT, inactive account/device, non-owner actor, inactive/unmapped room, stale roster, target mismatch, revoked target on add/update, missing target on update/remove, owner last-device removal, wrong group/op/actor/device/digest, expired assertion, unknown issuer, bad signature, replay, concurrent reservation, database timeout, or service unavailability.

Every rejection before merge must leave MLS epoch, membership, OPFS generation, and committed bytes unchanged. On persistence/finalization ambiguity, do not return a membership Commit or Welcome to the caller.

## Required tests

Test malformed and non-canonical CBOR, duplicate/unknown/missing claims, wrong types/lengths, wrong AAD, key ID, issuer, audience, group, operation, actor, target, roster version, digest, timestamps, expiry, replay, concurrent consume, exact idempotent retry, persistence failure after consume, successful finalization, and finalization recovery. Run identical deterministic fixtures in native Rust and WASM.

The production/default trust store remains empty until issuer provisioning, rotation, overlap, emergency revocation, and distribution are reviewed and explicitly enabled.
