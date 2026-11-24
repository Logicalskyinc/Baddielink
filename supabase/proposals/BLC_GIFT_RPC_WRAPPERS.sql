-- BaddieLink authenticated gift RPC wrappers
-- REVIEW PROPOSAL ONLY. Depends on BLC_LEDGER_FOUNDATION.sql and
-- BLC_GIFTS_AND_SETTLEMENT.sql. Do not execute against production.
-- These public RPCs never accept a sender/buyer user ID from the client.

BEGIN;

CREATE OR REPLACE FUNCTION public.purchase_gift_inventory(
  p_gift_id uuid,
  p_quantity integer,
  p_idempotency_key text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  caller_id uuid := (SELECT auth.uid());
  caller_email_confirmed boolean;
  caller_status text;
  result_transaction_id uuid;
BEGIN
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '28000';
  END IF;

  IF p_gift_id IS NULL
     OR p_quantity IS NULL
     OR p_quantity < 1 OR p_quantity > 100
     OR p_idempotency_key IS NULL
     OR length(p_idempotency_key) NOT BETWEEN 12 AND 160 THEN
    RAISE EXCEPTION 'Invalid gift inventory purchase request' USING ERRCODE = '22023';
  END IF;

  -- Lock all eligibility records before checking them. FOR SHARE blocks
  -- concurrent moderation, email-confirmation, and age-declaration updates
  -- until this purchase transaction commits. User-ID ordering is consistent
  -- with the send path and avoids cross-user lock-order cycles.
  PERFORM 1
  FROM auth.users u
  JOIN public.profiles p ON p.id = u.id
  JOIN public.user_private_settings ups ON ups.user_id = u.id
  WHERE u.id = caller_id
  ORDER BY u.id
  FOR SHARE OF u, p, ups;

  SELECT u.email_confirmed_at IS NOT NULL, p.moderation_status
    INTO caller_email_confirmed, caller_status
  FROM auth.users u
  JOIN public.profiles p ON p.id = u.id
  WHERE u.id = caller_id;

  IF NOT FOUND
     OR NOT caller_email_confirmed
     OR caller_status IN ('restricted', 'removed')
     OR NOT private.is_adult_declared(caller_id) THEN
    RAISE EXCEPTION 'Account is not eligible to purchase gifts' USING ERRCODE = '42501';
  END IF;

  result_transaction_id := private.purchase_gift_inventory(
    caller_id, p_gift_id, p_quantity, p_idempotency_key
  );

  RETURN result_transaction_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.send_gift(
  p_recipient_user_id uuid,
  p_gift_id uuid,
  p_idempotency_key text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  caller_id uuid := (SELECT auth.uid());
  sender_email_confirmed boolean;
  sender_status text;
  recipient_email_confirmed boolean;
  recipient_status text;
  sender_referrer_id uuid;
  result_transaction_id uuid;
BEGIN
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '28000';
  END IF;

  IF p_recipient_user_id IS NULL
     OR p_gift_id IS NULL
     OR p_idempotency_key IS NULL
     OR length(p_idempotency_key) NOT BETWEEN 12 AND 160
     OR p_recipient_user_id = caller_id THEN
    RAISE EXCEPTION 'Invalid gift request' USING ERRCODE = '22023';
  END IF;

  -- Resolve the sender's immutable referral attribution before locking.
  -- Include the referrer in the same ordered lock set: the provenance trigger
  -- locks this member's eligibility records after inventory-lot locking.
  -- Acquiring all participants up front prevents referral-cycle deadlocks
  -- (for example, A refers B while B refers A and both send concurrently).
  SELECT a.referrer_user_id
    INTO sender_referrer_id
  FROM private.referral_attributions a
  WHERE a.referred_user_id = caller_id;

  -- Lock sender, recipient and referrer eligibility records in deterministic
  -- UUID order. FOR SHARE blocks concurrent updates until this gift commits.
  PERFORM 1
  FROM auth.users u
  JOIN public.profiles p ON p.id = u.id
  JOIN public.user_private_settings ups ON ups.user_id = u.id
  WHERE u.id IN (caller_id, p_recipient_user_id, sender_referrer_id)
  ORDER BY u.id
  FOR SHARE OF u, p, ups;

  SELECT u.email_confirmed_at IS NOT NULL, p.moderation_status
    INTO sender_email_confirmed, sender_status
  FROM auth.users u
  JOIN public.profiles p ON p.id = u.id
  WHERE u.id = caller_id;

  IF NOT FOUND
     OR NOT sender_email_confirmed
     OR sender_status IN ('restricted', 'removed')
     OR NOT private.is_adult_declared(caller_id) THEN
    RAISE EXCEPTION 'Sender account is not eligible to send gifts' USING ERRCODE = '42501';
  END IF;

  SELECT u.email_confirmed_at IS NOT NULL, p.moderation_status
    INTO recipient_email_confirmed, recipient_status
  FROM auth.users u
  JOIN public.profiles p ON p.id = u.id
  WHERE u.id = p_recipient_user_id;

  IF NOT FOUND
     OR NOT recipient_email_confirmed
     OR recipient_status IN ('restricted', 'removed')
     OR NOT private.is_adult_declared(p_recipient_user_id) THEN
    RAISE EXCEPTION 'Recipient account is not eligible to receive gifts' USING ERRCODE = '42501';
  END IF;

  -- Existing helper checks blocks in both directions relative to auth.uid().
  IF private.is_blocked_with(p_recipient_user_id) THEN
    RAISE EXCEPTION 'Gift cannot be sent to this member' USING ERRCODE = '42501';
  END IF;

  result_transaction_id := private.settle_gift(
    caller_id, p_recipient_user_id, p_gift_id, p_idempotency_key
  );

  RETURN result_transaction_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.purchase_gift_inventory(uuid, integer, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.send_gift(uuid, uuid, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.purchase_gift_inventory(uuid, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_gift(uuid, uuid, text) TO authenticated;

COMMIT;

-- Before promotion, verify:
-- - authenticated cannot call the private functions directly;
-- - anon cannot execute either public RPC;
-- - sender identity always comes from auth.uid();
-- - recipient eligibility and mutual block checks are enforced;
-- - insufficient inventory, frozen wallet, or any ledger failure rolls back
--   the entire send operation;
-- - duplicate idempotency requests return the original transaction only when
--   the original operation parameters match;
-- - test email-unconfirmed, under-18, restricted, removed, missing-profile,
--   self-gift, blocked-in-either-direction and valid-member cases.
