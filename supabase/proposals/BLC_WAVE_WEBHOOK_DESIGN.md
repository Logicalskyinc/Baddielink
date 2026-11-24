# BLC Wave webhook processing design

Status: implementation exists on the review branch and is covered by isolated CI tests. No Edge Function is deployed, no Wave credentials are configured, and no real payment is accepted or credited.

## Confirmed Wave Checkout contract

The implementation targets the Wave Business Checkout API, not unrelated Wave products.

- Create checkout: `POST /v1/checkout/sessions`.
- Retrieve a checkout: `GET /v1/checkout/sessions/:id`.
- Checkout session identifiers begin with `cos-`.
- Session fields include `id`, `amount`, `currency`, `client_reference`, `checkout_status`, `payment_status`, and `transaction_id`.
- XOF amounts are integer strings with no decimal places.
- A completed payment is represented by `checkout_status = complete` and `payment_status = succeeded`.
- Wave's webhook event example uses `type = checkout.session.completed` and wraps the session in `data`.

## Checkout creation and retry safety

The review branch also contains `create-wave-checkout`, an authenticated Edge Function.

- The member identity comes from a verified Supabase access token. The request body supplies only the XOF amount and a client-generated idempotency key.
- The database creates a pending top-up and a stable, opaque `client_reference`; the caller cannot supply the member ID or provider account.
- A database claim serializes concurrent checkout creation for the same top-up.
- Wave's Checkout API documentation does not specify an `Idempotency-Key` header for session creation. The function therefore searches Wave by the stable `client_reference` before creating a new session, allowing retries to recover a session created before a timeout.
- The function persists the Wave checkout-session ID before returning the launch URL. If persistence cannot be confirmed, it does not return an unlinked payment URL.
- Open sessions return a launch URL. Completed sessions do not return a launch URL; expired sessions require a new top-up request key.
- The launch URL must be opened in the user's browser, not captured inside a mobile webview.

## Receiver architecture

Use a Supabase Edge Function named `wave-webhook` as the public HTTPS receiver. It is a webhook endpoint, not a browser endpoint.

- Configure `verify_jwt = false` only for this function because Wave cannot supply a Supabase user JWT. The handler must authenticate every request using the Wave webhook signing secret.
- Keep the Wave API key and webhook signing secret in Supabase project secrets. Never put either in the browser, repository, event payload, or logs.
- If the Wave API key has request signing enabled, also configure `WAVE_SANDBOX_API_SIGNING_SECRET`. The shared client signs POST requests over the exact JSON body and GET requests over the empty body. This outbound API signing secret is separate from the webhook signing secret.
- Read the raw request body once, enforce a small body-size limit, and verify the signature before parsing JSON.
- Parse `Wave-Signature` as `t=<unix-seconds>,v1=<hex>`. Accept multiple `v1` signatures to support secret rotation.
- Calculate HMAC-SHA256 over the exact concatenation `timestamp + raw_body`. Compare signatures using a constant-time comparison.
- Reject malformed signatures, missing signatures, timestamps older than five minutes, and timestamps too far in the future. Do not hash parsed or re-serialized JSON.
- Parse JSON only after signature verification. Reject malformed JSON and unsupported event structures.
- Persist signed event envelopes before classification. Record `checkout.session.payment_failed` and unsupported event types as `ignored` (without wallet effects); identical redeliveries return `duplicate`.

## Payment verification and credit

Only a signed `checkout.session.completed` event can be considered for a credit.

Before crediting, require all of the following:

1. `checkout_status = complete`.
2. `payment_status = succeeded`.
3. `currency = XOF`.
4. `client_reference` matches exactly one pending BLC top-up belonging to the same Wave provider account.
5. The event checkout-session ID matches the stored `checkout_session` provider reference for that top-up.
6. `amount` exactly matches the expected top-up XOF amount, compared as an integer string (no floating-point conversion).
7. `transaction_id` is present and is unique for this provider account.
8. A server-side `GET /v1/checkout/sessions/:id` retrieval confirms the same checkout ID, client reference, amount, currency, checkout status, payment status, and transaction ID before a wallet credit is posted.

The event payload is a notification, not an instruction to credit a user ID. Resolve the user only from the existing top-up row selected by the opaque `client_reference`. Never trust a user ID supplied in the webhook.

## Atomic database transaction

The `wave-webhook` Edge Function verifies the signature, retrieves the session from Wave, and calls the service-role-only `public.process_wave_checkout_event` RPC. The RPC performs the following in one PostgreSQL transaction:

1. Insert the provider event using the unique `(provider_account_id, provider_event_id)` key and persist the payload hash.
2. On an identical duplicate event, return the prior result without creating another wallet transaction. If the same event ID arrives with a different payload hash, mark the event `review_required`; alerting is not yet implemented.
3. Lock the matching top-up row with `FOR UPDATE`.
4. Validate the top-up state and every expected identity and amount field again inside the database.
5. Ensure no other top-up already owns the same provider transaction ID or checkout reference.
6. Insert one balanced `purchase_credit` wallet journal with a deterministic top-up-scoped idempotency key.
7. Update the top-up to `credited`, link the wallet journal, and insert exactly one purchased-BLC funding lot.
8. Mark the provider event processed.
9. Commit all effects together. Any error rolls back the event-processing transaction and credit journal together.

If a signed event is authentic but does not match the pending top-up, do not credit. Persist a redacted event and mark the top-up/event `review_required` where the identity is unambiguous. Do not retry a permanent mismatch forever.

## Response and retry behavior

- Return 2xx only after the event has been durably recorded and either processed, recognized as an identical duplicate, or safely classified for manual review.
- Return a retryable 5xx when a transient database or Wave API failure prevents durable processing.
- Return 401 for an invalid signature and 400 for an invalid event envelope.
- Keep processing short; Wave's webhook documentation specifies a response within five seconds and duplicate deliveries must be expected.
- Add reconciliation that queries Wave for pending sessions and compares them with local top-up state. Webhooks alone are not a complete reconciliation system.

## Required tests

- Valid signature and raw-body whitespace/key-order preservation.
- Invalid signature, malformed header, stale timestamp, future timestamp, and signature rotation with multiple `v1` values.
- Invalid JSON, oversized body, unknown event type, and Wave test event.
- Correct completed checkout; wrong currency, amount, client reference, session ID, transaction ID, or provider account.
- Duplicate event with identical payload and duplicate event ID with a changed payload.
- Two different event IDs for the same checkout.
- Concurrent delivery of the same event and concurrent events for one top-up.
- Database rollback when journal, funding-lot, or event processing fails.
- Retry after transient failure without duplicate wallet credit.
- Reconciliation of a missed webhook.

## Explicit exclusions

The review-branch code implements sandbox checkout creation and an atomic wallet-credit processor, but does not enable production credentials, real wallet credits, refunds, chargebacks, cash-out, Mobile Money payouts, or deployment. Each requires its own implementation, tests, and approval. Refund and chargeback accounting remains a separate release blocker.
