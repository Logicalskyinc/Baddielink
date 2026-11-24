\set ON_ERROR_STOP on

-- Runs after the existing BLC integration suite in the isolated PostgreSQL CI DB.
-- These fixtures and assertions never touch production data.

INSERT INTO private.payment_provider_accounts (
  id, provider_code, environment, provider_account_reference
) VALUES (
  '90000000-0000-0000-0000-000000000001',
  'wave', 'sandbox', 'ci-wave-wallet'
);

INSERT INTO private.blc_topups (
  id, user_id, provider_account_id, amount_xof, amount_blc,
  conversion_rate_numerator, conversion_rate_denominator,
  status, client_reference
) VALUES (
  '90000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  '90000000-0000-0000-0000-000000000001',
  2500, 2500, 1, 1, 'verified', 'ci-wave-topup-ref-0001'
);

INSERT INTO private.provider_payment_references (
  topup_id, provider_account_id, reference_type, provider_reference
) VALUES (
  '90000000-0000-0000-0000-000000000001',
  '90000000-0000-0000-0000-000000000001',
  'checkout_session', 'ci-wave-checkout-0001'
);

INSERT INTO private.provider_events (
  provider_account_id, provider_event_id, event_type,
  provider_reference, topup_id, signature_valid,
  payload_sha256, processing_status
) VALUES (
  '90000000-0000-0000-0000-000000000001',
  'ci-wave-event-0001', 'checkout.session.completed',
  'ci-wave-checkout-0001',
  '90000000-0000-0000-0000-000000000001',
  true, repeat('a', 64), 'queued'
);

DO $wave_schema_assertions$
DECLARE
  account_id uuid;
  topup_id uuid;
BEGIN
  -- Provider event IDs are unique within provider account.
  BEGIN
    INSERT INTO private.provider_events (
      provider_account_id, provider_event_id, event_type,
      signature_valid, payload_sha256
    ) VALUES (
      '90000000-0000-0000-0000-000000000001',
      'ci-wave-event-0001', 'checkout.session.completed',
      true, repeat('b', 64)
    );
    RAISE EXCEPTION 'Duplicate provider event ID was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  -- Invalid signatures cannot be queued for financial processing.
  BEGIN
    INSERT INTO private.provider_events (
      provider_account_id, provider_event_id, event_type,
      signature_valid, payload_sha256, processing_status
    ) VALUES (
      '90000000-0000-0000-0000-000000000001',
      'ci-wave-event-invalid', 'checkout.session.completed',
      false, repeat('c', 64), 'queued'
    );
    RAISE EXCEPTION 'Invalid signature event was queued';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  -- Conversion snapshot must exactly reconcile XOF and BLC.
  BEGIN
    INSERT INTO private.blc_topups (
      user_id, provider_account_id, amount_xof, amount_blc,
      conversion_rate_numerator, conversion_rate_denominator,
      client_reference
    ) VALUES (
      '00000000-0000-0000-0000-000000000002',
      '90000000-0000-0000-0000-000000000001',
      2500, 2499, 1, 1, 'ci-wave-invalid-rate-0001'
    );
    RAISE EXCEPTION 'Mismatched XOF/BLC conversion was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  -- A top-up funding lot must belong to the same user as its purchased wallet.
  SELECT id INTO account_id
  FROM private.wallet_accounts
  WHERE owner_user_id = '00000000-0000-0000-0000-000000000001'
    AND account_kind = 'purchased_blc';

  IF account_id IS NULL THEN
    RAISE EXCEPTION 'Expected purchased wallet fixture is missing';
  END IF;

  BEGIN
    INSERT INTO private.blc_topup_funding_lots (
      topup_id, user_id, wallet_account_id,
      original_amount_blc, remaining_amount_blc, consumed_amount_blc
    ) VALUES (
      '90000000-0000-0000-0000-000000000001',
      '00000000-0000-0000-0000-000000000002',
      account_id, 2500, 2500, 0
    );
    RAISE EXCEPTION 'Cross-user funding lot was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  -- Correct owner/account identity is accepted as a schema fact. This fixture
  -- intentionally does not create a wallet credit or mark the top-up credited.
  SELECT id INTO account_id
  FROM private.wallet_accounts
  WHERE owner_user_id = '00000000-0000-0000-0000-000000000002'
    AND account_kind = 'purchased_blc';

  IF account_id IS NULL THEN
    INSERT INTO private.wallet_accounts (
      owner_user_id, account_code, account_kind, unit, is_system
    ) VALUES (
      '00000000-0000-0000-0000-000000000002',
      'ci-wave-member-purchased-wallet',
      'purchased_blc', 'BLC', false
    ) RETURNING id INTO account_id;
  END IF;

  INSERT INTO private.blc_topup_funding_lots (
    topup_id, user_id, wallet_account_id,
    original_amount_blc, remaining_amount_blc, consumed_amount_blc
  ) VALUES (
    '90000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000002',
    account_id, 2500, 2500, 0
  );

  IF has_table_privilege('anon', 'private.blc_topups', 'SELECT')
     OR has_table_privilege('authenticated', 'private.blc_topups', 'INSERT')
     OR has_table_privilege('authenticated', 'private.provider_events', 'SELECT') THEN
    RAISE EXCEPTION 'Client role has direct access to private top-up records';
  END IF;

  IF has_function_privilege('authenticated',
      'private.reject_blc_topup_allocation_mutation()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Authenticated role can execute private trigger function';
  END IF;
END;
$wave_schema_assertions$;

SELECT 'BLC Wave top-up schema tests passed' AS result;
