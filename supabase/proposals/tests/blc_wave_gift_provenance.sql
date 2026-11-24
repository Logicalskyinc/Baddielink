\set ON_ERROR_STOP on

-- This test runs after BLC integration, Wave top-up schema, and
-- BLC_WAVE_GIFT_PROVENANCE.sql have been applied in isolated PostgreSQL CI.
-- It creates a real top-up credit journal and verifies deterministic allocation
-- into a gift inventory purchase. No provider call or production data is used.

DO $wave_inventory_provenance$
DECLARE
  v_user uuid := '00000000-0000-0000-0000-000000000013';
  v_provider uuid;
  v_gift_id uuid;
  v_price bigint;
  v_amount bigint;
  v_purchased_wallet uuid;
  v_issuance_wallet uuid;
  v_credit_tx uuid;
  v_purchase_tx uuid;
  v_topup_id uuid;
  v_topup_lot uuid;
  v_inventory_lot uuid;
  v_remaining bigint;
  v_consumed bigint;
  v_allocated bigint;
  v_source_remaining bigint;
BEGIN
  SELECT id INTO STRICT v_provider
  FROM private.payment_provider_accounts
  WHERE provider_code = 'wave' AND environment = 'sandbox'
  ORDER BY created_at, id
  LIMIT 1;

  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_user, 'wave-provenance@example.test', now());

  INSERT INTO public.profiles (id, moderation_status)
  VALUES (v_user, 'approved');

  INSERT INTO public.user_private_settings (user_id, date_of_birth, age_declaration_at)
  VALUES (v_user, DATE '1990-01-01', now());

  SELECT id, price_blc INTO STRICT v_gift_id, v_price
  FROM private.gift_catalog
  WHERE id = '10000000-0000-0000-0000-000000000001'
    AND is_active;

  v_amount := v_price + 50;

  v_purchased_wallet := private.ensure_member_wallet_account(
    v_user, 'purchased_blc', 'BLC'
  );

  SELECT id INTO STRICT v_issuance_wallet
  FROM private.wallet_accounts
  WHERE account_code = 'system:blc-issuance';

  INSERT INTO private.wallet_transactions (
    transaction_type, idempotency_key, actor_user_id, related_reference
  ) VALUES (
    'purchase_credit', 'ci-wave-provenance-credit-013', v_user, 'wave-topup'
  ) RETURNING id INTO v_credit_tx;

  INSERT INTO private.wallet_ledger_entries(transaction_id, account_id, unit, amount)
  VALUES
    (v_credit_tx, v_purchased_wallet, 'BLC', v_amount),
    (v_credit_tx, v_issuance_wallet, 'BLC', -v_amount);

  INSERT INTO private.blc_topups (
    user_id, provider_account_id, amount_xof, amount_blc,
    conversion_rate_numerator, conversion_rate_denominator,
    status, client_reference, credit_wallet_transaction_id,
    verified_at, credited_at
  ) VALUES (
    v_user, v_provider, v_amount, v_amount, 1, 1,
    'credited', 'ci-wave-provenance-topup-013',
    v_credit_tx, now(), now()
  ) RETURNING id INTO v_topup_id;

  INSERT INTO private.blc_topup_funding_lots (
    topup_id, user_id, wallet_account_id, credit_wallet_transaction_id,
    original_amount_blc, remaining_amount_blc, consumed_amount_blc
  ) VALUES (
    v_topup_id, v_user, v_purchased_wallet, v_credit_tx,
    v_amount, v_amount, 0
  ) RETURNING id INTO v_topup_lot;

  v_purchase_tx := private.purchase_gift_inventory(
    v_user, v_gift_id, 1, 'ci-wave-provenance-purchase-013'
  );

  SELECT id INTO STRICT v_inventory_lot
  FROM private.gift_inventory_funding_lots
  WHERE purchase_id = (
    SELECT id FROM private.gift_inventory_purchases
    WHERE wallet_transaction_id = v_purchase_tx
  );

  SELECT remaining_amount_blc, consumed_amount_blc
    INTO STRICT v_remaining, v_consumed
  FROM private.blc_topup_funding_lots
  WHERE id = v_topup_lot;

  IF v_remaining <> 50 OR v_consumed <> v_price THEN
    RAISE EXCEPTION 'Top-up lot allocation did not reconcile: remaining %, consumed %',
      v_remaining, v_consumed;
  END IF;

  SELECT coalesce(sum(allocation_amount_blc), 0)
    INTO v_allocated
  FROM private.blc_topup_lot_allocations
  WHERE inventory_purchase_id = (
    SELECT id FROM private.gift_inventory_purchases
    WHERE wallet_transaction_id = v_purchase_tx
  );

  IF v_allocated <> v_price THEN
    RAISE EXCEPTION 'Inventory purchase top-up allocations do not equal purchased debit';
  END IF;

  SELECT coalesce(sum(remaining_purchased_blc), 0)
    INTO v_source_remaining
  FROM private.gift_inventory_topup_funding_lots
  WHERE gift_inventory_funding_lot_id = v_inventory_lot
    AND topup_funding_lot_id = v_topup_lot;

  IF v_source_remaining <> v_price THEN
    RAISE EXCEPTION 'Top-up source was not propagated into inventory funding lot';
  END IF;

  IF (SELECT purchased_blc_remaining
      FROM private.gift_inventory_funding_lots
      WHERE id = v_inventory_lot) <> v_price THEN
    RAISE EXCEPTION 'Aggregate purchased inventory funding does not match source lots';
  END IF;
END;
$wave_inventory_provenance$;

-- Sending the purchased-funded inventory unit must consume its exact top-up
-- child source in the same settlement transaction.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000013', true);
SET LOCAL ROLE authenticated;
SELECT public.send_gift(
  '00000000-0000-0000-0000-000000000003',
  '10000000-0000-0000-0000-000000000001',
  'ci-wave-provenance-send-013'
);
RESET ROLE;
COMMIT;

DO $wave_inventory_consumption$
DECLARE
  v_remaining bigint;
  v_consumed bigint;
  v_aggregate_remaining bigint;
  v_topup_id uuid;
BEGIN
  SELECT id INTO STRICT v_topup_id
  FROM private.blc_topups
  WHERE client_reference = 'ci-wave-provenance-topup-013';

  SELECT remaining_purchased_blc, consumed_purchased_blc
    INTO STRICT v_remaining, v_consumed
  FROM private.gift_inventory_topup_funding_lots
  WHERE topup_funding_lot_id = (
    SELECT id FROM private.blc_topup_funding_lots WHERE topup_id = v_topup_id
  );

  SELECT purchased_blc_remaining INTO STRICT v_aggregate_remaining
  FROM private.gift_inventory_funding_lots
  WHERE purchase_id = (
    SELECT id FROM private.gift_inventory_purchases
    WHERE wallet_transaction_id = (
      SELECT id FROM private.wallet_transactions
      WHERE idempotency_key = 'ci-wave-provenance-purchase-013'
    )
  );

  IF v_remaining <> 0 OR v_consumed <> (
    SELECT amount_blc - 50 FROM private.blc_topups WHERE id = v_topup_id
  ) OR v_aggregate_remaining <> 0 THEN
    RAISE EXCEPTION
      'Gift settlement did not consume exact top-up inventory source: remaining %, consumed %, aggregate %',
      v_remaining, v_consumed, v_aggregate_remaining;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM private.gift_transactions
    WHERE idempotency_key = 'ci-wave-provenance-send-013'
      AND sender_user_id = '00000000-0000-0000-0000-000000000013'
      AND unit_face_value_xof = (
        SELECT price_blc FROM private.gift_catalog
        WHERE id = '10000000-0000-0000-0000-000000000001'
      )
  ) THEN
    RAISE EXCEPTION 'Gift settlement does not reflect purchased-funded amount';
  END IF;
END;
$wave_inventory_consumption$;


-- A single inventory purchase can draw from multiple independent Wave top-ups.
-- The source ledger must preserve FIFO allocation across both top-up lots.
DO $wave_multiple_topup_sources$
DECLARE
  v_user uuid := '00000000-0000-0000-0000-000000000015';
  v_provider uuid;
  v_gift_id uuid;
  v_price bigint;
  v_first_amount bigint;
  v_second_amount bigint;
  v_wallet uuid;
  v_issuance uuid;
  v_tx_one uuid;
  v_tx_two uuid;
  v_topup_one uuid;
  v_topup_two uuid;
  v_lot_one uuid;
  v_lot_two uuid;
  v_purchase_tx uuid;
  v_purchase_id uuid;
  v_first_allocation bigint;
  v_second_allocation bigint;
  v_child_count bigint;
  v_child_total bigint;
  v_first_remaining bigint;
  v_second_remaining bigint;
BEGIN
  SELECT id INTO STRICT v_provider
  FROM private.payment_provider_accounts
  WHERE provider_code = 'wave' AND environment = 'sandbox'
  ORDER BY created_at, id LIMIT 1;

  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_user, 'wave-multi-source@example.test', now());
  INSERT INTO public.profiles (id, moderation_status)
  VALUES (v_user, 'approved');
  INSERT INTO public.user_private_settings (user_id, date_of_birth, age_declaration_at)
  VALUES (v_user, DATE '1990-01-01', now());

  SELECT id, price_blc INTO STRICT v_gift_id, v_price
  FROM private.gift_catalog
  WHERE id = '10000000-0000-0000-0000-000000000001' AND is_active;

  IF v_price < 2 THEN
    RAISE EXCEPTION 'Fixture gift price must be at least 2 BLC';
  END IF;

  v_first_amount := greatest(1, v_price / 2);
  v_second_amount := v_price + 10 - v_first_amount;

  v_wallet := private.ensure_member_wallet_account(v_user, 'purchased_blc', 'BLC');
  SELECT id INTO STRICT v_issuance
  FROM private.wallet_accounts WHERE account_code = 'system:blc-issuance';

  INSERT INTO private.wallet_transactions(transaction_type, idempotency_key, actor_user_id)
  VALUES ('purchase_credit', 'ci-wave-multi-credit-one-015', v_user)
  RETURNING id INTO v_tx_one;
  INSERT INTO private.wallet_ledger_entries(transaction_id, account_id, unit, amount)
  VALUES (v_tx_one, v_wallet, 'BLC', v_first_amount),
         (v_tx_one, v_issuance, 'BLC', -v_first_amount);

  INSERT INTO private.blc_topups (
    user_id, provider_account_id, amount_xof, amount_blc,
    conversion_rate_numerator, conversion_rate_denominator,
    status, client_reference, credit_wallet_transaction_id,
    verified_at, credited_at
  ) VALUES (
    v_user, v_provider, v_first_amount, v_first_amount, 1, 1,
    'credited', 'ci-wave-multi-topup-one-015', v_tx_one, now(), now()
  ) RETURNING id INTO v_topup_one;

  INSERT INTO private.blc_topup_funding_lots (
    topup_id, user_id, wallet_account_id, credit_wallet_transaction_id,
    original_amount_blc, remaining_amount_blc, consumed_amount_blc, created_at
  ) VALUES (
    v_topup_one, v_user, v_wallet, v_tx_one,
    v_first_amount, v_first_amount, 0, now() - interval '1 minute'
  ) RETURNING id INTO v_lot_one;

  INSERT INTO private.wallet_transactions(transaction_type, idempotency_key, actor_user_id)
  VALUES ('purchase_credit', 'ci-wave-multi-credit-two-015', v_user)
  RETURNING id INTO v_tx_two;
  INSERT INTO private.wallet_ledger_entries(transaction_id, account_id, unit, amount)
  VALUES (v_tx_two, v_wallet, 'BLC', v_second_amount),
         (v_tx_two, v_issuance, 'BLC', -v_second_amount);

  INSERT INTO private.blc_topups (
    user_id, provider_account_id, amount_xof, amount_blc,
    conversion_rate_numerator, conversion_rate_denominator,
    status, client_reference, credit_wallet_transaction_id,
    verified_at, credited_at
  ) VALUES (
    v_user, v_provider, v_second_amount, v_second_amount, 1, 1,
    'credited', 'ci-wave-multi-topup-two-015', v_tx_two, now(), now()
  ) RETURNING id INTO v_topup_two;

  INSERT INTO private.blc_topup_funding_lots (
    topup_id, user_id, wallet_account_id, credit_wallet_transaction_id,
    original_amount_blc, remaining_amount_blc, consumed_amount_blc, created_at
  ) VALUES (
    v_topup_two, v_user, v_wallet, v_tx_two,
    v_second_amount, v_second_amount, 0, now()
  ) RETURNING id INTO v_lot_two;

  v_purchase_tx := private.purchase_gift_inventory(
    v_user, v_gift_id, 1, 'ci-wave-multi-purchase-015'
  );

  SELECT id INTO STRICT v_purchase_id
  FROM private.gift_inventory_purchases
  WHERE wallet_transaction_id = v_purchase_tx;

  SELECT allocation_amount_blc INTO STRICT v_first_allocation
  FROM private.blc_topup_lot_allocations
  WHERE inventory_purchase_id = v_purchase_id AND allocation_sequence = 1;

  SELECT allocation_amount_blc INTO STRICT v_second_allocation
  FROM private.blc_topup_lot_allocations
  WHERE inventory_purchase_id = v_purchase_id AND allocation_sequence = 2;

  IF v_first_allocation <> v_first_amount
     OR v_second_allocation <> v_price - v_first_amount THEN
    RAISE EXCEPTION
      'FIFO top-up allocation mismatch: first %, second %, expected first %, second %',
      v_first_allocation, v_second_allocation, v_first_amount, v_price - v_first_amount;
  END IF;

  SELECT remaining_amount_blc INTO STRICT v_first_remaining
  FROM private.blc_topup_funding_lots WHERE id = v_lot_one;
  SELECT remaining_amount_blc INTO STRICT v_second_remaining
  FROM private.blc_topup_funding_lots WHERE id = v_lot_two;

  IF v_first_remaining <> 0 OR v_second_remaining <> 10 THEN
    RAISE EXCEPTION
      'FIFO top-up lot balances mismatch: first %, second %',
      v_first_remaining, v_second_remaining;
  END IF;

  SELECT count(*), coalesce(sum(original_purchased_blc), 0)
    INTO v_child_count, v_child_total
  FROM private.gift_inventory_topup_funding_lots
  WHERE inventory_purchase_id = v_purchase_id;

  IF v_child_count <> 2 OR v_child_total <> v_price THEN
    RAISE EXCEPTION
      'Top-up source child lots did not reconcile: count %, total %, expected %',
      v_child_count, v_child_total, v_price;
  END IF;
END;
$wave_multiple_topup_sources$;

SELECT 'BLC Wave gift inventory provenance tests passed' AS result;
