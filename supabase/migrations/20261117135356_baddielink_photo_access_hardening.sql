
-- Restrict discovery-photo reads to adult-declared accounts as well.
drop policy if exists profile_photos_read_own_or_approved_discovery on public.profile_photos;
create policy profile_photos_read_own_or_approved_discovery
on public.profile_photos for select to authenticated
using (
  user_id = (select auth.uid())
  or (
    (select private.is_adult_declared((select auth.uid())))
    and moderation_status = 'approved'
    and exists (
      select 1 from public.profiles p
      where p.id = profile_photos.user_id
        and p.is_discoverable = true
        and p.moderation_status = 'approved'
        and (select private.is_adult_declared(p.id))
    )
    and not (select private.is_blocked_with(profile_photos.user_id))
  )
);

-- Only adult-declared users may upload photos to their private folder.
drop policy if exists baddielink_photo_upload_own_folder on storage.objects;
create policy baddielink_photo_upload_own_folder
on storage.objects for insert to authenticated
with check (
  bucket_id = 'baddielink-profile-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and (select private.is_adult_declared((select auth.uid())))
);

-- Storage reads for discovery also require the requesting account to be adult-declared.
drop policy if exists baddielink_photo_read_owner_or_approved_discovery on storage.objects;
create policy baddielink_photo_read_owner_or_approved_discovery
on storage.objects for select to authenticated
using (
  bucket_id = 'baddielink-profile-photos'
  and (
    (storage.foldername(name))[1] = (select auth.uid())::text
    or (
      (select private.is_adult_declared((select auth.uid())))
      and exists (
        select 1
        from public.profile_photos ph
        join public.profiles p on p.id = ph.user_id
        where ph.object_path = storage.objects.name
          and ph.user_id::text = (storage.foldername(storage.objects.name))[1]
          and ph.moderation_status = 'approved'
          and p.moderation_status = 'approved'
          and p.is_discoverable = true
          and (select private.is_adult_declared(ph.user_id))
          and not (select private.is_blocked_with(ph.user_id))
      )
    )
  )
);

-- Enforce a maximum of ten photo metadata records per user.
create or replace function private.enforce_profile_photo_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (
    select count(*) from public.profile_photos
    where user_id = new.user_id
  ) >= 10 then
    raise exception 'A profile can have at most 10 photos';
  end if;
  return new;
end;
$$;
revoke all on function private.enforce_profile_photo_limit() from public, anon, authenticated;

drop trigger if exists enforce_profile_photo_limit on public.profile_photos;
create trigger enforce_profile_photo_limit
before insert on public.profile_photos
for each row execute function private.enforce_profile_photo_limit();

comment on function public.confirm_adult_status(date) is
  'Intentional authenticated SECURITY DEFINER RPC. Sets only the caller DOB and declaration timestamp after server-side adult validation. Never sets age_verified_at.';
