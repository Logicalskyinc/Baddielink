-- Disposable PostgreSQL fixture for the MLS control-plane migration.
-- This is intentionally isolated from the hosted Supabase project.
\set ON_ERROR_STOP on

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;
create schema private;

create table auth.users (
  id uuid primary key
);

create table public.spaces (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'active'
    check (status in ('active', 'suspended', 'archived'))
);

create table public.space_memberships (
  space_id uuid not null references public.spaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'moderator', 'member')),
  status text not null check (status in ('pending', 'active', 'removed', 'banned')),
  primary key (space_id, user_id)
);

insert into auth.users (id) values
  ('10000000-0000-4000-8000-000000000001'),
  ('10000000-0000-4000-8000-000000000002'),
  ('10000000-0000-4000-8000-000000000003');

-- Existing room and membership must be backfilled by the migration.
insert into public.spaces (id, owner_id, status)
values (
  '20000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001',
  'active'
);

insert into public.space_memberships (space_id, user_id, role, status)
values (
  '20000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000001',
  'owner',
  'active'
);
