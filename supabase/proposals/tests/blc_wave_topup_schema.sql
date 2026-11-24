\set ON_ERROR_STOP on

-- Isolated schema tests. This file runs after the existing BLC integration
-- suite, which has already created eligible user 2 and its purchased wallet.
-- It does not call Wave or create real payment evidence.

DO $wave_schema_setup$
DECLARE
  v_provider_id uuid;
  v_user_id uuid := '00000000-0000-0000-0000-000000000002';
  v_purchased_account_id uuid;
  v_issuance_account_id uuid;
  v_credit_tx_id uuid;
  v_topup_id uuid;
BEGIN
  SELECT id INTO STRICT v_purchased_account_id
  FROM private.wallet_accounts
  WHERE owner_user_id = v_user_id
    AND account_kind = 'purchased_blc'
    AND unit = 'BLC';

  SELECT id INTO STRICT v_issuance_account_id
  FROM private.wallet_accounts
  WHERE account_code = 'system:blc-issuance';

  INSERT INTO private.payment_provider_accounts (
    provider_code, environment, provider_account_reference
  ) VALUES ('wave', 'sandbox', 'ci-wave-wallet')
  RETURNING id INTO v_provider_id;

  INSERT INTO private.wallet_transactions (
    transaction_type, idempotency_key, actor_user_id, related_reference
  ) VALUES (
    'purchase_credit', 'ci-wave-topup-credit-user-002', v_user_id, 'ci-wave-topup-002'
  ) RETURNING id INTO v_credit_tx_id;

  INSERT INTO private.wallet_ledger_entries (
    transaction_id, account_id, unit, amount
  ) VALUES
    (v_credit_tx_id, v_purchased_account_id, 'BLC', 25),
    (v_credit_tx_id, v_issuance_account_id, 'BLC', -25);

  INSERT INTO private.blc_topups (
    user_id, provider_account_id, amount_xof, amount_blc,
    conversion_rate_numerator, conversion_rate_denominator,
    status, client_reference, credit_wallet_transaction_id,
    verified_at, credited_at
  ) VALUES (
    v_user_id, v_provider_id, 25, 25, 1, 1,
    'credited', 'ci-wave-topup-client-002', v_credit_tx_id,
    now(), now()
  ) RETURNING id INTO v_topup_id;

  INSERT INTO private.provider_payment_references (
    topup_id, provider_account_id, reference_type, provider_reference
  ) VALUES
    (v_topup_id, v_provider_id, 'checkout_session', 'ci-wave-checkout-002'),
    (v_topup_id, v_provider_id, 'transaction', 'ci-wave-transaction-002');

  INSERT INTO private.provider_events (
    provider_account_id, provider_event_id, event_type, provider_reference,
    topup_id, signature_valid, payload_sha256, processing_status
  ) VALUES (
    v_provider_id, 'ci-wave-event-002', 'checkout.session.completed',
    'ci-wave-checkout-002', v_topup_id, true, repeat('a', 64), 'received'
  );

  INSERT INTO private.blc_topup_funding_lots (
    topup_id, user_id, wallet_account_id, credit_wallet_transaction_id,
    original_amount_blc, remaining_amount_blc, consumed_amount_blc
  ) VALUES (
    v_topup_id, v_user_id, v_purchased_account_id, v_credit_tx_id, 25, 25, 0
  );

  IF NOT EXISTS (
    SELECT 1
    FROM private.blc_topup_funding_lots lot
    WHERE lot.topup_id = v_topup_id
      AND lot.user_id = v_user_id
      AND lot.credit_wallet_transaction_id = v_credit_tx_id
  ) THEN
    RAISE EXCEPTION 'Top-up funding lot lost its credit transaction identity';
  END IF;
END;
$wave_schema_setup$;

DO $wave_schema_negative_tests$
DECLARE
  v_provider_id uuid;
  v_topup_id uuid;
  v_credit_tx_id uuid;
  v_other_user_tx_id uuid;
  v_other_wallet_id uuid;
  v_second_credit_tx_id uuid;
  v_second_topup_id uuid;
  v_member_wallet_id uuid;
  v_other_issuance_id uuid;
  v_issuance_id uuid;
  v_member_wallet_id uuid;
  v_second_credit_tx_id uuid;
  v_second_topup_id uuid;
BEGIN
  SELECT id INTO STRICT v_provider_id
  FROM private.payment_provider_accounts
  WHERE provider_account_reference = 'ci-wave-wallet';

  SELECT id INTO STRICT v_topup_id
  FROM private.blc_topups
  WHERE client_reference = 'ci-wave-topup-client-002';

  SELECT credit_wallet_transaction_id INTO STRICT v_credit_tx_id
  FROM private.blc_topups
  WHERE id = v_topup_id;

  -- Conversion snapshot must exactly reconcile XOF and BLC.
  BEGIN
    INSERT INTO private.blc_topups (
      user_id, provider_account_id, amount_xof, amount_blc,
      conversion_rate_numerator, conversion_rate_denominator, client_reference
    ) VALUES (
      '00000000-0000-0000-0000-000000000002',
      v_provider_id, 25, 24, 1, 1, 'ci-wave-invalid-conversion'
    );
    RAISE EXCEPTION 'Mismatched XOF/BLC conversion was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  -- A credited top-up cannot omit its immutable credit transaction.
  BEGIN
    INSERT INTO private.blc_topups (
      user_id, provider_account_id, amount_xof, amount_blc,
      conversion_rate_numerator, conversion_rate_denominator,
      status, client_reference
    ) VALUES (
      '00000000-0000-0000-0000-000000000002',
      v_provider_id, 10, 10, 1, 1,
      'credited', 'ci-wave-credit-missing'
    );
    RAISE EXCEPTION 'Credited top-up without journal was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  -- A wallet transaction owned by another member cannot be linked to this top-up.
  SELECT id INTO v_other_wallet_id
  FROM private.wallet_accounts
  WHERE owner_user_id = '00000000-0000-0000-0000-000000000004'
    AND account_kind = 'purchased_blc';

  IF v_other_wallet_id IS NULL THEN
    INSERT INTO private.wallet_accounts (
      owner_user_id, account_code, account_kind, unit, is_system
    ) VALUES (
      '00000000-0000-0000-0000-000000000004',
      'ci-wave-other-member-purchased-wallet',
      'purchased_blc', 'BLC', false
    ) RETURNING id INTO v_other_wallet_id;
  END IF;

  SELECT id INTO STRICT v_issuance_id
  FROM private.wallet_accounts WHERE account_code = 'system:blc-issuance';

  INSERT INTO private.wallet_transactions (
    transaction_type, idempotency_key, actor_user_id
  ) VALUES (
    'manual_adjustment', 'ci-wave-other-owner-credit',
    '00000000-0000-0000-0000-000000000004'
  ) RETURNING id INTO v_other_user_tx_id;

  INSERT INTO private.wallet_ledger_entries(transaction_id, account_id, unit, amount)
  VALUES
    (v_other_user_tx_id, v_other_wallet_id, 'BLC', 1),
    (v_other_user_tx_id, v_issuance_id, 'BLC', -1);

  -- Create a second credited top-up for user 2 so the wallet-owner FK can be
  -- tested independently of the one-lot-per-top-up uniqueness constraint.
  SELECT wallet_account_id INTO STRICT v_member_wallet_id
  FROM private.blc_topup_funding_lots
  WHERE topup_id = v_topup_id;

  INSERT INTO private.wallet_transactions (
    transaction_type, idempotency_key, actor_user_id
  ) VALUES (
    'purchase_credit', 'ci-wave-second-member-credit',
    '00000000-0000-0000-0000-000000000002'
  ) RETURNING id INTO v_second_credit_tx_id;

  INSERT INTO private.wallet_ledger_entries(transaction_id, account_id, unit, amount)
  VALUES
    (v_second_credit_tx_id, v_member_wallet_id, 'BLC', 5),
    (v_second_credit_tx_id, v_issuance_id, 'BLC', -5);

  INSERT INTO private.blc_topups (
    user_id, provider_account_id, amount_xof, amount_blc,
    conversion_rate_numerator, conversion_rate_denominator,
    status, client_reference, credit_wallet_transaction_id,
    verified_at, credited_at
  ) VALUES (
    '00000000-0000-0000-0000-000000000002',
    v_provider_id, 5, 5, 1, 1, 'credited',
    'ci-wave-second-topup-credit', v_second_credit_tx_id, now(), now()
  ) RETURNING id INTO v_second_topup_id;

  BEGIN
    INSERT INTO private.blc_topups (
      user_id, provider_account_id, amount_xof, amount_blc,
      conversion_rate_numerator, conversion_rate_denominator,
      status, client_reference, credit_wallet_transaction_id, credited_at
    ) VALUES (
      '00000000-0000-0000-0000-000000000002',
      v_provider_id, 1, 1, 1, 1, 'credited',
      'ci-wave-wrong-owner-credit', v_other_user_tx_id, now()
    );
    RAISE EXCEPTION 'Cross-member credit transaction was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;


  -- Duplicate provider event IDs must not create a second event record.
  BEGIN
    INSERT INTO private.provider_events (
      provider_account_id, provider_event_id, event_type, topup_id,
      signature_valid, payload_sha256
    ) VALUES (
      v_provider_id, 'ci-wave-event-002', 'checkout.session.completed',
      v_topup_id, true, repeat('b', 64)
    );
    RAISE EXCEPTION 'Duplicate provider event ID was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  -- Invalid-signature events cannot be queued for financial processing.
  BEGIN
    INSERT INTO private.provider_events (
      provider_account_id, provider_event_id, event_type, topup_id,
      signature_valid, payload_sha256, processing_status
    ) VALUES (
      v_provider_id, 'ci-wave-invalid-signature', 'checkout.session.completed',
      v_topup_id, false, repeat('c', 64), 'queued'
    );
    RAISE EXCEPTION 'Invalid-signature event was queued';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  -- Create a second credited top-up so the wrong-wallet test reaches the
  -- composite owner FK rather than the one-lot-per-top-up unique constraint.
  SELECT id INTO STRICT v_member_wallet_id
  FROM private.wallet_accounts
  WHERE owner_user_id = '00000000-0000-0000-0000-000000000002'
    AND account_kind = 'purchased_blc';

  INSERT INTO private.wallet_transactions (
    transaction_type, idempotency_key, actor_user_id
  ) VALUES (
    'purchase_credit', 'ci-wave-second-topup-credit-user-002',
    '00000000-0000-0000-0000-000000000002'
  ) RETURNING id INTO v_second_credit_tx_id;

  INSERT INTO private.wallet_ledger_entries(transaction_id, account_id, unit, amount)
  VALUES
    (v_second_credit_tx_id, v_member_wallet_id, 'BLC', 1),
    (v_second_credit_tx_id, v_issuance_id, 'BLC', -1);

  INSERT INTO private.blc_topups (
    user_id, provider_account_id, amount_xof, amount_blc,
    conversion_rate_numerator, conversion_rate_denominator,
    status, client_reference, credit_wallet_transaction_id, verified_at, credited_at
  ) VALUES (
    '00000000-0000-0000-0000-000000000002',
    v_provider_id, 1, 1, 1, 1, 'credited',
    'ci-wave-second-topup-client-002', v_second_credit_tx_id, now(), now()
  ) RETURNING id INTO v_second_topup_id;

  -- The funding lot must link to the top-up's exact credit journal and member.
  BEGIN
    INSERT INTO private.blc_topup_funding_lots (
      topup_id, user_id, wallet_account_id, credit_wallet_transaction_id,
      original_amount_blc, remaining_amount_blc, consumed_amount_blc
    ) VALUES (
      v_second_topup_id, '00000000-0000-0000-0000-000000000002',
      v_other_wallet_id, v_second_credit_tx_id, 5, 5, 0
    );
    RAISE EXCEPTION 'Cross-member top-up funding wallet was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  -- Browser roles receive no direct access to private financial tables/functions.
  IF has_table_privilege('anon', 'private.blc_topups', 'SELECT')
     OR has_table_privilege('authenticated', 'private.blc_topups', 'INSERT')
     OR has_table_privilege('anon', 'private.provider_events', 'SELECT')
     OR has_table_privilege('authenticated', 'private.blc_topup_funding_lots', 'UPDATE')
     OR has_function_privilege(
       'authenticated',
       'private.reject_blc_topup_allocation_mutation()',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Browser role has unexpected access to private top-up objects';
  END IF;
END;
$wave_schema_negative_tests$;

SELECT 'BLC Wave top-up schema constraint tests passed' AS result;
