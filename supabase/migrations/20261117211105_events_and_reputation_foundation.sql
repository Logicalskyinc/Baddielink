
create table if not exists public.reputation_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  score integer not null default 0 check (score >= 0),
  rank text not null default 'beginner'
    check (rank in ('beginner','novice','intermediate','advanced','expert','legend')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.reputation_profiles enable row level security;
grant select on public.reputation_profiles to authenticated;

create policy reputation_profiles_read_visible
on public.reputation_profiles
for select to authenticated
using (
  user_id = (select auth.uid())
  or exists (
    select 1 from public.profiles p
    where p.id = reputation_profiles.user_id
      and p.is_discoverable = true
      and p.moderation_status = 'approved'
      and (select private.is_adult_declared(p.id))
      and not (select private.is_blocked_with(p.id))
  )
);

create schema if not exists private;

create or replace function private.ensure_reputation_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.reputation_profiles (user_id)
  values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

revoke all on function private.ensure_reputation_profile() from public, anon, authenticated;

drop trigger if exists profiles_create_reputation_profile on public.profiles;
create trigger profiles_create_reputation_profile
after insert on public.profiles
for each row execute function private.ensure_reputation_profile();

insert into public.reputation_profiles (user_id)
select id from public.profiles
on conflict (user_id) do nothing;

create table if not exists public.event_organizers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  organization_name text not null default 'Organisateur',
  status text not null default 'pending'
    check (status in ('pending','approved','trusted','suspended')),
  approved_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.event_organizers enable row level security;
grant select on public.event_organizers to authenticated;

create policy event_organizers_read_own_or_approved
on public.event_organizers
for select to authenticated
using (
  user_id = (select auth.uid())
  or status in ('approved','trusted')
);

create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 3 and 120),
  description text not null check (char_length(description) between 10 and 2000),
  category text not null check (category in ('concert','party','exhibition','networking','community','culture','sports','other')),
  organizer_name text not null check (char_length(organizer_name) between 2 and 120),
  city text not null default 'Abidjan' check (char_length(city) between 2 and 80),
  district text check (district is null or char_length(district) <= 80),
  venue_name text not null check (char_length(venue_name) between 2 and 120),
  address text not null check (char_length(address) between 3 and 240),
  starts_at timestamptz not null,
  ends_at timestamptz,
  entry_fee_xof integer not null default 0 check (entry_fee_xof between 0 and 100000000),
  status text not null default 'pending_review'
    check (status in ('pending_review','published','rejected','cancelled','completed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint events_valid_time_range check (ends_at is null or ends_at > starts_at)
);

create index if not exists events_published_city_start_idx
  on public.events (city, starts_at)
  where status = 'published';
create index if not exists events_creator_created_idx
  on public.events (created_by, created_at desc);

alter table public.events enable row level security;
grant select, insert, update on public.events to authenticated;

create policy events_read_published_or_own
on public.events
for select to authenticated
using (status = 'published' or created_by = (select auth.uid()));

create policy events_submit_or_organizer_publish
on public.events
for insert to authenticated
with check (
  created_by = (select auth.uid())
  and exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid())
      and p.moderation_status = 'approved'
      and (select private.is_adult_declared(p.id))
  )
  and (
    status = 'pending_review'
    or (
      status = 'published'
      and exists (
        select 1 from public.event_organizers eo
        where eo.user_id = (select auth.uid())
          and eo.status in ('approved','trusted')
      )
    )
  )
);

create policy events_update_own_pending_or_organizer
on public.events
for update to authenticated
using (
  created_by = (select auth.uid())
  and (
    status = 'pending_review'
    or (
      status = 'published'
      and exists (
        select 1 from public.event_organizers eo
        where eo.user_id = (select auth.uid())
          and eo.status in ('approved','trusted')
      )
    )
  )
)
with check (
  created_by = (select auth.uid())
  and (
    status in ('pending_review','cancelled')
    or (
      status = 'published'
      and exists (
        select 1 from public.event_organizers eo
        where eo.user_id = (select auth.uid())
          and eo.status in ('approved','trusted')
      )
    )
  )
);

create table if not exists public.event_interests (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

create index if not exists event_interests_user_created_idx
  on public.event_interests (user_id, created_at desc);

alter table public.event_interests enable row level security;
grant select, insert, delete on public.event_interests to authenticated;

create policy event_interests_read_own
on public.event_interests
for select to authenticated
using (user_id = (select auth.uid()));

create policy event_interests_insert_own_published_event
on public.event_interests
for insert to authenticated
with check (
  user_id = (select auth.uid())
  and (select private.is_adult_declared((select auth.uid())))
  and exists (
    select 1 from public.events e
    join public.profiles p on p.id = e.created_by
    where e.id = event_interests.event_id
      and e.status = 'published'
      and p.moderation_status = 'approved'
      and not (select private.is_blocked_with(e.created_by))
  )
);

create policy event_interests_delete_own
on public.event_interests
for delete to authenticated
using (user_id = (select auth.uid()));
