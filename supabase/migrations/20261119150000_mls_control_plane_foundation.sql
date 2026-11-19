-- BaddieLink MLS control-plane foundation.
--
-- Repository migration source only. Do not apply to the hosted project until
-- local Supabase validation, Edge Function implementation, and security review
-- are complete and separately approved.
--
-- Existing public.spaces and public.space_memberships remain authoritative.
-- No MLS message content, plaintext, or private cryptographic key is stored here.

begin;

create table public.mls_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id bytea not null
    check (octet_length(device_id) between 16 and 64),
  credential_id bytea not null unique
    check (octet_length(credential_id) = 32),
  signature_public_key bytea not null
    check (octet_length(signature_public_key) = 32),
  status text not null default 'active'
    check (status in ('active', 'revoked')),
  registered_at timestamptz not null default clock_timestamp(),
  revoked_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  constraint mls_devices_revocation_state_check check (
    (status = 'active' and revoked_at is null)
    or (status = 'revoked' and revoked_at is not null)
  ),
  constraint mls_devices_id_user_unique unique (id, user_id)
);

create unique index mls_devices_one_active_device_id
  on public.mls_devices (user_id, device_id)
  where status = 'active';

create index mls_devices_user_status_idx
  on public.mls_devices (user_id, status);

comment on table public.mls_devices is
  'Server-managed MLS device registry. Contains public key material only; never device private keys.';

create table public.mls_space_groups (
  space_id uuid primary key references public.spaces(id) on delete cascade,
  group_id uuid not null default gen_random_uuid() unique,
  roster_version bigint not null default 1 check (roster_version > 0),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint mls_space_groups_space_group_unique unique (space_id, group_id)
);

comment on table public.mls_space_groups is
  'Server-owned one-to-one mapping from a BaddieLink space to an opaque MLS group and monotonic roster version.';

-- Backfill one opaque group mapping for every existing room. Memberships
-- remain in public.space_memberships; this table does not duplicate them.
insert into public.mls_space_groups (space_id)
select s.id
from public.spaces s
on conflict (space_id) do nothing;

create table public.mls_membership_authorizations (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null,
  group_id uuid not null,
  actor_user_id uuid not null,
  actor_device_id uuid not null,
  operation text not null check (operation in ('add', 'update', 'remove')),
  target_user_id uuid not null,
  target_device_id uuid not null,
  target_credential_id bytea not null
    check (octet_length(target_credential_id) = 32),
  target_signature_public_key bytea not null
    check (octet_length(target_signature_public_key) = 32),
  roster_version bigint not null check (roster_version > 0),
  commit_digest bytea not null check (octet_length(commit_digest) = 32),
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  constraint mls_authorization_expiry_check check (
    expires_at > created_at
    and expires_at <= created_at + interval '2 minutes'
  ),
  constraint mls_authorization_group_fk
    foreign key (space_id, group_id)
    references public.mls_space_groups (space_id, group_id)
    on delete cascade,
  constraint mls_authorization_actor_device_fk
    foreign key (actor_device_id, actor_user_id)
    references public.mls_devices (id, user_id)
    on delete restrict,
  constraint mls_authorization_target_device_fk
    foreign key (target_device_id, target_user_id)
    references public.mls_devices (id, user_id)
    on delete restrict
);

create index mls_authorizations_space_expiry_idx
  on public.mls_membership_authorizations (space_id, expires_at);

create index mls_authorizations_actor_device_idx
  on public.mls_membership_authorizations (actor_user_id, actor_device_id, created_at desc);

create index mls_authorizations_unconsumed_expiry_idx
  on public.mls_membership_authorizations (expires_at)
  where consumed_at is null;

comment on table public.mls_membership_authorizations is
  'Short-lived, exact-Commit, single-use MLS membership authorization ledger. Signed assertions are produced by the server, not trusted from this row alone.';

-- Server-owned tables are inaccessible to browser roles. The service role is
-- used only from authenticated server code after JWT validation.
alter table public.mls_devices enable row level security;
alter table public.mls_space_groups enable row level security;
alter table public.mls_membership_authorizations enable row level security;

revoke all on public.mls_devices from public, anon, authenticated;
revoke all on public.mls_space_groups from public, anon, authenticated;
revoke all on public.mls_membership_authorizations from public, anon, authenticated;

grant select, insert, update, delete on public.mls_devices to service_role;
grant select, insert, update, delete on public.mls_space_groups to service_role;
grant select, insert, update, delete on public.mls_membership_authorizations to service_role;

-- Roster version updates are performed by triggers, not client-callable RPCs.
create or replace function private.mls_bump_space_roster_version(p_space_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  update public.mls_space_groups
     set roster_version = roster_version + 1,
         updated_at = clock_timestamp()
   where space_id = p_space_id;

  if not found then
    raise exception 'MLS group mapping missing for space %', p_space_id
      using errcode = 'foreign_key_violation';
  end if;
end;
$function$;

create or replace function private.mls_track_membership_roster_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_space_id uuid;
begin
  if tg_op = 'INSERT' then
    v_space_id := new.space_id;
  elsif tg_op = 'DELETE' then
    v_space_id := old.space_id;
  else
    if new.role is not distinct from old.role
       and new.status is not distinct from old.status then
      return new;
    end if;
    v_space_id := new.space_id;
  end if;

  perform private.mls_bump_space_roster_version(v_space_id);

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$;

create trigger space_memberships_mls_roster_version
after insert or delete or update of role, status
on public.space_memberships
for each row
execute function private.mls_track_membership_roster_change();

create or replace function private.mls_track_space_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if new.status is distinct from old.status then
    perform private.mls_bump_space_roster_version(new.id);
  end if;
  return new;
end;
$function$;

create trigger spaces_mls_roster_status_version
after update of status on public.spaces
for each row
execute function private.mls_track_space_status_change();

revoke all on function private.mls_bump_space_roster_version(uuid)
  from public, anon, authenticated;
revoke all on function private.mls_track_membership_roster_change()
  from public, anon, authenticated;
revoke all on function private.mls_track_space_status_change()
  from public, anon, authenticated;

-- Atomic consume primitive. Edge Functions must validate the Supabase JWT and
-- verify the signed room-authorization assertion before calling this function.
-- The exact digest, actor, device, expiry and current roster are rechecked here.
-- An exact retry is idempotent; a different actor/device/digest cannot replay it.
create or replace function public.mls_consume_membership_authorization(
  p_authorization_id uuid,
  p_actor_user_id uuid,
  p_actor_device_id uuid,
  p_commit_digest bytea
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_space_id uuid;
  v_group_id uuid;
  v_roster_version bigint;
  v_actor_user_id uuid;
  v_actor_device_id uuid;
  v_commit_digest bytea;
  v_expires_at timestamptz;
  v_consumed_at timestamptz;
  v_current_roster_version bigint;
  v_device_active boolean;
begin
  if p_authorization_id is null
     or p_actor_user_id is null
     or p_actor_device_id is null
     or p_commit_digest is null
     or octet_length(p_commit_digest) <> 32 then
    return false;
  end if;

  select a.space_id, a.group_id, a.roster_version,
         a.actor_user_id, a.actor_device_id, a.commit_digest,
         a.expires_at, a.consumed_at
    into v_space_id, v_group_id, v_roster_version,
         v_actor_user_id, v_actor_device_id, v_commit_digest,
         v_expires_at, v_consumed_at
    from public.mls_membership_authorizations a
   where a.id = p_authorization_id
   for update;

  if not found
     or v_actor_user_id <> p_actor_user_id
     or v_actor_device_id <> p_actor_device_id
     or v_commit_digest <> p_commit_digest then
    return false;
  end if;

  -- Exact same request after a lost response is safe to acknowledge.
  if v_consumed_at is not null then
    return true;
  end if;

  select g.roster_version
    into v_current_roster_version
    from public.mls_space_groups g
   where g.space_id = v_space_id
     and g.group_id = v_group_id
   for update;

  if not found or v_current_roster_version <> v_roster_version then
    return false;
  end if;

  select (d.status = 'active' and d.revoked_at is null)
    into v_device_active
    from public.mls_devices d
   where d.id = v_actor_device_id
     and d.user_id = v_actor_user_id;

  if not found or not coalesce(v_device_active, false)
     or v_expires_at <= clock_timestamp() then
    return false;
  end if;

  update public.mls_membership_authorizations
     set consumed_at = clock_timestamp()
   where id = p_authorization_id
     and consumed_at is null;

  return found;
end;
$function$;

revoke all on function public.mls_consume_membership_authorization(uuid, uuid, uuid, bytea)
  from public, anon, authenticated;
grant execute on function public.mls_consume_membership_authorization(uuid, uuid, uuid, bytea)
  to service_role;

commit;
