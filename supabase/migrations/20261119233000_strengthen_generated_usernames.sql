-- Strengthen generated usernames for new accounts without changing existing handles.
-- 10 hexadecimal UUID characters provide a 40-bit suffix while keeping the
-- generated username within the existing 24-character profile constraint.

CREATE OR REPLACE FUNCTION private.create_user_records()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  base_name text;
  safe_name text;
BEGIN
  base_name := coalesce(
    nullif(trim(NEW.raw_user_meta_data ->> 'username'), ''),
    'member'
  );

  safe_name := lower(
    regexp_replace(base_name, '[^a-zA-Z0-9_]', '', 'g')
  );
  safe_name := left(safe_name, 13);

  IF char_length(safe_name) < 3 THEN
    safe_name := 'member';
  END IF;

  INSERT INTO public.profiles (id, username, display_name)
  VALUES (
    NEW.id,
    safe_name || '_' || left(replace(NEW.id::text, '-', ''), 10),
    coalesce(
      nullif(trim(NEW.raw_user_meta_data ->> 'display_name'), ''),
      'Nouveau membre'
    )
  );

  INSERT INTO public.user_private_settings (user_id)
  VALUES (NEW.id);

  RETURN NEW;
END;
$function$;

DO $$
DECLARE
  function_oid oid := 'private.create_user_records()'::regprocedure;
  function_definition text;
  trigger_definition text;
BEGIN
  SELECT pg_get_functiondef(function_oid) INTO function_definition;

  IF (SELECT prosecdef FROM pg_proc WHERE oid = function_oid) IS NOT TRUE THEN
    RAISE EXCEPTION 'Account-record trigger must remain SECURITY DEFINER';
  END IF;

  IF NOT ('search_path=""' = ANY(
    coalesce((SELECT proconfig FROM pg_proc WHERE oid = function_oid), ARRAY[]::text[])
  )) THEN
    RAISE EXCEPTION 'Account-record trigger must keep an empty search_path';
  END IF;

  IF position('left(safe_name, 13)' IN function_definition) = 0
     OR position('left(replace(NEW.id::text, ''-'', ''''), 10)' IN function_definition) = 0 THEN
    RAISE EXCEPTION 'Generated username must use a 13-character base and 10-character UUID suffix';
  END IF;

  SELECT pg_get_triggerdef(t.oid)
  INTO trigger_definition
  FROM pg_trigger t
  WHERE t.tgfoid = function_oid
    AND NOT t.tgisinternal;

  IF trigger_definition IS NULL
     OR trigger_definition NOT ILIKE '%AFTER INSERT ON auth.users%' THEN
    RAISE EXCEPTION 'Expected auth.users account creation trigger was not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'profiles'
      AND c.conname = 'profiles_username_format'
  ) THEN
    RAISE EXCEPTION 'Expected profiles username format constraint is missing';
  END IF;
END
$$;
