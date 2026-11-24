
create or replace function public.admin_list_roles()
returns table(user_id uuid,email text,role text,created_at timestamptz)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.has_admin_role('owner') then raise exception 'Owner access required' using errcode='42501'; end if;
  return query select r.user_id,u.email::text,r.role,r.created_at from private.admin_roles r join auth.users u on u.id=r.user_id order by r.created_at;
end $$;
revoke all on function public.admin_list_roles() from public, anon;
grant execute on function public.admin_list_roles() to authenticated;
