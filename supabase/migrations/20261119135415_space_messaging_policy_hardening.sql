begin;
drop policy space_messages_read_active_members on public.space_messages;
drop policy space_messages_admin_read on public.space_messages;

create policy space_messages_read_authorized
on public.space_messages
for select
to authenticated
using (
  private.has_admin_role(null::text)
  or private.can_access_space_messages(space_id, sender_id)
);

revoke all on function private.can_access_space_messages(uuid, uuid) from public, anon;
grant execute on function private.can_access_space_messages(uuid, uuid) to authenticated;
commit;