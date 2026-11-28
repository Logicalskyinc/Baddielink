# BLC refund and chargeback accounting design

Status: design proposal only. No refund, chargeback, payment-provider, wallet-freeze, or reversal SQL is implemented by this document. Do not apply to production.

## Scope and release boundary

This design covers verified real-money top-ups that credit purchased BLC, provider refunds, provider disputes/chargebacks, and duplicate or out-of-order provider events.

It does not authorize:
- Enabling top-ups or payment processing.
- Payouts, withdrawals, or Mobile Money cash-out.
- Debiting recipients' earnings to recover a sender's chargeback.
- Confiscating referral BLC or already-issued referral rewards.
- Editing or deleting posted ledger entries.

The current proposal has gift settlement and referral accounting, but no verified provider-credit workflow and no refund/chargeback posting workflow. The transaction type labels `refund` and `chargeback` are not implementations.

## Findings in the current ledger foundation

1. Posted transactions and ledger entries are append-only. Corrections must use new compensating transactions.
2. Idempotency keys are globally unique across wallet transactions.
3. Ledger balance is enforced independently per unit (BLC and XOF). The database does not itself prove that one BLC equals one XOF across units.
4. Current account kinds do not include a dedicated purchased-BLC backing liability/reserve account, processor clearing/receivable account, chargeback loss account, or provider-fee/chargeback-fee expense account.
5. `related_reference` is text, not a foreign key to a provider payment or original transaction. A separate immutable payment-event/operation record is needed for durable linkage.
6. No purchase-credit RPC or verified webhook pipeline is included in the reviewed proposal files.

These gaps must be addressed before real-money top-ups are enabled.

## Required provider event model

Create an immutable provider-operation record with, at minimum:
- Internal operation UUID.
- Provider name and provider account/environment identifier.
- Provider payment/charge identifier.
- Provider event identifier, unique within the provider account.
- Event type and provider-reported status.
- Amount and currency as reported by the provider.
- Normalized XOF amount, only after validating currency and amount.
- Related internal top-up UUID and original wallet transaction UUID, when known.
- Signature-verification result and verification timestamp.
- Received timestamp, provider event timestamp, and processing status.
- A safe, redacted payload digest or retained payload according to a documented privacy/retention policy.

Enforce uniqueness on (provider, provider account/environment, provider event ID). Also enforce one successful top-up credit per provider payment/charge ID. Do not rely on webhook delivery order.

Webhook processing must:
1. Verify the provider signature against the raw request body before trusting event fields.
2. Validate provider account, environment, currency, amount, payment identity and final settlement status.
3. Persist the provider event durably before acknowledging it.
4. Serialize processing by provider payment/charge ID.
5. Be idempotent for duplicate deliveries and safe for out-of-order events.
6. Re-fetch authoritative provider payment/dispute state when event order or payload state is ambiguous.
7. Record processing outcome and failure reason without logging secrets or full payment credentials.

A browser/client callback is never proof of payment.

## Top-up credit accounting prerequisites

Before a top-up can credit purchased BLC, define a complete journal mapping for:
- Provider funds pending/clearing or processor receivable.
- Purchased-BLC backing liability/reserve.
- Purchased-BLC member wallet liability.
- Provider fees and settlement differences.
- Reconciliation against provider settlement reports and bank/merchant statements.

The accounting policy must explicitly explain the relationship between XOF cash received, XOF backing, and BLC issued at the 1:1 rate. The existing per-currency balancing trigger does not enforce cross-currency equivalence. The purchase-credit operation must therefore validate and persist a single normalized amount used by both sides of the conversion.

Do not credit a member wallet until the provider's authoritative state satisfies the chosen settlement policy. If the provider supports asynchronous settlement, model pending separately from spendable purchased BLC.

## Refund policy and journal behavior

A refund is a new compensating operation linked to the original top-up and provider refund ID. It must not mutate the original top-up transaction.

The system must distinguish:
- Full refund.
- Partial refund.
- Refund pending, succeeded, failed, or reversed.
- Refund requested by the customer versus provider/issuer-initiated reversal.

For a refund that succeeds before any purchased BLC is spent:
- Reverse the unspent purchased-BLC liability and the matching backing/clearing amount.
- Ensure the reversal cannot exceed the original credited amount less prior successful reversals.
- Preserve the original top-up and all ledger entries.

For a partial refund:
- Track cumulative successful refund amount against the original top-up.
- Never refund more than the original settled amount.
- Convert XOF to BLC only under the same documented 1:1 policy and integer rules used at credit time.

For a refund after some purchased BLC has been spent:
- Freeze the member's purchased-BLC wallet while the exposure is evaluated.
- Reverse only the remaining unspent purchased BLC, bounded by the original top-up's remaining unspent provenance.
- Do not create a negative wallet balance.
- Do not silently debit referral BLC, recipient earnings, or unrelated purchased top-ups.
- Record the unrecovered amount as a separately classified platform/merchant exposure (loss or receivable only if legally and operationally supportable).
- Require a documented decision on whether the account remains frozen, can be restored after review, or is closed.

The exact policy for partial refunds after mixed spending must be specified at the top-up-lot level. A pooled purchased wallet balance is not enough to prove which top-up funded which gift. The existing inventory funding lots track purchased-versus-referral funding at inventory-purchase time, but they do not yet provide end-to-end top-up provenance for each purchased BLC unit. A top-up funding-lot model is required if refunds are to be attributed precisely.

## Chargeback and dispute policy

A chargeback/dispute is not the same event as a voluntary refund. Track its lifecycle separately:
- Opened / under dispute.
- Evidence submitted.
- Won / reversed.
- Lost / chargeback finalized.
- Fee assessed or adjusted.

On a credible dispute notification:
1. Persist the event and link it to the original provider payment.
2. Freeze further spending of the affected purchased-BLC exposure, using top-up provenance if available.
3. Do not immediately post a final chargeback loss while the dispute is pending unless provider rules require settlement.
4. Preserve gift settlement and referral records. Do not erase rewards or reverse recipient earnings automatically.
5. On a won dispute, release only the freeze attributable to that dispute, after rechecking other holds.
6. On a lost/finalized dispute, post a compensating journal for the amount and provider fees, bounded by the original payment and prior reversals.
7. Classify any spent/unrecoverable value to a dedicated platform chargeback-loss account, subject to accounting review. Do not fabricate a member receivable.
8. Keep an auditable link from provider dispute to original top-up, all compensating transactions, affected funding lots, and any manual review.

No member wallet may be driven negative. No reward or recipient earning may be confiscated by an automated chargeback handler.

## Concurrency, idempotency and atomicity

- Use a unique provider event key and a unique provider payment/charge key.
- Acquire locks in a documented deterministic order: provider payment/top-up record, affected top-up lots, then member wallet accounts ordered by UUID.
- Re-check cumulative refunds, chargeback state, remaining top-up amount and available unspent provenance after acquiring locks.
- In one database transaction, write the operation state, compensating wallet transaction, ledger entries, lot adjustments and wallet freeze/hold state.
- A retry with the same provider event must return the recorded result without another journal.
- A different event for the same payment must serialize and respect cumulative amount limits.
- A failure at any stage must roll back all database changes. External provider calls must not be performed while holding database row locks; use an outbox/job pattern where an outbound provider action is required.

## Reconciliation and observability

Provide a read-only reconciliation report that compares:
- Provider settled top-ups versus internal successful top-up credits.
- Provider refunds versus internal refund journals.
- Provider chargebacks and fees versus internal dispute journals.
- Remaining purchased-BLC top-up provenance versus member purchased-wallet balances and consumed inventory/gift provenance.
- Platform backing/reserve accounts versus outstanding purchased-BLC liabilities.

Alert on:
- Provider events stuck unprocessed.
- A provider payment credited more than once.
- Cumulative refund/chargeback amount exceeding the settled top-up.
- Unbalanced or missing journal entries.
- Negative or mismatched funding-lot quantities/amounts.
- A wallet freeze not cleared after a resolved dispute.
- Differences between provider settlement reports and internal records.

Never log card numbers, CVV, access tokens, webhook secrets, or unnecessary personal data.

## Required tests before implementation approval

1. Valid settled top-up credits once; duplicate event and duplicate payment delivery do not double-credit.
2. Invalid signature, wrong provider account, wrong environment, wrong currency, amount mismatch and non-final payment status do not credit.
3. Full refund before spend reverses exactly the unspent amount.
4. Partial refunds cannot exceed original settled amount cumulatively.
5. Refund retries do not duplicate reversals.
6. Refund after partial spend freezes the purchased wallet and reverses only traceable unspent purchased BLC.
7. Mixed top-up lots preserve provenance and do not consume referral BLC.
8. Chargeback pending freezes the defined exposure but does not prematurely post final loss.
9. Won dispute releases only its own hold.
10. Lost dispute posts one compensating journal, including separately classified provider fees.
11. Already-settled gifts, recipient earnings and referral rewards remain unchanged by automatic recovery.
12. Concurrent refund and chargeback events serialize and cannot over-reverse.
13. Out-of-order provider events converge to the authoritative provider state.
14. Any injected failure leaves no partial journal, lot update, or freeze-state mutation.
15. Reconciliation detects missing, duplicate and amount-mismatched provider operations.

## Decisions required before implementation

These are policy choices, not safe assumptions:
1. Which payment provider and which provider settlement state qualifies a top-up for spendable BLC?
2. Are refunds allowed after BLC has been spent, and who approves them?
3. For a post-spend refund or lost chargeback, is the unrecovered amount treated as platform loss, or is any member recovery legally permitted? Default engineering safeguard: no negative member balance and no automated clawback from recipients or referral rewards.
4. Should a dispute freeze only the remaining BLC traceable to that top-up, or all purchased BLC pending a reliable top-up-lot model? Until provenance exists, the safer interim policy is to freeze the entire purchased-BLC wallet, not referral BLC or recipient earnings.
5. What is the retention and evidence policy for provider payloads and dispute documents?

## Release gates

- Keep top-ups, refunds, chargebacks and payouts disabled until provider integration, accounting sign-off, legal/compliance review, reconciliation and isolated PostgreSQL concurrency/security tests are complete.
- Implement this as a separate proposal and migration series, not as an unreviewed addition to the referral-integrity migration.
- Require explicit approval before any production migration, provider credential configuration, billing change, or deployment.

## Selected candidate provider: Wave

Decision recorded: Wave is the selected candidate provider for BaddieLink's future XOF top-up integration. This is a provider selection for design and verification only, not approval to create a Wave business account, configure credentials, enable payments, or deploy code.

Official documentation reviewed:
- Business API overview: https://docs.wave.com/business
- Checkout API: https://docs.wave.com/checkout
- Webhooks: https://docs.wave.com/webhook
- Balance and reconciliation API: https://docs.wave.com/balance-api

Documented capabilities relevant to BaddieLink:
- Wave Business APIs require a Wave Business Account. API keys are scoped to a business wallet and must remain server-side. The Developer section is available to Business Portal admins; API access may require Wave to enable it.
- Checkout accepts XOF amounts with no decimal places and returns a `wave_launch_url` that must be opened in the user's browser, not embedded in an in-app webview.
- Checkout webhooks include `checkout.session.completed`; the event data exposes checkout/payment status, currency, amount, transaction ID and client reference.
- Webhook verification uses the raw request body and the webhook signing secret. Event IDs must be used for idempotency. Wave documents duplicate, missed and out-of-order delivery, so the application must reconcile with Wave's API rather than treating webhooks as the sole source of truth.
- Wave documents a Checkout refund endpoint and a Balance API transaction-refund endpoint. The documented Checkout refund request has no amount parameter and refunds the payment associated with the checkout. Do not assume partial refunds are supported by this endpoint.
- The Balance API exposes wallet balance, transaction listing and refunds, which can support reconciliation.

Important limitations to resolve with Wave before implementation:
1. Confirm that BaddieLink's legal entity and Wave Business Account can be onboarded in Côte d'Ivoire and that API Checkout is enabled for that account.
2. Confirm applicable merchant fees, settlement timing, settlement reporting, transaction limits, refund rules and any reserve/hold requirements.
3. Confirm whether partial refunds are available through another approved Wave workflow. The public Checkout refund endpoint documents a full checkout refund only.
4. Confirm how Wave notifies merchants about disputes, reversals, chargebacks and chargeback fees. The public webhook event list reviewed documents checkout and merchant-payment events, but does not document a complete chargeback/dispute lifecycle.
5. Confirm how to obtain authoritative payment state and dispute evidence when webhook events are missed or arrive out of order.

Implementation constraints:
- Never credit BLC from the browser success redirect. Credit only after server-side verification of the authoritative Wave payment state and a valid webhook/reconciliation result.
- Store Wave checkout ID, Wave transaction ID, client reference, provider event ID, environment and normalized XOF amount against one internal top-up.
- Keep Wave API keys and webhook secrets in server-side secret storage. Never put them in frontend code, Git, logs or chat.
- Verify webhook signatures against the exact raw body before parsing. Use constant-time comparison and timestamp/replay checks according to Wave's current webhook signing documentation.
- Persist the event before acknowledging it, process asynchronously, deduplicate by provider event ID, and reconcile against Wave's Checkout/Balance APIs.
- Treat refund requests as external side effects. Persist an internal refund operation and idempotency state before calling Wave; reconcile the final Wave transaction state before posting the internal compensating ledger journal.
- Do not implement chargeback handling until Wave confirms the actual dispute/reversal lifecycle and available event/API support.

This provider choice does not change the release gates: top-ups, refunds, chargebacks, payouts and cash-out remain disabled until provenance, accounting, compliance, integration tests and explicit release approvals are complete.

