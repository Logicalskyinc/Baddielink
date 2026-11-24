-- BaddieLink Wave top-up schema foundation
-- REVIEW PROPOSAL ONLY. Apply after the BLC ledger, gift and referral proposals
-- in isolated PostgreSQL CI. This file defines storage and identity constraints
-- only. It does not create checkout, webhook, wallet-credit, refund or chargeback
-- processing functions. Do not execute against production.

BEGIN;

-- Composite identity keys let foreign keys enforce that a provider operation,
-- top-up, wallet account and inventory purchase all belong to the same member.
ALTER TABLE private.wallet_accounts
  ADD CONSTRAINT wallet_accounts_id_owner_kind_unique
  UNIQUE (id, owner_user_id, account_kind);

ALTER TABLE private.wallet_transactions
  ADD CONSTRAINT wallet_transactions_id_actor_unique
  UNIQUE (id, actor_user_id);

ALTER TABLE private.gift_inventory_purchases
  ADD CONSTRAINT gift_inventory_purchases_wallet_buyer_unique
  UNIQUE (wallet_transaction_id, buyer_user_id);

ALTER TABLE private.gift_inventory_purchases
  ADD CONSTRAINT gift_inventory_purchases_identity_transaction_unique
  UNIQUE (id, buyer_user_id, wallet_transaction_id);

CREATE TABLE private.payment_provider_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_code text NOT NULL CHECK (provider_code IN ('wave')),
  environment text NOT NULL CHECK (environment IN ('sandbox', 'production')),
  provider_account_reference text,
  currency_code text NOT NULL DEFAULT 'XOF' CHECK (currency_code = 'XOF'),
  is_enabled boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (provider_account_reference IS NULL OR length(btrim(provider_account_reference)) > 0)
);

-- Treat NULL account references as one value for uniqueness. A provider account
-- must be explicitly identified before more than one account uses an environment.
CREATE UNIQUE INDEX payment_provider_accounts_identity_unique
  ON private.payment_provider_accounts (
    provider_code,
    environment,
    coalesce(provider_account_reference, '')
  );

CREATE TABLE private.blc_topups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  provider_account_id uuid NOT NULL
    REFERENCES private.payment_provider_accounts(id) ON DELETE RESTRICT,
  currency_code text NOT NULL DEFAULT 'XOF' CHECK (currency_code = 'XOF'),
  amount_xof bigint NOT NULL CHECK (amount_xof > 0),
  amount_blc bigint NOT NULL CHECK (amount_blc > 0),
  conversion_rate_numerator bigint NOT NULL CHECK (conversion_rate_numerator > 0),
  conversion_rate_denominator bigint NOT NULL CHECK (conversion_rate_denominator > 0),
  status text NOT NULL DEFAULT 'created' CHECK (status IN (
    'created', 'checkout_pending', 'payment_pending', 'verified',
    'credited', 'expired', 'failed', 'review_required', 'cancelled'
  )),
  client_reference text NOT NULL UNIQUE
    CHECK (length(btrim(client_reference)) BETWEEN 12 AND 160),
  credit_wallet_transaction_id uuid UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  verified_at timestamptz,
  credited_at timestamptz,
  CONSTRAINT blc_topups_conversion_exact
    CHECK (
      amount_blc::numeric * conversion_rate_denominator::numeric
      = amount_xof::numeric * conversion_rate_numerator::numeric
    ),
  CONSTRAINT blc_topups_credit_timestamp_pair
    CHECK ((credit_wallet_transaction_id IS NULL) = (credited_at IS NULL)),
  CONSTRAINT blc_topups_credited_requires_journal
    CHECK ((status = 'credited') = (credit_wallet_transaction_id IS NOT NULL)),
  CONSTRAINT blc_topups_expiry_after_creation
    CHECK (expires_at IS NULL OR expires_at > created_at),
  CONSTRAINT blc_topups_verification_after_creation
    CHECK (verified_at IS NULL OR verified_at >= created_at),
  CONSTRAINT blc_topups_credit_after_creation
    CHECK (credited_at IS NULL OR credited_at >= created_at),
  CONSTRAINT blc_topups_id_provider_unique UNIQUE (id, provider_account_id),
  CONSTRAINT blc_topups_id_user_unique UNIQUE (id, user_id),
  CONSTRAINT blc_topups_id_user_credit_unique UNIQUE (id, user_id, credit_wallet_transaction_id),
  CONSTRAINT blc_topups_credit_actor_fk
    FOREIGN KEY (credit_wallet_transaction_id, user_id)
    REFERENCES private.wallet_transactions(id, actor_user_id)
    ON DELETE RESTRICT
);

CREATE INDEX blc_topups_user_history_idx
  ON private.blc_topups(user_id, created_at DESC);

CREATE INDEX blc_topups_provider_status_idx
  ON private.blc_topups(provider_account_id, status, created_at);

CREATE TABLE private.provider_payment_references (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  topup_id uuid NOT NULL,
  provider_account_id uuid NOT NULL,
  reference_type text NOT NULL CHECK (reference_type IN ('checkout_session', 'transaction')),
  provider_reference text NOT NULL CHECK (length(btrim(provider_reference)) BETWEEN 1 AND 255),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT provider_payment_references_topup_provider_fk
    FOREIGN KEY (topup_id, provider_account_id)
    REFERENCES private.blc_topups(id, provider_account_id)
    ON DELETE RESTRICT,
  CONSTRAINT provider_payment_references_identity_unique
    UNIQUE (provider_account_id, reference_type, provider_reference)
);

CREATE INDEX provider_payment_references_topup_idx
  ON private.provider_payment_references(topup_id, reference_type);

CREATE TABLE private.provider_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_account_id uuid NOT NULL
    REFERENCES private.payment_provider_accounts(id) ON DELETE RESTRICT,
  provider_event_id text NOT NULL CHECK (length(btrim(provider_event_id)) BETWEEN 1 AND 255),
  event_type text NOT NULL CHECK (length(btrim(event_type)) BETWEEN 1 AND 128),
  provider_reference text,
  topup_id uuid,
  signature_valid boolean NOT NULL,
  signature_timestamp timestamptz,
  payload_sha256 text NOT NULL CHECK (payload_sha256 ~ '^[0-9a-f]{64}$'),
  payload_redacted jsonb,
  processing_status text NOT NULL DEFAULT 'received' CHECK (processing_status IN (
    'received', 'queued', 'processed', 'ignored_duplicate',
    'rejected', 'review_required', 'failed_retryable'
  )),
  processing_attempts integer NOT NULL DEFAULT 0 CHECK (processing_attempts >= 0),
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz,
  last_error_code text CHECK (last_error_code IS NULL OR length(last_error_code) <= 128),
  last_error_at timestamptz,
  CONSTRAINT provider_events_topup_provider_fk
    FOREIGN KEY (topup_id, provider_account_id)
    REFERENCES private.blc_topups(id, provider_account_id)
    ON DELETE RESTRICT,
  CONSTRAINT provider_events_provider_event_unique
    UNIQUE (provider_account_id, provider_event_id),
  CONSTRAINT provider_events_processed_timestamp_check
    CHECK ((processing_status = 'processed') = (processed_at IS NOT NULL)),
  CONSTRAINT provider_events_invalid_signature_not_queued
    CHECK (signature_valid OR processing_status IN ('received', 'rejected'))
);

CREATE INDEX provider_events_pending_idx
  ON private.provider_events(provider_account_id, received_at)
  WHERE processing_status IN ('received', 'queued', 'failed_retryable', 'review_required');

CREATE TABLE private.blc_topup_funding_lots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  topup_id uuid NOT NULL UNIQUE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  wallet_account_id uuid NOT NULL,
  wallet_account_kind text NOT NULL DEFAULT 'purchased_blc'
    CHECK (wallet_account_kind = 'purchased_blc'),
  credit_wallet_transaction_id uuid NOT NULL,
  original_amount_blc bigint NOT NULL CHECK (original_amount_blc > 0),
  remaining_amount_blc bigint NOT NULL CHECK (remaining_amount_blc >= 0),
  consumed_amount_blc bigint NOT NULL CHECK (consumed_amount_blc >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT blc_topup_funding_lots_amounts_reconcile
    CHECK (remaining_amount_blc + consumed_amount_blc = original_amount_blc),
  CONSTRAINT blc_topup_funding_lots_topup_owner_credit_fk
    FOREIGN KEY (topup_id, user_id, credit_wallet_transaction_id)
    REFERENCES private.blc_topups(id, user_id, credit_wallet_transaction_id)
    ON DELETE RESTRICT,
  CONSTRAINT blc_topup_funding_lots_wallet_owner_fk
    FOREIGN KEY (wallet_account_id, user_id, wallet_account_kind)
    REFERENCES private.wallet_accounts(id, owner_user_id, account_kind)
    ON DELETE RESTRICT,
  CONSTRAINT blc_topup_funding_lots_id_user_unique UNIQUE (id, user_id)
);

ALTER TABLE private.blc_topups
  ADD CONSTRAINT blc_topups_id_credit_transaction_unique
  UNIQUE (id, credit_wallet_transaction_id);

ALTER TABLE private.blc_topup_funding_lots
  ADD COLUMN credit_wallet_transaction_id uuid;

ALTER TABLE private.blc_topup_funding_lots
  ALTER COLUMN credit_wallet_transaction_id SET NOT NULL;

ALTER TABLE private.blc_topup_funding_lots
  ADD CONSTRAINT blc_topup_funding_lots_credit_transaction_fk
  FOREIGN KEY (topup_id, credit_wallet_transaction_id)
  REFERENCES private.blc_topups(id, credit_wallet_transaction_id)
  ON DELETE RESTRICT;

CREATE OR REPLACE FUNCTION private.require_credited_topup_funding_lot()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
DECLARE
  topup_row private.blc_topups%ROWTYPE;
BEGIN
  SELECT * INTO topup_row
  FROM private.blc_topups
  WHERE id = NEW.topup_id
    AND user_id = NEW.user_id
  FOR SHARE;

  IF NOT FOUND
     OR topup_row.status <> 'credited'
     OR topup_row.credit_wallet_transaction_id IS DISTINCT FROM NEW.credit_wallet_transaction_id
     OR topup_row.amount_blc IS DISTINCT FROM NEW.original_amount_blc THEN
    RAISE EXCEPTION 'Funding lot must match a credited top-up and its wallet journal'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER blc_topup_funding_lot_requires_credit
  BEFORE INSERT ON private.blc_topup_funding_lots
  FOR EACH ROW EXECUTE FUNCTION private.require_credited_topup_funding_lot();

REVOKE ALL ON FUNCTION private.require_credited_topup_funding_lot()
FROM PUBLIC, anon, authenticated;

CREATE INDEX blc_topup_funding_lots_user_idx
  ON private.blc_topup_funding_lots(user_id, created_at, id)
  WHERE remaining_amount_blc > 0;

-- Immutable allocation facts link purchased BLC consumed by an inventory
-- purchase to the exact top-up lot. Available lot value is derived from
-- original_amount_blc minus the sum of these allocations. A trusted spend
-- function must lock the lot and enforce that aggregate before inserting.
CREATE TABLE private.blc_topup_lot_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  topup_funding_lot_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  inventory_purchase_id uuid NOT NULL,
  wallet_transaction_id uuid NOT NULL,
  allocation_amount_blc bigint NOT NULL CHECK (allocation_amount_blc > 0),
  allocation_sequence integer NOT NULL CHECK (allocation_sequence > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT blc_topup_lot_allocations_lot_owner_fk
    FOREIGN KEY (topup_funding_lot_id, user_id)
    REFERENCES private.blc_topup_funding_lots(id, user_id)
    ON DELETE RESTRICT,
  CONSTRAINT blc_topup_lot_allocations_purchase_identity_fk
    FOREIGN KEY (inventory_purchase_id, user_id, wallet_transaction_id)
    REFERENCES private.gift_inventory_purchases(id, buyer_user_id, wallet_transaction_id)
    ON DELETE RESTRICT,
  CONSTRAINT blc_topup_lot_allocations_wallet_actor_fk
    FOREIGN KEY (wallet_transaction_id, user_id)
    REFERENCES private.wallet_transactions(id, actor_user_id)
    ON DELETE RESTRICT,
  CONSTRAINT blc_topup_lot_allocations_sequence_unique
    UNIQUE (inventory_purchase_id, allocation_sequence)
);

CREATE INDEX blc_topup_lot_allocations_lot_idx
  ON private.blc_topup_lot_allocations(topup_funding_lot_id, created_at, id);

CREATE INDEX blc_topup_lot_allocations_purchase_idx
  ON private.blc_topup_lot_allocations(inventory_purchase_id, allocation_sequence);

-- Allocation facts are append-only. Corrections require a separately designed
-- compensating allocation record, never an UPDATE or DELETE.
CREATE OR REPLACE FUNCTION private.reject_blc_topup_allocation_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  RAISE EXCEPTION 'Top-up source allocations are immutable';
END;
$function$;

CREATE TRIGGER blc_topup_lot_allocations_immutable
  BEFORE UPDATE OR DELETE ON private.blc_topup_lot_allocations
  FOR EACH ROW EXECUTE FUNCTION private.reject_blc_topup_allocation_mutation();

ALTER TABLE private.payment_provider_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.blc_topups ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.provider_payment_references ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.provider_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.blc_topup_funding_lots ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.blc_topup_lot_allocations ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
  private.payment_provider_accounts,
  private.blc_topups,
  private.provider_payment_references,
  private.provider_events,
  private.blc_topup_funding_lots,
  private.blc_topup_lot_allocations
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION private.reject_blc_topup_allocation_mutation()
FROM PUBLIC, anon, authenticated;

COMMIT;
