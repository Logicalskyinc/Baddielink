-- Follow-up hardening for the live Salon foundation.
-- Trigger functions are invoked by PostgreSQL triggers, not by client RPC calls.
revoke all on function private.add_space_owner_membership() from public, anon, authenticated;
revoke all on function private.protect_space_membership_identity() from public, anon, authenticated;

create index if not exists spaces_owner_id_idx on public.spaces (owner_id);
