-- BaddieLink Salons foundation.
-- Communities will reuse this shared space model in a later migration.
-- Encrypted messaging is intentionally excluded until the E2EE implementation is verified.

create table public.spaces (
  id uuid primary key default gen_random_uuid(),
  space_type text not null default 'salon' check (space_type in ('salon', 'community')),
  name text not null check (char_length(btrim(name)) between 3 and 60),
  slug text not null unique check (slug ~ '^[a-z0-9-]{3,72}$'),
  description text not null default '' check (char_length(description) <= 500),
  city text not null default 'Abidjan' check (char_length(btrim(city)) between 1 and 80),
  visibility text not null default 'public' check (visibility in ('public', 'private')),
  join_policy text not null default 'open' check (join_policy in ('open', 'approval', 'invite_only')),
  status text not null default 'active' check (status in ('active', 'suspended', 'archived')),
  owner_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint spaces_private_join_policy check (visibility <> 'private' or join_policy <> 'open')
);

create table public.space_memberships (
  space_id uuid not null references public.spaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'moderator', 'member')),
  status text not null default 'pending' check (status in ('pending', 'active', 'removed', 'banned')),
  joined_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (space_id, user_id)
);

create index spaces_active_discovery_idx on public.spaces (space_type, city, created_at desc)
  where status = 'active' and visibility = 'public';
create index space_memberships_user_status_idx on public.space_memberships (user_id, status, created_at desc);
create index space_memberships_space_status_idx on public.space_memberships (space_id, status, created_at desc);

create or replace function private.is_active_space_member(p_space_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $func$
  select (select auth.uid()) is not null and exists (
    select 1 from public.space_memberships m
    where m.space_id = p_space_id and m.user_id = (select auth.uid())
      and m.status = 'active'
  );
$func$;

create or replace function private.is_space_owner(p_space_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $func$
  select (select auth.uid()) is not null and exists (
    select 1 from public.spaces s
    where s.id = p_space_id and s.owner_id = (select auth.uid())
  );
$func$;

revoke all on function private.is_active_space_member(uuid) from public, anon;
revoke all on function private.is_space_owner(uuid) from public, anon;
grant execute on function private.is_active_space_member(uuid) to authenticated;
grant execute on function private.is_space_owner(uuid) to authenticated;

create or replace function private.protect_space_membership_identity()
returns trigger language plpgsql set search_path = ''
as $func$
begin
  if new.space_id <> old.space_id or new.user_id <> old.user_id then
    raise exception 'Space membership identity cannot be changed';
  end if;
  if old.role = 'owner' then
    raise exception 'Space owner membership cannot be changed';
  end if;
  return new;
end;
$func$;

create trigger space_memberships_protect_identity
before update on public.space_memberships
for each row execute function private.protect_space_membership_identity();

create or replace function private.add_space_owner_membership()
returns trigger language plpgsql security definer set search_path = ''
as $func$
begin
  insert into public.space_memberships (space_id, user_id, role, status, joined_at)
  values (new.id, new.owner_id, 'owner', 'active', now());
  return new;
end;
$func$;

create trigger spaces_add_owner_membership after insert on public.spaces
for each row execute function private.add_space_owner_membership();

alter table public.spaces enable row level security;
alter table public.space_memberships enable row level security;
revoke all on public.spaces from anon, authenticated;
revoke all on public.space_memberships from anon, authenticated;
grant select, insert, update on public.spaces to authenticated;
grant select, insert, update on public.space_memberships to authenticated;

create policy spaces_select_public_or_member on public.spaces
for select to authenticated using (
  status = 'active' and (
    (visibility = 'public' and space_type = 'salon')
    or exists (select 1 from public.space_memberships m
      where m.space_id = spaces.id and m.user_id = (select auth.uid())
        and m.status in ('active', 'pending'))
  )
);

create policy spaces_insert_approved_adult_owner on public.spaces
for insert to authenticated with check (
  owner_id = (select auth.uid()) and space_type = 'salon' and status = 'active'
  and exists (select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.moderation_status = 'approved')
  and (select private.is_adult_declared((select auth.uid())))
);

create policy spaces_update_owner on public.spaces
for update to authenticated
using (owner_id = (select auth.uid()) and (select private.is_active_space_member(spaces.id)))
with check (
  owner_id = (select auth.uid()) and space_type = 'salon'
  and status in ('active', 'archived')
);

create policy memberships_select_self_or_active_peers on public.space_memberships
for select to authenticated using (
  user_id = (select auth.uid())
  or (select private.is_active_space_member(space_memberships.space_id))
);

create policy memberships_insert_self_join on public.space_memberships
for insert to authenticated with check (
  user_id = (select auth.uid()) and role = 'member'
  and exists (select 1 from public.spaces s where s.id = space_id
    and s.space_type = 'salon' and s.status = 'active'
    and s.visibility = 'public'
    and ((s.join_policy = 'open' and status = 'active')
      or (s.join_policy = 'approval' and status = 'pending')))
  and (select private.is_adult_declared((select auth.uid())))
);

create policy memberships_owner_invite on public.space_memberships
for insert to authenticated with check (
  user_id <> (select auth.uid()) and role = 'member' and status = 'active'
  and (select private.is_space_owner(space_id))
);

create policy memberships_owner_manage on public.space_memberships
for update to authenticated
using (
  role <> 'owner' and (select private.is_space_owner(space_memberships.space_id))
)
with check (
  role in ('member', 'moderator') and status in ('active', 'removed', 'banned')
  and (select private.is_space_owner(space_memberships.space_id))
);

create policy memberships_self_leave on public.space_memberships
for update to authenticated using (
  user_id = (select auth.uid()) and role = 'member' and status in ('active', 'pending')
)
with check (user_id = (select auth.uid()) and role = 'member' and status = 'removed');

comment on table public.spaces is 'Shared public/private space model for BaddieLink Salons and Communities. Encrypted messaging is separate.';
comment on table public.space_memberships is 'Space membership, roles and join state. Account identity remains platform-controlled.';
