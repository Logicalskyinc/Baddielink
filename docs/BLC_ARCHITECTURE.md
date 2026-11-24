# BaddieCoins (BLC) Architecture

**Status:** Architecture baseline for implementation review  
**Product:** BaddieLink  
**Market:** Côte d'Ivoire first  
**Currency:** XOF / FCFA  
**Implementation status:** Specification only. No wallet schema, payment integration, ledger mutation, or production database change is included in this document.

## 1. Product and launch constraints

BaddieCoins (BLC) is BaddieLink's internal credit and virtual-gift economy. The system must be server-authoritative and auditable. The browser must never calculate or write authoritative balances.

Approved product rules:

- Conversion reference: **1 FCFA = 1 BLC**.
- Gift split: **70% recipient share / 30% platform share**.
- Referral commission: **5% of the purchased-BLC-funded portion of eligible gift value**, released only when the referred member sends the gift. It is reclassified from the already-earned 30% platform commission; referral-funded BLC does not qualify. For a fully purchased-BLC-funded gift, BaddieLink retains 25% and the referrer receives 5%.
- Referral rewards at initial launch are **BLC-only**. No Mobile Money or bank withdrawal for referral commissions at launch.
- Minimum future CFA earnings withdrawal threshold: **2,500 FCFA**.
- No direct user-to-user BLC transfers.
- Purchased BLC cannot be withdrawn, resold, or exchanged for cash.
- Promotional BLC must be separately classified and must not become cash-withdrawable.
- No real-money payment or payout flow is enabled by this architecture document.

The 70/30 gift split is an accounting rule, not a client-side calculation. The transaction that consumes a gift must record the gross value and both allocations atomically.

## 2. Separate balances by economic purpose

Do not combine these balances into one generic wallet.

### 2.1 Purchased BLC wallet

- Denominated in BLC.
- Credited only after server-side provider verification.
- Cannot be transferred directly to another member.
- Cannot be withdrawn or converted to CFA.
- Refunds and chargebacks must reverse or reserve the corresponding eligible purchased balance through ledger entries, never by silently editing a balance.

### 2.2 Gift inventory

- Each gift type and quantity is tracked individually.
- Gift inventory is not the same as a BLC balance.
- Gift consumption is atomic and cannot result in negative inventory.
- Gift transfers/delivery must be idempotent to prevent duplicate sends after retries.
- Gift catalog pricing and availability are server-controlled.

### 2.3 CFA earnings wallet

- Receives the recipient's 70% share from eligible gifts when the gift transaction is finalized.
- Pending, disputed, reversed, or fraud-reviewed amounts are unavailable for withdrawal.
- The 2,500 FCFA minimum applies to eligible withdrawable earnings, not purchased BLC.
- Payouts remain disabled until a provider, compliance requirements, reconciliation, fraud controls, and explicit launch approval are in place.

### 2.4 Referral rewards

Referral rewards are a separate entitlement/ledger category, not CFA earnings.

- Credit 5% of the purchased-BLC-funded portion of a referred member's gift value in BLC.
- Defer the reward until that member sends the gift and the platform has earned its 30% commission.
- Fund the reward by reclassifying 5% of the eligible portion from platform revenue into referral funding; do not create an unfunded liability at top-up time.
- Track purchased-BLC and referral-BLC provenance through gift inventory purchases and FIFO consumption.
- Referral-funded BLC never generates another referral reward.
- Referral BLC is not cash-withdrawable. Refunds, chargebacks, fraud and reversals require compensating ledger treatment.
- Enforce one eligible referrer per referred account and prevent self-referrals and referral loops.

## 3. Ledger-first accounting

The immutable ledger is the source of truth. Cached wallet totals, if introduced for performance, are derived projections and must be reconcilable from ledger entries.

Minimum ledger properties:

- Unique transaction ID and idempotency key.
- Account/member ID and wallet/category.
- Entry type and signed amount.
- Currency/unit (BLC or XOF).
- Related purchase, gift, referral, refund, chargeback, or payout ID.
- Status and effective timestamp.
- Creation timestamp and trusted actor/source.
- Reversal linkage for compensating entries.

Never update or delete a posted ledger entry. Correct mistakes with compensating entries that reference the original transaction.

All multi-account movements must execute in one database transaction. Lock affected wallet/account rows in a stable order or use equivalent concurrency-safe constraints. Enforce non-negative spendable balances in the database, not only in JavaScript.

## 4. Gift transaction lifecycle

A gift send must be a single server-authoritative operation:

1. Authenticate the sender and verify account eligibility.
2. Validate the gift SKU, current price, recipient eligibility, and inventory.
3. Lock the sender's gift inventory and any affected accounting rows.
4. Consume exactly one or more available gift units.
5. Record the gross gift value.
6. Allocate 70% to the recipient's CFA earnings accounting and 30% to the platform account.
7. Write immutable ledger entries and the gift delivery record.
8. Commit all changes together.

If any step fails, the complete operation rolls back. A repeated request with the same idempotency key returns the original result and must not consume another gift.

The implementation must define rounding for fractional percentages. Use integer minor units (FCFA) and a documented deterministic rounding rule; ensure recipient plus platform allocations always equal the gross amount.

## 5. Payment lifecycle

No provider has been selected or approved in this phase. Keep provider-specific code behind a server-side adapter.

Required lifecycle:

- Create a pending purchase intent with a unique reference.
- Initiate payment through a configured provider only after provider and fee review.
- Verify payment server-to-server using the provider's authoritative API or signed webhook.
- Validate amount, currency, reference, status, and merchant/account identity.
- Process webhooks idempotently and tolerate duplicate/out-of-order delivery.
- Credit purchased BLC only after verified successful payment.
- Reconcile provider settlement against internal purchase and ledger records.
- Handle pending, failed, expired, reversed, refunded, and charged-back states explicitly.

Never trust a browser redirect, client callback, screenshot, or user-supplied payment status as proof of payment. Never expose provider secrets or Supabase service-role credentials in browser code.

## 6. Refunds, chargebacks, fraud, and reversals

- Preserve a complete audit trail for every state transition.
- Prevent spending of pending or disputed credits.
- Apply compensating ledger entries for refunds and chargebacks.
- If purchased credits have already been spent, create a recoverable negative/receivable state or place the account under review according to a documented policy; do not silently erase unrelated earnings.
- Rate-limit purchase, gift, referral, and payout operations.
- Detect self-referrals, multi-account abuse, repeated payment references, gift collusion, and unusual velocity.
- Keep moderation decisions separate from financial ledger history.
- Require privileged server-side authorization and audit records for manual adjustments.

## 7. Security and database requirements

- RLS on every exposed table; private accounting tables should live in a non-exposed schema where appropriate.
- Members may read only their own permitted wallet summaries and transaction history.
- Members cannot insert, update, or delete ledger entries, wallet balances, payment status, referral attribution, or gift accounting directly.
- All mutations go through narrowly scoped server-side functions with explicit authentication, authorization, input validation, and idempotency.
- Use SECURITY DEFINER only when required, with a fixed safe search_path, explicit auth.uid()/role checks, and restricted EXECUTE grants.
- Never trust user-editable metadata for financial authorization.
- Add indexes for member history, transaction references, idempotency keys, provider references, and reconciliation queries.
- Keep internal platform accounts and adjustment capabilities inaccessible to ordinary members.

## 8. Proposed logical entities

These are design entities, **not existing or deployed tables**:

- wallet_accounts: member and platform account identities by wallet type.
- wallet_ledger_entries: immutable debit/credit entries.
- gift_catalog: server-managed gift SKU, price, status and metadata.
- member_gift_inventory: per-member gift SKU quantities.
- gift_transactions: sender, recipient, SKU, quantity, gross value, split, and status.
- payment_intents: pending and verified provider purchase lifecycle.
- payment_events: deduplicated provider webhook/event records.
- referral_attributions: immutable referrer/referred relationship and eligibility state.
- referral_rewards: 5% BLC reward calculation and settlement state.
- payout_requests: future CFA earnings payout requests, disabled until separately approved.
- financial_audit_events: privileged adjustments and operational review records.

Before implementing these entities, inspect the live schema and recover the missing migration history. Reuse or adapt existing tables only after verifying their exact columns, constraints, triggers, and RLS policies. Do not assume any entity above already exists.

## 9. Delivery sequence

1. Recover and reconcile the existing migration history with the live schema.
2. Write and review the complete data model, constraints, ledger posting rules, and RLS matrix.
3. Implement schema and server-side ledger operations in a safe isolated database environment. If no free isolated environment exists, keep database changes as reviewed migration files and do not apply them to the shared production project.
4. Add read-only wallet summary/history queries.
5. Implement gift inventory and atomic gift delivery.
6. Implement immutable referral attribution and BLC-only deferred rewards tied to purchased-BLC-funded gift inventory consumption.
7. Evaluate payment providers and legal/compliance requirements separately.
8. Only after explicit approval, implement real payment/payout integration and controlled launch.

## 10. Acceptance criteria

BLC is not complete when a wallet screen merely renders. Before any real-money launch, tests must cover:

- Concurrent spending and gift sends.
- Duplicate requests and webhook delivery.
- Partial failure and transaction rollback.
- Rounding conservation (recipient + platform = gross).
- Refund and chargeback reversals.
- Referral abuse and eligibility.
- RLS denial of direct client writes.
- Reconciliation of every displayed balance against ledger entries.
- Auditability and operational recovery.

The UI must not display a fabricated balance. Until a real ledger-backed read path exists, show a clear unavailable/coming-soon state instead of a demo amount.
