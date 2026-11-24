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

SELECT 'BLC Wave gift inventory provenance tests passed' AS result;
