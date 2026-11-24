\set ON_ERROR_STOP on

-- Runs after BLC_WAVE_TOPUP_SCHEMA.sql and BLC_WAVE_CHECKOUT_RPCS.sql.
-- All records are isolated CI fixtures. No Wave request or wallet credit occurs.

UPDATE private.payment_provider_accounts
SET is_enabled = true
WHERE provider_code = 'wave'
  AND environment = 'sandbox'
  AND provider_account_reference = 'ci-wave-wallet';

SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000002',
  false
);

SET ROLE authenticated;

SELECT topup_id AS wave_checkout_topup_id,
       client_reference AS wave_checkout_client_reference
FROM public.create_wave_topup(1000, 'ci-wave-checkout-key-0002')
\gset

-- A retry with the same key and amount must return the same top-up.
SELECT topup_id AS wave_checkout_retry_topup_id
FROM public.create_wave_topup(1000, 'ci-wave-checkout-key-0002')
\gset

SELECT CASE
  WHEN :'wave_checkout_topup_id' = :'wave_checkout_retry_topup_id'
  THEN 'idempotent retry passed'
  ELSE (1 / 0)::text
END AS idempotency_result;

-- Reusing the same key for a different amount must fail.
DO $wave_checkout_idempotency_negative$
BEGIN
  BEGIN
    PERFORM 1 FROM public.create_wave_topup(1001, 'ci-wave-checkout-key-0002');
    RAISE EXCEPTION 'Checkout idempotency key accepted a different amount';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;
END;
$wave_checkout_idempotency_negative$;

SELECT * FROM public.claim_wave_checkout_creation(
  :'wave_checkout_topup_id'::uuid
);

SELECT claim_status AS wave_checkout_replay_status
FROM public.claim_wave_checkout_creation(:'wave_checkout_topup_id'::uuid)
\gset

SELECT CASE
  WHEN :'wave_checkout_replay_status' = 'in_progress'
  THEN 'concurrent checkout claim protection passed'
  ELSE (1 / 0)::text
END AS claim_replay_result;

SELECT public.attach_wave_checkout_session(
  :'wave_checkout_topup_id'::uuid,
  'cos-ci-wave-checkout-0002'
);

RESET ROLE;

DO $wave_checkout_assertions$
DECLARE
  v_topup_id uuid;
BEGIN
  SELECT r.topup_id INTO STRICT v_topup_id
  FROM private.blc_checkout_requests r
  WHERE r.user_id = '00000000-0000-0000-0000-000000000002'
    AND r.idempotency_key = 'ci-wave-checkout-key-0002';

  IF (SELECT status FROM private.blc_topups WHERE id = v_topup_id) <> 'checkout_pending' THEN
    RAISE EXCEPTION 'Checkout session attachment did not transition top-up to checkout_pending';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM private.provider_payment_references
    WHERE topup_id = v_topup_id
      AND reference_type = 'checkout_session'
      AND provider_reference = 'cos-ci-wave-checkout-0002'
  ) THEN
    RAISE EXCEPTION 'Checkout session reference was not persisted';
  END IF;

  IF has_function_privilege('anon', 'public.create_wave_topup(bigint,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.claim_wave_checkout_creation(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.attach_wave_checkout_session(uuid,text)', 'EXECUTE')
 THEN
    RAISE EXCEPTION 'Anonymous role can execute Wave checkout RPCs';
  END IF;

  IF has_table_privilege('authenticated', 'private.blc_checkout_requests', 'SELECT')
     OR has_table_privilege('authenticated', 'private.blc_checkout_requests', 'INSERT') THEN
    RAISE EXCEPTION 'Authenticated role has direct access to checkout request table';
  END IF;
END;
$wave_checkout_assertions$;

SELECT 'BLC Wave checkout RPC tests passed' AS result;
