# BaddieLink E2EE backend integration assessment

Status: repository design, migration source drafted, and read-only database inspection. The migration is not locally validated and this document does not authorize applying SQL or deploying Edge Functions.

## Verified database model

The live project uses `public.spaces` as the canonical Salon/Community room record. Its primary key is UUID `id`; `space_type` is `salon` or `community`; `status` is `active`, `suspended`, or `archived`; ownership is `owner_id` referencing `auth.users(id)`.

`public.space_memberships` is the authoritative membership record with composite primary key `(space_id, user_id)`, role `owner | moderator | member`, and status `pending | active | removed | banned`. Existing RLS policies permit self-join/leave/rejoin and owner invitation/management. Existing trigger protects membership identity and prevents owner membership changes. A separate trigger creates the owner's active membership when a space is inserted.

Do not create a second room or membership system. Legacy `public.matches` and `public.messages` are match-based direct messaging and must not be repurposed as MLS room storage.

## Verified E2EE boundary

The experimental PR is open and draft. Current head at inspection: `e59e44eaa3098857dbd5c3cdc99584222b7ecd52`. Its authorization contract specifies separate device registration and room-scoped membership authorization, exact Commit digest binding, server-side roster versioning, one-time consume, and fail-closed worker sequencing.

The live Supabase project currently reports no deployed Edge Functions. No E2EE device registry, MLS group mapping, roster version, or authorization-consumption tables were found in the inspected schema.

## Required backend additions

1. **Device registry**: a server-owned record bound to `auth.users.id`, with device reference, credential ID, public signature key, lifecycle status, timestamps, and revocation. Never store device private keys or accept issuer trust keys from a browser.
2. **MLS room mapping**: map each `spaces.id` to one server-created opaque MLS group identifier. The browser must not invent or rebind this mapping.
3. **Roster version**: monotonic version for each mapped room. Increment transactionally when membership is inserted/deleted or when role/status changes; also invalidate on room suspension/archive. Use the existing membership table as source of truth.
4. **Membership authorization ledger**: server-only records binding room/group, authenticated actor/device, operation, resolved target binding, current roster version, exact Commit digest, expiry, unique authorization ID, and consumption state. Consume under a transaction/compare-and-swap so concurrent operations cannot both use one roster version.
5. **Authenticated server endpoints**: verify the Supabase access token; derive actor from verified identity; check current membership, role, device status, room status, target, and roster version server-side. Never trust actor IDs, role, leaf index, target identity, or roster version supplied by the browser.
6. **Signing and trust**: define a versioned room-authorization assertion distinct from the existing generic device-attestation v1. Provision issuer private key only in server secrets, publish/rotate its public trust anchor through a controlled release, and keep production trust empty until this is ready.
7. **Worker integration**: inspect and stage MLS Commit, request exact room authorization, verify internally, consume once, merge, persist journal, then publish. Any failure before merge leaves committed group state unchanged.

## Migration design constraints

- Enable RLS on every new table in exposed `public` schema.
- Revoke all direct `anon` and `authenticated` access to server-owned registry, authorization, and group-mapping records; only the server-side service role should operate them.
- Keep trigger functions non-callable by client roles and use an empty/locked `search_path`.
- Do not use broad `SECURITY DEFINER` RPCs as a shortcut.
- Avoid storing signed assertions as trusted merely because a row exists; server signature verification and one-time consumption remain mandatory.
- Add indexes for account/device lookup, group/space lookup, active authorization expiry, and unconsumed authorization ID.
- Add tests for duplicate device registration, revoked device, stale roster version, wrong group/operation/target/digest, expiry, replay, concurrent consume, membership changes, room suspension, and rollback on failed transaction.

## Current status

- [x] Read-only Supabase migration inventory: 19 migrations recorded; `default_people_discovery_on` is applied as version `20261119122243`.
- [x] Read-only schema inspection: `spaces` and `space_memberships` columns, constraints, RLS policies, and triggers checked.
- [x] Existing room model reused in the design; legacy match messaging left untouched.
- [x] Existing E2EE authorization contract reviewed.
- [x] Draft repository-only migration source: `supabase/migrations/20261119150000_mls_control_plane_foundation.sql` (device registry, server-created space/group mapping, roster version triggers, immutable one-time authorization ledger, and atomic consume primitive).
- [ ] Validate the migration against a disposable/local Supabase database. The current execution environment has no Supabase CLI, PostgreSQL client/server, or Docker runtime, so SQL execution and concurrency testing have not been performed.
- [ ] Implement and test authenticated Edge Functions and atomic authorization consumption.
- [ ] Implement worker integration and rejection matrix.
- [ ] Configure issuer key, rotation, and production trust anchor after security review.
- [ ] Obtain explicit approval before applying migration or deploying functions to the live Supabase project.

## Explicit non-actions

No live database schema was changed. The new migration exists only on the experimental GitHub branch and is not recorded as applied. No Edge Function was deployed. No Render deployment, production feature activation, or billing change was made.
