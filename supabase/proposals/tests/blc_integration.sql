\set ON_ERROR_STOP on

-- Fixed test identities. These exist only in the ephemeral CI database.
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('00000000-0000-0000-0000-000000000001', 'referrer@example.test', now()),
  ('00000000-0000-0000-0000-000000000002', 'sender@example.test', now()),
  ('00000000-0000-0000-0000-000000000003', 'recipient@example.test', now());

INSERT INTO public.profiles (id, moderation_status) VALUES
  ('00000000-0000-0000-0000-000000000001', 'approved'),
  ('00000000-0000-0000-0000-000000000002', 'approved'),
  ('00000000-0000-0000-0000-000000000003', 'approved');

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
);

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

  IF (SELECT quantity FROM private.member_gift_inventory
      WHERE user_id = '00000000-0000-0000-0000-000000000002'
        AND gift_id = gift_row.gift_id) <> 0 THEN
    RAISE EXCEPTION 'Gift inventory quantity was not decremented';
  END IF;
END;
$$;

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
  IF (SELECT count(*) FROM private.gift_transactions) <> 1
     OR (SELECT count(*) FROM private.referral_rewards) <> 1 THEN
    RAISE EXCEPTION 'Idempotent retry created duplicate financial records';
  END IF;

  IF has_function_privilege('anon', 'public.send_gift(uuid,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Anonymous role can execute send_gift';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.send_gift(uuid,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Authenticated role cannot execute send_gift';
  END IF;

  IF has_function_privilege('authenticated', 'private.settle_gift(uuid,uuid,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Authenticated role can execute the private settlement function';
  END IF;

  IF has_table_privilege('authenticated', 'private.wallet_ledger_entries', 'SELECT')
     OR has_table_privilege('authenticated', 'private.wallet_ledger_entries', 'INSERT') THEN
    RAISE EXCEPTION 'Authenticated role has direct ledger table access';
  END IF;
END;
$$;

SELECT 'BLC PostgreSQL integration tests passed' AS result;
