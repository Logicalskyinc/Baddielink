-- Atomic Wave checkout webhook processing.
-- REVIEW PROPOSAL ONLY. This is applied only in isolated PostgreSQL CI.
-- The caller must verify Wave's HMAC signature and retrieve the session from
-- Wave before invoking the service-role-only public wrapper.
BEGIN;

CREATE OR REPLACE FUNCTION private.process_wave_checkout_event(
  p_provider_account_id uuid,
  p_provider_event_id text,
  p_event_type text,
  p_checkout_session_id text,
  p_transaction_id text,
  p_client_reference text,
  p_amount_xof bigint,
  p_currency_code text,
  p_checkout_status text,
  p_payment_status text,
  p_payload_sha256 text,
  p_signature_timestamp timestamptz,
  p_payload_redacted jsonb
)
RETURNS TABLE (
  processing_result text,
  processed_topup_id uuid,
  wallet_transaction_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event_id uuid;
  v_existing_hash text;
  v_existing_status text;
  v_topup private.blc_topups%ROWTYPE;
  v_existing_reference_topup uuid;
  v_member_wallet uuid;
  v_issuance_wallet uuid;
  v_wallet_transaction uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM private.payment_provider_accounts a
    WHERE a.id = p_provider_account_id
      AND a.provider_code = 'wave'
      AND a.environment = 'sandbox'
      AND a.currency_code = 'XOF'
  ) THEN
    RAISE EXCEPTION 'Webhook provider account must be a configured Wave sandbox account'
      USING ERRCODE = '22023';
  END IF;

  IF p_provider_account_id IS NULL
     OR p_provider_event_id IS NULL
     OR length(btrim(p_provider_event_id)) NOT BETWEEN 1 AND 255
     OR p_event_type IS NULL
     OR length(btrim(p_event_type)) NOT BETWEEN 1 AND 128
     OR p_payload_sha256 IS NULL
     OR p_payload_sha256 !~ '^[0-9a-f]{64}$'
     OR p_signature_timestamp IS NULL THEN
    RAISE EXCEPTION 'Invalid verified Wave event envelope'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO private.provider_events (
    provider_account_id, provider_event_id, event_type,
    provider_reference, signature_valid, signature_timestamp,
    payload_sha256, payload_redacted, processing_status
  ) VALUES (
    p_provider_account_id, p_provider_event_id, p_event_type,
    p_checkout_session_id, true, p_signature_timestamp,
    p_payload_sha256, p_payload_redacted, 'received'
  )
  ON CONFLICT (provider_account_id, provider_event_id) DO NOTHING
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT e.id, e.payload_sha256, e.processing_status, e.topup_id
      INTO v_event_id, v_existing_hash, v_existing_status, processed_topup_id
    FROM private.provider_events e
    WHERE e.provider_account_id = p_provider_account_id
      AND e.provider_event_id = p_provider_event_id
    FOR UPDATE;

    IF v_existing_hash IS DISTINCT FROM p_payload_sha256 THEN
      UPDATE private.provider_events
      SET processing_status = 'review_required',
          processed_at = NULL,
          last_error_code = 'event_payload_hash_conflict',
          last_error_at = now()
      WHERE id = v_event_id;

      RETURN QUERY SELECT 'review_required'::text, processed_topup_id, NULL::uuid;
      RETURN;
    END IF;

    IF v_existing_status = 'processed' THEN
      RETURN QUERY
      SELECT 'duplicate'::text, processed_topup_id,
             (SELECT t.credit_wallet_transaction_id
              FROM private.blc_topups t WHERE t.id = processed_topup_id);
      RETURN;
    END IF;

    IF v_existing_status = 'ignored' THEN
      RETURN QUERY SELECT 'duplicate'::text, processed_topup_id, NULL::uuid;
      RETURN;
    END IF;

    IF v_existing_status IN ('review_required', 'rejected') THEN
      RETURN QUERY SELECT v_existing_status, processed_topup_id, NULL::uuid;
      RETURN;
    END IF;
  END IF;

  IF p_event_type <> 'checkout.session.completed' THEN
    UPDATE private.provider_events
    SET processing_status = 'ignored',
        last_error_code = CASE
          WHEN p_event_type = 'checkout.session.payment_failed'
            THEN 'checkout_payment_failed'
          ELSE 'unsupported_event_type'
        END,
        last_error_at = now()
    WHERE id = v_event_id;

    RETURN QUERY SELECT 'ignored_event'::text, NULL::uuid, NULL::uuid;
    RETURN;
  END IF;

  IF p_checkout_session_id IS NULL
     OR length(btrim(p_checkout_session_id)) NOT BETWEEN 1 AND 255
     OR p_transaction_id IS NULL
     OR length(btrim(p_transaction_id)) NOT BETWEEN 1 AND 255
     OR p_client_reference IS NULL
     OR length(btrim(p_client_reference)) NOT BETWEEN 12 AND 160
     OR p_amount_xof IS NULL
     OR p_amount_xof <= 0
     OR p_currency_code <> 'XOF'
     OR p_checkout_status <> 'complete'
     OR p_payment_status <> 'succeeded' THEN
    RAISE EXCEPTION 'Wave checkout is not a completed XOF payment'
      USING ERRCODE = '22023';
  END IF;

  SELECT t.* INTO v_topup
  FROM private.blc_topups t
  WHERE t.provider_account_id = p_provider_account_id
    AND t.client_reference = p_client_reference
  FOR UPDATE;

  IF NOT FOUND THEN
    UPDATE private.provider_events
    SET processing_status = 'review_required',
        last_error_code = 'topup_reference_not_found',
        last_error_at = now()
    WHERE id = v_event_id;

    RETURN QUERY SELECT 'review_required'::text, NULL::uuid, NULL::uuid;
    RETURN;
  END IF;

  UPDATE private.provider_events
  SET topup_id = v_topup.id
  WHERE id = v_event_id;

  IF v_topup.amount_xof <> p_amount_xof
     OR v_topup.currency_code <> p_currency_code
     OR v_topup.status NOT IN ('checkout_pending', 'credited') THEN
    UPDATE private.provider_events
    SET processing_status = 'review_required',
        last_error_code = 'topup_state_or_amount_mismatch',
        last_error_at = now()
    WHERE id = v_event_id;

    IF v_topup.status IN ('created', 'checkout_pending', 'payment_pending', 'verified') THEN
      UPDATE private.blc_topups
      SET status = 'review_required'
      WHERE id = v_topup.id;
    END IF;

    RETURN QUERY SELECT 'review_required'::text, v_topup.id, NULL::uuid;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM private.provider_payment_references r
    WHERE r.topup_id = v_topup.id
      AND r.provider_account_id = p_provider_account_id
      AND r.reference_type = 'checkout_session'
      AND r.provider_reference = p_checkout_session_id
  ) THEN
    UPDATE private.provider_events
    SET processing_status = 'review_required',
        last_error_code = 'checkout_session_mismatch',
        last_error_at = now()
    WHERE id = v_event_id;

    UPDATE private.blc_topups
    SET status = 'review_required'
    WHERE id = v_topup.id
      AND status IN ('created', 'checkout_pending', 'payment_pending', 'verified');

    RETURN QUERY SELECT 'review_required'::text, v_topup.id, NULL::uuid;
    RETURN;
  END IF;

  SELECT r.topup_id INTO v_existing_reference_topup
  FROM private.provider_payment_references r
  WHERE r.provider_account_id = p_provider_account_id
    AND r.reference_type = 'transaction'
    AND r.provider_reference = p_transaction_id;

  IF v_existing_reference_topup IS NOT NULL THEN
    IF v_existing_reference_topup = v_topup.id
       AND v_topup.status = 'credited' THEN
      UPDATE private.provider_events
      SET processing_status = 'ignored_duplicate'
      WHERE id = v_event_id;

      RETURN QUERY SELECT 'duplicate'::text, v_topup.id,
                          v_topup.credit_wallet_transaction_id;
      RETURN;
    END IF;

    UPDATE private.provider_events
    SET processing_status = 'review_required',
        last_error_code = 'provider_transaction_reused',
        last_error_at = now()
    WHERE id = v_event_id;

    UPDATE private.blc_topups
    SET status = 'review_required'
    WHERE id = v_topup.id
      AND status IN ('created', 'checkout_pending', 'payment_pending', 'verified');

    RETURN QUERY SELECT 'review_required'::text, v_topup.id, NULL::uuid;
    RETURN;
  END IF;

  IF v_topup.status = 'credited' THEN
    UPDATE private.provider_events
    SET processing_status = 'review_required',
        last_error_code = 'credited_topup_has_new_provider_transaction',
        last_error_at = now()
    WHERE id = v_event_id;

    RETURN QUERY SELECT 'review_required'::text, v_topup.id,
                        v_topup.credit_wallet_transaction_id;
    RETURN;
  END IF;

  v_member_wallet := private.ensure_member_wallet_account(
    v_topup.user_id, 'purchased_blc', 'BLC'
  );

  -- Serialize this credit with concurrent wallet spending on the member account.
  PERFORM 1
  FROM private.wallet_accounts a
  WHERE a.id = v_member_wallet
  FOR UPDATE;

  SELECT a.id INTO STRICT v_issuance_wallet
  FROM private.wallet_accounts a
  WHERE a.account_code = 'system:blc-issuance'
    AND a.account_kind = 'platform_blc_issuance'
    AND a.unit = 'BLC'
    AND a.is_system;

  INSERT INTO private.wallet_transactions (
    transaction_type, idempotency_key, actor_user_id,
    related_reference, metadata
  ) VALUES (
    'purchase_credit',
    'wave-topup:' || v_topup.id::text,
    v_topup.user_id,
    v_topup.client_reference,
    jsonb_build_object(
      'provider', 'wave',
      'provider_event_id', p_provider_event_id,
      'checkout_session_id', p_checkout_session_id,
      'provider_transaction_id', p_transaction_id,
      'amount_xof', p_amount_xof,
      'amount_blc', v_topup.amount_blc
    )
  ) RETURNING id INTO v_wallet_transaction;

  INSERT INTO private.wallet_ledger_entries (
    transaction_id, account_id, unit, amount
  ) VALUES
    (v_wallet_transaction, v_member_wallet, 'BLC', v_topup.amount_blc),
    (v_wallet_transaction, v_issuance_wallet, 'BLC', -v_topup.amount_blc);

  UPDATE private.blc_topups
  SET status = 'credited',
      credit_wallet_transaction_id = v_wallet_transaction,
      verified_at = coalesce(verified_at, now()),
      credited_at = now()
  WHERE id = v_topup.id
    AND status = 'checkout_pending';

  INSERT INTO private.provider_payment_references (
    topup_id, provider_account_id, reference_type, provider_reference
  ) VALUES (
    v_topup.id, p_provider_account_id, 'transaction', p_transaction_id
  );

  INSERT INTO private.blc_topup_funding_lots (
    topup_id, user_id, wallet_account_id, credit_wallet_transaction_id,
    original_amount_blc, remaining_amount_blc, consumed_amount_blc
  ) VALUES (
    v_topup.id, v_topup.user_id, v_member_wallet, v_wallet_transaction,
    v_topup.amount_blc, v_topup.amount_blc, 0
  );

  UPDATE private.provider_events
  SET processing_status = 'processed',
      processed_at = now(),
      topup_id = v_topup.id
  WHERE id = v_event_id;

  RETURN QUERY SELECT 'credited'::text, v_topup.id, v_wallet_transaction;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_wave_checkout_event(
  p_provider_account_id uuid,
  p_provider_event_id text,
  p_event_type text,
  p_checkout_session_id text,
  p_transaction_id text,
  p_client_reference text,
  p_amount_xof bigint,
  p_currency_code text,
  p_checkout_status text,
  p_payment_status text,
  p_payload_sha256 text,
  p_signature_timestamp timestamptz,
  p_payload_redacted jsonb
)
RETURNS TABLE (
  processing_result text,
  processed_topup_id uuid,
  wallet_transaction_id uuid
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT * FROM private.process_wave_checkout_event(
    p_provider_account_id, p_provider_event_id, p_event_type,
    p_checkout_session_id, p_transaction_id, p_client_reference,
    p_amount_xof, p_currency_code, p_checkout_status, p_payment_status,
    p_payload_sha256, p_signature_timestamp, p_payload_redacted
  );
$function$;

-- Deferred ledger constraint triggers execute at transaction end under the
-- invoking service_role. Grant only the read/update rights those trigger bodies
-- require; service_role still cannot insert ledger entries directly.
GRANT USAGE ON SCHEMA private TO service_role;
GRANT SELECT, UPDATE ON TABLE private.wallet_transactions TO service_role;
GRANT SELECT ON TABLE private.wallet_ledger_entries TO service_role;

REVOKE ALL ON FUNCTION private.process_wave_checkout_event(
  uuid, text, text, text, text, text, bigint, text, text, text, text, timestamptz, jsonb
) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.process_wave_checkout_event(
  uuid, text, text, text, text, text, bigint, text, text, text, text, timestamptz, jsonb
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.process_wave_checkout_event(
  uuid, text, text, text, text, text, bigint, text, text, text, text, timestamptz, jsonb
) TO service_role;

COMMIT;
