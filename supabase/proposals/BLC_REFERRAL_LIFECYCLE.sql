-- BaddieLink referral-code lifecycle API
-- REVIEW PROPOSAL ONLY. Apply after BLC_REFERRAL_REWARDS.sql.
-- No production migration or database execution is included.

BEGIN;

-- Only the owner may request their own code. Code generation is serialized
-- per owner so concurrent calls return one stable code instead of racing the
-- unique owner constraint.
CREATE OR REPLACE FUNCTION public.get_my_referral_code()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  caller_id uuid;
  existing_code text;
  candidate_code text;
  existing_active boolean;
BEGIN
  caller_id := auth.uid();
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '28000';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(caller_id::text, 0)
  );

  SELECT c.referral_code, c.is_active
    INTO existing_code, existing_active
  FROM private.referral_codes c
  WHERE c.owner_user_id = caller_id
  FOR UPDATE;

  IF FOUND THEN
    IF existing_active IS NOT TRUE THEN
      RAISE EXCEPTION 'Your referral code has been deactivated';
    END IF;
    RETURN existing_code;
  END IF;

  LOOP
    -- 96 bits of UUID-v4 randomness, encoded as 24 uppercase hex characters.
    candidate_code := pg_catalog.upper(
      pg_catalog.substr(
        pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', ''),
        1,
        24
      )
    );

    BEGIN
      INSERT INTO private.referral_codes (owner_user_id, referral_code)
      VALUES (caller_id, candidate_code);
      RETURN candidate_code;
    EXCEPTION WHEN unique_violation THEN
      -- Retry a code collision. The owner lock makes an owner conflict
      -- unexpected, but the unique constraint remains the final authority.
      IF EXISTS (
        SELECT 1 FROM private.referral_codes c
        WHERE c.owner_user_id = caller_id
      ) THEN
        SELECT c.referral_code, c.is_active
          INTO existing_code, existing_active
        FROM private.referral_codes c
        WHERE c.owner_user_id = caller_id
        FOR UPDATE;
        IF existing_active IS NOT TRUE THEN
          RAISE EXCEPTION 'Your referral code has been deactivated';
        END IF;
        RETURN existing_code;
      END IF;
    END;
  END LOOP;
END;
$function$;

-- Deactivation is intentionally one-way and idempotent.
CREATE OR REPLACE FUNCTION public.deactivate_my_referral_code()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  caller_id uuid;
  changed_rows integer;
  code_exists boolean;
BEGIN
  caller_id := auth.uid();
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '28000';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(caller_id::text, 0)
  );

  UPDATE private.referral_codes
  SET is_active = false
  WHERE owner_user_id = caller_id
    AND is_active = true;

  GET DIAGNOSTICS changed_rows = ROW_COUNT;
  IF changed_rows > 0 THEN
    RETURN true;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM private.referral_codes c
    WHERE c.owner_user_id = caller_id
  ) INTO code_exists;

  IF NOT code_exists THEN
    RAISE EXCEPTION 'You do not have a referral code';
  END IF;

  RETURN false;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_my_referral_code() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.deactivate_my_referral_code() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_referral_code() TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_my_referral_code() TO authenticated;

-- Aggregate-only referral dashboard. Never returns referred member identities.
CREATE OR REPLACE FUNCTION public.get_my_referral_summary()
RETURNS TABLE (
  total_referrals bigint,
  rewarded_referrals bigint,
  pending_referrals bigint,
  total_rewards_blc bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  caller_id uuid;
BEGIN
  caller_id := auth.uid();
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '28000';
  END IF;

  RETURN QUERY
  SELECT
    count(DISTINCT a.id)::bigint,
    count(DISTINCT r.referral_attribution_id)::bigint,
    (count(DISTINCT a.id) - count(DISTINCT r.referral_attribution_id))::bigint,
    coalesce(sum(r.reward_amount_blc), 0)::bigint
  FROM private.referral_attributions a
  LEFT JOIN private.referral_rewards r
    ON r.referral_attribution_id = a.id
  WHERE a.referrer_user_id = caller_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_my_referral_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_referral_summary() TO authenticated;

-- Code identity is permanent. The only permitted update is active -> inactive.
CREATE OR REPLACE FUNCTION private.guard_referral_code_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Referral codes cannot be deleted';
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.owner_user_id IS DISTINCT FROM OLD.owner_user_id
     OR NEW.referral_code IS DISTINCT FROM OLD.referral_code
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR (OLD.is_active = false AND NEW.is_active = true) THEN
    RAISE EXCEPTION 'Referral-code identity is immutable and deactivation is permanent';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER referral_codes_guard_lifecycle
  BEFORE UPDATE OR DELETE ON private.referral_codes
  FOR EACH ROW EXECUTE FUNCTION private.guard_referral_code_lifecycle();

REVOKE ALL ON FUNCTION private.guard_referral_code_lifecycle() FROM PUBLIC, anon, authenticated;

-- The signup metadata contains only a referral code, never a referrer ID.
-- raw_user_meta_data is user-editable, so it is used solely as an untrusted
-- code input. The database resolves the actual owner and validates activity.
CREATE OR REPLACE FUNCTION private.attribute_new_auth_user_from_referral_code()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  supplied_code text;
  matched_code_id uuid;
  matched_owner_id uuid;
BEGIN
  supplied_code := pg_catalog.upper(
    pg_catalog.btrim(NEW.raw_user_meta_data ->> 'referral_code')
  );

  IF supplied_code IS NULL OR supplied_code = '' THEN
    RETURN NEW;
  END IF;

  SELECT c.id, c.owner_user_id
    INTO matched_code_id, matched_owner_id
  FROM private.referral_codes c
  WHERE c.referral_code = supplied_code
    AND c.is_active = true
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Referral code is invalid or inactive'
      USING ERRCODE = '23514';
  END IF;

  IF matched_owner_id = NEW.id THEN
    RAISE EXCEPTION 'Self-referral is not allowed'
      USING ERRCODE = '23514';
  END IF;

  INSERT INTO private.referral_attributions (
    referrer_user_id,
    referred_user_id,
    referral_code_id
  ) VALUES (
    matched_owner_id,
    NEW.id,
    matched_code_id
  );

  RETURN NEW;
END;
$function$;

CREATE TRIGGER on_auth_user_referral_attribution
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION private.attribute_new_auth_user_from_referral_code();

REVOKE ALL ON FUNCTION private.attribute_new_auth_user_from_referral_code()
  FROM PUBLIC, anon, authenticated;

COMMIT;

-- Signup behavior:
-- * no code: account creation proceeds without attribution;
-- * valid active code: attribution is inserted in the auth.users transaction;
-- * invalid/inactive/self-referral code: auth user creation rolls back;
-- * changing metadata after signup cannot change the immutable attribution.
