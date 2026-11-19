
create or replace function private.enforce_profile_photo_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Serialize concurrent uploads for the same account before counting.
  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));

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
