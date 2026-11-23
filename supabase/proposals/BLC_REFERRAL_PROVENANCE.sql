-- BaddieLink deferred referral reward funding provenance
-- REVIEW PROPOSAL ONLY. Apply after BLC_LEDGER_FOUNDATION.sql,
-- BLC_GIFTS_AND_SETTLEMENT.sql and BLC_REFERRAL_REWARDS.sql.
-- Never execute against production until isolated PostgreSQL tests pass.
--
-- A referral reward is earned only when a referred member sends a gift from
-- inventory whose original purchase was funded by verified purchased BLC.
-- Referral-funded BLC is explicitly excluded. Rewards are reclassified from
-- the platform's already-earned 30% gift commission (5% to referrer, 25% retained).

BEGIN;

CREATE TABLE private.gift_inventory_funding_lots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_id uuid NOT NULL UNIQUE
    REFERENCES private.gift_inventory_purchases(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  gift_id uuid NOT NULL REFERENCES private.gift_catalog(id) ON DELETE RESTRICT,
  quantity_remaining integer NOT NULL CHECK (quantity_remaining >= 0),
  purchased_blc_remaining bigint NOT NULL CHECK (purchased_blc_remaining >= 0),
  referral_blc_remaining bigint NOT NULL CHECK (referral_blc_remaining >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT gift_inventory_funding_lot_empty_check
    CHECK (quantity_remaining > 0 OR (purchased_blc_remaining = 0 AND referral_blc_remaining = 0))
);

CREATE INDEX gift_inventory_funding_lots_fifo_idx
  ON private.gift_inventory_funding_lots(user_id, gift_id, created_at, id)
  WHERE quantity_remaining > 0;

ALTER TABLE private.gift_inventory_funding_lots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.gift_inventory_funding_lots
  FROM PUBLIC, anon, authenticated;

-- Capture exact BLC source amounts from the posted purchase's own ledger
-- entries. This avoids trusting caller-supplied funding composition.
CREATE OR REPLACE FUNCTION private.record_gift_inventory_funding_lot()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  purchased_amount bigint;
  referral_amount bigint;
  buyer_purchased_account uuid;
  buyer_referral_account uuid;
BEGIN
  SELECT id INTO buyer_purchased_account
  FROM private.wallet_accounts
  WHERE owner_user_id = NEW.buyer_user_id
    AND account_kind = 'purchased_blc' AND unit = 'BLC';

  SELECT id INTO buyer_referral_account
  FROM private.wallet_accounts
  WHERE owner_user_id = NEW.buyer_user_id
    AND account_kind = 'referral_blc' AND unit = 'BLC';

  SELECT coalesce(-sum(e.amount) FILTER (WHERE e.account_id = buyer_purchased_account), 0),
         coalesce(-sum(e.amount) FILTER (WHERE e.account_id = buyer_referral_account), 0)
    INTO purchased_amount, referral_amount
  FROM private.wallet_ledger_entries e
  WHERE e.transaction_id = NEW.wallet_transaction_id
    AND e.unit = 'BLC';

  IF purchased_amount + referral_amount <> NEW.unit_price_blc * NEW.quantity THEN
    RAISE EXCEPTION 'Gift inventory purchase funding does not reconcile';
  END IF;

  INSERT INTO private.gift_inventory_funding_lots (
    purchase_id, user_id, gift_id, quantity_remaining,
    purchased_blc_remaining, referral_blc_remaining
  )
  VALUES (
    NEW.id, NEW.buyer_user_id, NEW.gift_id, NEW.quantity,
    purchased_amount, referral_amount
  );

  RETURN NEW;
END;
$function$;

CREATE TRIGGER gift_inventory_purchase_record_funding
AFTER INSERT ON private.gift_inventory_purchases
FOR EACH ROW EXECUTE FUNCTION private.record_gift_inventory_funding_lot();

-- Runs in the same transaction as gift settlement. It consumes one FIFO
-- inventory unit, calculates the top-up-funded portion, and adds balanced
-- XOF/BLC entries to the still-draft gift wallet transaction before commit.
CREATE OR REPLACE FUNCTION private.apply_deferred_referral_reward()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  gift_price bigint;
  lot_id uuid;
  lot_quantity integer;
  purchased_remaining bigint;
  referral_remaining bigint;
  purchased_unit bigint;
  referral_unit bigint;
  eligible_xof bigint;
  attribution_id uuid;
  referrer_id uuid;
  reward_blc bigint;
  referrer_wallet_id uuid;
  platform_revenue_id uuid;
  referral_funding_id uuid;
  issuance_id uuid;
BEGIN
  SELECT price_blc INTO gift_price
  FROM private.gift_catalog
  WHERE id = NEW.gift_id;

  SELECT id, quantity_remaining, purchased_blc_remaining, referral_blc_remaining
    INTO lot_id, lot_quantity, purchased_remaining, referral_remaining
  FROM private.gift_inventory_funding_lots
  WHERE user_id = NEW.sender_user_id
    AND gift_id = NEW.gift_id
    AND quantity_remaining > 0
  ORDER BY created_at, id
  LIMIT 1
  FOR UPDATE;

  IF lot_id IS NULL OR lot_quantity < 1 THEN
    RAISE EXCEPTION 'Gift inventory funding provenance is missing';
  END IF;

  IF lot_quantity = 1 THEN
    purchased_unit := purchased_remaining;
    referral_unit := referral_remaining;
  ELSE
    purchased_unit := floor(purchased_remaining::numeric / lot_quantity)::bigint;
    referral_unit := gift_price - purchased_unit;
  END IF;

  IF purchased_unit < 0 OR referral_unit < 0
     OR purchased_unit + referral_unit <> gift_price
     OR purchased_unit > purchased_remaining
     OR referral_unit > referral_remaining THEN
    RAISE EXCEPTION 'Gift inventory funding lot is inconsistent';
  END IF;

  UPDATE private.gift_inventory_funding_lots
  SET quantity_remaining = quantity_remaining - 1,
      purchased_blc_remaining = purchased_blc_remaining - purchased_unit,
      referral_blc_remaining = referral_blc_remaining - referral_unit
  WHERE id = lot_id;

  eligible_xof := least(NEW.unit_face_value_xof, purchased_unit);

  SELECT a.id, a.referrer_user_id
    INTO attribution_id, referrer_id
  FROM private.referral_attributions a
  JOIN auth.users ru ON ru.id = a.referrer_user_id
  JOIN public.profiles rp ON rp.id = a.referrer_user_id
  WHERE a.referred_user_id = NEW.sender_user_id
    AND ru.email_confirmed_at IS NOT NULL
    AND rp.moderation_status NOT IN ('restricted', 'removed')
    AND private.is_adult_declared(a.referrer_user_id)
  FOR SHARE OF a;

  reward_blc := CASE
    WHEN attribution_id IS NOT NULL
      THEN floor(eligible_xof * 5 / 100.0)::bigint
    ELSE 0
  END;

  IF reward_blc > 0 THEN
    referrer_wallet_id := private.ensure_member_wallet_account(
      referrer_id, 'referral_blc', 'BLC'
    );

    SELECT id INTO platform_revenue_id
    FROM private.wallet_accounts
    WHERE account_code = 'system:xof-platform-revenue';


    SELECT id INTO referral_funding_id
    FROM private.wallet_accounts
    WHERE account_code = 'system:xof-referral-funding';


    SELECT id INTO issuance_id
    FROM private.wallet_accounts
    WHERE account_code = 'system:blc-issuance';


    IF referrer_wallet_id IS NULL OR platform_revenue_id IS NULL
       OR referral_funding_id IS NULL OR issuance_id IS NULL THEN
      RAISE EXCEPTION 'Referral reward ledger accounts are not configured';
    END IF;

    INSERT INTO private.wallet_ledger_entries(transaction_id, account_id, unit, amount)
    VALUES
      (NEW.wallet_transaction_id, platform_revenue_id, 'XOF', -reward_blc),
      (NEW.wallet_transaction_id, referral_funding_id, 'XOF', reward_blc),
      (NEW.wallet_transaction_id, referrer_wallet_id, 'BLC', reward_blc),
      (NEW.wallet_transaction_id, issuance_id, 'BLC', -reward_blc);

    UPDATE private.gift_transactions
    SET referral_share_xof = reward_blc,
        platform_share_xof = platform_share_xof - reward_blc
    WHERE id = NEW.id;

    INSERT INTO private.referral_rewards (
      referral_attribution_id, referrer_user_id, referred_user_id,
      gift_transaction_id, eligible_amount_xof, reward_amount_blc,
      wallet_transaction_id
    )
    VALUES (
      attribution_id, referrer_id, NEW.sender_user_id,
      NEW.id, eligible_xof, reward_blc, NEW.wallet_transaction_id
    );
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER gift_transaction_apply_deferred_referral
AFTER INSERT ON private.gift_transactions
FOR EACH ROW EXECUTE FUNCTION private.apply_deferred_referral_reward();

REVOKE ALL ON FUNCTION private.record_gift_inventory_funding_lot()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.apply_deferred_referral_reward()
  FROM PUBLIC, anon, authenticated;

COMMIT;

-- Locking strategy: the funding-lot row is the serialization point for
-- inventory provenance consumption. Member wallet rows are locked only when
-- debiting spendable balances; credit-only wallet identity lookups and static
-- platform account identity lookups are intentionally unlocked. This avoids
-- cross-path lock inversions while preserving spend and lot serialization.

-- Accounting invariants:
-- 1. Gift inventory funding lots reconcile to the exact BLC debited at purchase.
-- 2. FIFO consumption preserves every purchased/referral-funded BLC unit.
-- 3. Only the purchased-BLC portion can qualify for the recurring referral.
-- 4. The 5% reward is released only on gift send, after 30% platform commission
--    is earned. It is reclassified from platform revenue into referral funding.
-- 5. Referral BLC spending never creates a referral reward.
-- 6. Reward ledger entries share the gift settlement transaction and are atomic.
-- 7. No cash-out, bank payout, or Mobile Money path is introduced.
