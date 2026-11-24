create schema if not exists private;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  display_name text not null,
  bio text not null default '',
  city text not null default 'Abidjan',
  country_code text not null default 'CI' check (country_code = 'CI'),
  gender text,
  interested_in text[] not null default '{}',
  is_discoverable boolean not null default false,
  moderation_status text not null default 'pending'
    check (moderation_status in ('pending', 'approved', 'restricted', 'removed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_username_format check (username ~ '^[a-z0-9_]{3,24}$'),
  constraint profiles_display_name_length check (char_length(display_name) between 1 and 60),
  constraint profiles_bio_length check (char_length(bio) <= 500),
  constraint profiles_city_length check (char_length(city) between 1 and 80)
);

create table public.user_private_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  date_of_birth date,
  age_declaration_at timestamptz,
  age_verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint dob_not_future check (date_of_birth is null or date_of_birth <= current_date)
);

create table public.profile_photos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  object_path text not null unique,
  display_order smallint not null default 0 check (display_order between 0 and 9),
  moderation_status text not null default 'pending'
    check (moderation_status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now()
);

create table public.likes (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  receiver_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint likes_no_self check (sender_id <> receiver_id),
  constraint likes_unique_pair unique (sender_id, receiver_id)
);

create table public.matches (
  id uuid primary key default gen_random_uuid(),
  user_one_id uuid not null references auth.users(id) on delete cascade,
  user_two_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  constraint matches_canonical_pair check (user_one_id < user_two_id),
  constraint matches_unique_pair unique (user_one_id, user_two_id)
);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint messages_body_length check (char_length(body) between 1 and 2000)
);

create table public.blocks (
  id uuid primary key default gen_random_uuid(),
  blocker_id uuid not null references auth.users(id) on delete cascade,
  blocked_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint blocks_no_self check (blocker_id <> blocked_id),
  constraint blocks_unique_pair unique (blocker_id, blocked_id)
);

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reported_user_id uuid references auth.users(id) on delete set null,
  message_id uuid references public.messages(id) on delete set null,
  reason text not null check (reason in ('harassment', 'fake_profile', 'underage_safety', 'scam', 'sexual_solicitation', 'spam', 'other')),
  details text not null default '',
  status text not null default 'open' check (status in ('open', 'reviewing', 'actioned', 'closed')),
  created_at timestamptz not null default now(),
  constraint reports_target_required check (reported_user_id is not null or message_id is not null),
  constraint reports_details_length check (char_length(details) <= 2000)
);

create index profiles_discovery_idx
  on public.profiles (city, created_at desc)
  where is_discoverable = true and moderation_status = 'approved';
create index profile_photos_user_order_idx on public.profile_photos (user_id, display_order);
create index likes_receiver_idx on public.likes (receiver_id, created_at desc);
create index matches_user_one_idx on public.matches (user_one_id, created_at desc);
create index matches_user_two_idx on public.matches (user_two_id, created_at desc);
create index messages_match_created_idx on public.messages (match_id, created_at desc);
create index blocks_blocked_idx on public.blocks (blocked_id);
create index reports_status_created_idx on public.reports (status, created_at);

create or replace function private.is_blocked_with(target_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.blocks b
    where
      (b.blocker_id = (select auth.uid()) and b.blocked_id = target_user_id)
      or
      (b.blocked_id = (select auth.uid()) and b.blocker_id = target_user_id)
  );
$$;

revoke all on function private.is_blocked_with(uuid) from public;
grant usage on schema private to authenticated;
grant execute on function private.is_blocked_with(uuid) to authenticated;

create or replace function private.create_match_on_mutual_like()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  first_user uuid;
  second_user uuid;
begin
  if exists (
    select 1 from public.likes l
    where l.sender_id = new.receiver_id and l.receiver_id = new.sender_id
  ) and not exists (
    select 1 from public.blocks b
    where (b.blocker_id = new.sender_id and b.blocked_id = new.receiver_id)
       or (b.blocker_id = new.receiver_id and b.blocked_id = new.sender_id)
  ) then
    first_user := least(new.sender_id, new.receiver_id);
    second_user := greatest(new.sender_id, new.receiver_id);
    insert into public.matches (user_one_id, user_two_id)
    values (first_user, second_user)
    on conflict (user_one_id, user_two_id) do nothing;
  end if;
  return new;
end;
$$;

revoke all on function private.create_match_on_mutual_like() from public;

create trigger likes_create_mutual_match
after insert on public.likes
for each row execute function private.create_match_on_mutual_like();

create or replace function private.create_user_records()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  base_name text;
  safe_name text;
begin
  base_name := coalesce(nullif(trim(new.raw_user_meta_data ->> 'username'), ''), 'member');
  safe_name := lower(regexp_replace(base_name, '[^a-zA-Z0-9_]', '', 'g'));
  safe_name := left(safe_name, 18);
  if char_length(safe_name) < 3 then
    safe_name := 'member';
  end if;

  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    safe_name || '_' || left(replace(new.id::text, '-', ''), 5),
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), 'Nouveau membre')
  );

  insert into public.user_private_settings (user_id)
  values (new.id);

  return new;
end;
$$;

revoke all on function private.create_user_records() from public;

create trigger on_auth_user_created_baddielink
after insert on auth.users
for each row execute function private.create_user_records();

alter table public.profiles enable row level security;
alter table public.user_private_settings enable row level security;
alter table public.profile_photos enable row level security;
alter table public.likes enable row level security;
alter table public.matches enable row level security;
alter table public.messages enable row level security;
alter table public.blocks enable row level security;
alter table public.reports enable row level security;

revoke all on public.profiles, public.user_private_settings, public.profile_photos,
  public.likes, public.matches, public.messages, public.blocks, public.reports
from anon, authenticated;

grant select on public.profiles to authenticated;
grant insert (id, username, display_name, bio, city, gender, interested_in, is_discoverable)
  on public.profiles to authenticated;
grant update (username, display_name, bio, city, gender, interested_in, is_discoverable)
  on public.profiles to authenticated;

grant select, update (date_of_birth, age_declaration_at)
  on public.user_private_settings to authenticated;
grant select, insert (user_id, object_path, display_order), update (display_order)
  on public.profile_photos to authenticated;
grant select, insert, delete on public.likes to authenticated;
grant select on public.matches to authenticated;
grant select, insert on public.messages to authenticated;
grant update (read_at) on public.messages to authenticated;
grant select, insert, delete on public.blocks to authenticated;
grant select, insert on public.reports to authenticated;

create policy "profiles_visible_to_owner_or_approved_discovery"
on public.profiles for select to authenticated
using (
  id = (select auth.uid())
  or (
    is_discoverable = true
    and moderation_status = 'approved'
    and id <> (select auth.uid())
    and not (select private.is_blocked_with(id))
  )
);

create policy "profiles_insert_own_pending"
on public.profiles for insert to authenticated
with check (id = (select auth.uid()) and moderation_status = 'pending');

create policy "profiles_update_own"
on public.profiles for update to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

create policy "private_settings_read_own"
on public.user_private_settings for select to authenticated
using (user_id = (select auth.uid()));

create policy "private_settings_update_own"
on public.user_private_settings for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

create policy "profile_photos_read_own_or_approved_discovery"
on public.profile_photos for select to authenticated
using (
  user_id = (select auth.uid())
  or (
    moderation_status = 'approved'
    and exists (
      select 1 from public.profiles p
      where p.id = profile_photos.user_id
        and p.is_discoverable = true
        and p.moderation_status = 'approved'
    )
    and not (select private.is_blocked_with(user_id))
  )
);

create policy "profile_photos_insert_own"
on public.profile_photos for insert to authenticated
with check (user_id = (select auth.uid()) and moderation_status = 'pending');

create policy "profile_photos_update_own"
on public.profile_photos for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

create policy "likes_read_participants"
on public.likes for select to authenticated
using (
  sender_id = (select auth.uid())
  or receiver_id = (select auth.uid())
);

create policy "likes_insert_own"
on public.likes for insert to authenticated
with check (
  sender_id = (select auth.uid())
  and sender_id <> receiver_id
  and not (select private.is_blocked_with(receiver_id))
  and exists (
    select 1 from public.profiles p
    where p.id = receiver_id
      and p.is_discoverable = true
      and p.moderation_status = 'approved'
  )
);

create policy "likes_delete_own"
on public.likes for delete to authenticated
using (sender_id = (select auth.uid()));

create policy "matches_read_participants"
on public.matches for select to authenticated
using (
  (user_one_id = (select auth.uid()) or user_two_id = (select auth.uid()))
  and not (select private.is_blocked_with(
    case when user_one_id = (select auth.uid()) then user_two_id else user_one_id end
  ))
);

create policy "messages_read_match_participants"
on public.messages for select to authenticated
using (
  exists (
    select 1 from public.matches m
    where m.id = messages.match_id
      and (m.user_one_id = (select auth.uid()) or m.user_two_id = (select auth.uid()))
      and m.ended_at is null
  )
  and not (select private.is_blocked_with(sender_id))
);

create policy "messages_insert_sender_in_active_match"
on public.messages for insert to authenticated
with check (
  sender_id = (select auth.uid())
  and exists (
    select 1 from public.matches m
    where m.id = messages.match_id
      and (m.user_one_id = (select auth.uid()) or m.user_two_id = (select auth.uid()))
      and m.ended_at is null
      and not (select private.is_blocked_with(
        case when m.user_one_id = (select auth.uid()) then m.user_two_id else m.user_one_id end
      ))
  )
);

create policy "messages_update_read_receipt"
on public.messages for update to authenticated
using (
  sender_id <> (select auth.uid())
  and exists (
    select 1 from public.matches m
    where m.id = messages.match_id
      and (m.user_one_id = (select auth.uid()) or m.user_two_id = (select auth.uid()))
  )
)
with check (
  sender_id <> (select auth.uid())
);

create policy "blocks_read_own"
on public.blocks for select to authenticated
using (blocker_id = (select auth.uid()));

create policy "blocks_insert_own"
on public.blocks for insert to authenticated
with check (blocker_id = (select auth.uid()) and blocker_id <> blocked_id);

create policy "blocks_delete_own"
on public.blocks for delete to authenticated
using (blocker_id = (select auth.uid()));

create policy "reports_read_own"
on public.reports for select to authenticated
using (reporter_id = (select auth.uid()));

create policy "reports_insert_own"
on public.reports for insert to authenticated
with check (
  reporter_id = (select auth.uid())
  and (reported_user_id is null or reported_user_id <> (select auth.uid()))
);