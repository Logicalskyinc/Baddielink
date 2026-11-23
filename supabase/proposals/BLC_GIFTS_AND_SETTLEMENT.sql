-- BaddieLink gift catalog, inventory and atomic settlement
-- REVIEW PROPOSAL ONLY. Depends on supabase/proposals/BLC_LEDGER_FOUNDATION.sql.
-- Intentionally outside supabase/migrations. Do not execute against production.
-- All money and credits are integer minor units (XOF and whole BLC).

BEGIN;

-- Inventory backing uses the platform_xof_gift_inventory_liability system account
-- seeded by the companion ledger foundation proposal.

CREATE TABLE private.gift_catalog (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  gift_code text NOT NULL UNIQUE,
  display_name text NOT NULL,
  description text,
  price_blc bigint NOT NULL CHECK (price_blc > 0),
  face_value_xof bigint NOT NULL CHECK (face_value_xof > 0),
  asset_key text NOT NULL,
  is_active boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT gift_catalog_value_parity CHECK (price_blc = face_value_xof)
);

CREATE TABLE private.member_gift_inventory (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  gift_id uuid NOT NULL REFERENCES private.gift_catalog(id) ON DELETE RESTRICT,
  quantity bigint NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, gift_id)
);

CREATE TABLE private.gift_inventory_purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  buyer_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  gift_id uuid NOT NULL REFERENCES private.gift_catalog(id) ON DELETE RESTRICT,
  quantity integer NOT NULL CHECK (quantity BETWEEN 1 AND 100),
  unit_price_blc bigint NOT NULL CHECK (unit_price_blc > 0),
  unit_face_value_xof bigint NOT NULL CHECK (unit_face_value_xof > 0),
  wallet_transaction_id uuid NOT NULL UNIQUE REFERENCES private.wallet_transactions(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE private.gift_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  recipient_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  gift_id uuid NOT NULL REFERENCES private.gift_catalog(id) ON DELETE RESTRICT,
  quantity integer NOT NULL DEFAULT 1 CHECK (quantity = 1),
  unit_face_value_xof bigint NOT NULL CHECK (unit_face_value_xof > 0),
  recipient_share_xof bigint NOT NULL CHECK (recipient_share_xof > 0),
  platform_share_xof bigint NOT NULL CHECK (platform_share_xof >= 0),
  wallet_transaction_id uuid NOT NULL UNIQUE REFERENCES private.wallet_transactions(id) ON DELETE RESTRICT,
  idempotency_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT gift_transaction_split_conserves_value
    CHECK (recipient_share_xof + platform_share_xof = unit_face_value_xof),
  CONSTRAINT gift_transaction_not_self_gift CHECK (sender_user_id <> recipient_user_id)
);

CREATE INDEX gift_transactions_recipient_history_idx
  ON private.gift_transactions(recipient_user_id, created_at DESC);

CREATE INDEX gift_transactions_sender_history_idx
  ON private.gift_transactions(sender_user_id, created_at DESC);

ALTER TABLE private.gift_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.member_gift_inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gift_inventory_purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gift_transactions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
  private.gift_catalog,
  private.member_gift_inventory,
  private.gift_inventory_purchases,
  private.gift_transactions
FROM PUBLIC, anon, authenticated;

-- Catalog is managed by trusted backend/admin tooling only.
-- No member-facing direct table mutation is granted.

CREATE OR REPLACE FUNCTION private.ensure_member_wallet_account(
  target_user_id uuid,
  target_account_kind text,
  target_unit text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  result_id uuid;
BEGIN
  INSERT INTO private.wallet_accounts (
    owner_user_id, account_code, account_kind, unit, is_system
  )
  VALUES (
    target_user_id,
    'member:' || target_user_id::text || ':' || target_account_kind,
    target_account_kind,
    target_unit,
    false
  )
  ON CONFLICT (account_code) DO NOTHING;

  SELECT id INTO result_id
  FROM private.wallet_accounts
  WHERE owner_user_id = target_user_id
    AND account_kind = target_account_kind
    AND unit = target_unit
  FOR UPDATE;

  IF result_id IS NULL THEN
    RAISE EXCEPTION 'Unable to resolve member wallet account';
  END IF;

  RETURN result_id;
END;
$function$;

-- This purchase RPC is intentionally backend-only for now. It assumes a
-- verified, posted BLC balance exists in the purchased_blc account. Balance
-- calculation locks the account row to serialize concurrent spending.
CREATE OR REPLACE FUNCTION private.purchase_gift_inventory(
  target_user_id uuid,
  target_gift_id uuid,
  target_quantity integer,
  target_idempotency_key text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  gift_row private.gift_catalog%ROWTYPE;
  purchased_account_id uuid;
  issuance_account_id uuid;
  clearing_account_id uuid;
  inventory_liability_account_id uuid;
  current_balance bigint;
  total_blc bigint;
  total_xof bigint;
  transaction_id uuid;
  existing_transaction_id uuid;
  inventory_row private.member_gift_inventory%ROWTYPE;
BEGIN
  IF target_user_id IS NULL OR target_quantity IS NULL
     OR target_quantity < 1 OR target_quantity > 100
     OR target_idempotency_key IS NULL
     OR length(target_idempotency_key) NOT BETWEEN 12 AND 160 THEN
    RAISE EXCEPTION 'Invalid gift inventory purchase request';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(target_idempotency_key, 0));

  SELECT wallet_transaction_id INTO existing_transaction_id
  FROM private.gift_inventory_purchases
  WHERE buyer_user_id = target_user_id
    AND wallet_transaction_id IN (
      SELECT id FROM private.wallet_transactions
      WHERE idempotency_key = target_idempotency_key
    );

  IF existing_transaction_id IS NOT NULL THEN
    RETURN existing_transaction_id;
  END IF;

  SELECT * INTO gift_row
  FROM private.gift_catalog
  WHERE id = target_gift_id AND is_active
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Gift is unavailable';
  END IF;

  total_blc := gift_row.price_blc * target_quantity;
  total_xof := gift_row.face_value_xof * target_quantity;

  SELECT id INTO purchased_account_id
  FROM private.wallet_accounts
  WHERE owner_user_id = target_user_id
    AND account_kind = 'purchased_blc'
    AND unit = 'BLC'
    AND NOT is_frozen
  FOR UPDATE;

  IF purchased_account_id IS NULL THEN
    RAISE EXCEPTION 'Purchased BLC wallet unavailable';
  END IF;

  SELECT coalesce(sum(amount), 0) INTO current_balance
  FROM private.wallet_ledger_entries
  WHERE account_id = purchased_account_id
    AND unit = 'BLC';

  IF current_balance < total_blc THEN
    RAISE EXCEPTION 'Insufficient purchased BLC balance';
  END IF;

  SELECT id INTO issuance_account_id
  FROM private.wallet_accounts
  WHERE account_code = 'system:blc-issuance'
  FOR UPDATE;

  SELECT id INTO clearing_account_id
  FROM private.wallet_accounts
  WHERE account_code = 'system:xof-gift-clearing'
  FOR UPDATE;

  SELECT id INTO inventory_liability_account_id
  FROM private.wallet_accounts
  WHERE account_code = 'system:xof-gift-inventory-liability'
  FOR UPDATE;

  IF issuance_account_id IS NULL OR clearing_account_id IS NULL
     OR inventory_liability_account_id IS NULL THEN
    RAISE EXCEPTION 'Required platform ledger accounts are not configured';
  END IF;

  INSERT INTO private.wallet_transactions (
    transaction_type, idempotency_key, actor_user_id, related_reference, metadata
  )
  VALUES (
    'gift_inventory_purchase', target_idempotency_key, target_user_id,
    target_gift_id::text,
    jsonb_build_object('operation', 'gift_inventory_purchase', 'quantity', target_quantity)
  )
  RETURNING id INTO transaction_id;

  INSERT INTO private.wallet_ledger_entries(transaction_id, account_id, unit, amount)
  VALUES
    (transaction_id, purchased_account_id, 'BLC', -total_blc),
    (transaction_id, issuance_account_id, 'BLC', total_blc),
    (transaction_id, clearing_account_id, 'XOF', -total_xof),
    (transaction_id, inventory_liability_account_id, 'XOF', total_xof);

  INSERT INTO private.gift_inventory_purchases (
    buyer_user_id, gift_id, quantity, unit_price_blc,
    unit_face_value_xof, wallet_transaction_id
  )
  VALUES (
    target_user_id, target_gift_id, target_quantity, gift_row.price_blc,
    gift_row.face_value_xof, transaction_id
  );

  INSERT INTO private.member_gift_inventory(user_id, gift_id, quantity)
  VALUES (target_user_id, target_gift_id, target_quantity)
  ON CONFLICT (user_id, gift_id)
  DO UPDATE SET
    quantity = private.member_gift_inventory.quantity + EXCLUDED.quantity,
    updated_at = now();

  RETURN transaction_id;
END;
$function$;

-- Atomic inventory decrement and 70/30 XOF settlement.
-- The caller-facing wrapper must authenticate auth.uid() and invoke this
-- internal function only with that authenticated sender id.
CREATE OR REPLACE FUNCTION private.settle_gift(
  target_sender_id uuid,
  target_recipient_id uuid,
  target_gift_id uuid,
  target_idempotency_key text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  gift_row private.gift_catalog%ROWTYPE;
  inventory_quantity bigint;
  recipient_account_id uuid;
  revenue_account_id uuid;
  inventory_liability_account_id uuid;
  transaction_id uuid;
  existing_transaction_id uuid;
  recipient_share bigint;
  platform_share bigint;
BEGIN
  IF target_sender_id IS NULL OR target_recipient_id IS NULL
     OR target_sender_id = target_recipient_id
     OR target_idempotency_key IS NULL
     OR length(target_idempotency_key) NOT BETWEEN 12 AND 160 THEN
    RAISE EXCEPTION 'Invalid gift settlement request';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(target_idempotency_key, 0));

  SELECT id INTO existing_transaction_id
  FROM private.wallet_transactions
  WHERE idempotency_key = target_idempotency_key;

  IF existing_transaction_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM private.gift_transactions
      WHERE wallet_transaction_id = existing_transaction_id
        AND sender_user_id = target_sender_id
        AND recipient_user_id = target_recipient_id
        AND gift_id = target_gift_id
    ) THEN
      RETURN existing_transaction_id;
    END IF;
    RAISE EXCEPTION 'Idempotency key already used for another operation';
  END IF;

  SELECT * INTO gift_row
  FROM private.gift_catalog
  WHERE id = target_gift_id AND is_active
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Gift is unavailable';
  END IF;

  SELECT quantity INTO inventory_quantity
  FROM private.member_gift_inventory
  WHERE user_id = target_sender_id AND gift_id = target_gift_id
  FOR UPDATE;

  IF inventory_quantity IS NULL OR inventory_quantity < 1 THEN
    RAISE EXCEPTION 'Gift not present in inventory';
  END IF;

  UPDATE private.member_gift_inventory
  SET quantity = quantity - 1, updated_at = now()
  WHERE user_id = target_sender_id AND gift_id = target_gift_id;

  recipient_share := floor(gift_row.face_value_xof * 70 / 100.0)::bigint;
  platform_share := gift_row.face_value_xof - recipient_share;

  recipient_account_id := private.ensure_member_wallet_account(
    target_recipient_id, 'recipient_earnings_xof', 'XOF'
  );

  SELECT id INTO revenue_account_id
  FROM private.wallet_accounts
  WHERE account_code = 'system:xof-platform-revenue'
  FOR UPDATE;

  SELECT id INTO inventory_liability_account_id
  FROM private.wallet_accounts
  WHERE account_code = 'system:xof-gift-inventory-liability'
  FOR UPDATE;

  IF revenue_account_id IS NULL OR inventory_liability_account_id IS NULL THEN
    RAISE EXCEPTION 'Gift settlement accounts are not configured';
  END IF;

  INSERT INTO private.wallet_transactions (
    transaction_type, idempotency_key, actor_user_id, related_reference, metadata
  )
  VALUES (
    'gift_settlement', target_idempotency_key, target_sender_id,
    target_gift_id::text,
    jsonb_build_object('operation', 'gift_send', 'recipient_user_id', target_recipient_id)
  )
  RETURNING id INTO transaction_id;

  INSERT INTO private.wallet_ledger_entries(transaction_id, account_id, unit, amount)
  VALUES
    (transaction_id, inventory_liability_account_id, 'XOF', -gift_row.face_value_xof),
    (transaction_id, recipient_account_id, 'XOF', recipient_share),
    (transaction_id, revenue_account_id, 'XOF', platform_share);

  INSERT INTO private.gift_transactions (
    sender_user_id, recipient_user_id, gift_id, unit_face_value_xof,
    recipient_share_xof, platform_share_xof, wallet_transaction_id, idempotency_key
  )
  VALUES (
    target_sender_id, target_recipient_id, target_gift_id, gift_row.face_value_xof,
    recipient_share, platform_share, transaction_id, target_idempotency_key
  );

  RETURN transaction_id;
END;
$function$;

REVOKE ALL ON FUNCTION private.ensure_member_wallet_account(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.purchase_gift_inventory(uuid, uuid, integer, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.settle_gift(uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;

COMMIT;

-- Required integration before promotion:
-- 1. Add public SECURITY DEFINER wrappers that derive sender/buyer from auth.uid(),
--    verify email confirmation + adult declaration + non-restricted account,
--    verify recipient eligibility and block state, and grant EXECUTE only to
--    authenticated. Never accept an arbitrary sender id from the browser.
-- 2. Define refund/chargeback treatment for already-sent gifts before payments.
-- 3. Add catalog read API with only active public gift fields.
-- 4. Add concurrency, duplicate-request, insufficient-balance, self-gift,
--    blocked-user, rounding, rollback and ledger-reconciliation tests.
