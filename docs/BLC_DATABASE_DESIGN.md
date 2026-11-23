# BaddieCoins Database Design and Access Matrix

**Status:** Design only; not applied to Supabase.  
**Reviewed against:** Live BaddieLink schema and current RLS catalog (read-only inspection).  
**Target:** Existing repository feature branch `feat/mobile-profile-header-polish`.

## Existing database facts

The live project currently has no BLC wallet, ledger, gift inventory, payment intent, payout, or referral reward tables. Existing tables include profiles, user_private_settings, reputation_profiles, events, reports, spaces, space_memberships, and space_messages.

The live database already has a shared `spaces` model supporting `salon` and `community` types. Do not create a parallel community schema.

The existing schema is protected by RLS. Financial functionality must not weaken existing profile, moderation, event, messaging, or space policies.

## Proposed accounting model

Use a non-exposed `private` schema for authoritative financial records. The browser must not receive write access to financial tables.

### Account classes

1. `purchased_blc`: member purchased credit, non-withdrawable and non-transferable.
2. `gift_inventory`: discrete gift SKU quantities; not a fungible BLC balance.
3. `recipient_earnings_xof`: CFA-denominated eligible gift earnings, subject to holds and future payout eligibility.
4. `referral_blc`: BLC referral rewards, never cash-withdrawable.
5. `platform_revenue_xof`: platform share and accounting counterpart.
6. `platform_referral_funding_xof`: accounting allocation from platform share to referral reward liability. Must not add a second 5% charge to the purchase.

These are logical account classes. Physical schema and posting model must be finalized before migration authoring.

## Proposed entities and invariants

| Entity | Purpose | Required invariants |
|---|---|---|
| wallet_accounts | Account identity and unit/type | Unique owner + account class + unit; platform accounts have no member owner |
| wallet_ledger_entries | Immutable journal | Append-only; signed integer amount; account/unit consistency; transaction and idempotency references |
| gift_catalog | Server-managed gift SKU | Price in integer XOF; active flag; no client-controlled pricing |
| member_gift_inventory | Per-member SKU quantity | Non-negative integer; atomic decrement; unique member + SKU |
| gift_transactions | Gift delivery and split record | Gross equals recipient allocation + platform allocation; one idempotent transaction |
| payment_intents | Provider purchase lifecycle | Unique internal reference; server-verified amount/currency/status |
| payment_events | Provider callback deduplication | Unique provider event ID; signature/verification metadata; replay-safe |
| referral_attributions | Referrer relationship | One immutable eligible referrer per referred account; no self-referral |
| referral_rewards | Reward calculation and settlement | 5% of eligible net purchase value; funded from platform's 30% share |
| payout_requests | Future earnings withdrawal | Disabled until separate provider/compliance approval; minimum 2,500 XOF |
| financial_audit_events | Privileged financial operations | Append-only actor, reason, before/after reference and timestamp |

## Ledger and transaction rules

- Use integer minor units only. Do not use floating point for money or BLC.
- Store unit/currency explicitly on every account and ledger entry.
- A posted ledger entry is never updated or deleted. Corrections use linked compensating entries.
- A posting transaction must write all debits, credits, transaction records, and idempotency result atomically.
- Use database row locks or equivalent concurrency-safe constraints for inventory and spendable balances.
- Use deterministic rounding for the 70/30 split. The two allocations must always sum exactly to the gross value.
- Gift sending must not debit a generic BLC balance unless the member explicitly bought a gift using BLC. Gift inventory and wallet credits remain separate.
- Payment confirmation must be server-to-server verified. Browser redirects and client claims are not proof of payment.
- Duplicate payment events and duplicate gift requests must return the original outcome without duplicate credits or inventory consumption.
- Refunds and chargebacks use compensating entries and preserve the original transaction history.
- No direct member-to-member BLC transfer, no purchased-BLC cash-out, no gift resale, and no referral cash-out at initial launch.

## Access-control matrix

| Actor | Read | Write |
|---|---|---|
| Authenticated member | Own wallet summary, own ledger history, own gift inventory, own gift history, own referral reward history | No direct table writes |
| Gift posting RPC | Minimum required account/inventory state | Atomic gift transaction and ledger postings |
| Payment webhook/service | Relevant payment intent and event | Verified payment state and purchased-credit ledger postings |
| Referral settlement worker | Eligible purchase and attribution state | Referral reward postings funded from platform share |
| Payout service (future) | Eligible earnings and payout state | Payout state and linked ledger postings, only after separate launch approval |
| Admin/moderator | No unrestricted financial write access | No direct balance edits; exceptional adjustment must use dedicated audited RPC and owner-level authorization |
| Anonymous user | Nothing | Nothing |

All exposed read endpoints must enforce owner scoping. The `private` schema must not be added to PostgREST's exposed schemas. Revoke direct INSERT, UPDATE, and DELETE on ledger/accounting tables from `anon` and `authenticated`. Mutations must go through narrow server-side functions with explicit authorization and idempotency.

Any SECURITY DEFINER function must use an empty or fixed safe search_path, schema-qualify referenced objects, verify the caller/role explicitly, and have EXECUTE granted only to the required roles. Do not expose service-role credentials in the browser.

## Integration with existing moderation rules

The existing discovery policies correctly require approved profiles for visibility. Keep that requirement.

The existing event, organizer, and Salon RLS policies also currently require moderation approval for several actions. The approved product policy is broader: an email-confirmed adult member whose account is not restricted/removed may use member features without manual profile approval, while discoverability remains approval-controlled. That policy requires a separate reviewed RLS migration; do not weaken discovery or moderation policies as a side effect of BLC work.

Financial eligibility should require:
- Authenticated account.
- Confirmed email.
- Adult self-declaration recorded in `user_private_settings`.
- Profile exists and is not `restricted` or `removed`.
- No active account-level financial hold or fraud restriction.

The self-declaration timestamp is not formal age verification. Do not label it as identity or age verification.

## Implementation gate

Before creating an executable migration:

1. Recover the missing historical migration SQL or establish a verified baseline from the live catalog.
2. Confirm the current database object definitions, triggers, grants, and relevant function bodies.
3. Finalize the exact account and journal model, including treatment of purchased credits already spent before a refund/chargeback.
4. Write explicit constraints, indexes, grants, RLS policies, and RPC signatures.
5. Add tests for concurrency, idempotency, rollback, rounding conservation, RLS denial, and ledger reconciliation.

No BLC DDL has been applied to the live database. This design document is not a migration and does not create a test environment.
