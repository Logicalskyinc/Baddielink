-- BaddieLink recurring referral rewards
-- REVIEW PROPOSAL ONLY. Depends on the BLC ledger and gift settlement proposals.
-- Referral rewards are BLC-only and funded from the existing 30% platform share.
-- For an eligible referred member's gift: recipient 70%, referrer 5%, platform 25%.
-- Without an eligible referrer: recipient 70%, platform 30%.
-- No cash-out, bank payout, or Mobile Money flow is defined here.

BEGIN;

CREATE TABLE private.referral_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE RESTRICT,
  referral_code text NOT NULL UNIQUE,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE private.referral_attributions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referrer_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  referred_user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE RESTRICT,
  referral_code_id uuid NOT NULL REFERENCES private.referral_codes(id) ON DELETE RESTRICT,
  attributed_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT referral_no_self_referral CHECK (referrer_user_id <> referred_user_id)
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
-- 6. Reward calculation is floor(eligible gift face value * 5 / 100) whole BLC.
--    Values that round to zero produce no reward; platform retains that remainder.
-- 7. Every reward must be posted in the same wallet transaction as the eligible
--    gift settlement, with XOF funding moved from platform revenue to referral
--    funding and BLC credited to the referrer's non-withdrawable referral wallet.
-- 8. No cash-out or transfer from referral_blc is permitted.
-- 9. Test duplicate gift events, duplicate signup attribution, race conditions,
--    blocked/self-referrals, ineligible referrers, rounding and ledger balance.
