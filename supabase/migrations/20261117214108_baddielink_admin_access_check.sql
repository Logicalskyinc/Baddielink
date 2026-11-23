
create or replace function public.is_baddielink_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select private.has_admin_role(null); $$;
revoke all on function public.is_baddielink_admin() from public, anon;
grant execute on function public.is_baddielink_admin() to authenticated;

create or replace function public.admin_set_moderator(p_user_id uuid, p_enabled boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_before jsonb; v_after jsonb;
begin
  if not private.has_admin_role('owner') then raise exception 'Owner access required' using errcode='42501'; end if;
  if p_user_id=auth.uid() then raise exception 'Owner role cannot be changed here' using errcode='22023'; end if;
  select to_jsonb(r) into v_before from private.admin_roles r where r.user_id=p_user_id;
  if p_enabled then
    insert into private.admin_roles(user_id,role,granted_by)
    values(p_user_id,'moderator',auth.uid())
    on conflict(user_id) do update set role='moderator',granted_by=auth.uid();
  else
    delete from private.admin_roles where user_id=p_user_id and role='moderator';
  end if;
  select to_jsonb(r) into v_after from private.admin_roles r where r.user_id=p_user_id;
  insert into public.admin_audit_log(actor_id,action,target_type,target_id,reason,before_data,after_data)
  values(auth.uid(),case when p_enabled then 'moderator_granted' else 'moderator_revoked' end,'admin_role',p_user_id,left(p_reason,1000),v_before,v_after);
end $$;
revoke all on function public.admin_set_moderator(uuid,boolean,text) from public, anon;
grant execute on function public.admin_set_moderator(uuid,boolean,text) to authenticated;
