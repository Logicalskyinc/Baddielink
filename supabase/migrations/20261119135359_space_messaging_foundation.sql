begin;

create table public.space_messages (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now(),
  constraint space_messages_body_length
    check (char_length(body) between 1 and 2000)
);

create index space_messages_room_history_idx
  on public.space_messages (space_id, created_at desc, id desc);

create index space_messages_sender_idx
  on public.space_messages (sender_id, created_at desc);

create or replace function private.can_access_space_messages(
  target_space_id uuid,
  target_sender_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select
    (select auth.uid()) is not null
    and exists (
      select 1
      from public.spaces s
      join public.space_memberships m on m.space_id = s.id
      join public.profiles viewer on viewer.id = (select auth.uid())
      join public.profiles sender on sender.id = target_sender_id
      where s.id = target_space_id
        and s.status = 'active'
        and m.user_id = (select auth.uid())
        and m.status = 'active'
        and viewer.moderation_status = 'approved'
        and sender.moderation_status = 'approved'
        and private.is_adult_declared((select auth.uid()))
        and private.is_adult_declared(target_sender_id)
        and not private.is_blocked_with(target_sender_id)
    );
$function$;

alter table public.space_messages enable row level security;

revoke all on public.space_messages from anon, public;
grant select, insert on public.space_messages to authenticated;

create policy space_messages_read_active_members
on public.space_messages
for select
to authenticated
using (private.can_access_space_messages(space_id, sender_id));

create policy space_messages_insert_active_members
on public.space_messages
for insert
to authenticated
with check (
  sender_id = (select auth.uid())
  and private.can_access_space_messages(space_id, sender_id)
);

create policy space_messages_admin_read
on public.space_messages
for select
to authenticated
using (private.has_admin_role(null::text));

alter table public.reports
  add column space_message_id uuid
  references public.space_messages(id) on delete set null;

alter table public.reports
  drop constraint reports_target_required;

alter table public.reports
  add constraint reports_target_required
  check (
    reported_user_id is not null
    or message_id is not null
    or space_message_id is not null
  );

create index reports_space_message_idx
  on public.reports(space_message_id)
  where space_message_id is not null;

do $block$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'space_messages'
  ) then
    alter publication supabase_realtime add table public.space_messages;
  end if;
end;
$block$;

commit;