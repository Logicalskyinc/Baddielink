# BaddieLink E2EE backend integration assessment

Status: repository design, migration source drafted, and read-only database inspection. The SQL draft is not a migration yet and this document does not authorize applying SQL or deploying Edge Functions.

## Verified database model

The live project uses `public.spaces` as the canonical Salon/Community room record. Its primary key is UUID `id`; `space_type` is `salon` or `community`; `status` is `active`, `suspended`, or `archived`; ownership is `owner_id` referencing `auth.users(id)`.

`public.space_memberships` is the authoritative membership record with composite primary key `(space_id, user_id)`, role `owner | moderator | member`, and status `pending | active | removed | banned`. Existing RLS policies permit self-join/leave/rejoin and owner invitation/management. Existing trigger protects membership identity and prevents owner membership changes. A separate trigger creates the owner's active membership when a space is inserted.

Do not create a second room or membership system. Legacy `public.matches` and `public.messages` are match-based direct messaging and must not be repurposed as MLS room storage.

## Verified E2EE boundary

The experimental PR is open and draft. Its current authorization contract specifies separate device registration and room-scoped membership authorization, exact Commit digest binding, a credential-bound per-room device roster, serialized reservation/finalization, and fail-closed worker sequencing.

The live Supabase project currently reports no deployed Edge Functions. No E2EE device registry, MLS group mapping, roster version, or authorization-consumption tables were found in the inspected schema.

## Required backend additions

1. **Device registry**: a server-owned record bound to `auth.users.id`, with device reference, credential ID, unique public signature key, lifecycle status, timestamps, and revocation. Never store device private keys or accept issuer trust keys from a browser.
2. **MLS room mapping**: map each `spaces.id` to one server-created opaque MLS group identifier. The browser must not invent or rebind this mapping.
3. **Roster version and device projection**: monotonic version for each mapped room, incremented when an authorized device-level MLS roster change is finalized and when room status changes. Account membership/role is checked directly at consume and finalize time; unrelated account joins/leaves must not invalidate a different device-level Commit. A separate server-only per-room device projection binds registered device, account, SHA-256 hash of the serialized MLS BasicCredential identity, and exact signature public key. It deliberately stores no MLS leaf index. Existing rooms cannot be backfilled from account membership alone; their device projection remains empty until an authorized bootstrap/reconciliation process proves device-to-leaf bindings.
4. **Membership authorization ledger**: server-only records bind room/group, authenticated actor/device, one supported operation (`add` or `remove`), resolved target device/credential/key, current roster version, exact Commit digest, expiry, unique authorization ID, and consumption/application state. Consume reserves the room under a row lock; finalization after local durable persistence applies the device projection, advances the roster version, and releases the reservation. A pending reservation blocks competing authorizations. Exact retries are idempotent only for the same authorization and digest.
5. **Authenticated server endpoints**: verify the Supabase access token; derive actor from verified identity; check current membership, role, device status, room status, target, and roster version server-side. Never trust actor IDs, role, leaf index, target identity, or roster version supplied by the browser.
6. **Signing and trust**: define a versioned room-authorization assertion distinct from the existing generic device-attestation v1. Provision issuer private key only in server secrets, publish/rotate its public trust anchor through a controlled release, and keep production trust empty until this is ready.
7. **Worker integration**: inspect and stage one membership proposal, request exact room authorization, verify internally, consume/reserve once, merge, persist journal, finalize the server device roster, then publish. Any failure before merge leaves committed group state unchanged.

## Migration design constraints

- Enable RLS on every new table in exposed `public` schema.
- Revoke all direct `anon` and `authenticated` access to server-owned registry, authorization, and group-mapping records; only the server-side service role should operate them.
- Keep trigger functions non-callable by client roles and use an empty/locked `search_path`.
- Do not use broad `SECURITY DEFINER` RPCs as a shortcut.
- Avoid storing signed assertions as trusted merely because a row exists; server signature verification and one-time consumption remain mandatory.
- Add indexes for account/device lookup, group/space lookup, active authorization expiry, and unconsumed authorization ID.
- Add tests for duplicate device registration, revoked device, stale roster version, wrong group/operation/target/digest, expiry, replay, concurrent consume, membership changes, room suspension, account erasure constraints, and rollback on failed transaction. The current fixture covers room mapping, account membership gate, roster version semantics, Add/Remove projection, reservation concurrency, exact retry, digest mismatch, revocation during pending authorization, and grants; additional cases remain.

## Current status

- [x] Static review enforces exact registered device/credential/signature-key bindings in both the room roster and authorization target foreign keys.
- [x] Membership authorization is Add/Remove-only; MLS Update proposals are rejected until a separately designed device-rekey protocol exists.
- [x] Exact consume retries remain idempotent after finalization advances the roster version.
- [x] Consume and finalization lock actor/target device rows in deterministic order to serialize against concurrent revocation.

- [x] Read-only Supabase migration inventory: 22 migrations recorded; `default_people_discovery_on` is applied as version `20261119122243`.
- [x] Read-only schema inspection: `spaces` and `space_memberships` columns, constraints, RLS policies, and triggers checked.
- [x] Existing room model reused in the design; legacy match messaging left untouched.
- [x] Existing E2EE authorization contract reviewed.
- [x] Define server-maintained credential-bound device roster without persisting unstable MLS leaf indexes.
- [x] Define two-phase authorization reservation/finalization to prevent concurrent Commits from consuming one roster version.
- [x] Require exactly one membership proposal per Commit until batch authorization is designed.
- [x] Worker staged proposal inspection now emits SHA-256 credential hashes for Add/Update/Remove and resolves Remove to the current MLS member's credential/key binding.
- [x] Worker rejects compound membership Commits while the authorization record remains single-target.
- [x] Worker rejects staged proposal bindings unless credential hash and signature key are canonical 32-byte values.
- [x] Device revocation is blocked while a consumed room authorization is awaiting finalization.
- [x] Account deletion is restricted until device/roster/audit cleanup can be performed without orphaning MLS leaves.
- [x] MLS membership authorization is owner-only, matching the existing BaddieLink owner-management policy; last owner device removal is rejected.
- [x] Draft repository-only SQL source (kept outside migrations until CLI generation and validation): `supabase/drafts/mls_control_plane_foundation.sql` (immutable device registry, server-created space/group mapping, owner-bound first-device bootstrap, credential-bound per-room device projection, roster versioning, one-target authorization ledger, room reservation, post-persistence finalization, and revocation/account-erasure guards).
- [ ] Validate the SQL draft against a disposable PostgreSQL/Supabase database. The repository now includes a PostgreSQL CI workflow and fixtures covering room mapping, owner first-device bootstrap/idempotency, account membership gating, device admission/removal, pending reservation concurrency, exact retry, digest mismatch, revocation ordering and key/device identifier reuse, finalization, and grants. CI has not yet been confirmed green.
- [ ] Implement authenticated Edge Functions for device registration, authorization issuance, consume, and finalize.
- [ ] Connect the worker to the authenticated consume/finalize endpoints and complete the rejection matrix.
- [ ] Configure issuer key, rotation, and production trust anchor after security review.
- [ ] Obtain explicit approval before applying migration or deploying functions to the live Supabase project.

## Explicit non-actions

No live database schema was changed. The SQL draft is kept outside `supabase/migrations/` so it cannot be accidentally applied by a normal migration push. It remains unexecuted and must not be treated as production-ready. No Edge Function was deployed. No Render deployment, production feature activation, or billing change was made.
