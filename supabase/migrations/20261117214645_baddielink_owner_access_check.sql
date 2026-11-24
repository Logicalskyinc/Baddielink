
create or replace function public.is_baddielink_owner()
returns boolean language sql stable security definer set search_path = ''
as $$ select private.has_admin_role('owner'); $$;
revoke all on function public.is_baddielink_owner() from public, anon;
grant execute on function public.is_baddielink_owner() to authenticated;
