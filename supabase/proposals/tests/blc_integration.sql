\set ON_ERROR_STOP on

-- Fixed test identities. These exist only in the ephemeral CI database.
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('00000000-0000-0000-0000-000000000001', 'referrer@example.test', now()),
  ('00000000-0000-0000-0000-000000000002', 'sender@example.test', now()),
  ('00000000-0000-0000-0000-000000000003', 'recipient@example.test', now()),
  ('00000000-0000-0000-0000-000000000004', 'mixed-sender@example.test', now()),
  ('00000000-0000-0000-0000-000000000005', 'referral-only-sender@example.test', now()),
  ('00000000-0000-0000-0000-000000000006', 'rollback-sender@example.test', now());

INSERT INTO public.profiles (id, moderation_status) VALUES
  ('00000000-0000-0000-0000-000000000001', 'approved'),
  ('00000000-0000-0000-0000-000000000002', 'approved'),
  ('00000000-0000-0000-0000-000000000003', 'approved'),
  ('00000000-0000-0000-0000-000000000004', 'approved'),
  ('00000000-0000-0000-0000-000000000005', 'approved'),
  ('00000000-0000-0000-0000-000000000006', 'approved');

INSERT INTO public.user_private_settings (user_id, date_of_birth, age_declaration_at) VALUES
  ('00000000-0000-0000-0000-000000000001', DATE '1990-01-01', now()),
  ('00000000-0000-0000-0000-000000000002', DATE '1990-01-01', now()),
  ('00000000-0000-0000-0000-000000000003', DATE '1990-01-01', now()),
  ('00000000-0000-0000-0000-000000000004', DATE '1990-01-01', now()),
  ('00000000-0000-0000-0000-000000000005', DATE '1990-01-01', now()),
  ('00000000-0000-0000-0000-000000000006', DATE '1990-01-01', now());

INSERT INTO private.gift_catalog (
  id, gift_code, display_name, price_blc, face_value_xof, asset_key, is_active
) VALUES (
  '10000000-0000-0000-0000-000000000001',
  'ci-test-rose', 'CI Test Rose', 100, 100, 'test/rose.svg', true
);

INSERT INTO private.referral_codes (
  id, owner_user_id, referral_code
) VALUES (
  '20000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  'REFERRERTEST01'
);

INSERT INTO private.referral_attributions (
  id, referrer_user_id, referred_user_id, referral_code_id
) VALUES (
  '30000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-000000000001'
), (
  '30000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000004',
  '20000000-0000-0000-0000-000000000001'
), (
  '30000000-0000-0000-0000-000000000003',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000005',
  '20000000-0000-0000-0000-000000000001'
);


-- The referral code must belong to the declared referrer. A mismatched owner
-- must be rejected by the composite foreign key.
DO $test$
BEGIN
  BEGIN
    INSERT INTO private.referral_attributions (
      id, referrer_user_id, referred_user_id, referral_code_id
    ) VALUES (
      '30000000-0000-0000-0000-000000000099',
      '00000000-0000-0000-0000-000000000002',
      '00000000-0000-0000-0000-000000000003',
      '20000000-0000-0000-0000-000000000001'
    );
    RAISE EXCEPTION 'Mismatched referral-code owner was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;
END;
$test$;

-- An inactive code cannot create a new attribution.
INSERT INTO private.referral_codes (
  id, owner_user_id, referral_code, is_active
) VALUES (
  '20000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000006',
  'INACTIVE-CODE-006',
  false
);

DO $test$
BEGIN
  BEGIN
    INSERT INTO private.referral_attributions (
      id, referrer_user_id, referred_user_id, referral_code_id
    ) VALUES (
      '30000000-0000-0000-0000-000000000098',
      '00000000-0000-0000-0000-000000000006',
      '00000000-0000-0000-0000-000000000003',
      '20000000-0000-0000-0000-000000000002'
    );
    RAISE EXCEPTION 'Inactive referral code was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END;
$test$;

-- Seed 100 purchased BLC as a balanced, posted test credit.
BEGIN;
DO $$
DECLARE
  member_account uuid;
  issuance_account uuid;
  tx_id uuid;
BEGIN
  member_account := private.ensure_member_wallet_account(
    '00000000-0000-0000-0000-000000000002', 'purchased_blc', 'BLC'
  );
  SELECT id INTO issuance_account
  FROM private.wallet_accounts
  WHERE account_code = 'system:blc-issuance';

  INSERT INTO private.wallet_transactions (
    transaction_type, idempotency_key, actor_user_id
  ) VALUES (
    'purchase_credit', 'ci-seed-purchased-credit-001',
    '00000000-0000-0000-0000-000000000002'
  ) RETURNING id INTO tx_id;

  INSERT INTO private.wallet_ledger_entries(transaction_id, account_id, unit, amount)
  VALUES
    (tx_id, member_account, 'BLC', 100),
    (tx_id, issuance_account, 'BLC', -100);
END;
$$;
COMMIT;

-- Seed mixed-funding and referral-only balances. These are isolated test
-- credits representing already-earned referral BLC; each unit is balanced.
BEGIN;
DO $ci$
DECLARE
  user_id uuid;
  purchased_account uuid;
  referral_account uuid;
  issuance_account uuid;
  revenue_account uuid;
  referral_funding_account uuid;
  tx_id uuid;
BEGIN
  SELECT id INTO issuance_account FROM private.wallet_accounts
  WHERE account_code = 'system:blc-issuance';
  SELECT id INTO revenue_account FROM private.wallet_accounts
  WHERE account_code = 'system:xof-platform-revenue';
  SELECT id INTO referral_funding_account FROM private.wallet_accounts
  WHERE account_code = 'system:xof-referral-funding';

  -- User 4 receives 60 purchased + 40 referral BLC.
  user_id := '00000000-0000-0000-0000-000000000004';
  purchased_account := private.ensure_member_wallet_account(user_id, 'purchased_blc', 'BLC');
  referral_account := private.ensure_member_wallet_account(user_id, 'referral_blc', 'BLC');
  INSERT INTO private.wallet_transactions(transaction_type, idempotency_key, actor_user_id)
  VALUES ('purchase_credit', 'ci-mixed-funding-seed-004', user_id) RETURNING id INTO tx_id;
  INSERT INTO private.wallet_ledger_entries(transaction_id, account_id, unit, amount)
  VALUES
    (tx_id, purchased_account, 'BLC', 60),
    (tx_id, referral_account, 'BLC', 40),
    (tx_id, issuance_account, 'BLC', -100),
    (tx_id, revenue_account, 'XOF', -40),
    (tx_id, referral_funding_account, 'XOF', 40);

  -- User 5 receives referral BLC only.
  user_id := '00000000-0000-0000-0000-000000000005';
  referral_account := private.ensure_member_wallet_account(user_id, 'referral_blc', 'BLC');
  INSERT INTO private.wallet_transactions(transaction_type, idempotency_key, actor_user_id)
  VALUES ('purchase_credit', 'ci-referral-only-seed-005', user_id) RETURNING id INTO tx_id;
  INSERT INTO private.wallet_ledger_entries(transaction_id, account_id, unit, amount)
  VALUES
    (tx_id, referral_account, 'BLC', 100),
    (tx_id, issuance_account, 'BLC', -100),
    (tx_id, revenue_account, 'XOF', -100),
    (tx_id, referral_funding_account, 'XOF', 100);

  -- User 6 receives purchased BLC for an intentional trigger-failure rollback test.
  user_id := '00000000-0000-0000-0000-000000000006';
  purchased_account := private.ensure_member_wallet_account(user_id, 'purchased_blc', 'BLC');
  INSERT INTO private.wallet_transactions(transaction_type, idempotency_key, actor_user_id)
  VALUES ('purchase_credit', 'ci-rollback-seed-006', user_id) RETURNING id INTO tx_id;
  INSERT INTO private.wallet_ledger_entries(transaction_id, account_id, unit, amount)
  VALUES
    (tx_id, purchased_account, 'BLC', 100),
    (tx_id, issuance_account, 'BLC', -100);
END;
$ci$;
COMMIT;

-- Purchase one gift each with mixed, referral-only, and rollback-test funding.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_gift_inventory('10000000-0000-0000-0000-000000000001', 1, 'ci-mixed-purchase-004');
RESET ROLE;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000005', true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_gift_inventory('10000000-0000-0000-0000-000000000001', 1, 'ci-referral-only-purchase-005');
RESET ROLE;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000006', true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_gift_inventory('10000000-0000-0000-0000-000000000001', 1, 'ci-rollback-purchase-006');
RESET ROLE;
COMMIT;

-- Exercise the authenticated wrapper, deriving sender identity from auth.uid().
BEGIN;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
SET LOCAL ROLE authenticated;
SELECT public.purchase_gift_inventory(
  '10000000-0000-0000-0000-000000000001', 1, 'ci-gift-purchase-001'
);
RESET ROLE;
COMMIT;

-- Send one gift. The AFTER INSERT provenance trigger must add referral ledger
-- entries while the wallet transaction is still draft; deferred posting runs
-- only at transaction commit.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
SET LOCAL ROLE authenticated;
SELECT public.send_gift(
  '00000000-0000-0000-0000-000000000003',
  '10000000-0000-0000-0000-000000000001',
  'ci-gift-send-001'
);
RESET ROLE;
COMMIT;

-- Send mixed-funded and referral-only gifts through the same authenticated RPC.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', true);
SET LOCAL ROLE authenticated;
SELECT public.send_gift('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'ci-mixed-send-004');
RESET ROLE;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000005', true);
SET LOCAL ROLE authenticated;
SELECT public.send_gift('00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'ci-referral-only-send-005');
RESET ROLE;
COMMIT;

-- Assert the 70 / 5 / 25 split, one reward, consumed provenance, and balanced
-- posted ledger transactions in both units.
DO $$
DECLARE
  gift_row private.gift_transactions%ROWTYPE;
  reward_row private.referral_rewards%ROWTYPE;
  tx_id uuid;
  remaining_units integer;
BEGIN
  SELECT * INTO STRICT gift_row
  FROM private.gift_transactions
  WHERE idempotency_key = 'ci-gift-send-001';

  IF gift_row.recipient_share_xof <> 70
     OR gift_row.referral_share_xof <> 5
     OR gift_row.platform_share_xof <> 25 THEN
    RAISE EXCEPTION 'Unexpected gift split: recipient %, referral %, platform %',
      gift_row.recipient_share_xof,
      gift_row.referral_share_xof,
      gift_row.platform_share_xof;
  END IF;

  SELECT * INTO STRICT reward_row
  FROM private.referral_rewards
  WHERE gift_transaction_id = gift_row.id;

  IF reward_row.eligible_amount_xof <> 100
     OR reward_row.reward_amount_blc <> 5 THEN
    RAISE EXCEPTION 'Unexpected referral reward calculation';
  END IF;

  SELECT quantity_remaining INTO STRICT remaining_units
  FROM private.gift_inventory_funding_lots
  WHERE user_id = '00000000-0000-0000-0000-000000000002'
    AND gift_id = gift_row.gift_id;

  IF remaining_units <> 0 THEN
    RAISE EXCEPTION 'Gift inventory funding lot was not consumed';
  END IF;

  tx_id := gift_row.wallet_transaction_id;

  IF NOT (SELECT is_posted FROM private.wallet_transactions WHERE id = tx_id) THEN
    RAISE EXCEPTION 'Gift wallet transaction was not posted';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM private.wallet_ledger_entries
    WHERE transaction_id = tx_id
    GROUP BY unit
    HAVING sum(amount) <> 0
  ) THEN
    RAISE EXCEPTION 'Gift settlement ledger is not balanced';
  END IF;

  IF coalesce((SELECT quantity FROM private.member_gift_inventory
      WHERE user_id = '00000000-0000-0000-0000-000000000002'
        AND gift_id = gift_row.gift_id), -1) <> 0 THEN
    RAISE EXCEPTION 'Gift inventory quantity was not decremented';
  END IF;
END;
$$;

-- Mixed funding must reward only the purchased 60% of the gift value.
DO $ci$
DECLARE
  mixed_row private.gift_transactions%ROWTYPE;
  mixed_reward private.referral_rewards%ROWTYPE;
  referral_only_row private.gift_transactions%ROWTYPE;
  remaining_purchased bigint;
  remaining_referral bigint;
BEGIN
  SELECT * INTO STRICT mixed_row FROM private.gift_transactions
  WHERE idempotency_key = 'ci-mixed-send-004';
  IF mixed_row.recipient_share_xof <> 70
     OR mixed_row.referral_share_xof <> 3
     OR mixed_row.platform_share_xof <> 27 THEN
    RAISE EXCEPTION 'Mixed funding split incorrect: recipient %, referral %, platform %',
      mixed_row.recipient_share_xof, mixed_row.referral_share_xof, mixed_row.platform_share_xof;
  END IF;

  SELECT * INTO STRICT mixed_reward FROM private.referral_rewards
  WHERE gift_transaction_id = mixed_row.id;
  IF mixed_reward.eligible_amount_xof <> 60 OR mixed_reward.reward_amount_blc <> 3 THEN
    RAISE EXCEPTION 'Mixed funding reward should be 3 BLC on 60 XOF eligible value';
  END IF;

  SELECT * INTO STRICT referral_only_row FROM private.gift_transactions
  WHERE idempotency_key = 'ci-referral-only-send-005';
  IF referral_only_row.recipient_share_xof <> 70
     OR referral_only_row.referral_share_xof <> 0
     OR referral_only_row.platform_share_xof <> 30 THEN
    RAISE EXCEPTION 'Referral-funded gift must not earn a referral reward';
  END IF;

  IF EXISTS (SELECT 1 FROM private.referral_rewards WHERE gift_transaction_id = referral_only_row.id) THEN
    RAISE EXCEPTION 'Referral-funded BLC incorrectly generated a referral reward';
  END IF;

  SELECT purchased_blc_remaining, referral_blc_remaining
    INTO remaining_purchased, remaining_referral
  FROM private.gift_inventory_funding_lots
  WHERE user_id = '00000000-0000-0000-0000-000000000004';
  IF remaining_purchased <> 0 OR remaining_referral <> 0 THEN
    RAISE EXCEPTION 'Mixed funding provenance was not fully consumed';
  END IF;

  IF (SELECT count(*) FROM private.gift_transactions) <> 3
     OR (SELECT count(*) FROM private.referral_rewards) <> 2 THEN
    RAISE EXCEPTION 'Unexpected gift/reward record counts after funding cases';
  END IF;
END;
$ci$;

-- Reward identity must match both the immutable attribution and the actual gift sender.
DO $identity$
DECLARE
  referral_only_gift private.gift_transactions%ROWTYPE;
  sender_two_attribution uuid;
  sender_five_attribution uuid;
  unrelated_wallet_transaction uuid;
BEGIN
  SELECT * INTO STRICT referral_only_gift
  FROM private.gift_transactions
  WHERE idempotency_key = 'ci-referral-only-send-005';

  SELECT id INTO STRICT sender_two_attribution
  FROM private.referral_attributions
  WHERE referred_user_id = '00000000-0000-0000-0000-000000000002';

  SELECT id INTO STRICT sender_five_attribution
  FROM private.referral_attributions
  WHERE referred_user_id = '00000000-0000-0000-0000-000000000005';

  -- Wrong referrer for an otherwise matching attribution and gift sender.
  BEGIN
    INSERT INTO private.referral_rewards (
      referral_attribution_id, referrer_user_id, referred_user_id,
      gift_transaction_id, eligible_amount_xof, reward_amount_blc,
      wallet_transaction_id
    ) VALUES (
      sender_five_attribution,
      '00000000-0000-0000-0000-000000000002',
      '00000000-0000-0000-0000-000000000005',
      referral_only_gift.id, 10, 1, referral_only_gift.wallet_transaction_id
    );
    RAISE EXCEPTION 'Mismatched reward referrer was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  -- The reward wallet transaction must be the same transaction that settled this gift.
  SELECT id INTO STRICT unrelated_wallet_transaction
  FROM private.wallet_transactions
  WHERE idempotency_key = 'ci-seed-purchased-credit-001';

  BEGIN
    INSERT INTO private.referral_rewards (
      referral_attribution_id, referrer_user_id, referred_user_id,
      gift_transaction_id, eligible_amount_xof, reward_amount_blc,
      wallet_transaction_id
    ) VALUES (
      sender_five_attribution,
      '00000000-0000-0000-0000-000000000001',
      '00000000-0000-0000-0000-000000000005',
      referral_only_gift.id, 10, 1, unrelated_wallet_transaction
    );
    RAISE EXCEPTION 'Reward linked to an unrelated wallet transaction was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  -- Reward amount must equal floor(eligible amount * 5%).
  BEGIN
    INSERT INTO private.referral_rewards (
      referral_attribution_id, referrer_user_id, referred_user_id,
      gift_transaction_id, eligible_amount_xof, reward_amount_blc,
      wallet_transaction_id
    ) VALUES (
      sender_five_attribution,
      '00000000-0000-0000-0000-000000000001',
      '00000000-0000-0000-0000-000000000005',
      referral_only_gift.id, 100, 4, referral_only_gift.wallet_transaction_id
    );
    RAISE EXCEPTION 'Incorrect five-percent reward amount was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  -- Attribution identity matches, but the gift was sent by a different member.
  BEGIN
    INSERT INTO private.referral_rewards (
      referral_attribution_id, referrer_user_id, referred_user_id,
      gift_transaction_id, eligible_amount_xof, reward_amount_blc,
      wallet_transaction_id
    ) VALUES (
      sender_two_attribution,
      '00000000-0000-0000-0000-000000000001',
      '00000000-0000-0000-0000-000000000002',
      referral_only_gift.id, 10, 1, referral_only_gift.wallet_transaction_id
    );
    RAISE EXCEPTION 'Reward for a gift sent by another member was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;
END;
$identity$;

-- Force a failure inside the AFTER INSERT provenance trigger, after settlement
-- has decremented inventory and written draft ledger rows. The statement must
-- roll back every write, including the inventory decrement.
DO $ci$
DECLARE
  before_inventory bigint;
  before_transactions bigint;
  before_gifts bigint;
BEGIN
  SELECT quantity INTO before_inventory FROM private.member_gift_inventory
  WHERE user_id = '00000000-0000-0000-0000-000000000006'
    AND gift_id = '10000000-0000-0000-0000-000000000001';

  SELECT count(*) INTO before_transactions FROM private.wallet_transactions;
  SELECT count(*) INTO before_gifts FROM private.gift_transactions;

  DELETE FROM private.gift_inventory_funding_lots
  WHERE user_id = '00000000-0000-0000-0000-000000000006';

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000006', true);
    PERFORM public.send_gift(
      '00000000-0000-0000-0000-000000000003',
      '10000000-0000-0000-0000-000000000001',
      'ci-forced-rollback-send-006'
    );
    RAISE EXCEPTION 'Expected missing-provenance trigger failure did not occur';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM = 'Expected missing-provenance trigger failure did not occur' THEN
      RAISE;
    END IF;
  END;

  IF (SELECT quantity FROM private.member_gift_inventory
      WHERE user_id = '00000000-0000-0000-0000-000000000006'
        AND gift_id = '10000000-0000-0000-0000-000000000001') <> before_inventory THEN
    RAISE EXCEPTION 'Failed gift send did not roll back inventory decrement';
  END IF;

  IF (SELECT count(*) FROM private.wallet_transactions) <> before_transactions
     OR (SELECT count(*) FROM private.gift_transactions) <> before_gifts THEN
    RAISE EXCEPTION 'Failed gift send left partial financial records';
  END IF;
END;
$ci$;

-- A retry with the same key must return the original transaction and must not
-- create a second gift or referral reward.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
SET LOCAL ROLE authenticated;
SELECT public.send_gift(
  '00000000-0000-0000-0000-000000000003',
  '10000000-0000-0000-0000-000000000001',
  'ci-gift-send-001'
);
RESET ROLE;
COMMIT;

DO $$
BEGIN
  IF (SELECT count(*) FROM private.gift_transactions) <> 3
     OR (SELECT count(*) FROM private.referral_rewards) <> 2 THEN
    RAISE EXCEPTION 'Idempotent retry created duplicate financial records';
  END IF;

  IF has_function_privilege('anon', 'public.send_gift(uuid,uuid,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.purchase_gift_inventory(uuid,integer,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Anonymous role can execute a gift RPC';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.send_gift(uuid,uuid,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.purchase_gift_inventory(uuid,integer,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Authenticated role cannot execute the intended public gift RPCs';
  END IF;

  IF has_function_privilege('authenticated', 'private.ensure_member_wallet_account(uuid,text,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'private.purchase_gift_inventory(uuid,uuid,integer,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'private.settle_gift(uuid,uuid,uuid,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'private.apply_deferred_referral_reward()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'private.record_gift_inventory_funding_lot()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'private.assert_wallet_transaction_balanced()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'private.require_draft_wallet_transaction()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'private.reject_wallet_transaction_mutation()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'private.reject_wallet_ledger_mutation()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'private.reject_gift_catalog_value_change()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'private.reject_referral_attribution_mutation()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'private.reject_referral_reward_mutation()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Authenticated role can execute a private financial function';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'private.wallet_accounts','private.wallet_transactions','private.wallet_ledger_entries',
      'private.gift_catalog','private.member_gift_inventory','private.gift_inventory_purchases',
      'private.gift_transactions','private.referral_codes','private.referral_attributions',
      'private.referral_rewards','private.gift_inventory_funding_lots'
    ]) AS t(table_name)
    CROSS JOIN unnest(ARRAY['anon','authenticated']) AS r(role_name)
    CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) AS p(privilege_name)
    WHERE has_table_privilege(r.role_name, t.table_name, p.privilege_name)
  ) THEN
    RAISE EXCEPTION 'A client role has direct access to a private financial table';
  END IF;
END;
$$;

SELECT 'BLC PostgreSQL integration tests passed' AS result;
