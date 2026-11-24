\set ON_ERROR_STOP on

-- Runs after the checkout RPC test has created and attached one sandbox top-up.
-- All webhook evidence is synthetic and the database is isolated CI PostgreSQL.

SELECT t.id AS wave_webhook_topup_id,
       t.provider_account_id AS wave_webhook_provider_id,
       t.client_reference AS wave_webhook_client_reference
FROM private.blc_topups t
JOIN private.blc_checkout_requests r ON r.topup_id = t.id
WHERE r.user_id = '00000000-0000-0000-0000-000000000002'
  AND r.idempotency_key = 'ci-wave-checkout-key-0002'
\gset

SET ROLE service_role;

SELECT processing_result AS wave_webhook_first_result
FROM public.process_wave_checkout_event(
  :'wave_webhook_provider_id'::uuid,
  'evt-ciwave0002',
  'checkout.session.completed',
  'cos-ciwavecheckout0002',
  'TCNCIWAVE0002',
  :'wave_webhook_client_reference',
  1000,
  'XOF',
  'complete',
  'succeeded',
  repeat('d', 64),
  now(),
  '{"id":"evt-ciwave0002","type":"checkout.session.completed","data":{"id":"cos-ciwavecheckout0002","amount":"1000","currency":"XOF","payment_status":"succeeded","checkout_status":"complete","transaction_id":"TCNCIWAVE0002"}}'::jsonb
)
\gset

SELECT CASE
  WHEN :'wave_webhook_first_result' = 'credited'
  THEN 'Wave top-up credited'
  ELSE (1 / 0)::text
END AS first_credit_assertion;

-- Same provider event and exact body hash is an idempotent retry.
SELECT processing_result AS wave_webhook_duplicate_result
FROM public.process_wave_checkout_event(
  :'wave_webhook_provider_id'::uuid,
  'evt-ciwave0002',
  'checkout.session.completed',
  'cos-ciwavecheckout0002',
  'TCNCIWAVE0002',
  :'wave_webhook_client_reference',
  1000,
  'XOF',
  'complete',
  'succeeded',
  repeat('d', 64),
  now(),
  '{"id":"evt-ciwave0002","type":"checkout.session.completed","data":{"id":"cos-ciwavecheckout0002","amount":"1000","currency":"XOF","payment_status":"succeeded","checkout_status":"complete","transaction_id":"TCNCIWAVE0002"}}'::jsonb
)
\gset

SELECT CASE
  WHEN :'wave_webhook_duplicate_result' = 'duplicate'
  THEN 'duplicate webhook retry passed'
  ELSE (1 / 0)::text
END AS duplicate_assertion;

-- A second event ID pointing to the same top-up and provider transaction
-- must not create a second credit.
SELECT processing_result AS wave_webhook_second_event_result
FROM public.process_wave_checkout_event(
  :'wave_webhook_provider_id'::uuid,
  'evt-ciwave0002-second',
  'checkout.session.completed',
  'cos-ciwavecheckout0002',
  'TCNCIWAVE0002',
  :'wave_webhook_client_reference',
  1000,
  'XOF',
  'complete',
  'succeeded',
  repeat('e', 64),
  now(),
  '{"id":"evt-ciwave0002-second","type":"checkout.session.completed","data":{"id":"cos-ciwavecheckout0002","amount":"1000","currency":"XOF","payment_status":"succeeded","checkout_status":"complete","transaction_id":"TCNCIWAVE0002"}}'::jsonb
)
\gset

SELECT CASE
  WHEN :'wave_webhook_second_event_result' = 'duplicate'
  THEN 'provider transaction duplicate protection passed'
  ELSE (1 / 0)::text
END AS provider_transaction_duplicate_assertion;

-- Same event ID with a changed payload hash is quarantined, never credited again.
SELECT processing_result AS wave_webhook_hash_conflict_result
FROM public.process_wave_checkout_event(
  :'wave_webhook_provider_id'::uuid,
  'evt-ciwave0002',
  'checkout.session.completed',
  'cos-ciwavecheckout0002',
  'TCNCIWAVE0002',
  :'wave_webhook_client_reference',
  1000,
  'XOF',
  'complete',
  'succeeded',
  repeat('f', 64),
  now(),
  '{"id":"evt-ciwave0002","type":"checkout.session.completed","data":{"changed":true}}'::jsonb
)
\gset

SELECT CASE
  WHEN :'wave_webhook_hash_conflict_result' = 'review_required'
  THEN 'event payload conflict quarantined'
  ELSE (1 / 0)::text
END AS payload_conflict_assertion;

RESET ROLE;

DO $wave_webhook_accounting_assertions$
DECLARE
  v_topup_id uuid;
  v_credit_tx uuid;
  v_user_id uuid := '00000000-0000-0000-0000-000000000002';
BEGIN
  SELECT id, credit_wallet_transaction_id
    INTO STRICT v_topup_id, v_credit_tx
  FROM private.blc_topups
  WHERE client_reference = (
    SELECT client_reference FROM private.blc_topups
    WHERE id = (
      SELECT topup_id FROM private.blc_checkout_requests
      WHERE user_id = v_user_id
        AND idempotency_key = 'ci-wave-checkout-key-0002'
    )
  );

  IF (SELECT status FROM private.blc_topups WHERE id = v_topup_id) <> 'credited' THEN
    RAISE EXCEPTION 'Top-up was not credited after verified event';
  END IF;

  IF (SELECT count(*) FROM private.wallet_transactions
      WHERE id = v_credit_tx
        AND transaction_type = 'purchase_credit'
        AND actor_user_id = v_user_id
        AND is_posted) <> 1 THEN
    RAISE EXCEPTION 'Exactly one posted purchase-credit transaction was not created';
  END IF;

  IF (SELECT coalesce(sum(e.amount), 0)
      FROM private.wallet_ledger_entries e
      WHERE e.transaction_id = v_credit_tx
        AND e.unit = 'BLC') <> 0 THEN
    RAISE EXCEPTION 'Top-up credit journal is not balanced';
  END IF;

  IF (SELECT count(*) FROM private.wallet_transactions
      WHERE idempotency_key = 'wave-topup:' || v_topup_id::text) <> 1 THEN
    RAISE EXCEPTION 'Duplicate webhook created more than one wallet transaction';
  END IF;

  IF (SELECT count(*) FROM private.blc_topup_funding_lots
      WHERE topup_id = v_topup_id
        AND original_amount_blc = 1000
        AND remaining_amount_blc = 1000
        AND consumed_amount_blc = 0) <> 1 THEN
    RAISE EXCEPTION 'Purchased-BLC funding lot was not created exactly once';
  END IF;

  IF (SELECT processing_status FROM private.provider_events
      WHERE provider_event_id = 'evt-ciwave0002') <> 'review_required'
     OR (SELECT processed_at FROM private.provider_events
         WHERE provider_event_id = 'evt-ciwave0002') IS NOT NULL THEN
    RAISE EXCEPTION 'Conflicting event hash was not quarantined correctly';
  END IF;

  IF has_function_privilege(
       'authenticated',
       'public.process_wave_checkout_event(uuid,text,text,text,text,text,bigint,text,text,text,text,timestamp with time zone,jsonb)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.process_wave_checkout_event(uuid,text,text,text,text,text,bigint,text,text,text,text,timestamp with time zone,jsonb)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Browser role can execute Wave webhook credit processor';
  END IF;
END;
$wave_webhook_accounting_assertions$;

SELECT 'BLC Wave webhook processing tests passed' AS result;
