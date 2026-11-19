# MLS control-plane migration validation checklist

This checklist applies to `supabase/drafts/mls_control_plane_foundation.sql`. It is a repository-only draft and has not been applied to any Supabase project.

## Required local Supabase tests before approval

### Migration / schema
- Apply the migration to a disposable local Supabase database initialized from the repository migrations.
- Confirm every existing `spaces` row receives exactly one MLS group mapping.
- Confirm each group ID is unique and each mapping has a positive roster version.
- Confirm no new tables contain plaintext messages, private keys, or client-provided issuer trust anchors.
- Confirm rollback leaves the original room and membership schema unchanged.

### Access control
- As `anon` and `authenticated`, verify SELECT/INSERT/UPDATE/DELETE are denied on all four MLS control-plane tables.
- Verify `authenticated` cannot execute the consume function.
- Verify `service_role` can execute the bootstrap, consume, and finalize functions.
- Verify trigger functions cannot be called as RPCs by browser roles.
- Verify no new RLS policy accidentally grants client access.

### Roster version
- Insert a membership and verify exactly one increment.
- Delete a membership and verify exactly one increment.
- Change role and verify exactly one increment.
- Change status and verify exactly one increment.
- Update unrelated membership fields and verify no increment.
- Suspend/archive/restore a space and verify each status transition increments once.
- Run concurrent membership changes and verify no increments are lost.
- Verify a failed membership transaction rolls back the roster version increment.

### Device registry
- Reject malformed device IDs, credential IDs, and public keys.
- Reject duplicate credential IDs.
- Reject duplicate active device IDs for one account.
- Permit a new active registration after the prior device registration is revoked, without reactivating the old credential.
- Verify revoked devices cannot consume authorizations.

### Authorization ledger / atomic consume
- Reject unknown authorization IDs.
- Reject wrong actor, device, or Commit digest.
- Reject expired authorization.
- Reject stale roster version after any membership/room-status change.
- Reject revoked actor device.
- Reject second consume with a different actor/device/digest.
- Verify exact same actor/device/digest retry is idempotent.
- Race two consume requests for the same authorization; only the exact same authorization tuple may return success.
- Race a consume against a roster change and verify transaction ordering is deterministic and no stale roster authorization succeeds after the change commits.
- Race consume/finalize against device revocation and verify row locks serialize the operations without allowing a mid-commit key revocation.
- Verify target device belongs to target account through the composite foreign key.
- Verify authorization rows are removed when their owning room is deleted.

## Follow-up implementation not included in this migration

- Authenticated device registration endpoint.
- Authorization issuance endpoint that checks current room role, room state, active actor device, target account/device, and server-generated MLS Commit digest.
- Issuer key provisioning, signing, public trust-anchor rotation, and independent verifier tests.
- Worker integration that stages the MLS Commit, verifies the assertion, consumes it, and only then merges/persists/publishes.
- Negative end-to-end tests proving rejection leaves the MLS epoch and durable OPFS generation unchanged.

## Status

- [x] SQL source drafted in repository.
- [ ] Local Supabase migration execution.
- [ ] Local RLS/grant and trigger tests.
- [ ] Concurrency and replay tests.
- [ ] Edge Function implementation and tests.
- [ ] Worker integration and browser rejection tests.
- [ ] Independent security review.
- [ ] Explicit approval before any hosted migration or deployment.
