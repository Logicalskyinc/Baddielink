-- Authenticated Wave checkout preparation RPCs.
-- REVIEW PROPOSAL ONLY. These functions create pending top-up records and
-- attach checkout references. They do not credit BLC or verify payment.
BEGIN;

CREATE TABLE private.blc_checkout_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  idempotency_key text NOT NULL CHECK (length(btrim(idempotency_key)) BETWEEN 16 AND 128),
  amount_xof bigint NOT NULL CHECK (amount_xof > 0),
  topup_id uuid NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT blc_checkout_requests_topup_owner_fk
    FOREIGN KEY (topup_id, user_id)
    REFERENCES private.blc_topups(id, user_id) ON DELETE RESTRICT,
  CONSTRAINT blc_checkout_requests_user_key_unique
    UNIQUE (user_id, idempotency_key)
);

ALTER TABLE private.blc_checkout_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.blc_checkout_requests FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.create_wave_topup(
  p_amount_xof bigint,
  p_idempotency_key text
)
RETURNS TABLE (
  topup_id uuid,
  provider_account_id uuid,
  client_reference text,
  amount_xof bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_provider_id uuid;
  v_topup_id uuid;
  v_reference text;
  v_existing_topup_id uuid;
  v_existing_provider_id uuid;
  v_existing_reference text;
  v_existing_amount bigint;
  v_existing_status text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '28000';
  END IF;

  IF p_amount_xof IS NULL OR p_amount_xof <= 0 THEN
    RAISE EXCEPTION 'Top-up amount must be a positive XOF integer'
      USING ERRCODE = '22023';
  END IF;

  IF p_idempotency_key IS NULL
     OR length(btrim(p_idempotency_key)) NOT BETWEEN 16 AND 128 THEN
    RAISE EXCEPTION 'A 16 to 128 character idempotency key is required'
      USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(v_user_id::text || ':' || p_idempotency_key, 0)
  );

  SELECT r.topup_id, r.amount_xof, t.provider_account_id,
         t.client_reference, t.status
    INTO v_existing_topup_id, v_existing_amount, v_existing_provider_id,
         v_existing_reference, v_existing_status
  FROM private.blc_checkout_requests r
  JOIN private.blc_topups t ON t.id = r.topup_id
  WHERE r.user_id = v_user_id
    AND r.idempotency_key = p_idempotency_key
  FOR UPDATE OF r, t;

  IF FOUND THEN
    IF v_existing_amount <> p_amount_xof THEN
      RAISE EXCEPTION 'Idempotency key was already used with a different amount'
        USING ERRCODE = '22023';
    END IF;

    IF v_existing_status IN ('failed', 'expired', 'cancelled', 'review_required') THEN
      RAISE EXCEPTION 'This checkout request is no longer reusable; create a new request key'
        USING ERRCODE = '55000';
    END IF;

    RETURN QUERY SELECT v_existing_topup_id, v_existing_provider_id,
                        v_existing_reference, v_existing_amount;
    RETURN;
  END IF;

  SELECT p.id INTO v_provider_id
  FROM private.payment_provider_accounts p
  WHERE p.provider_code = 'wave'
    AND p.environment = 'sandbox'
    AND p.currency_code = 'XOF'
    AND p.is_enabled
  ORDER BY p.created_at, p.id
  LIMIT 1
  FOR SHARE;

  IF v_provider_id IS NULL THEN
    RAISE EXCEPTION 'Wave sandbox checkout is not configured'
      USING ERRCODE = '55000';
  END IF;

  v_reference := 'blc_' || replace(gen_random_uuid()::text, '-', '');

  INSERT INTO private.blc_topups (
    user_id, provider_account_id, amount_xof, amount_blc,
    conversion_rate_numerator, conversion_rate_denominator,
    status, client_reference
  ) VALUES (
    v_user_id, v_provider_id, p_amount_xof, p_amount_xof,
    1, 1, 'created', v_reference
  ) RETURNING id INTO v_topup_id;

  INSERT INTO private.blc_checkout_requests (
    user_id, idempotency_key, amount_xof, topup_id
  ) VALUES (
    v_user_id, p_idempotency_key, p_amount_xof, v_topup_id
  );

  RETURN QUERY SELECT v_topup_id, v_provider_id, v_reference, p_amount_xof;
END;
$function$;

CREATE OR REPLACE FUNCTION public.attach_wave_checkout_session(
  p_topup_id uuid,
  p_checkout_session_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_provider_id uuid;
  v_status text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '28000';
  END IF;

  IF p_topup_id IS NULL
     OR p_checkout_session_id IS NULL
     OR length(btrim(p_checkout_session_id)) NOT BETWEEN 1 AND 255 THEN
    RAISE EXCEPTION 'Invalid checkout session attachment'
      USING ERRCODE = '22023';
  END IF;

  SELECT t.provider_account_id, t.status
    INTO v_provider_id, v_status
  FROM private.blc_topups t
  WHERE t.id = p_topup_id
    AND t.user_id = v_user_id
  FOR UPDATE;

  IF NOT FOUND OR v_status <> 'created' THEN
    RAISE EXCEPTION 'Top-up is unavailable or no longer awaiting checkout'
      USING ERRCODE = '55000';
  END IF;

  INSERT INTO private.provider_payment_references (
    topup_id, provider_account_id, reference_type, provider_reference
  ) VALUES (
    p_topup_id, v_provider_id, 'checkout_session', p_checkout_session_id
  );

  UPDATE private.blc_topups
  SET status = 'checkout_pending'
  WHERE id = p_topup_id
    AND user_id = v_user_id
    AND status = 'created';
END;
$function$;

CREATE OR REPLACE FUNCTION public.fail_wave_topup_checkout(p_topup_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '28000';
  END IF;

  UPDATE private.blc_topups
  SET status = 'failed'
  WHERE id = p_topup_id
    AND user_id = v_user_id
    AND status = 'created';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Top-up cannot be marked failed in its current state'
      USING ERRCODE = '55000';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_wave_topup(bigint, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.attach_wave_checkout_session(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fail_wave_topup_checkout(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_wave_topup(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.attach_wave_checkout_session(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fail_wave_topup_checkout(uuid) TO authenticated;

COMMIT;
