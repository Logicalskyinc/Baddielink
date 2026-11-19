\set ON_ERROR_STOP on

do $$
declare
  v_group_id uuid;
  v_version bigint;
  v_actor_device uuid;
  v_target_device uuid;
  v_target_device_2 uuid;
  v_auth_id uuid;
  v_auth_id_2 uuid;
  v_auth_id_competing uuid;
  v_auth_id_remove uuid;
  v_digest bytea := decode(repeat('ab', 32), 'hex');
  v_wrong_digest bytea := decode(repeat('cd', 32), 'hex');
  v_result boolean;
  v_revocation_blocked boolean := false;
  v_device_reuse_rejected boolean := false;
  v_key_reuse_rejected boolean := false;
begin
  -- Existing room is mapped exactly once at version 1.
  select group_id, roster_version into v_group_id, v_version
    from public.mls_space_groups
   where space_id = '20000000-0000-4000-8000-000000000001';
  if v_group_id is null or v_version <> 1 then
    raise exception 'existing room MLS mapping/backfill failed';
  end if;

  -- New room gets a mapping through its trigger.
  insert into public.spaces (id, owner_id, status)
  values (
    '20000000-0000-4000-8000-000000000002',
    '10000000-0000-4000-8000-000000000002',
    'active'
  );
  if not exists (
    select 1 from public.mls_space_groups
     where space_id = '20000000-0000-4000-8000-000000000002'
       and roster_version = 1
  ) then
    raise exception 'new room MLS mapping trigger failed';
  end if;

  -- Membership insert and role/status changes each increment exactly once.
  insert into public.space_memberships (space_id, user_id, role, status)
  values (
    '20000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000002',
    'member',
    'active'
  );
  select roster_version into v_version
    from public.mls_space_groups
   where space_id = '20000000-0000-4000-8000-000000000001';
  if v_version <> 1 then raise exception 'account membership insert changed the MLS device roster version'; end if;

  update public.space_memberships
     set role = 'moderator'
   where space_id = '20000000-0000-4000-8000-000000000001'
     and user_id = '10000000-0000-4000-8000-000000000002';
  select roster_version into v_version
    from public.mls_space_groups
   where space_id = '20000000-0000-4000-8000-000000000001';
  if v_version <> 1 then raise exception 'account role update changed the MLS device roster version'; end if;

  update public.space_memberships
     set status = 'removed'
   where space_id = '20000000-0000-4000-8000-000000000001'
     and user_id = '10000000-0000-4000-8000-000000000002';
  select roster_version into v_version
    from public.mls_space_groups
   where space_id = '20000000-0000-4000-8000-000000000001';
  if v_version <> 1 then raise exception 'account membership status update changed the MLS device roster version'; end if;

  update public.spaces set status = 'suspended'
   where id = '20000000-0000-4000-8000-000000000001';
  select roster_version into v_version
    from public.mls_space_groups
   where space_id = '20000000-0000-4000-8000-000000000001';
  if v_version <> 2 then raise exception 'room status did not invalidate the MLS roster version'; end if;

  -- Prepare actor and target device registrations against real auth users.
  insert into public.mls_devices
    (user_id, device_id, credential_id, signature_public_key)
  values
    ('10000000-0000-4000-8000-000000000001', decode(repeat('11',16),'hex'),
     decode(repeat('21',32),'hex'), decode(repeat('31',32),'hex'))
  returning id into v_actor_device;

  insert into public.mls_devices
    (user_id, device_id, credential_id, signature_public_key)
  values
    ('10000000-0000-4000-8000-000000000003', decode(repeat('12',16),'hex'),
     decode(repeat('22',32),'hex'), decode(repeat('32',32),'hex'))
  returning id into v_target_device;

  -- Return room to active before the server-authorized first-device bootstrap.
  update public.spaces set status = 'active'
   where id = '20000000-0000-4000-8000-000000000001';

  select b.group_id, b.roster_version
    into v_group_id, v_version
    from public.mls_bootstrap_space_device(
      '20000000-0000-4000-8000-000000000001',
      '10000000-0000-4000-8000-000000000001',
      v_actor_device,
      decode(repeat('21',32),'hex'),
      decode(repeat('31',32),'hex')
    ) b;

  if not exists (
    select 1 from public.mls_space_device_roster
     where space_id = '20000000-0000-4000-8000-000000000001'
       and user_id = '10000000-0000-4000-8000-000000000001'
       and device_id = v_actor_device
  ) then
    raise exception 'owner first-device bootstrap did not create the roster entry';
  end if;

  -- Exact bootstrap retry must not duplicate the owner device or advance
  -- the roster version a second time.
  select b.group_id, b.roster_version
    into v_group_id, v_version
    from public.mls_bootstrap_space_device(
      '20000000-0000-4000-8000-000000000001',
      '10000000-0000-4000-8000-000000000001',
      v_actor_device,
      decode(repeat('21',32),'hex'),
      decode(repeat('31',32),'hex')
    ) b;

  if (select count(*) from public.mls_space_device_roster
       where space_id = '20000000-0000-4000-8000-000000000001') <> 1 then
    raise exception 'idempotent bootstrap duplicated the owner device';
  end if;

  insert into public.space_memberships (space_id, user_id, role, status)
  values (
    '20000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000003',
    'member',
    'active'
  );
  select roster_version into v_version
    from public.mls_space_groups
   where space_id = '20000000-0000-4000-8000-000000000001';

  insert into public.mls_membership_authorizations (
    space_id, group_id, actor_user_id, actor_device_id, operation,
    target_user_id, target_device_id, target_credential_id,
    target_signature_public_key, roster_version, commit_digest, expires_at
  )
  select
    g.space_id, g.group_id,
    '10000000-0000-4000-8000-000000000001', v_actor_device, 'add',
    '10000000-0000-4000-8000-000000000003', v_target_device,
    decode(repeat('22',32),'hex'), decode(repeat('32',32),'hex'),
    g.roster_version, v_digest, clock_timestamp() + interval '90 seconds'
  from public.mls_space_groups g
  where g.space_id = '20000000-0000-4000-8000-000000000001'
  returning id into v_auth_id;

  -- A second authorization for the same roster version must not be able to
  -- reserve the room while the first Commit is pending.
  insert into public.mls_membership_authorizations (
    space_id, group_id, actor_user_id, actor_device_id, operation,
    target_user_id, target_device_id, target_credential_id,
    target_signature_public_key, roster_version, commit_digest, expires_at
  )
  select
    g.space_id, g.group_id,
    '10000000-0000-4000-8000-000000000001', v_actor_device, 'add',
    '10000000-0000-4000-8000-000000000003', v_target_device,
    decode(repeat('22',32),'hex'), decode(repeat('32',32),'hex'),
    g.roster_version, v_wrong_digest, clock_timestamp() + interval '90 seconds'
  from public.mls_space_groups g
  where g.space_id = '20000000-0000-4000-8000-000000000001'
  returning id into v_auth_id_competing;

  v_result := public.mls_consume_membership_authorization(
    v_auth_id,
    '10000000-0000-4000-8000-000000000001',
    v_actor_device,
    v_digest
  );
  if v_result is not true then raise exception 'valid authorization consume failed'; end if;

  v_result := public.mls_consume_membership_authorization(
    v_auth_id_competing,
    '10000000-0000-4000-8000-000000000001',
    v_actor_device,
    v_wrong_digest
  );
  if v_result is not false then
    raise exception 'competing authorization consumed the same roster version';
  end if;

  -- Exact retry is idempotent; wrong digest is not.
  v_result := public.mls_consume_membership_authorization(
    v_auth_id,
    '10000000-0000-4000-8000-000000000001',
    v_actor_device,
    v_digest
  );
  if v_result is not true then raise exception 'exact consume retry was not idempotent'; end if;

  if not exists (
    select 1 from public.mls_space_groups
     where space_id = '20000000-0000-4000-8000-000000000001'
       and pending_authorization_id = v_auth_id
       and roster_version = v_version
  ) then
    raise exception 'consume did not reserve the room without prematurely changing roster version';
  end if;

  begin
    update public.mls_devices
       set status = 'revoked'
     where id = v_target_device;
  exception when raise_exception then
    v_revocation_blocked := true;
  end;
  if not v_revocation_blocked then
    raise exception 'device revocation was allowed while an MLS authorization was pending';
  end if;

  v_result := public.mls_finalize_membership_authorization(
    v_auth_id,
    '10000000-0000-4000-8000-000000000001',
    v_actor_device,
    v_digest
  );
  if v_result is not true then raise exception 'valid authorization finalization failed'; end if;

  if not exists (
    select 1 from public.mls_space_device_roster
     where space_id = '20000000-0000-4000-8000-000000000001'
       and device_id = v_target_device
       and credential_id = decode(repeat('22',32),'hex')
       and signature_public_key = decode(repeat('32',32),'hex')
  ) then
    raise exception 'finalization did not add the exact authorized target device';
  end if;

  if not exists (
    select 1 from public.mls_space_groups
     where space_id = '20000000-0000-4000-8000-000000000001'
       and pending_authorization_id is null
       and roster_version = v_version + 1
  ) then
    raise exception 'finalization did not advance and unlock the room roster';
  end if;

  v_result := public.mls_consume_membership_authorization(
    v_auth_id,
    '10000000-0000-4000-8000-000000000001',
    v_actor_device,
    v_wrong_digest
  );
  if v_result is not false then raise exception 'wrong digest was accepted'; end if;

  -- Remove is resolved against the server's credential-bound room roster.
  select roster_version into v_version
    from public.mls_space_groups
   where space_id = '20000000-0000-4000-8000-000000000001';

  insert into public.mls_membership_authorizations (
    space_id, group_id, actor_user_id, actor_device_id, operation,
    target_user_id, target_device_id, target_credential_id,
    target_signature_public_key, roster_version, commit_digest, expires_at
  )
  select
    g.space_id, g.group_id,
    '10000000-0000-4000-8000-000000000001', v_actor_device, 'remove',
    '10000000-0000-4000-8000-000000000003', v_target_device,
    decode(repeat('22',32),'hex'), decode(repeat('32',32),'hex'),
    g.roster_version, v_wrong_digest, clock_timestamp() + interval '90 seconds'
  from public.mls_space_groups g
  where g.space_id = '20000000-0000-4000-8000-000000000001'
  returning id into v_auth_id_remove;

  v_result := public.mls_consume_membership_authorization(
    v_auth_id_remove,
    '10000000-0000-4000-8000-000000000001',
    v_actor_device,
    v_wrong_digest
  );
  if v_result is not true then raise exception 'valid Remove authorization consume failed'; end if;

  v_result := public.mls_finalize_membership_authorization(
    v_auth_id_remove,
    '10000000-0000-4000-8000-000000000001',
    v_actor_device,
    v_wrong_digest
  );
  if v_result is not true then raise exception 'valid Remove authorization finalization failed'; end if;

  if exists (
    select 1 from public.mls_space_device_roster
     where space_id = '20000000-0000-4000-8000-000000000001'
       and device_id = v_target_device
  ) then
    raise exception 'Remove finalization left the target device in the MLS roster';
  end if;

  -- Once the device has been removed from every room, revocation is allowed.
  update public.mls_devices
     set status = 'revoked'
   where id = v_target_device;
  if not exists (
    select 1 from public.mls_devices
     where id = v_target_device
       and status = 'revoked'
       and revoked_at is not null
  ) then
    raise exception 'removed MLS device could not be revoked';
  end if;

  -- A target device revoked after authorization issuance must not be added.
  insert into public.mls_devices
    (user_id, device_id, credential_id, signature_public_key)
  values
    ('10000000-0000-4000-8000-000000000003', decode(repeat('13',16),'hex'),
     decode(repeat('23',32),'hex'), decode(repeat('33',32),'hex'))
  returning id into v_target_device_2;

  insert into public.mls_membership_authorizations (
    space_id, group_id, actor_user_id, actor_device_id, operation,
    target_user_id, target_device_id, target_credential_id,
    target_signature_public_key, roster_version, commit_digest, expires_at
  )
  select
    g.space_id, g.group_id,
    '10000000-0000-4000-8000-000000000001', v_actor_device, 'add',
    '10000000-0000-4000-8000-000000000003', v_target_device_2,
    decode(repeat('23',32),'hex'), decode(repeat('33',32),'hex'),
    g.roster_version, v_wrong_digest, clock_timestamp() + interval '90 seconds'
  from public.mls_space_groups g
  where g.space_id = '20000000-0000-4000-8000-000000000001'
  returning id into v_auth_id_2;

  update public.mls_devices
     set status = 'revoked', revoked_at = clock_timestamp()
   where id = v_target_device_2;

  v_result := public.mls_consume_membership_authorization(
    v_auth_id_2,
    '10000000-0000-4000-8000-000000000001',
    v_actor_device,
    v_wrong_digest
  );
  if v_result is not false then
    raise exception 'authorization for revoked target device was accepted';
  end if;

  begin
    insert into public.mls_devices
      (user_id, device_id, credential_id, signature_public_key)
    values
      ('10000000-0000-4000-8000-000000000003', decode(repeat('13',16),'hex'),
       decode(repeat('24',32),'hex'), decode(repeat('34',32),'hex'));
  exception when unique_violation then
    v_device_reuse_rejected := true;
  end;
  if not v_device_reuse_rejected then
    raise exception 'revoked device identifier was reused for a new registration';
  end if;

  begin
    insert into public.mls_devices
      (user_id, device_id, credential_id, signature_public_key)
    values
      ('10000000-0000-4000-8000-000000000003', decode(repeat('14',16),'hex'),
       decode(repeat('25',32),'hex'), decode(repeat('33',32),'hex'));
  exception when unique_violation then
    v_key_reuse_rejected := true;
  end;
  if not v_key_reuse_rejected then
    raise exception 'revoked device signing key was reused by another registration';
  end if;
end $$;

-- Browser roles must not be able to read or execute privileged data/functions.
do $$
begin
  if has_table_privilege('anon', 'public.mls_devices', 'select')
     or has_table_privilege('authenticated', 'public.mls_devices', 'select')
     or has_table_privilege('anon', 'public.mls_space_device_roster', 'select')
     or has_table_privilege('authenticated', 'public.mls_space_device_roster', 'select')
     or has_table_privilege('service_role', 'public.mls_space_device_roster', 'insert')
     or has_table_privilege('anon', 'public.mls_membership_authorizations', 'insert')
     or has_table_privilege('authenticated', 'public.mls_membership_authorizations', 'insert') then
    raise exception 'browser role has unexpected MLS table privileges';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.mls_bootstrap_space_device(uuid,uuid,uuid,bytea,bytea)',
    'execute'
  ) then
    raise exception 'authenticated can execute privileged bootstrap function';
  end if;
  if not has_function_privilege(
    'service_role',
    'public.mls_bootstrap_space_device(uuid,uuid,uuid,bytea,bytea)',
    'execute'
  ) then
    raise exception 'service_role cannot execute bootstrap function';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.mls_consume_membership_authorization(uuid,uuid,uuid,bytea)',
    'execute'
  ) then
    raise exception 'authenticated can execute privileged consume function';
  end if;
  if not has_function_privilege(
    'service_role',
    'public.mls_consume_membership_authorization(uuid,uuid,uuid,bytea)',
    'execute'
  ) then
    raise exception 'service_role cannot execute consume function';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.mls_finalize_membership_authorization(uuid,uuid,uuid,bytea)',
    'execute'
  ) then
    raise exception 'authenticated can execute privileged finalize function';
  end if;
  if not has_function_privilege(
    'service_role',
    'public.mls_finalize_membership_authorization(uuid,uuid,uuid,bytea)',
    'execute'
  ) then
    raise exception 'service_role cannot execute finalize function';
  end if;
end $$;

select 'MLS control-plane migration smoke tests passed' as result;
