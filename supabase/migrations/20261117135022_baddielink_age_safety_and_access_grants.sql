
alter table public.user_private_settings
  add constraint user_private_settings_adult_only
  check (
    date_of_birth is null
    or date_of_birth <= (current_date - interval '18 years')::date
  );

grant update (username, display_name, bio, city, gender, interested_in, is_discoverable)
  on public.profiles to authenticated;

grant update (date_of_birth)
  on public.user_private_settings to authenticated;

grant insert on public.profile_photos to authenticated;
grant update (display_order) on public.profile_photos to authenticated;

grant update (read_at) on public.messages to authenticated;

create index if not exists messages_sender_idx
  on public.messages (sender_id, created_at desc);
create index if not exists reports_reporter_idx
  on public.reports (reporter_id, created_at desc);
create index if not exists reports_reported_user_idx
  on public.reports (reported_user_id, created_at desc)
  where reported_user_id is not null;
create index if not exists reports_message_idx
  on public.reports (message_id)
  where message_id is not null;

comment on column public.user_private_settings.age_verified_at is
  'Reserved for a future real age-verification workflow. Must not be set from client input.';
comment on column public.user_private_settings.age_declaration_at is
  'Timestamp of the user age declaration; this is not identity or age verification.';
