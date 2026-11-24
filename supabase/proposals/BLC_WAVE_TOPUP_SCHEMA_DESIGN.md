# BLC Wave top-up schema and transaction lifecycle

Status: schema design only. This document is not an executable migration. No payment integration, provider credentials, wallet crediting, production writes, or deployment are authorized.

Candidate provider: Wave Business API, XOF. The internal schema is provider-neutral; Wave-specific identifiers and payloads are stored as provider references.

## 1. Design boundaries

Separate these concerns:
1. Payment intent and provider checkout.
2. Provider event ingestion and verification.
3. Internal top-up approval and purchased-BLC credit.
4. Top-up funding provenance and later spending allocations.
5. Refund/dispute operations and reconciliation.

The provider confirms external money movement. The internal ledger remains the authority for BLC balances. A successful browser redirect is never proof of payment.

Do not add a generic "payment succeeded" endpoint that lets a client credit itself. All wallet credits must be performed by a trusted server-side worker after authoritative provider verification.

## 2. Proposed tables

Names are proposed; final names must be reconciled against the existing schema before SQL is written.

### A. `private.payment_provider_accounts`

One row per provider wallet/environment configuration. No secrets are stored in this table.

Columns:
- `id uuid primary key`
- `provider_code text not null` (initially `wave`)
- `environment text not null` (`sandbox` or `production`)
- `provider_account_reference text null` (non-secret account/wallet identifier)
- `currency_code text not null default 'XOF'`
- `is_enabled boolean not null default false`
- `created_at timestamptz not null`
- `updated_at timestamptz not null`

Constraints:
- Unique (`provider_code`, `environment`, `provider_account_reference`), accounting for nullable references.
- Environment and currency constrained to supported values.
- Enabled state is an operational feature flag, not a substitute for deployment or legal approval.

API keys, request-signing secrets and webhook signing secrets belong in Render secret storage or a dedicated secret manager, never in Postgres rows, migrations, frontend code or logs.

### B. `private.blc_topups`

One internal top-up intent per member-initiated purchase.

Columns:
- `id uuid primary key`
- `user_id uuid not null references auth.users(id)`
- `provider_account_id uuid not null references private.payment_provider_accounts(id)`
- `currency_code text not null` (XOF only in initial launch)
- `amount_xof bigint not null check (amount_xof > 0)`
- `amount_blc bigint not null check (amount_blc > 0)`
- `conversion_rate_numerator bigint not null`
- `conversion_rate_denominator bigint not null`
- `status text not null`: `created`, `checkout_pending`, `payment_pending`, `verified`, `credited`, `expired`, `failed`, `review_required`, `cancelled`
- `client_reference text not null unique` (opaque internal reference, no PII)
- `provider_checkout_id text null`
- `provider_transaction_id text null`
- `credit_wallet_transaction_id uuid null` (unique when non-null)
- `created_at timestamptz not null`
- `expires_at timestamptz null`
- `verified_at timestamptz null`
- `credited_at timestamptz null`

Constraints and invariants:
- Amounts are integer minor units; XOF is represented as whole CFA amounts.
- Initial conversion policy is 1 BLC = 1 XOF, stored explicitly as 1/1 on the top-up. Never recompute historical credit from a mutable global rate.
- The server calculates both amounts. Client input may request a permitted XOF amount but cannot supply the member ID, BLC amount, status, or provider identifiers.
- A top-up can transition to credited once only.
- Unique provider transaction/checkout identity must be scoped by provider account and environment, preferably in a dedicated provider-payment mapping table if a provider can return multiple IDs per payment.
- The user must own the top-up. RLS should expose only their own safe status fields; no direct client INSERT/UPDATE/DELETE.
- The top-up is not spendable until the ledger credit and funding lot are committed atomically.

### C. `private.provider_payment_references`

Maps external provider identifiers to the internal top-up. Keeping this separate avoids nullable provider-ID uniqueness traps and allows multiple external references.

Columns:
- `id uuid primary key`
- `topup_id uuid not null references private.blc_topups(id)`
- `provider_account_id uuid not null references private.payment_provider_accounts(id)`
- `reference_type text not null`: `checkout_session`, `transaction`
- `provider_reference text not null`
- `created_at timestamptz not null`

Constraints:
- Unique (`provider_account_id`, `reference_type`, `provider_reference`).
- A reference cannot be reassigned to another top-up.
- Provider identifiers are opaque text; never parse business meaning from their format.

### D. `private.provider_events`

Immutable record of each accepted or rejected webhook delivery.

Columns:
- `id uuid primary key`
- `provider_account_id uuid not null references private.payment_provider_accounts(id)`
- `provider_event_id text not null`
- `event_type text not null`
- `provider_reference text null`
- `topup_id uuid null references private.blc_topups(id)`
- `signature_valid boolean not null`
- `signature_timestamp timestamptz null`
- `payload_sha256 text not null`
- `payload_redacted jsonb null` (only if retention policy approves)
- `processing_status text not null`: `received`, `queued`, `processed`, `ignored_duplicate`, `rejected`, `review_required`, `failed_retryable`
- `processing_attempts integer not null default 0`
- `received_at timestamptz not null`
- `processed_at timestamptz null`
- `last_error_code text null` (safe code, no secrets or raw payload)
- `last_error_at timestamptz null`

Constraints:
- Unique (`provider_account_id`, `provider_event_id`).
- Signature-invalid events must never be queued for financial processing.
- Preserve a payload digest even when full payload retention is disabled.
- Do not store Authorization headers, signing secrets, full phone numbers, or unnecessary customer data.
- Event rows are append-only except for controlled processing metadata; preserve a separate attempt/audit history if retry detail is required.

### E. `private.blc_topup_funding_lots`

One lot for each successfully credited top-up.

Columns:
- `id uuid primary key`
- `topup_id uuid not null unique references private.blc_topups(id)`
- `user_id uuid not null references auth.users(id)`
- `wallet_account_id uuid not null references private.wallet_accounts(id)`
- `original_amount_blc bigint not null check (original_amount_blc > 0)`
- `remaining_amount_blc bigint not null check (remaining_amount_blc >= 0)`
- `consumed_amount_blc bigint not null check (consumed_amount_blc >= 0)`
- `created_at timestamptz not null`

Invariants:
- `remaining + consumed = original`.
- The lot's user and wallet account owner must match the top-up owner and purchased-BLC account.
- Lot creation and purchased-wallet ledger credit occur in one database transaction.
- No client can create, update or delete lots.
- Do not silently restore a lot after refund; use compensating records and explicit lot adjustment entries.

### F. `private.blc_topup_lot_allocations`

Exact purchased-BLC source allocation when purchased BLC is consumed to buy gift inventory.

Columns:
- `id uuid primary key`
- `topup_funding_lot_id uuid not null references private.blc_topup_funding_lots(id)`
- `inventory_purchase_id uuid not null references private.gift_inventory_purchases(id)`
- `wallet_transaction_id uuid not null references private.wallet_transactions(id)`
- `amount_blc bigint not null check (amount_blc > 0)`
- `allocation_sequence integer not null`
- `created_at timestamptz not null`

Constraints:
- Unique (`inventory_purchase_id`, `allocation_sequence`).
- Composite identity must ensure lot user, inventory buyer and wallet transaction actor are the same member.
- Allocation total for a purchase must equal its purchased-BLC-funded debit, not the combined purchased+referral spend.
- Allocation updates and wallet debits must be atomic.
- Lock lots in deterministic order (created_at, id); do not allocate more than a lot's remaining amount.

### G. Gift inventory source allocations

Extend the current gift inventory funding provenance with child allocations that preserve the source of each inventory value:
- `inventory_purchase_id`
- `topup_funding_lot_id` nullable only for referral-funded source
- `source_kind` constrained to `purchased_topup` or `referral`
- `original_amount_blc`, `remaining_amount_blc`
- `original_quantity`, `remaining_quantity`
- source allocation sequence and timestamps

Use a composite check/FK design so `purchased_topup` requires a top-up lot and `referral` forbids one. Each gift settlement consumes source allocations deterministically and links consumed amounts to the gift transaction. Do not overload the existing aggregate funding-lot row with multiple top-up identities.

## 3. State transitions

### Top-up

`created → checkout_pending → payment_pending → verified → credited`

Terminal or exception paths:
- `created/checkout_pending → expired`
- `payment_pending → failed`
- Any identity, amount, currency, account, or event inconsistency → `review_required`
- A verified provider payment that has not yet been journaled remains `verified`, not credited.

A late success event for an expired top-up must not be discarded or automatically credited. Re-fetch authoritative provider state and route to review/reconciliation.

### Provider event

`received → queued → processed`

Duplicate event ID: acknowledge idempotently, do not create a second financial operation.

Invalid signature: reject and record minimal security metadata; never process.

Out-of-order event: fetch the authoritative checkout/payment state from Wave and reconcile the internal top-up state. Do not let an older failure event overwrite a confirmed success.

## 4. Transaction boundaries

### Create checkout

1. Authenticate member and validate eligibility.
2. Validate allowed amount bounds and integer XOF.
3. Create internal top-up with server-generated client reference and fixed 1/1 conversion snapshot.
4. Commit the intent before calling Wave.
5. Create Wave Checkout session from a server worker using a stable idempotency strategy supported by the provider API; confirm Wave's exact idempotency contract before relying on one.
6. Persist checkout session ID and launch URL. Return only the launch URL and safe expiry/status to the client.
7. If the provider call times out, query/reconcile before creating a second checkout to avoid duplicate payment requests.

Do not hold database locks while calling Wave.

### Receive webhook

1. Enforce HTTPS and body-size limits.
2. Read raw request bytes before JSON parsing.
3. Verify `Wave-Signature` with HMAC-SHA256 using the exact raw body and timestamp; constant-time compare signatures; enforce the documented timestamp window.
4. Insert provider event using unique provider event ID.
5. If duplicate, return success without reprocessing.
6. Queue processing and return HTTP 2xx quickly. Wave documents a 5-second response expectation and retries for up to 3 days if no 2xx is returned.
7. Worker retrieves the authoritative checkout state from Wave where needed, validates provider account, environment, checkout ID, client reference, amount, currency and successful payment status.
8. Lock the internal top-up row and re-check it has not already been credited.
9. In one database transaction, create wallet transaction, balanced BLC/XOF ledger entries, top-up funding lot, and mark top-up credited.
10. Mark provider event processed. Any failure rolls back the financial journal and lot creation; event remains retryable/reviewable.

### Credit posting

A dedicated server-only function should accept only an internal top-up ID and verified provider-operation ID. It must load the amount, user and account identities from persisted rows. It must not accept caller-supplied member ID, BLC amount, ledger account IDs, or source split.

Unique constraints are the final duplicate-credit barrier. Locks are necessary for state transitions but are not a replacement for unique constraints.

## 5. Ledger/accounting decisions still open

Do not write journal SQL until finance/accounting signs off on debit/credit semantics for:
- Wave funds pending/receivable or clearing.
- Purchased-BLC outstanding backing/liability.
- Member purchased-BLC wallet liability.
- Platform revenue and gift inventory conversion.
- Provider fees and settlement variance.
- Refunds and chargeback loss.

The current ledger balances each unit separately. Add explicit cross-currency reconciliation invariants for XOF received, BLC credited, purchased BLC outstanding, and consumed provenance. A matching number in two columns is not a substitute for an accounting policy.

## 6. Security and operational requirements

- Use a Wave API key with least required permissions. Wave states API keys are wallet-bound and can move money or access sensitive data; store them server-side only.
- Enable Wave request signing when creating the API key. Wave documents that signing cannot be disabled for that key; if signing must be stopped, the key must be revoked and replaced.
- Keep API key, request-signing secret and webhook signing secret in server-side secret storage, separated by sandbox/production.
- Use Wave webhook Signing Secret, not the weaker shared-secret bearer strategy, for production.
- Verify signature against raw body. Wave explicitly warns that parsing and reserializing JSON changes whitespace/key order and breaks verification.
- Use event ID for idempotency. Wave documents duplicate, missed and out-of-order webhook delivery; reconcile pending records through Checkout/Balance APIs.
- Webhook endpoint should respond within 5 seconds; persist then enqueue, process asynchronously.
- Reconcile daily against Wave Balance API transaction listings and business-wallet balance.
- Do not rely solely on webhook delivery for reconciliation.
- Do not expose provider credentials to the frontend or ChatGPT. Never ask the user to paste secrets into chat.
- Sandbox and production must use separate provider account references, keys, webhook endpoints/secrets, and test records.

## 7. Required isolated PostgreSQL test plan

1. Member cannot create a top-up for another user.
2. Client cannot set amount_blc, status, credited timestamp, provider transaction ID or wallet transaction ID.
3. Top-up amount is positive integer XOF and conversion snapshot is valid.
4. Duplicate checkout/provider payment references cannot map to multiple top-ups.
5. Duplicate webhook event ID is recorded/acknowledged once.
6. Invalid signature never enters financial processing.
7. Old, future, malformed and mismatched webhook signatures are rejected.
8. Out-of-order failed then completed event converges to authoritative success without duplicate credit.
9. Completed then stale failed event cannot downgrade credited state.
10. Two concurrent workers cannot credit one top-up twice.
11. Wallet credit and funding lot are atomic; injected failure rolls back both.
12. Funding lot owner and purchased-wallet account owner must match top-up owner.
13. Two top-ups for one user remain distinct after wallet pooling.
14. Concurrent inventory purchases cannot overspend a funding lot.
15. Allocation sum equals purchased-BLC debit exactly; referral BLC is never assigned a top-up lot.
16. Gift inventory source allocations reconcile to the existing inventory funding totals.
17. Gift settlement consumes the exact source allocations and cannot reuse an allocation.
18. Provider amount, currency, account, environment or client-reference mismatch routes to review and never credits.
19. Provider timeout during checkout creation reconciles before retry.
20. Daily reconciliation detects missing, duplicate, late, mismatched and uncredited provider operations.

## 8. Wave account onboarding checklist

When the Business Account is created, confirm through the Wave Business Portal or Wave support:
- Business account is registered and active in Côte d'Ivoire.
- XOF Checkout API is enabled for this business wallet.
- Developer section/API access is enabled for an Admin user.
- Sandbox availability and test credentials.
- Production API key permissions can be restricted to required Checkout/Balance operations.
- Request signing can be enabled at key creation.
- Webhook Signing Secret can be created and rotated.
- Fees, settlement timing, limits, refund process, and dispute/chargeback procedures are documented.
- Wave confirms the merchant's permitted use case and any stored-value/virtual-currency requirements.

Do not configure the production API key or webhook secret until the integration has passed isolated tests and separate release approval.

## 9. Official Wave documentation

- Business APIs and key management: https://docs.wave.com/business
- Checkout API: https://docs.wave.com/checkout
- Webhooks and signature verification: https://docs.wave.com/webhook
- Balance and reconciliation API: https://docs.wave.com/balance-api

The public documentation describes checkout completion and payment failure webhook events, but does not establish a complete chargeback/dispute event lifecycle for this merchant use case. Confirm dispute handling directly with Wave before implementing it.

## 10. Release gates

- This document is a design artifact only.
- No SQL migration or application code has been created by this stage.
- No live provider request, credential, webhook registration, or account change has occurred.
- Top-ups, refunds, chargebacks, payouts and cash-out remain disabled.
- Production migration, provider credentials, merge and deployment require separate explicit approval.
