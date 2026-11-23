
create policy baddielink_photo_read_admin
on storage.objects for select to authenticated
using (bucket_id='baddielink-profile-photos' and private.has_admin_role(null));

create index if not exists admin_roles_granted_by_idx on private.admin_roles(granted_by);
create index if not exists admin_audit_log_actor_created_idx on public.admin_audit_log(actor_id,created_at desc);
