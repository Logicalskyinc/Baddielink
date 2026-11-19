
drop policy if exists profile_photos_update_own on public.profile_photos;
create policy profile_photos_update_own_pending
on public.profile_photos
for update to authenticated
using (user_id = (select auth.uid()))
with check (
  user_id = (select auth.uid())
  and moderation_status = 'pending'
);
