# BaddieLink BLC validation plan

Status: design-stage test plan. No proposal SQL in this directory has been applied to Supabase.

## Dependency order

1. `BLC_LEDGER_FOUNDATION.sql`
2. `BLC_GIFTS_AND_SETTLEMENT.sql`
3. `BLC_REFERRAL_REWARDS.sql`
4. `BLC_REFERRAL_PROVENANCE.sql`
5. `BLC_GIFT_RPC_WRAPPERS.sql`
6. `BLC_REFERRAL_LIFECYCLE.sql`

The deferred-referral provenance triggers require the gift tables, referral tables and ledger foundation. They must all be installed before any gift inventory purchase or gift-send call is allowed.

## Ledger invariants

- Every posted wallet transaction has at least one ledger entry.
- Sum of entries is zero independently for each currency.
- Posted transaction metadata cannot be changed.
- Ledger entries cannot be updated or deleted.
- No entry can be inserted after its parent transaction is posted.
- Idempotency keys are unique across all wallet operations.
- Member wallet accounts cannot be duplicated for the same owner and account kind.

## Gift inventory tests

- Inventory purchase succeeds with sufficient purchased BLC.
- Inventory purchase fails with insufficient purchased BLC.
- Inventory purchase fails for frozen or missing purchased wallet.
- Inventory quantity increases by exactly the requested amount.
- A retry with the same key and identical parameters returns the original transaction.
- Reusing the same key with different buyer, gift or quantity fails.
- Concurrent purchases cannot overspend the purchased BLC balance.
- Gift price is read from the server-side catalog, never from client input.

## Gift settlement tests

- Sending a gift decrements exactly one inventory item.
- Missing inventory fails without changing balances.
- Self-gifting fails.
- Unconfirmed, underage, restricted or removed senders/recipients fail.
- Mutual block in either direction prevents the gift.
- Duplicate identical requests return the original transaction.
- Reusing an idempotency key with different parameters fails.
- Concurrent sends cannot consume the same final inventory item twice.
- Any failure rolls back inventory, gift record, ledger entries and referral reward together.

## Split and deferred referral tests

For every gift:
- Recipient receives 70% of face value in XOF earnings.
- Platform initially recognizes 30% of face value in XOF revenue.
- Inventory provenance is consumed FIFO and exactly one inventory unit is decremented.
- Gift transaction XOF and BLC entries balance independently.

For a referred member sending a gift from fully purchased-BLC-funded inventory:
- Referrer receives floor(5% of the eligible purchased-BLC-funded gift value) whole BLC.
- The reward is reclassified from the already-earned 30% platform commission.
- Platform retains the remainder of its 30% share.
- Reward ledger entries are part of the same wallet transaction as gift settlement.

For a referred member sending a gift from fully referral-BLC-funded inventory:
- No referral reward is created.
- Platform retains the full 30% commission.

For mixed-funded inventory:
- Only the purchased-BLC-funded portion qualifies.
- Referral-funded BLC never creates a second-generation referral reward.
- FIFO lot consumption and integer remainder allocation preserve exact unit value and batch totals.

Also test:
- An inventory purchase creates a funding lot from its ledger entries, not caller input.
- Funding lots reconcile purchased plus referral BLC to the original purchase quantity and price.
- Missing or inconsistent provenance fails the gift send atomically.
- Self-referral is rejected and attribution is unique and immutable.
- Referrer must remain email-confirmed, adult-declared and not restricted/removed.
- Reward rounding below one BLC results in no reward; platform retains that amount.
- Concurrent sends cannot consume the same funding lot unit twice.
- Duplicate gift requests do not create duplicate rewards.
- Refund/chargeback and compensating-ledger treatment is designed before real-money top-ups are enabled.
- Referral BLC cannot be withdrawn or transferred as cash.

## Referral-code lifecycle tests

- Authenticated members can retrieve or create only their own referral code.
- Repeated code retrieval returns the same code and never creates duplicates.
- Generated codes use a high-entropy server-side value; clients cannot choose or reassign code ownership.
- Referral code identity is immutable; deactivation is permanent and idempotent.
- Anonymous users cannot execute referral-code lifecycle functions.
- Signup without a referral code remains valid and creates no attribution.
- Signup with a valid active code atomically attributes the new account to the code owner.
- Invalid, inactive or self-referral codes reject signup and roll back the auth.users insert.
- Signup metadata supplies only the code string; the database resolves the referrer identity.
- Changing user metadata after signup cannot change the immutable attribution.
- Concurrent code retrieval and deactivation serialize on the member identity; concurrent code use and deactivation serialize on the code row.

## Security tests

- Anonymous role cannot execute gift RPCs.
- Authenticated role cannot execute private ledger functions directly.
- Caller identity is derived from `auth.uid()`.
- Client cannot supply sender/buyer identity, price, split or reward amount.
- Private financial tables have no direct grants to `anon` or `authenticated`.
- SECURITY DEFINER functions use an empty search path and fully qualified object names.

## Release gates

Do not promote proposals into `supabase/migrations` until:
- SQL syntax and object dependency order pass in an isolated PostgreSQL database.
- All invariant, concurrency, idempotency and security tests pass.
- Refund/chargeback treatment is designed before any real-money purchase is enabled.
- A review confirms the accounting treatment and rounding rules.
- User approves the migration and subsequent deployment sequence.

No production SQL execution, payment processing, payouts or withdrawals are authorized by this plan.
