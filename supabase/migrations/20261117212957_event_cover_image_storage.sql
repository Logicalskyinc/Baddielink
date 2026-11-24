
alter table public.events
  add column if not exists event_image_path text;

alter table public.events
  drop constraint if exists events_event_image_path_owner_folder;

alter table public.events
  add constraint events_event_image_path_owner_folder
  check (
    event_image_path is null
    or event_image_path like created_by::text || '/%'
  );

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'baddielink-event-images',
  'baddielink-event-images',
  false,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set public = false,
    file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists baddielink_event_image_upload_own_folder on storage.objects;
create policy baddielink_event_image_upload_own_folder
on storage.objects
for insert to authenticated
with check (
  bucket_id = 'baddielink-event-images'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and (select private.is_adult_declared((select auth.uid())))
);

drop policy if exists baddielink_event_image_read_owner_or_published on storage.objects;
create policy baddielink_event_image_read_owner_or_published
on storage.objects
for select to authenticated
using (
  bucket_id = 'baddielink-event-images'
  and (
    (storage.foldername(name))[1] = (select auth.uid())::text
    or (
      (select private.is_adult_declared((select auth.uid())))
      and exists (
        select 1
        from public.events e
        where e.event_image_path = objects.name
          and e.status = 'published'
          and not (select private.is_blocked_with(e.created_by))
      )
    )
  )
);

drop policy if exists baddielink_event_image_delete_own_folder on storage.objects;
create policy baddielink_event_image_delete_own_folder
on storage.objects
for delete to authenticated
using (
  bucket_id = 'baddielink-event-images'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);
