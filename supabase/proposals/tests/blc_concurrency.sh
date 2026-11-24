#!/usr/bin/env bash
set -euo pipefail

# Disposable PostgreSQL CI database only. Two independent psql sessions race
# the same spendable balance, then the same final gift inventory unit.

psql -X -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO auth.users (id, email, email_confirmed_at)
VALUES ('00000000-0000-0000-0000-000000000009', 'concurrency-sender@example.test', now());
INSERT INTO public.profiles (id, moderation_status)
VALUES ('00000000-0000-0000-0000-000000000009', 'approved');
INSERT INTO public.user_private_settings (user_id, date_of_birth, age_declaration_at)
VALUES ('00000000-0000-0000-0000-000000000009', DATE '1990-01-01', now());

DO $seed$
DECLARE member_account uuid; issuance_account uuid; tx_id uuid;
BEGIN
  member_account := private.ensure_member_wallet_account(
    '00000000-0000-0000-0000-000000000009', 'purchased_blc', 'BLC');
  SELECT id INTO issuance_account FROM private.wallet_accounts
  WHERE account_code = 'system:blc-issuance';
  INSERT INTO private.wallet_transactions(transaction_type,idempotency_key,actor_user_id)
  VALUES ('purchase_credit','ci-concurrency-credit-007',
          '00000000-0000-0000-0000-000000000009') RETURNING id INTO tx_id;
  INSERT INTO private.wallet_ledger_entries(transaction_id,account_id,unit,amount)
  VALUES (tx_id,member_account,'BLC',100),(tx_id,issuance_account,'BLC',-100);
END;
$seed$;
SQL

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

run_race() {
  local label="$1" sql_one="$2" sql_two="$3"
  psql -X -v ON_ERROR_STOP=1 -c "$sql_one" >"$tmp_dir/$label-1.log" 2>&1 &
  local pid_one=$!
  psql -X -v ON_ERROR_STOP=1 -c "$sql_two" >"$tmp_dir/$label-2.log" 2>&1 &
  local pid_two=$!
  local status_one=0 status_two=0
  set +e
  wait "$pid_one"; status_one=$?
  wait "$pid_two"; status_two=$?
  set -e
  if ! { [[ "$status_one" -eq 0 && "$status_two" -ne 0 ]] || [[ "$status_one" -ne 0 && "$status_two" -eq 0 ]]; }; then
    cat "$tmp_dir/$label-1.log" "$tmp_dir/$label-2.log"
    echo "Expected exactly one successful $label operation; statuses: $status_one, $status_two" >&2
    return 1
  fi
}

purchase_a="BEGIN; SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000009',true); SET LOCAL ROLE authenticated; SELECT public.purchase_gift_inventory('10000000-0000-0000-0000-000000000001',1,'ci-concurrent-purchase-a-007'); RESET ROLE; COMMIT;"
purchase_b="BEGIN; SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000009',true); SET LOCAL ROLE authenticated; SELECT public.purchase_gift_inventory('10000000-0000-0000-0000-000000000001',1,'ci-concurrent-purchase-b-007'); RESET ROLE; COMMIT;"
run_race purchase "$purchase_a" "$purchase_b"

psql -X -v ON_ERROR_STOP=1 <<'SQL'
DO $check_purchase$
DECLARE bal bigint; qty bigint;
BEGIN
  SELECT coalesce(sum(e.amount),0) INTO bal
  FROM private.wallet_ledger_entries e JOIN private.wallet_accounts a ON a.id=e.account_id
  WHERE a.owner_user_id='00000000-0000-0000-0000-000000000009'
    AND a.account_kind='purchased_blc' AND e.unit='BLC';
  SELECT coalesce(sum(quantity),0) INTO qty FROM private.member_gift_inventory
  WHERE user_id='00000000-0000-0000-0000-000000000009'
    AND gift_id='10000000-0000-0000-0000-000000000001';
  IF bal <> 0 OR qty <> 1 THEN
    RAISE EXCEPTION 'Concurrent purchase violated balance/inventory: balance %, quantity %',bal,qty;
  END IF;
END;
$check_purchase$;
SQL

send_a="BEGIN; SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000009',true); SET LOCAL ROLE authenticated; SELECT public.send_gift('00000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','ci-concurrent-send-a-007'); RESET ROLE; COMMIT;"
send_b="BEGIN; SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000009',true); SET LOCAL ROLE authenticated; SELECT public.send_gift('00000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','ci-concurrent-send-b-007'); RESET ROLE; COMMIT;"
run_race send "$send_a" "$send_b"

psql -X -v ON_ERROR_STOP=1 <<'SQL'
DO $check_send$
DECLARE sends bigint; qty bigint; lots bigint;
BEGIN
  SELECT count(*) INTO sends FROM private.gift_transactions
  WHERE sender_user_id='00000000-0000-0000-0000-000000000009';
  SELECT coalesce(sum(quantity),0) INTO qty FROM private.member_gift_inventory
  WHERE user_id='00000000-0000-0000-0000-000000000009'
    AND gift_id='10000000-0000-0000-0000-000000000001';
  SELECT coalesce(sum(quantity_remaining),0) INTO lots FROM private.gift_inventory_funding_lots
  WHERE user_id='00000000-0000-0000-0000-000000000009'
    AND gift_id='10000000-0000-0000-0000-000000000001';
  IF sends <> 1 OR qty <> 0 OR lots <> 0 THEN
    RAISE EXCEPTION 'Concurrent send violated inventory/provenance: sends %, quantity %, lot units %',sends,qty,lots;
  END IF;
END;
$check_send$;
SELECT 'BLC concurrent purchase and send tests passed' AS result;
SQL
