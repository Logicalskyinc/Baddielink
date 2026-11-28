import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import {
  buildWaveCheckoutRequest,
  createWaveCheckoutSession,
  parseWaveSignatureHeader,
  retrieveWaveCheckoutSession,
  searchWaveCheckoutByClientReference,
  verifyWaveWebhookSignature,
} from "./wave.js";

const secret = "wave-webhook-test-secret";
const now = 1_800_000_000;
const body = '{"id":"evt_test_01","type":"checkout.session.completed"}';

function sign(timestamp, rawBody = body, signingSecret = secret) {
  const digest = createHmac("sha256", signingSecret)
    .update(String(timestamp) + rawBody)
    .digest("hex");
  return `t=${timestamp},v1=${digest}`;
}

test("parses Wave signature and multiple v1 values", () => {
  const valid = sign(now);
  const signature = valid.split(",")[1].slice(3);
  const parsed = parseWaveSignatureHeader(`t=${now},v1=${"0".repeat(64)},v1=${signature}`);
  assert.equal(parsed.timestamp, now);
  assert.equal(parsed.signatures.length, 2);
});

test("rejects malformed and duplicate timestamp fields", () => {
  assert.equal(parseWaveSignatureHeader(""), null);
  assert.equal(parseWaveSignatureHeader(`t=${now},t=${now},v1=${"a".repeat(64)}`), null);
  assert.equal(parseWaveSignatureHeader(`t=x,v1=${"a".repeat(64)}`), null);
  assert.equal(parseWaveSignatureHeader(`t=${now},v1=bad`), null);
});

test("accepts a valid signature over the exact raw body", async () => {
  const result = await verifyWaveWebhookSignature({
    rawBody: body,
    signatureHeader: sign(now),
    webhookSecret: secret,
    nowSeconds: now,
  });
  assert.equal(result.valid, true);
  assert.equal(result.timestamp, now);
});

test("supports multiple signatures during secret rotation", async () => {
  const oldSignature = createHmac("sha256", "old-secret")
    .update(String(now) + body).digest("hex");
  const currentSignature = sign(now);
  const result = await verifyWaveWebhookSignature({
    rawBody: body,
    signatureHeader: `t=${now},v1=${oldSignature},${currentSignature.split(",")[1]}`,
    webhookSecret: secret,
    nowSeconds: now,
  });
  assert.equal(result.valid, true);
});

test("rejects changed raw body and wrong secret", async () => {
  const signatureHeader = sign(now);
  const changed = await verifyWaveWebhookSignature({
    rawBody: body + " ",
    signatureHeader,
    webhookSecret: secret,
    nowSeconds: now,
  });
  const wrongSecret = await verifyWaveWebhookSignature({
    rawBody: body,
    signatureHeader,
    webhookSecret: "wrong-secret",
    nowSeconds: now,
  });
  assert.equal(changed.valid, false);
  assert.equal(wrongSecret.valid, false);
});

test("rejects stale and excessively future timestamps", async () => {
  for (const timestamp of [now - 301, now + 31]) {
    const result = await verifyWaveWebhookSignature({
      rawBody: body,
      signatureHeader: sign(timestamp),
      webhookSecret: secret,
      nowSeconds: now,
    });
    assert.equal(result.valid, false);
    assert.equal(result.reason, "timestamp_out_of_range");
  }
});

test("accepts timestamps inside the configured tolerance", async () => {
  const result = await verifyWaveWebhookSignature({
    rawBody: body,
    signatureHeader: sign(now - 300),
    webhookSecret: secret,
    nowSeconds: now,
  });
  assert.equal(result.valid, true);
});

test("builds an integer XOF checkout request", () => {
  assert.deepEqual(buildWaveCheckoutRequest({
    amountXof: 2500,
    clientReference: "baddielink-topup-001",
    successUrl: "https://baddielink.onrender.com/payment/success",
    errorUrl: "https://baddielink.onrender.com/payment/error",
  }), {
    amount: "2500",
    currency: "XOF",
    client_reference: "baddielink-topup-001",
    success_url: "https://baddielink.onrender.com/payment/success",
    error_url: "https://baddielink.onrender.com/payment/error",
  });
});

test("rejects fractional, unsafe, invalid and non-HTTPS checkout inputs", () => {
  const base = {
    amountXof: 2500,
    clientReference: "baddielink-topup-001",
    successUrl: "https://example.com/success",
    errorUrl: "https://example.com/error",
  };
  assert.throws(() => buildWaveCheckoutRequest({ ...base, amountXof: 1.5 }), TypeError);
  assert.throws(() => buildWaveCheckoutRequest({ ...base, amountXof: Number.MAX_SAFE_INTEGER + 1 }), TypeError);
  assert.throws(() => buildWaveCheckoutRequest({ ...base, clientReference: "short" }), TypeError);
  assert.throws(() => buildWaveCheckoutRequest({ ...base, successUrl: "http://example.com" }), TypeError);
});

test("creates a checkout and returns only validated session fields", async () => {
  let captured;
  const result = await createWaveCheckoutSession({
    apiKey: "sandbox-key",
    amountXof: 2500,
    clientReference: "baddielink-topup-001",
    successUrl: "https://example.com/success",
    errorUrl: "https://example.com/error",
    fetchImpl: async (url, options) => {
      captured = { url, options };
      return new Response(JSON.stringify({
        id: "cos-test001",
        amount: "2500",
        currency: "XOF",
        client_reference: "baddielink-topup-001",
        checkout_status: "open",
        wave_launch_url: "https://pay.wave.com/c/cos-test001",
        transaction_id: null,
      }), { status: 200, headers: { "content-type": "application/json" } });
    },
  });

  assert.equal(captured.url, "https://api.wave.com/v1/checkout/sessions");
  assert.equal(captured.options.headers.Authorization, "Bearer sandbox-key");
  assert.equal(JSON.parse(captured.options.body).amount, "2500");
  assert.equal(result.id, "cos-test001");
  assert.equal(result.wave_launch_url, "https://pay.wave.com/c/cos-test001");
  assert.equal("transaction_id" in result, false);
});

test("rejects a Wave session with mismatched amount or launch host", async () => {
  const input = {
    apiKey: "sandbox-key",
    amountXof: 2500,
    clientReference: "baddielink-topup-001",
    successUrl: "https://example.com/success",
    errorUrl: "https://example.com/error",
    fetchImpl: async () => new Response(JSON.stringify({
      id: "cos-test001",
      amount: "1",
      currency: "XOF",
      client_reference: "baddielink-topup-001",
      wave_launch_url: "https://evil.example/pay",
    }), { status: 200 }),
  };
  await assert.rejects(createWaveCheckoutSession(input), /does not match/);
});


test("searches Wave for an existing checkout using the stable client reference", async () => {
  let requestedUrl;
  const session = {
    id: "cos-existing001",
    amount: "2500",
    currency: "XOF",
    client_reference: "baddielink-topup-001",
    checkout_status: "open",
    payment_status: "processing",
    wave_launch_url: "https://pay.wave.com/c/cos-existing001",
  };
  const result = await searchWaveCheckoutByClientReference({
    apiKey: "sandbox-key",
    amountXof: 2500,
    clientReference: "baddielink-topup-001",
    fetchImpl: async (url) => {
      requestedUrl = url;
      return new Response(JSON.stringify({ result: [session] }), { status: 200 });
    },
  });
  assert.equal(new URL(requestedUrl).searchParams.get("client_reference"), "baddielink-topup-001");
  assert.equal(result.id, "cos-existing001");
});

test("returns null when no Wave checkout exists for the client reference", async () => {
  const result = await searchWaveCheckoutByClientReference({
    apiKey: "sandbox-key",
    amountXof: 2500,
    clientReference: "baddielink-topup-001",
    fetchImpl: async () => new Response(JSON.stringify({ result: [] }), { status: 200 }),
  });
  assert.equal(result, null);
});

test("rejects multiple Wave sessions for one BLC client reference", async () => {
  const session = {
    id: "cos-existing001",
    amount: "2500",
    currency: "XOF",
    client_reference: "baddielink-topup-001",
    checkout_status: "open",
    wave_launch_url: "https://pay.wave.com/c/cos-existing001",
  };
  await assert.rejects(searchWaveCheckoutByClientReference({
    apiKey: "sandbox-key",
    amountXof: 2500,
    clientReference: "baddielink-topup-001",
    fetchImpl: async () => new Response(JSON.stringify({ result: [session, session] }), { status: 200 }),
  }), /Multiple Wave checkout sessions/);
});

test("retrieves an existing checkout and revalidates all top-up identity fields", async () => {
  const result = await retrieveWaveCheckoutSession({
    apiKey: "sandbox-key",
    checkoutSessionId: "cos-existing001",
    amountXof: 2500,
    clientReference: "baddielink-topup-001",
    fetchImpl: async () => new Response(JSON.stringify({
      id: "cos-existing001",
      amount: "2500",
      currency: "XOF",
      client_reference: "baddielink-topup-001",
      checkout_status: "open",
      payment_status: "processing",
      wave_launch_url: "https://pay.wave.com/c/cos-existing001",
    }), { status: 200 }),
  });
  assert.equal(result.id, "cos-existing001");
});


test("signs outbound Wave POST and GET requests when request signing is enabled", async () => {
  const requestSecret = "wave-api-request-signing-secret";
  let postRequest;
  await createWaveCheckoutSession({
    apiKey: "sandbox-key",
    requestSigningSecret: requestSecret,
    amountXof: 2500,
    clientReference: "baddielink-topup-001",
    successUrl: "https://example.com/success",
    errorUrl: "https://example.com/error",
    fetchImpl: async (url, options) => {
      postRequest = { url, options };
      return new Response(JSON.stringify({
        id: "cos-signed001",
        amount: "2500",
        currency: "XOF",
        client_reference: "baddielink-topup-001",
        checkout_status: "open",
        wave_launch_url: "https://pay.wave.com/c/cos-signed001",
      }), { status: 200 });
    },
  });

  const postSignature = parseWaveSignatureHeader(postRequest.options.headers["Wave-Signature"]);
  const expectedPost = createHmac("sha256", requestSecret)
    .update(String(postSignature.timestamp) + postRequest.options.body)
    .digest("hex");
  assert.equal(postSignature.signatures.includes(expectedPost), true);

  let getRequest;
  await searchWaveCheckoutByClientReference({
    apiKey: "sandbox-key",
    requestSigningSecret: requestSecret,
    amountXof: 2500,
    clientReference: "baddielink-topup-001",
    fetchImpl: async (url, options) => {
      getRequest = { url, options };
      return new Response(JSON.stringify({ result: [] }), { status: 200 });
    },
  });

  const getSignature = parseWaveSignatureHeader(getRequest.options.headers["Wave-Signature"]);
  const expectedGet = createHmac("sha256", requestSecret)
    .update(String(getSignature.timestamp))
    .digest("hex");
  assert.equal(getSignature.signatures.includes(expectedGet), true);
});

test("does not leak provider response bodies on API errors", async () => {
  await assert.rejects(createWaveCheckoutSession({
    apiKey: "sandbox-key",
    amountXof: 2500,
    clientReference: "baddielink-topup-001",
    successUrl: "https://example.com/success",
    errorUrl: "https://example.com/error",
    fetchImpl: async () => new Response("private provider diagnostics", { status: 401 }),
  }), /HTTP 401/);
});
