-- BaddieLink recurring referral rewards
-- REVIEW PROPOSAL ONLY. Depends on the BLC ledger and gift settlement proposals.
-- Rewards are deferred until a referred member sends a gift from purchased-BLC-funded inventory.
-- The reward is 5% of the purchased-BLC-funded portion, carved from the 30% commission
-- already earned on that gift. Referral-funded BLC never qualifies.
-- No cash-out, bank payout, or Mobile Money flow is defined here.

BEGIN;

CREATE TABLE private.referral_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE RESTRICT,
  referral_code text NOT NULL UNIQUE,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT referral_codes_id_owner_unique UNIQUE (id, owner_user_id)
);

CREATE TABLE private.referral_attributions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  referred_user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE RESTRICT,
  referral_code_id uuid NOT NULL,
  attributed_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT referral_no_self_referral CHECK (referrer_user_id <> referred_user_id),
  CONSTRAINT referral_attribution_code_owner_fk
    FOREIGN KEY (referral_code_id, referrer_user_id)
    REFERENCES private.referral_codes(id, owner_user_id)
    ON DELETE RESTRICT
);

CREATE INDEX referral_attributions_referrer_idx
  ON private.referral_attributions(referrer_user_id, attributed_at DESC);

CREATE TABLE private.referral_rewards (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referral_attribution_id uuid NOT NULL REFERENCES private.referral_attributions(id) ON DELETE RESTRICT,
  referrer_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  referred_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  gift_transaction_id uuid NOT NULL UNIQUE REFERENCES private.gift_transactions(id) ON DELETE RESTRICT,
  eligible_amount_xof bigint NOT NULL CHECK (eligible_amount_xof > 0),
  reward_amount_blc bigint NOT NULL CHECK (reward_amount_blc > 0),
  wallet_transaction_id uuid NOT NULL UNIQUE REFERENCES private.wallet_transactions(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT referral_reward_identity_check CHECK (referrer_user_id <> referred_user_id)
);

CREATE INDEX referral_rewards_referrer_history_idx
  ON private.referral_rewards(referrer_user_id, created_at DESC);

ALTER TABLE private.referral_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.referral_attributions ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.referral_rewards ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
  private.referral_codes,
  private.referral_attributions,
  private.referral_rewards
FROM PUBLIC, anon, authenticated;


-- A referral code must be active when attribution is created. Lock the code
-- row so concurrent deactivation cannot race attribution creation.
CREATE OR REPLACE FUNCTION private.require_active_referral_code()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
DECLARE
  code_is_active boolean;
BEGIN
  SELECT c.is_active INTO code_is_active
  FROM private.referral_codes c
  WHERE c.id = NEW.referral_code_id
    AND c.owner_user_id = NEW.referrer_user_id
  FOR SHARE;

  IF NOT FOUND OR NOT code_is_active THEN
    RAISE EXCEPTION 'Referral code is invalid or inactive' USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER referral_attributions_require_active_code
  BEFORE INSERT ON private.referral_attributions
  FOR EACH ROW EXECUTE FUNCTION private.require_active_referral_code();

REVOKE ALL ON FUNCTION private.require_active_referral_code() FROM PUBLIC, anon, authenticated;

-- A referral attribution is permanent. Correct fraud through a separate,
-- audited reversal process; never rewrite the original referrer.
CREATE OR REPLACE FUNCTION private.reject_referral_attribution_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  RAISE EXCEPTION 'Referral attribution is immutable';
END;
$function$;

CREATE TRIGGER referral_attributions_immutable
  BEFORE UPDATE OR DELETE ON private.referral_attributions
  FOR EACH ROW EXECUTE FUNCTION private.reject_referral_attribution_mutation();

CREATE OR REPLACE FUNCTION private.reject_referral_reward_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  RAISE EXCEPTION 'Referral reward records are immutable; use a compensating ledger transaction';
END;
$function$;

CREATE TRIGGER referral_rewards_immutable
  BEFORE UPDATE OR DELETE ON private.referral_rewards
  FOR EACH ROW EXECUTE FUNCTION private.reject_referral_reward_mutation();

REVOKE ALL ON FUNCTION private.reject_referral_attribution_mutation() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.reject_referral_reward_mutation() FROM PUBLIC, anon, authenticated;

COMMIT;

-- Required authenticated API work before launch:
-- 1. Generate referral codes server-side with a cryptographically secure random source.
-- 2. Bind attribution only during eligible signup, after validating an active code.
-- 3. Never permit a user to change their referrer after attribution.
-- 4. Prevent self-referral, duplicate attribution, and referral-code owner changes.
-- 5. Only reward a referrer whose account remains email-confirmed, adult-declared,
--    and not restricted/removed at settlement time.
-- 6. Reward calculation is floor(purchased-BLC-funded gift value * 5 / 100) whole BLC.
--    Referral-funded BLC is excluded; values rounding to zero create no reward.
-- 7. Reward posting is atomic with gift settlement: XOF is reclassified from earned
--    platform revenue into referral funding, and BLC is credited to referral_blc.
-- 8. No cash-out or transfer from referral_blc is permitted.
-- 9. Test FIFO provenance, mixed funding, integer remainder allocation, duplicate
--    gift events, concurrent sends, ineligible referrers, rounding and ledger balance.
