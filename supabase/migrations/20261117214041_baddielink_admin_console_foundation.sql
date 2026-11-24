
create table if not exists private.admin_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','moderator')),
  granted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
revoke all on private.admin_roles from anon, authenticated;
grant usage on schema private to authenticated;

insert into private.admin_roles (user_id, role, granted_by)
values ('24176239-3ccf-4153-8da0-943f130b522a'::uuid, 'owner', null)
on conflict (user_id) do update set role='owner';

create or replace function private.has_admin_role(required_role text default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from private.admin_roles r
    where r.user_id = (select auth.uid())
      and (required_role is null or r.role = required_role or r.role = 'owner')
  );
$$;
revoke all on function private.has_admin_role(text) from public, anon;
grant execute on function private.has_admin_role(text) to authenticated;

create table if not exists public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references auth.users(id) on delete restrict,
  action text not null,
  target_type text not null,
  target_id uuid not null,
  reason text,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);
alter table public.admin_audit_log enable row level security;
revoke all on public.admin_audit_log from anon, authenticated;
grant select on public.admin_audit_log to authenticated;
create policy admin_audit_log_read_admin on public.admin_audit_log
for select to authenticated using (private.has_admin_role(null));

do $$
declare t text;
begin
  foreach t in array array['profiles','profile_photos','events','event_organizers','organizer_applications','event_reports','reports'] loop
    execute format('drop policy if exists %I on public.%I', 'admin_read_'||t, t);
    execute format('create policy %I on public.%I for select to authenticated using (private.has_admin_role(null))', 'admin_read_'||t, t);
  end loop;
end $$;

create or replace function public.admin_review_event(p_event_id uuid, p_decision text, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_before jsonb; v_after jsonb; v_status text;
begin
  if not private.has_admin_role(null) then raise exception 'Admin access required' using errcode='42501'; end if;
  if p_decision not in ('publish','reject') then raise exception 'Invalid event decision' using errcode='22023'; end if;
  select to_jsonb(e) into v_before from public.events e where e.id=p_event_id and e.status='pending_review' for update;
  if v_before is null then raise exception 'Pending event not found' using errcode='P0002'; end if;
  v_status := case when p_decision='publish' then 'published' else 'rejected' end;
  update public.events set status=v_status, updated_at=now() where id=p_event_id returning to_jsonb(events) into v_after;
  insert into public.admin_audit_log(actor_id,action,target_type,target_id,reason,before_data,after_data)
  values(auth.uid(),'event_'||p_decision,'event',p_event_id,left(p_reason,1000),v_before,v_after);
end $$;

create or replace function public.admin_review_organizer_application(p_application_id uuid, p_decision text, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_before jsonb; v_after jsonb; v_user uuid; v_name text;
begin
  if not private.has_admin_role(null) then raise exception 'Admin access required' using errcode='42501'; end if;
  if p_decision not in ('approve','reject') then raise exception 'Invalid organizer decision' using errcode='22023'; end if;
  select to_jsonb(a), a.user_id, a.organization_name into v_before,v_user,v_name
  from public.organizer_applications a where a.id=p_application_id and a.status='pending' for update;
  if v_before is null then raise exception 'Pending organizer application not found' using errcode='P0002'; end if;
  update public.organizer_applications set status=case when p_decision='approve' then 'approved' else 'rejected' end, reviewed_at=now(), updated_at=now()
  where id=p_application_id returning to_jsonb(organizer_applications) into v_after;
  if p_decision='approve' then
    insert into public.event_organizers(user_id,organization_name,status,approved_at)
    values(v_user,v_name,'approved',now())
    on conflict(user_id) do update set organization_name=excluded.organization_name,status='approved',approved_at=now();
  end if;
  insert into public.admin_audit_log(actor_id,action,target_type,target_id,reason,before_data,after_data)
  values(auth.uid(),'organizer_'||p_decision,'organizer_application',p_application_id,left(p_reason,1000),v_before,v_after);
end $$;

create or replace function public.admin_review_profile_photo(p_photo_id uuid, p_decision text, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_before jsonb; v_after jsonb;
begin
  if not private.has_admin_role(null) then raise exception 'Admin access required' using errcode='42501'; end if;
  if p_decision not in ('approve','reject') then raise exception 'Invalid photo decision' using errcode='22023'; end if;
  select to_jsonb(p) into v_before from public.profile_photos p where p.id=p_photo_id and p.moderation_status='pending' for update;
  if v_before is null then raise exception 'Pending profile photo not found' using errcode='P0002'; end if;
  update public.profile_photos set moderation_status=case when p_decision='approve' then 'approved' else 'rejected' end
  where id=p_photo_id returning to_jsonb(profile_photos) into v_after;
  insert into public.admin_audit_log(actor_id,action,target_type,target_id,reason,before_data,after_data)
  values(auth.uid(),'profile_photo_'||p_decision,'profile_photo',p_photo_id,left(p_reason,1000),v_before,v_after);
end $$;

create or replace function public.admin_review_event_report(p_report_id uuid, p_decision text, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_before jsonb; v_after jsonb;
begin
  if not private.has_admin_role(null) then raise exception 'Admin access required' using errcode='42501'; end if;
  if p_decision not in ('reviewed','dismissed') then raise exception 'Invalid report decision' using errcode='22023'; end if;
  select to_jsonb(r) into v_before from public.event_reports r where r.id=p_report_id and r.status='pending' for update;
  if v_before is null then raise exception 'Pending event report not found' using errcode='P0002'; end if;
  update public.event_reports set status=p_decision where id=p_report_id returning to_jsonb(event_reports) into v_after;
  insert into public.admin_audit_log(actor_id,action,target_type,target_id,reason,before_data,after_data)
  values(auth.uid(),'event_report_'||p_decision,'event_report',p_report_id,left(p_reason,1000),v_before,v_after);
end $$;

create or replace function public.admin_review_member(p_user_id uuid, p_decision text, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_before jsonb; v_after jsonb;
begin
  if not private.has_admin_role(null) then raise exception 'Admin access required' using errcode='42501'; end if;
  if p_user_id=auth.uid() then raise exception 'Cannot moderate your own admin account' using errcode='22023'; end if;
  if p_decision not in ('approve','restrict','remove') then raise exception 'Invalid member decision' using errcode='22023'; end if;
  select to_jsonb(p) into v_before from public.profiles p where p.id=p_user_id for update;
  if v_before is null then raise exception 'Member profile not found' using errcode='P0002'; end if;
  update public.profiles set
    moderation_status=case p_decision when 'approve' then 'approved' when 'restrict' then 'restricted' else 'removed' end,
    is_discoverable=case when p_decision='approve' then is_discoverable else false end,
    updated_at=now()
  where id=p_user_id returning to_jsonb(profiles) into v_after;
  insert into public.admin_audit_log(actor_id,action,target_type,target_id,reason,before_data,after_data)
  values(auth.uid(),'member_'||p_decision,'member',p_user_id,left(p_reason,1000),v_before,v_after);
end $$;

create or replace function public.admin_review_member_report(p_report_id uuid, p_decision text, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_before jsonb; v_after jsonb;
begin
  if not private.has_admin_role(null) then raise exception 'Admin access required' using errcode='42501'; end if;
  if p_decision not in ('reviewing','actioned','closed') then raise exception 'Invalid member report decision' using errcode='22023'; end if;
  select to_jsonb(r) into v_before from public.reports r where r.id=p_report_id and r.status in ('open','reviewing') for update;
  if v_before is null then raise exception 'Open member report not found' using errcode='P0002'; end if;
  update public.reports set status=p_decision where id=p_report_id returning to_jsonb(reports) into v_after;
  insert into public.admin_audit_log(actor_id,action,target_type,target_id,reason,before_data,after_data)
  values(auth.uid(),'member_report_'||p_decision,'member_report',p_report_id,left(p_reason,1000),v_before,v_after);
end $$;

revoke all on function public.admin_review_event(uuid,text,text) from public, anon;
revoke all on function public.admin_review_organizer_application(uuid,text,text) from public, anon;
revoke all on function public.admin_review_profile_photo(uuid,text,text) from public, anon;
revoke all on function public.admin_review_event_report(uuid,text,text) from public, anon;
revoke all on function public.admin_review_member(uuid,text,text) from public, anon;
revoke all on function public.admin_review_member_report(uuid,text,text) from public, anon;
grant execute on function public.admin_review_event(uuid,text,text) to authenticated;
grant execute on function public.admin_review_organizer_application(uuid,text,text) to authenticated;
grant execute on function public.admin_review_profile_photo(uuid,text,text) to authenticated;
grant execute on function public.admin_review_event_report(uuid,text,text) to authenticated;
grant execute on function public.admin_review_member(uuid,text,text) to authenticated;
grant execute on function public.admin_review_member_report(uuid,text,text) to authenticated;
