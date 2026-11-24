-- Serialize reciprocal-like processing per user pair.
-- The transaction-scoped advisory lock makes concurrent opposite likes
-- evaluate the reciprocal-like check in a serialized order. The function
-- remains VOLATILE so its internal SQL statements use fresh snapshots.

CREATE OR REPLACE FUNCTION private.create_match_on_mutual_like()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  first_user uuid;
  second_user uuid;
BEGIN
  first_user := LEAST(NEW.sender_id, NEW.receiver_id);
  second_user := GREATEST(NEW.sender_id, NEW.receiver_id);

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      first_user::text || ':' || second_user::text,
      0
    )
  );

  IF EXISTS (
    SELECT 1
    FROM public.likes l
    WHERE l.sender_id = NEW.receiver_id
      AND l.receiver_id = NEW.sender_id
  ) AND NOT EXISTS (
    SELECT 1
    FROM public.blocks b
    WHERE (b.blocker_id = NEW.sender_id AND b.blocked_id = NEW.receiver_id)
       OR (b.blocker_id = NEW.receiver_id AND b.blocked_id = NEW.sender_id)
  ) THEN
    INSERT INTO public.matches (user_one_id, user_two_id)
    VALUES (first_user, second_user)
    ON CONFLICT (user_one_id, user_two_id) DO NOTHING;
  END IF;

  RETURN NEW;
END;
$function$;

DO $$
DECLARE
  function_oid oid := 'private.create_match_on_mutual_like()'::regprocedure;
  trigger_definition text;
BEGIN
  IF (SELECT provolatile FROM pg_proc WHERE oid = function_oid) <> 'v' THEN
    RAISE EXCEPTION 'Mutual-like trigger function must remain VOLATILE';
  END IF;

  IF position('pg_advisory_xact_lock' IN pg_get_functiondef(function_oid)) = 0
     OR position('hashtextextended' IN pg_get_functiondef(function_oid)) = 0 THEN
    RAISE EXCEPTION 'Mutual-like trigger function is missing pair-scoped transaction locking';
  END IF;

  SELECT pg_get_triggerdef(t.oid)
  INTO trigger_definition
  FROM pg_trigger t
  WHERE t.tgfoid = function_oid
    AND NOT t.tgisinternal;

  IF trigger_definition IS NULL
     OR trigger_definition NOT ILIKE '%AFTER INSERT ON public.likes%' THEN
    RAISE EXCEPTION 'Expected AFTER INSERT trigger on public.likes was not found';
  END IF;
END
$$;
