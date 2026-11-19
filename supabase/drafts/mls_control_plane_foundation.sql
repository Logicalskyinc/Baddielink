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
  user_id uuid not null references auth.users(id) on delete restrict,
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

-- Device identity and public-key bindings are immutable. A replacement key
-- must be registered as a new device; an old device can only be revoked.
create or replace function private.mls_protect_device_binding()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if new.user_id is distinct from old.user_id
     or new.device_id is distinct from old.device_id
     or new.credential_id is distinct from old.credential_id
     or new.signature_public_key is distinct from old.signature_public_key
     or new.registered_at is distinct from old.registered_at
     or new.created_at is distinct from old.created_at then
    raise exception 'MLS device identity and key binding are immutable';
  end if;

  if old.status = 'revoked' and new.status <> 'revoked' then
    raise exception 'A revoked MLS device cannot be reactivated';
  end if;

  if old.status = 'active' and new.status = 'revoked' then
    new.revoked_at := clock_timestamp();
  elsif new.status = 'active' then
    new.revoked_at := null;
  elsif new.revoked_at is distinct from old.revoked_at then
    raise exception 'MLS device revocation timestamp cannot be rewritten';
  end if;

  return new;
end;
$function$;

create trigger mls_devices_protect_binding
before update on public.mls_devices
for each row
execute function private.mls_protect_device_binding();

revoke all on function private.mls_protect_device_binding()
  from public, anon, authenticated;

comment on table public.mls_devices is
  'Server-managed MLS device registry. Contains public key material only; never device private keys.';

-- Account deletion is intentionally restricted while MLS device/roster/audit
-- records exist. A separate account-erasure workflow must revoke devices,
-- remove them from every MLS room, and retain/purge audit records by policy
-- before deleting auth.users. Silent cascades could orphan live MLS leaves.

create table public.mls_space_groups (
  space_id uuid primary key references public.spaces(id) on delete cascade,
  group_id uuid not null default gen_random_uuid() unique,
  roster_version bigint not null default 1 check (roster_version > 0),
  pending_authorization_id uuid,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  constraint mls_space_groups_space_group_unique unique (space_id, group_id)
);

comment on table public.mls_space_groups is
  'Server-owned one-to-one mapping from a BaddieLink space to an opaque MLS group and monotonic roster version.';

-- Server-maintained projection of devices admitted to each MLS group.
-- This is deliberately credential-bound and contains no MLS leaf indexes:
-- leaf indexes are tree-local and must be resolved from the authenticated MLS
-- state by the worker for each staged Commit.
create table public.mls_space_device_roster (
  space_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  credential_id bytea not null check (octet_length(credential_id) = 32),
  signature_public_key bytea not null check (octet_length(signature_public_key) = 32),
  joined_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  primary key (space_id, device_id),
  unique (space_id, credential_id),
  constraint mls_space_device_roster_group_fk
    foreign key (space_id) references public.mls_space_groups(space_id)
    on delete cascade,
  constraint mls_space_device_roster_device_fk
    foreign key (device_id, user_id)
    references public.mls_devices(id, user_id)
    on delete restrict
);

create index mls_space_device_roster_user_idx
  on public.mls_space_device_roster (space_id, user_id);

comment on table public.mls_space_device_roster is
  'Server-maintained MLS admission projection keyed by registered device and credential hash; never stores tree-local leaf indexes.';

-- Backfill one opaque group mapping for every existing room. Memberships
-- remain in public.space_memberships; this table does not duplicate them.
insert into public.mls_space_groups (space_id)
select s.id
from public.spaces s
on conflict (space_id) do nothing;

-- Ensure rooms created after this migration receive their server-owned MLS
-- group mapping before the existing owner-membership trigger inserts a row.
create or replace function private.mls_create_space_group_mapping()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  insert into public.mls_space_groups (space_id)
  values (new.id)
  on conflict (space_id) do nothing;
  return new;
end;
$function$;

-- PostgreSQL orders same-event triggers by name. The leading "a_" ensures
-- this runs before the existing spaces_add_owner_membership trigger.
create trigger a_spaces_mls_create_group_mapping
after insert on public.spaces
for each row
execute function private.mls_create_space_group_mapping();

revoke all on function private.mls_create_space_group_mapping()
  from public, anon, authenticated;


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
  applied_at timestamptz,
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

-- Authorization contents are immutable after issuance. The only allowed
-- update is the one-way transition consumed_at: NULL -> timestamp.
create or replace function private.mls_protect_authorization_immutability()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if new.id is distinct from old.id
     or new.space_id is distinct from old.space_id
     or new.group_id is distinct from old.group_id
     or new.actor_user_id is distinct from old.actor_user_id
     or new.actor_device_id is distinct from old.actor_device_id
     or new.operation is distinct from old.operation
     or new.target_user_id is distinct from old.target_user_id
     or new.target_device_id is distinct from old.target_device_id
     or new.target_credential_id is distinct from old.target_credential_id
     or new.target_signature_public_key is distinct from old.target_signature_public_key
     or new.roster_version is distinct from old.roster_version
     or new.commit_digest is distinct from old.commit_digest
     or new.created_at is distinct from old.created_at
     or new.expires_at is distinct from old.expires_at then
    raise exception 'MLS membership authorization is immutable';
  end if;

  if old.consumed_at is not null
     or new.consumed_at is null then
    if new.consumed_at is distinct from old.consumed_at then
      raise exception 'MLS authorization consumption is a one-way transition';
    end if;
  end if;

  if old.applied_at is not null
     or (new.applied_at is not null and new.consumed_at is null) then
    if new.applied_at is distinct from old.applied_at then
      raise exception 'MLS authorization application is a one-way transition';
    end if;
  end if;

  return new;
end;
$function$;

create trigger mls_authorizations_protect_immutability
before update on public.mls_membership_authorizations
for each row
execute function private.mls_protect_authorization_immutability();

revoke all on function private.mls_protect_authorization_immutability()
  from public, anon, authenticated;

comment on table public.mls_membership_authorizations is
  'Short-lived, exact-Commit, single-use MLS membership authorization ledger. Signed assertions are produced by the server, not trusted from this row alone.';

alter table public.mls_space_groups
  add constraint mls_space_groups_pending_authorization_fk
  foreign key (pending_authorization_id)
  references public.mls_membership_authorizations(id)
  on delete set null;

-- Server-owned tables are inaccessible to browser roles. The service role is
-- used only from authenticated server code after JWT validation.
alter table public.mls_devices enable row level security;
alter table public.mls_space_groups enable row level security;
alter table public.mls_space_device_roster enable row level security;
alter table public.mls_membership_authorizations enable row level security;

revoke all on public.mls_devices from public, anon, authenticated;
revoke all on public.mls_space_groups from public, anon, authenticated;
revoke all on public.mls_space_device_roster from public, anon, authenticated;
revoke all on public.mls_membership_authorizations from public, anon, authenticated;

grant select, insert, update on public.mls_devices to service_role;
grant select on public.mls_space_groups to service_role;
grant select on public.mls_space_device_roster to service_role;
grant select, insert on public.mls_membership_authorizations to service_role;

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
  v_target_user_id uuid;
  v_target_device_id uuid;
  v_target_credential_id bytea;
  v_target_signature_public_key bytea;
  v_operation text;
  v_commit_digest bytea;
  v_expires_at timestamptz;
  v_consumed_at timestamptz;
  v_applied_at timestamptz;
  v_current_roster_version bigint;
  v_pending_authorization_id uuid;
  v_space_active boolean;
  v_space_owner_id uuid;
  v_owner_device_count bigint;
  v_actor_can_manage boolean;
  v_actor_is_in_roster boolean;
  v_target_is_in_roster boolean;
  v_device_active boolean;
  v_target_device_active boolean;
begin
  if p_authorization_id is null
     or p_actor_user_id is null
     or p_actor_device_id is null
     or p_commit_digest is null
     or octet_length(p_commit_digest) <> 32 then
    return false;
  end if;

  select a.space_id, a.group_id, a.roster_version,
         a.actor_user_id, a.actor_device_id,
         a.target_user_id, a.target_device_id,
         a.target_credential_id, a.target_signature_public_key,
         a.operation, a.commit_digest, a.expires_at, a.consumed_at, a.applied_at
    into v_space_id, v_group_id, v_roster_version,
         v_actor_user_id, v_actor_device_id,
         v_target_user_id, v_target_device_id,
         v_target_credential_id, v_target_signature_public_key,
         v_operation, v_commit_digest, v_expires_at, v_consumed_at, v_applied_at
    from public.mls_membership_authorizations a
   where a.id = p_authorization_id
   for update;

  if not found
     or v_actor_user_id <> p_actor_user_id
     or v_actor_device_id <> p_actor_device_id
     or v_commit_digest <> p_commit_digest then
    return false;
  end if;

  select g.roster_version, g.pending_authorization_id,
         (s.status = 'active'), s.owner_id
    into v_current_roster_version, v_pending_authorization_id, v_space_active, v_space_owner_id
    from public.mls_space_groups g
    join public.spaces s on s.id = g.space_id
   where g.space_id = v_space_id
     and g.group_id = v_group_id
   for update of g;

  if not found
     or not coalesce(v_space_active, false)
     or v_current_roster_version <> v_roster_version
     or (v_pending_authorization_id is not null
         and v_pending_authorization_id <> p_authorization_id) then
    return false;
  end if;

  -- A consumed retry is valid only while its reservation still owns this
  -- room, or after the exact authorization has already been finalized.
  if v_consumed_at is not null then
    return v_pending_authorization_id = p_authorization_id
      or v_applied_at is not null;
  end if;

  select exists (
    select 1
      from public.space_memberships sm
     where sm.space_id = v_space_id
       and sm.user_id = v_actor_user_id
       and sm.status = 'active'
       and sm.role = 'owner'
  ) into v_actor_can_manage;

  if not coalesce(v_actor_can_manage, false) then
    return false;
  end if;

  select exists (
    select 1
      from public.mls_space_device_roster r
     where r.space_id = v_space_id
       and r.user_id = v_actor_user_id
       and r.device_id = v_actor_device_id
  ) into v_actor_is_in_roster;

  if not coalesce(v_actor_is_in_roster, false) then
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

  -- Add/update targets must still be active and retain the exact immutable
  -- credential/key binding at consume time. A removal may target a revoked
  -- device because revocation must not prevent removing it from a room.
  select exists (
    select 1
      from public.mls_space_device_roster r
     where r.space_id = v_space_id
       and r.user_id = v_target_user_id
       and r.device_id = v_target_device_id
       and r.credential_id = v_target_credential_id
       and r.signature_public_key = v_target_signature_public_key
  ) into v_target_is_in_roster;

  if v_operation in ('add', 'update') then
    -- Device admission/update cannot bypass the ordinary BaddieLink
    -- account-level room-membership gate.
    if not exists (
      select 1
        from public.space_memberships sm
       where sm.space_id = v_space_id
         and sm.user_id = v_target_user_id
         and sm.status = 'active'
    ) then
      return false;
    end if;
  end if;

  if v_operation = 'add' then
    if coalesce(v_target_is_in_roster, false) then
      return false;
    end if;

    select (
      d.status = 'active'
      and d.revoked_at is null
      and d.credential_id = v_target_credential_id
      and d.signature_public_key = v_target_signature_public_key
    )
      into v_target_device_active
      from public.mls_devices d
     where d.id = v_target_device_id
       and d.user_id = v_target_user_id;

    if not found or not coalesce(v_target_device_active, false) then
      return false;
    end if;
  elsif v_operation in ('update', 'remove') then
    if not coalesce(v_target_is_in_roster, false) then
      return false;
    end if;

    if v_operation = 'remove' and v_target_user_id = v_space_owner_id then
      select count(*)
        into v_owner_device_count
        from public.mls_space_device_roster r
       where r.space_id = v_space_id
         and r.user_id = v_space_owner_id;

      if v_owner_device_count <= 1 then
        return false;
      end if;
    end if;

    if v_operation = 'update' then
      select (
        d.status = 'active'
        and d.revoked_at is null
        and d.credential_id = v_target_credential_id
        and d.signature_public_key = v_target_signature_public_key
      )
        into v_target_device_active
        from public.mls_devices d
       where d.id = v_target_device_id
         and d.user_id = v_target_user_id;

      if not found or not coalesce(v_target_device_active, false) then
        return false;
      end if;
    end if;
  end if;

  update public.mls_space_groups
     set pending_authorization_id = p_authorization_id
   where space_id = v_space_id
     and group_id = v_group_id
     and roster_version = v_roster_version
     and pending_authorization_id is null;

  if not found then
    return false;
  end if;

  update public.mls_membership_authorizations
     set consumed_at = clock_timestamp()
   where id = p_authorization_id
     and consumed_at is null;

  if not found then
    raise exception 'MLS authorization was not consumable after acquiring its room lock';
  end if;

  return true;
end;
$function$;

revoke all on function public.mls_consume_membership_authorization(uuid, uuid, uuid, bytea)
  from public, anon, authenticated;
grant execute on function public.mls_consume_membership_authorization(uuid, uuid, uuid, bytea)
  to service_role;

-- Finalization is a separate transaction after the worker has merged and
-- durably journaled the exact authorized Commit. The pending group lock blocks
-- another membership authorization until this projection is advanced.
create or replace function public.mls_finalize_membership_authorization(
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
  v_operation text;
  v_target_user_id uuid;
  v_target_device_id uuid;
  v_target_credential_id bytea;
  v_target_signature_public_key bytea;
  v_commit_digest bytea;
  v_consumed_at timestamptz;
  v_applied_at timestamptz;
  v_pending_authorization_id uuid;
  v_current_roster_version bigint;
  v_actor_device_active boolean;
  v_target_device_active boolean;
begin
  if p_authorization_id is null
     or p_actor_user_id is null
     or p_actor_device_id is null
     or p_commit_digest is null
     or octet_length(p_commit_digest) <> 32 then
    return false;
  end if;

  select a.space_id, a.group_id, a.roster_version,
         a.actor_user_id, a.actor_device_id, a.operation,
         a.target_user_id, a.target_device_id, a.target_credential_id,
         a.target_signature_public_key, a.commit_digest,
         a.consumed_at, a.applied_at
    into v_space_id, v_group_id, v_roster_version,
         v_actor_user_id, v_actor_device_id, v_operation,
         v_target_user_id, v_target_device_id, v_target_credential_id,
         v_target_signature_public_key, v_commit_digest,
         v_consumed_at, v_applied_at
    from public.mls_membership_authorizations a
   where a.id = p_authorization_id
   for update;

  if not found
     or v_actor_user_id <> p_actor_user_id
     or v_actor_device_id <> p_actor_device_id
     or v_commit_digest <> p_commit_digest
     or v_consumed_at is null then
    return false;
  end if;

  if v_applied_at is not null then
    return true;
  end if;

  select g.roster_version, g.pending_authorization_id
    into v_current_roster_version, v_pending_authorization_id
    from public.mls_space_groups g
   where g.space_id = v_space_id
     and g.group_id = v_group_id
   for update;

  if not found
     or v_current_roster_version <> v_roster_version
     or v_pending_authorization_id <> p_authorization_id then
    return false;
  end if;

  select (d.status = 'active' and d.revoked_at is null)
    into v_actor_device_active
    from public.mls_devices d
   where d.id = v_actor_device_id
     and d.user_id = v_actor_user_id;

  if not found or not coalesce(v_actor_device_active, false) then
    return false;
  end if;

  if v_operation in ('add', 'update') then
    select (
      d.status = 'active'
      and d.revoked_at is null
      and d.credential_id = v_target_credential_id
      and d.signature_public_key = v_target_signature_public_key
    )
      into v_target_device_active
      from public.mls_devices d
     where d.id = v_target_device_id
       and d.user_id = v_target_user_id;

    if not found or not coalesce(v_target_device_active, false) then
      return false;
    end if;
  end if;

  if v_operation = 'add' then
    insert into public.mls_space_device_roster (
      space_id, user_id, device_id, credential_id, signature_public_key
    ) values (
      v_space_id, v_target_user_id, v_target_device_id,
      v_target_credential_id, v_target_signature_public_key
    );
  elsif v_operation = 'update' then
    update public.mls_space_device_roster
       set credential_id = v_target_credential_id,
           signature_public_key = v_target_signature_public_key,
           updated_at = clock_timestamp()
     where space_id = v_space_id
       and user_id = v_target_user_id
       and device_id = v_target_device_id;

    if not found then
      return false;
    end if;
  elsif v_operation = 'remove' then
    delete from public.mls_space_device_roster
     where space_id = v_space_id
       and user_id = v_target_user_id
       and device_id = v_target_device_id;

    if not found then
      return false;
    end if;
  else
    return false;
  end if;

  update public.mls_space_groups
     set roster_version = roster_version + 1,
         pending_authorization_id = null,
         updated_at = clock_timestamp()
   where space_id = v_space_id
     and group_id = v_group_id
     and pending_authorization_id = p_authorization_id;

  if not found then
    raise exception 'MLS roster finalization lost its pending authorization lock';
  end if;

  update public.mls_membership_authorizations
     set applied_at = clock_timestamp()
   where id = p_authorization_id
     and applied_at is null;

  return found;
end;
$function$;

revoke all on function public.mls_finalize_membership_authorization(uuid, uuid, uuid, bytea)
  from public, anon, authenticated;
grant execute on function public.mls_finalize_membership_authorization(uuid, uuid, uuid, bytea)
  to service_role;

commit;
