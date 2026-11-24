
create table if not exists public.organizer_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  organization_name text not null check (char_length(trim(organization_name)) between 2 and 120),
  organization_type text not null check (organization_type in ('business','association','venue','independent','other')),
  website_url text,
  description text not null check (char_length(trim(description)) between 20 and 1200),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.organizer_applications enable row level security;
grant select, insert on public.organizer_applications to authenticated;
drop policy if exists organizer_applications_read_own on public.organizer_applications;
create policy organizer_applications_read_own on public.organizer_applications
for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists organizer_applications_insert_own on public.organizer_applications;
create policy organizer_applications_insert_own on public.organizer_applications
for insert to authenticated with check (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid())
      and p.moderation_status = 'approved'
      and (select private.is_adult_declared(p.id))
  )
);

create table if not exists public.event_reports (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reason text not null check (reason in ('spam','misleading','unsafe','harassment','other')),
  details text check (details is null or char_length(details) <= 1000),
  status text not null default 'pending' check (status in ('pending','reviewed','dismissed')),
  created_at timestamptz not null default now(),
  unique (event_id, reporter_id)
);
create index if not exists event_reports_status_created_idx on public.event_reports(status, created_at);
alter table public.event_reports enable row level security;
grant select, insert on public.event_reports to authenticated;
drop policy if exists event_reports_read_own on public.event_reports;
create policy event_reports_read_own on public.event_reports
for select to authenticated using (reporter_id = (select auth.uid()));
drop policy if exists event_reports_insert_published on public.event_reports;
create policy event_reports_insert_published on public.event_reports
for insert to authenticated with check (
  reporter_id = (select auth.uid())
  and (select private.is_adult_declared((select auth.uid())))
  and exists (
    select 1 from public.events e
    where e.id = event_reports.event_id
      and e.status = 'published'
      and e.created_by <> (select auth.uid())
  )
);
