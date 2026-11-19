
-- Private profile-photo storage. Files are served only through authenticated
-- storage access or short-lived signed URLs created by a trusted backend.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'baddielink-profile-photos',
  'baddielink-profile-photos',
  false,
  5242880,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy "baddielink_photo_upload_own_folder"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'baddielink-profile-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "baddielink_photo_read_owner_or_approved_discovery"
on storage.objects for select to authenticated
using (
  bucket_id = 'baddielink-profile-photos'
  and (
    (storage.foldername(name))[1] = (select auth.uid())::text
    or exists (
      select 1
      from public.profile_photos ph
      join public.profiles p on p.id = ph.user_id
      where ph.object_path = storage.objects.name
        and ph.user_id::text = (storage.foldername(storage.objects.name))[1]
        and ph.moderation_status = 'approved'
        and p.moderation_status = 'approved'
        and p.is_discoverable = true
        and not (select private.is_blocked_with(ph.user_id))
    )
  )
);

create policy "baddielink_photo_delete_own_folder"
on storage.objects for delete to authenticated
using (
  bucket_id = 'baddielink-profile-photos'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

-- Age declaration is accepted only through this server-side function.
create or replace function public.confirm_adult_status(p_date_of_birth date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  if p_date_of_birth is null
     or p_date_of_birth > (current_date - interval '18 years')::date
     or p_date_of_birth < (current_date - interval '100 years')::date then
    raise exception 'BaddieLink is available only to adults aged 18 or older'
      using errcode = '22023';
  end if;

  update public.user_private_settings
  set date_of_birth = p_date_of_birth,
      age_declaration_at = now(),
      updated_at = now()
  where user_id = current_user_id;

  if not found then
    raise exception 'User account settings were not found';
  end if;
end;
$$;

revoke all on function public.confirm_adult_status(date) from public, anon;
grant execute on function public.confirm_adult_status(date) to authenticated;

-- Clients cannot directly set DOB or declaration timestamps, and cannot
-- mark an account as age-verified.
revoke update (date_of_birth, age_declaration_at, age_verified_at)
on public.user_private_settings from authenticated;

create or replace function private.is_adult_declared(target_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.user_private_settings s
    where s.user_id = target_user_id
      and s.date_of_birth is not null
      and s.date_of_birth <= (current_date - interval '18 years')::date
      and s.age_declaration_at is not null
  );
$$;

revoke all on function private.is_adult_declared(uuid) from public, anon, authenticated;

-- Public discovery requires an adult declaration and approved moderation.
drop policy if exists profiles_visible_to_owner_or_approved_discovery on public.profiles;
create policy profiles_visible_to_owner_or_approved_discovery
on public.profiles for select to authenticated
using (
  id = (select auth.uid())
  or (
    is_discoverable = true
    and moderation_status = 'approved'
    and id <> (select auth.uid())
    and (select private.is_adult_declared(id))
    and (select private.is_adult_declared((select auth.uid())))
    and not (select private.is_blocked_with(id))
  )
);

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own
on public.profiles for update to authenticated
using (id = (select auth.uid()))
with check (
  id = (select auth.uid())
  and (
    is_discoverable = false
    or (select private.is_adult_declared((select auth.uid())))
  )
);

drop policy if exists likes_insert_own on public.likes;
create policy likes_insert_own
on public.likes for insert to authenticated
with check (
  sender_id = (select auth.uid())
  and sender_id <> receiver_id
  and (select private.is_adult_declared(sender_id))
  and (select private.is_adult_declared(receiver_id))
  and not (select private.is_blocked_with(receiver_id))
  and exists (
    select 1 from public.profiles p
    where p.id = likes.receiver_id
      and p.is_discoverable = true
      and p.moderation_status = 'approved'
  )
);

drop policy if exists messages_insert_sender_in_active_match on public.messages;
create policy messages_insert_sender_in_active_match
on public.messages for insert to authenticated
with check (
  sender_id = (select auth.uid())
  and (select private.is_adult_declared(sender_id))
  and exists (
    select 1
    from public.matches m
    where m.id = messages.match_id
      and (m.user_one_id = (select auth.uid()) or m.user_two_id = (select auth.uid()))
      and m.ended_at is null
      and (select private.is_adult_declared(
        case when m.user_one_id = (select auth.uid()) then m.user_two_id else m.user_one_id end
      ))
      and not (select private.is_blocked_with(
        case when m.user_one_id = (select auth.uid()) then m.user_two_id else m.user_one_id end
      ))
  )
);
