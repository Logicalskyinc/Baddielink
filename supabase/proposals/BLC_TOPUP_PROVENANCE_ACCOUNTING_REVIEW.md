# BLC purchased-funding provenance and backing review

Status: read-only accounting review and proposed design. No SQL implementation is included. No production changes are authorized.

Reviewed proposal files at PR #11 head `a1867cee8bc9030f486b7790c202cf5f5c620642`:
- `BLC_LEDGER_FOUNDATION.sql`
- `BLC_GIFTS_AND_SETTLEMENT.sql`
- `BLC_GIFT_RPC_WRAPPERS.sql`
- `BLC_REFERRAL_PROVENANCE.sql`

## Executive finding

The current design distinguishes purchased BLC from referral BLC at the member-wallet and gift-inventory-purchase levels. It does not preserve the identity of the original top-up/provider payment that supplied purchased BLC.

Consequently, it can calculate the purchased-funded portion of a gift inventory unit, but cannot reliably attribute that purchased portion to a particular top-up, refund, or chargeback.

The current ledger also has no dedicated purchased-BLC backing/reserve account or provider-settlement reconciliation model. The existing XOF gift-clearing account is used as a balancing account in inventory purchase journals, but it is not linked to a provider payment, settlement batch, or top-up funding record.

This is a release blocker for real-money top-ups and automated refund/chargeback processing. It does not prevent continued isolated testing of the current proposal-only gift/referral functionality.

## Verified current behavior

### 1. Wallet and ledger foundation

The current account kinds include:
- Member: `purchased_blc`, `referral_blc`, `recipient_earnings_xof`.
- System: `platform_blc_issuance`, `platform_xof_gift_clearing`, `platform_xof_revenue`, `platform_xof_referral_funding`, `platform_xof_gift_inventory_liability`.

There is no dedicated account kind for purchased-BLC backing/reserve, provider receivable/settlement, chargeback loss, or provider fees.

The ledger enforces per-currency transaction balance and append-only posted records. That does not itself establish the economic backing of purchased BLC or enforce cross-currency parity. The 1 BLC = 1 XOF policy needs an explicit, auditable accounting bridge.

### 2. Gift inventory purchase

The purchase function:
- Locks the member's purchased and referral wallet accounts in stable ID order.
- Spends referral BLC first, then purchased BLC.
- Debits the member's BLC wallets.
- Posts BLC issuance entries to balance the BLC side.
- Posts XOF entries using the gift-inventory liability, XOF clearing, and referral-funding accounts.
- Creates one gift-inventory purchase record.

The purchase record stores buyer, gift, quantity, unit price, unit face value, and wallet transaction ID. It does not store which top-up lot(s) funded the purchased-BLC portion.

The comment in the SQL explicitly says the purchased wallet remains zero until a separately verified BLC purchase-credit flow exists. No such top-up-credit workflow is included in the reviewed proposal files.

### 3. Gift inventory provenance

The current `gift_inventory_funding_lots` table stores one row per inventory purchase, with:
- Remaining quantity.
- Aggregate purchased-BLC amount remaining.
- Aggregate referral-BLC amount remaining.

Its trigger derives those amounts from the inventory-purchase ledger entries, which is better than trusting client input. The gift-send trigger consumes the lots FIFO and uses the purchased-funded amount to calculate referral eligibility.

However, this is only purchased-versus-referral provenance. It does not identify the original top-up, provider payment, or provider settlement. Once purchased BLC from multiple top-ups is pooled in the member wallet, the current model cannot trace which top-up funded a later inventory purchase.

### 4. Refund and chargeback consequence

The current model cannot calculate, for a particular top-up:
- How much purchased BLC remains in the member wallet.
- How much was converted into unsent gift inventory.
- How much funded gifts that have already been sent.
- How much has already been refunded or charged back.
- Which provider event and compensating journal correspond to that top-up.

A wallet-wide balance alone is not enough. It can be used for a conservative freeze, but not for precise top-up-specific reversal or recovery.

## Recommended architecture before top-ups

### A. Provider payment and top-up records

Introduce a durable top-up/payment domain model, separate from wallet transactions.

At minimum:
- `payment_providers` or a controlled provider identifier.
- `provider_payments`: internal UUID, provider/environment, provider payment ID, member ID, XOF amount, currency, provider status, normalized status, settlement timestamp, and immutable identity.
- `provider_events`: provider event ID, payment ID, event type, signature verification result, received timestamp, provider timestamp, processing status, and payload digest/redacted evidence.
- `blc_topups`: internal top-up UUID, member ID, provider payment reference, normalized XOF amount, BLC amount, status, credit transaction ID, and timestamps.

Required uniqueness:
- Provider + provider account/environment + provider payment ID.
- Provider + provider account/environment + provider event ID.
- One successful BLC credit per internal top-up/provider payment.
- One top-up credit journal per top-up.

Provider events must be verified against the raw request body before being trusted. Persist the event durably and process idempotently. Browser callbacks are not proof of payment.

### B. Purchased-BLC funding lots

Create a top-up funding-lot record when a verified top-up credits purchased BLC.

Each lot should preserve:
- Top-up ID and original wallet-credit transaction ID.
- Member wallet/account ID.
- Original purchased BLC amount.
- Remaining unspent purchased BLC amount.
- Consumed amount.
- Creation time and status.

The top-up lot and member-wallet credit must be created atomically. The top-up record must not be marked credited unless its ledger transaction posts successfully.

### C. Source allocations when purchased BLC is spent

A top-up lot alone is insufficient if the member wallet pools multiple top-ups. Each purchase of gift inventory must persist the exact source allocation of purchased BLC across top-up lots.

Recommended normalized allocation record:
- Inventory-purchase wallet transaction ID.
- Top-up funding-lot ID.
- Purchased BLC amount consumed from that lot.
- Allocation sequence/FIFO order.
- Created timestamp.

Allocate purchased BLC from eligible lots in a deterministic order, such as oldest eligible lot first. Lock funding-lot rows in that same deterministic order. In the same transaction, decrement each lot's remaining amount, debit the purchased wallet, and write allocation rows.

Referral BLC remains a separate source and must never be allocated to a purchased top-up lot.

### D. Propagate top-up provenance into gift inventory

The existing aggregate inventory funding lot should either be extended with child source-allocation rows or replaced with a normalized source-lot model.

A robust model should preserve, for each inventory purchase and each source:
- Original inventory purchase ID.
- Top-up funding-lot ID for purchased BLC, or an explicit referral-funded source.
- Remaining quantity and remaining value attributable to that source.
- Amount consumed when a gift is sent.
- Link to the gift settlement transaction.

Gift sends must consume inventory source allocations deterministically and atomically with inventory decrement and settlement. This provides the chain:

`provider payment → top-up → purchased-BLC credit → wallet spend allocation → inventory source allocation → gift settlement`.

The existing FIFO inventory lot behavior is a useful foundation, but aggregate purchased/referral amounts alone cannot complete this chain.

### E. Backing and reconciliation accounts

Add a documented accounting policy and account model for:
- Provider funds pending/receivable or settlement clearing.
- Purchased-BLC backing/reserve or outstanding purchased-BLC liability.
- Provider fees.
- Chargeback loss or a separately justified receivable.
- Any settlement variance.

Do not simply add account names and assume the accounting is correct. The accountant/finance owner must define debit/credit semantics and journal examples for:
1. Payment authorized but not settled.
2. Payment settled and BLC credited.
3. Purchased BLC spent on gift inventory.
4. Gift inventory converted into a sent gift.
5. Full and partial refund before spending.
6. Refund after partial or complete spending.
7. Chargeback opened, won, and lost.
8. Provider fees and settlement adjustments.

The ledger's current per-unit balance constraint does not enforce that the XOF backing amount equals the corresponding BLC issuance or outstanding liability. Add explicit reconciliation queries and invariant tests for the cross-currency relationship.

## Safe interim policy

Until top-up provenance and provider reconciliation exist:
- Do not enable real-money top-ups or payment crediting.
- Do not implement automatic top-up-specific refunds or chargeback clawbacks.
- If a genuine dispute must be handled manually in a future controlled pilot, freeze the entire purchased-BLC wallet while preserving referral BLC and recipient earnings. Do not pretend the pooled balance identifies the affected top-up.
- Do not reverse already-sent gifts, recipient earnings, or issued referral rewards automatically.
- Keep all compensating ledger entries append-only and linked to the original operation.

## Required tests before provider-credit implementation

1. Two or more top-ups credited to one member remain separately traceable after wallet pooling.
2. A gift inventory purchase allocates purchased BLC across top-up lots deterministically.
3. Referral BLC is never allocated to a top-up lot.
4. Concurrent gift inventory purchases cannot overspend a top-up lot or wallet.
5. Every inventory source allocation reconciles to the purchased-BLC debit in its purchase transaction.
6. Inventory source allocations reconcile to the remaining inventory quantities and values.
7. Gift settlement consumes the correct source allocation and cannot consume the same inventory unit twice.
8. Full and partial refunds cannot exceed the original top-up after prior refunds.
9. A refund can distinguish remaining wallet BLC, unsent inventory value, and already-settled gift value.
10. Chargeback events cannot double reverse a top-up or race a refund.
11. Provider duplicate and out-of-order events converge to the authoritative provider state.
12. Provider settlement reports reconcile to internal top-up records, journals, and outstanding backing.
13. Any failure rolls back the journal, lot updates, allocation records, and hold/freeze state atomically.

## Decisions still required

1. Which provider and which authoritative provider status qualifies a payment for spendable BLC?
2. Is top-up credit allowed only after settlement, or is there a separately modeled pending balance?
3. What is the accounting treatment and owner of the purchased-BLC backing/reserve?
4. What is the refund policy after purchased BLC has been spent or converted into gift inventory?
5. Who approves a manual exception, and what evidence is retained?
6. What are the legal/accounting requirements for chargeback loss, member recovery, and provider fees?

## Release status

- This review is documentation only.
- No SQL was added or changed.
- No provider credentials, payment integrations, migrations, production writes, or deployments were performed.
- PR #11 remains separate and draft.
- Top-ups, refunds, chargebacks, payouts, and cash-out remain disabled.

## Selected provider decision: Wave

Wave is the selected candidate for future BaddieLink XOF top-ups. This is a design decision only. It does not establish merchant eligibility, activate a Wave Business Account, authorize credentials, or enable payments.

Wave's public Business API documentation states that API use requires a Wave Business Account, with API keys scoped to the business wallet. The Checkout API documents XOF amounts without decimal places and provides a browser launch URL. The Webhooks documentation describes raw-body signature verification, event-ID idempotency, and duplicate/missed/out-of-order delivery. The Balance API provides transaction listing and refund operations.

Before implementation, Wave must confirm Côte d'Ivoire business onboarding/API eligibility, merchant fees and settlement timing, partial-refund availability, and dispute/chargeback notification and evidence workflows. The published Checkout refund endpoint documents a full checkout refund with no amount parameter. The public webhook event list reviewed does not document a complete dispute/chargeback lifecycle.

Official references:
- https://docs.wave.com/business
- https://docs.wave.com/checkout
- https://docs.wave.com/webhook
- https://docs.wave.com/balance-api

The provenance chain remains provider-neutral in its data model. Store Wave identifiers and events as provider references, but do not hard-code provider assumptions into wallet accounting. The internal top-up/funding-lot ledger remains the source of BLC accounting truth; Wave remains the external payment and settlement evidence source.

