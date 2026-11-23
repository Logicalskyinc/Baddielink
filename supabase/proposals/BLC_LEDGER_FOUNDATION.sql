-- BaddieLink BLC ledger foundation
-- REVIEW PROPOSAL ONLY. This file is intentionally outside supabase/migrations.
-- Do not execute against production. Promote to a timestamped migration only
-- after CLI-generated migration workflow, peer review, and isolated testing.

BEGIN;

CREATE SCHEMA IF NOT EXISTS private;

CREATE TABLE private.wallet_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  account_code text NOT NULL,
  account_kind text NOT NULL CHECK (account_kind IN (
    'purchased_blc',
    'referral_blc',
    'recipient_earnings_xof',
    'platform_blc_issuance',
    'platform_xof_gift_clearing',
    'platform_xof_revenue',
    'platform_xof_referral_funding'
  )),
  unit text NOT NULL CHECK (unit IN ('BLC', 'XOF')),
  is_system boolean NOT NULL DEFAULT false,
  is_frozen boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wallet_accounts_system_owner_check CHECK (
    (is_system AND owner_user_id IS NULL)
    OR (NOT is_system AND owner_user_id IS NOT NULL)
  ),
  CONSTRAINT wallet_accounts_kind_unit_check CHECK (
    (account_kind IN ('purchased_blc', 'referral_blc', 'platform_blc_issuance') AND unit = 'BLC')
    OR (account_kind IN (
      'recipient_earnings_xof',
      'platform_xof_gift_clearing',
      'platform_xof_revenue',
      'platform_xof_referral_funding'
    ) AND unit = 'XOF')
  ),
  CONSTRAINT wallet_accounts_id_unit_unique UNIQUE (id, unit),
  CONSTRAINT wallet_accounts_code_unique UNIQUE (account_code)
);

CREATE UNIQUE INDEX wallet_accounts_member_kind_unique
  ON private.wallet_accounts(owner_user_id, account_kind)
  WHERE owner_user_id IS NOT NULL;

CREATE UNIQUE INDEX wallet_accounts_system_kind_unique
  ON private.wallet_accounts(account_kind)
  WHERE is_system;

CREATE TABLE private.wallet_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_type text NOT NULL CHECK (transaction_type IN (
    'purchase_credit',
    'gift_settlement',
    'referral_reward',
    'refund',
    'chargeback',
    'manual_adjustment',
    'payout'
  )),
  idempotency_key text NOT NULL,
  actor_user_id uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  related_reference text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_posted boolean NOT NULL DEFAULT false,
  posted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wallet_transactions_idempotency_unique UNIQUE (idempotency_key),
  CONSTRAINT wallet_transactions_metadata_object CHECK (jsonb_typeof(metadata) = 'object'),
  CONSTRAINT wallet_transactions_posted_timestamp_check CHECK ((is_posted AND posted_at IS NOT NULL) OR (NOT is_posted AND posted_at IS NULL))
);

CREATE TABLE private.wallet_ledger_entries (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_id uuid NOT NULL REFERENCES private.wallet_transactions(id) ON DELETE RESTRICT,
  account_id uuid NOT NULL,
  unit text NOT NULL CHECK (unit IN ('BLC', 'XOF')),
  amount bigint NOT NULL CHECK (amount <> 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wallet_ledger_account_unit_fk
    FOREIGN KEY (account_id, unit)
    REFERENCES private.wallet_accounts(id, unit)
    ON DELETE RESTRICT
);

CREATE INDEX wallet_ledger_entries_account_history_idx
  ON private.wallet_ledger_entries(account_id, created_at DESC, id DESC);

CREATE INDEX wallet_ledger_entries_transaction_idx
  ON private.wallet_ledger_entries(transaction_id, unit);

CREATE INDEX wallet_transactions_actor_history_idx
  ON private.wallet_transactions(actor_user_id, created_at DESC);

-- The ledger is append-only. Correct mistakes with compensating transactions.
CREATE OR REPLACE FUNCTION private.reject_wallet_transaction_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Wallet transactions cannot be deleted';
  END IF;

  -- The only permitted update is the deferred transition from draft to posted.
  IF OLD.is_posted
     OR NEW.id IS DISTINCT FROM OLD.id
     OR NEW.transaction_type IS DISTINCT FROM OLD.transaction_type
     OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
     OR NEW.actor_user_id IS DISTINCT FROM OLD.actor_user_id
     OR NEW.related_reference IS DISTINCT FROM OLD.related_reference
     OR NEW.metadata IS DISTINCT FROM OLD.metadata
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.is_posted IS DISTINCT FROM true
     OR NEW.posted_at IS NULL THEN
    RAISE EXCEPTION 'Posted wallet transactions are immutable';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION private.reject_wallet_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  RAISE EXCEPTION 'Wallet ledger records are immutable; post a compensating transaction instead';
END;
$function$;

CREATE OR REPLACE FUNCTION private.assert_wallet_transaction_balanced()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
DECLARE
  target_transaction_id uuid;
  already_posted boolean;
BEGIN
  IF TG_TABLE_NAME = 'wallet_transactions' THEN
    target_transaction_id := NEW.id;
  ELSE
    target_transaction_id := NEW.transaction_id;
  END IF;

  SELECT t.is_posted
    INTO already_posted
  FROM private.wallet_transactions t
  WHERE t.id = target_transaction_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Wallet transaction % does not exist', target_transaction_id;
  END IF;

  -- Multiple deferred constraint triggers may fire for one transaction.
  IF already_posted THEN
    RETURN NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM private.wallet_ledger_entries e
    WHERE e.transaction_id = target_transaction_id
  ) THEN
    RAISE EXCEPTION 'Wallet transaction % has no ledger entries', target_transaction_id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM private.wallet_ledger_entries e
    WHERE e.transaction_id = target_transaction_id
    GROUP BY e.unit
    HAVING sum(e.amount) <> 0
  ) THEN
    RAISE EXCEPTION 'Wallet transaction % is not balanced per unit', target_transaction_id;
  END IF;

  UPDATE private.wallet_transactions
  SET is_posted = true, posted_at = now()
  WHERE id = target_transaction_id;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION private.require_draft_wallet_transaction()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
DECLARE
  parent_is_posted boolean;
BEGIN
  SELECT t.is_posted
    INTO parent_is_posted
  FROM private.wallet_transactions t
  WHERE t.id = NEW.transaction_id
  FOR UPDATE;

  IF NOT FOUND OR parent_is_posted THEN
    RAISE EXCEPTION 'Ledger entries can only be added to an existing draft transaction';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER wallet_transactions_immutable
  BEFORE UPDATE OR DELETE ON private.wallet_transactions
  FOR EACH ROW EXECUTE FUNCTION private.reject_wallet_transaction_mutation();

CREATE TRIGGER wallet_ledger_entries_immutable
  BEFORE UPDATE OR DELETE ON private.wallet_ledger_entries
  FOR EACH ROW EXECUTE FUNCTION private.reject_wallet_ledger_mutation();

CREATE TRIGGER wallet_ledger_entries_require_draft
  BEFORE INSERT ON private.wallet_ledger_entries
  FOR EACH ROW EXECUTE FUNCTION private.require_draft_wallet_transaction();

-- A deferred check posts the transaction only after all journal entries exist.
-- Once posted, new entries and all changes/deletes are rejected.
CREATE CONSTRAINT TRIGGER wallet_transaction_balance_on_create
  AFTER INSERT ON private.wallet_transactions
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION private.assert_wallet_transaction_balanced();

CREATE CONSTRAINT TRIGGER wallet_transaction_balance_on_entry
  AFTER INSERT ON private.wallet_ledger_entries
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION private.assert_wallet_transaction_balanced();

-- System accounts are stable by account_code and can be seeded idempotently.
INSERT INTO private.wallet_accounts (account_code, account_kind, unit, is_system)
VALUES
  ('system:blc-issuance', 'platform_blc_issuance', 'BLC', true),
  ('system:xof-gift-clearing', 'platform_xof_gift_clearing', 'XOF', true),
  ('system:xof-platform-revenue', 'platform_xof_revenue', 'XOF', true),
  ('system:xof-referral-funding', 'platform_xof_referral_funding', 'XOF', true)
ON CONFLICT (account_code) DO NOTHING;

-- Private financial records are not exposed through the client Data API.
-- No anon/authenticated table grants are created. No browser mutation path exists.
ALTER TABLE private.wallet_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.wallet_ledger_entries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
  private.wallet_accounts,
  private.wallet_transactions,
  private.wallet_ledger_entries
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.reject_wallet_transaction_mutation() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.reject_wallet_ledger_mutation() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.assert_wallet_transaction_balanced() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.require_draft_wallet_transaction() FROM PUBLIC, anon, authenticated;

COMMIT;
