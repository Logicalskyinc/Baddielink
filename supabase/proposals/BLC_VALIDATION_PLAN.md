# BaddieLink BLC validation plan

Status: design-stage test plan. No proposal SQL in this directory has been applied to Supabase.

## Dependency order

1. `BLC_LEDGER_FOUNDATION.sql`
2. `BLC_GIFTS_AND_SETTLEMENT.sql`
3. `BLC_REFERRAL_REWARDS.sql`
4. `BLC_GIFT_RPC_WRAPPERS.sql`

The gift settlement PL/pgSQL function resolves referral tables when invoked, so the referral proposal must be installed before any gift-send call is allowed.

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

## Split and referral tests

For an eligible gift with a referred sender:
- Recipient receives 70% of face value in XOF earnings.
- Referrer receives floor(5% of face value) whole BLC.
- Platform receives the remaining XOF share, normally 25%.
- Referral funding is debited from the platform's existing 30% share.
- XOF entries balance to zero; BLC entries balance to zero.

For a gift without an eligible referrer:
- Recipient receives 70%.
- Platform receives 30%.
- No referral reward is created.

Also test:
- A referral attribution is unique and immutable.
- Self-referral is rejected.
- Referrer must remain email-confirmed, adult-declared and not restricted/removed.
- Reward rounding below one BLC results in zero reward and the unallocated remainder stays with the platform.
- Referral rewards cannot be withdrawn or transferred as cash.

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
