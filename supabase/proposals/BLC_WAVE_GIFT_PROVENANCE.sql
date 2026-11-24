-- BLC Wave purchased-funding provenance into gift inventory.
-- REVIEW PROPOSAL ONLY. Apply after BLC_WAVE_TOPUP_SCHEMA.sql and
-- BLC_REFERRAL_PROVENANCE.sql in isolated PostgreSQL CI.
-- No provider checkout, webhook, wallet credit, refund or production operation
-- is implemented by this file.

BEGIN;

ALTER TABLE private.gift_inventory_funding_lots
  ADD CONSTRAINT gift_inventory_funding_lots_source_identity_unique
  UNIQUE (id, purchase_id, user_id);

CREATE TABLE private.gift_inventory_topup_funding_lots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  gift_inventory_funding_lot_id uuid NOT NULL,
  inventory_purchase_id uuid NOT NULL,
  topup_funding_lot_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  wallet_transaction_id uuid NOT NULL,
  original_purchased_blc bigint NOT NULL CHECK (original_purchased_blc > 0),
  remaining_purchased_blc bigint NOT NULL CHECK (remaining_purchased_blc >= 0),
  consumed_purchased_blc bigint NOT NULL CHECK (consumed_purchased_blc >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT gift_inventory_topup_funding_amounts_reconcile
    CHECK (remaining_purchased_blc + consumed_purchased_blc = original_purchased_blc),
  CONSTRAINT gift_inventory_topup_funding_inventory_identity_fk
    FOREIGN KEY (gift_inventory_funding_lot_id, inventory_purchase_id, user_id)
    REFERENCES private.gift_inventory_funding_lots(id, purchase_id, user_id)
    ON DELETE RESTRICT,
  CONSTRAINT gift_inventory_topup_funding_topup_identity_fk
    FOREIGN KEY (topup_funding_lot_id, user_id)
    REFERENCES private.blc_topup_funding_lots(id, user_id)
    ON DELETE RESTRICT,
  CONSTRAINT gift_inventory_topup_funding_purchase_identity_fk
    FOREIGN KEY (inventory_purchase_id, user_id, wallet_transaction_id)
    REFERENCES private.gift_inventory_purchases(id, buyer_user_id, wallet_transaction_id)
    ON DELETE RESTRICT,
  CONSTRAINT gift_inventory_topup_funding_source_unique
    UNIQUE (gift_inventory_funding_lot_id, topup_funding_lot_id)
);

CREATE INDEX gift_inventory_topup_funding_fifo_idx
  ON private.gift_inventory_topup_funding_lots(
    gift_inventory_funding_lot_id, created_at, topup_funding_lot_id
  )
  WHERE remaining_purchased_blc > 0;

ALTER TABLE private.gift_inventory_topup_funding_lots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.gift_inventory_topup_funding_lots
  FROM PUBLIC, anon, authenticated;

-- Called by an AFTER INSERT trigger on gift_inventory_purchases. The purchased
-- debit is read from the transaction's own journal, never supplied by a client.
-- Top-up lots are locked in FIFO order and decremented in the same transaction
-- as the inventory purchase and its wallet journal.
CREATE OR REPLACE FUNCTION private.allocate_topup_lots_for_inventory_purchase()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  purchased_account_id uuid;
  purchased_debit bigint;
  unallocated bigint;
  lot_row record;
  allocation_amount bigint;
  allocation_sequence integer := 0;
BEGIN
  SELECT id INTO purchased_account_id
  FROM private.wallet_accounts
  WHERE owner_user_id = NEW.buyer_user_id
    AND account_kind = 'purchased_blc'
    AND unit = 'BLC';

  IF purchased_account_id IS NULL THEN
    RAISE EXCEPTION 'Purchased BLC wallet is missing for inventory purchase';
  END IF;

  SELECT coalesce(-sum(e.amount), 0)
    INTO purchased_debit
  FROM private.wallet_ledger_entries e
  WHERE e.transaction_id = NEW.wallet_transaction_id
    AND e.account_id = purchased_account_id
    AND e.unit = 'BLC'
    AND e.amount < 0;

  IF purchased_debit < 0 THEN
    RAISE EXCEPTION 'Purchased BLC inventory debit is invalid';
  END IF;

  IF purchased_debit = 0 THEN
    RETURN NEW;
  END IF;

  unallocated := purchased_debit;

  FOR lot_row IN
    SELECT l.id, l.remaining_amount_blc
    FROM private.blc_topup_funding_lots l
    WHERE l.user_id = NEW.buyer_user_id
      AND l.remaining_amount_blc > 0
    ORDER BY l.created_at, l.id
    FOR UPDATE
  LOOP
    EXIT WHEN unallocated = 0;

    allocation_amount := least(unallocated, lot_row.remaining_amount_blc);
    IF allocation_amount <= 0 THEN
      CONTINUE;
    END IF;

    UPDATE private.blc_topup_funding_lots
    SET remaining_amount_blc = remaining_amount_blc - allocation_amount,
        consumed_amount_blc = consumed_amount_blc + allocation_amount
    WHERE id = lot_row.id
      AND user_id = NEW.buyer_user_id;

    allocation_sequence := allocation_sequence + 1;

    INSERT INTO private.blc_topup_lot_allocations (
      topup_funding_lot_id, user_id, inventory_purchase_id,
      wallet_transaction_id, allocation_amount_blc, allocation_sequence
    )
    VALUES (
      lot_row.id, NEW.buyer_user_id, NEW.id,
      NEW.wallet_transaction_id, allocation_amount, allocation_sequence
    );

    unallocated := unallocated - allocation_amount;
  END LOOP;

  IF unallocated <> 0 THEN
    RAISE EXCEPTION
      'Purchased BLC debit exceeds available top-up funding provenance by % BLC',
      unallocated
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER gift_inventory_purchase_allocate_topup_lots
AFTER INSERT ON private.gift_inventory_purchases
FOR EACH ROW EXECUTE FUNCTION private.allocate_topup_lots_for_inventory_purchase();

REVOKE ALL ON FUNCTION private.allocate_topup_lots_for_inventory_purchase()
FROM PUBLIC, anon, authenticated;

-- Runs after the existing referral-provenance trigger has created the aggregate
-- gift_inventory_funding_lots row. It carries the exact top-up allocations into
-- a source-specific inventory lot, preserving multiple top-ups per purchase.
CREATE OR REPLACE FUNCTION private.record_gift_inventory_topup_sources()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  funding_lot_id uuid;
  aggregate_purchased bigint;
  allocated_purchased bigint;
BEGIN
  SELECT id, purchased_blc_remaining
    INTO funding_lot_id, aggregate_purchased
  FROM private.gift_inventory_funding_lots
  WHERE purchase_id = NEW.id
    AND user_id = NEW.buyer_user_id
    AND gift_id = NEW.gift_id;

  IF funding_lot_id IS NULL THEN
    RAISE EXCEPTION 'Aggregate gift inventory funding lot was not created';
  END IF;

  SELECT coalesce(sum(a.allocation_amount_blc), 0)
    INTO allocated_purchased
  FROM private.blc_topup_lot_allocations a
  WHERE a.inventory_purchase_id = NEW.id
    AND a.user_id = NEW.buyer_user_id
    AND a.wallet_transaction_id = NEW.wallet_transaction_id;

  IF allocated_purchased <> aggregate_purchased THEN
    RAISE EXCEPTION
      'Top-up source allocations (%) do not reconcile with purchased inventory funding (%)',
      allocated_purchased, aggregate_purchased
      USING ERRCODE = '23514';
  END IF;

  INSERT INTO private.gift_inventory_topup_funding_lots (
    gift_inventory_funding_lot_id, inventory_purchase_id,
    topup_funding_lot_id, user_id, wallet_transaction_id,
    original_purchased_blc, remaining_purchased_blc, consumed_purchased_blc
  )
  SELECT
    funding_lot_id, NEW.id, a.topup_funding_lot_id, NEW.buyer_user_id,
    NEW.wallet_transaction_id, a.allocation_amount_blc,
    a.allocation_amount_blc, 0
  FROM private.blc_topup_lot_allocations a
  WHERE a.inventory_purchase_id = NEW.id
    AND a.user_id = NEW.buyer_user_id
    AND a.wallet_transaction_id = NEW.wallet_transaction_id
  ORDER BY a.allocation_sequence;

  RETURN NEW;
END;
$function$;

-- Trigger names determine AFTER INSERT execution order. "zz_" ensures the
-- aggregate funding-lot trigger has completed before source rows are copied.
CREATE TRIGGER zz_gift_inventory_purchase_record_topup_sources
AFTER INSERT ON private.gift_inventory_purchases
FOR EACH ROW EXECUTE FUNCTION private.record_gift_inventory_topup_sources();

REVOKE ALL ON FUNCTION private.record_gift_inventory_topup_sources()
FROM PUBLIC, anon, authenticated;

COMMIT;
