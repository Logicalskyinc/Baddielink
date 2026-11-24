const encoder = new TextEncoder();

async function buildWaveRequestHeaders(apiKey, rawBody, requestSigningSecret) {
  const headers = { Authorization: "Bearer " + apiKey };
  if (!requestSigningSecret) return headers;

  const timestamp = String(Math.floor(Date.now() / 1000));
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(requestSigningSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(timestamp + rawBody),
  );
  headers["Wave-Signature"] = "t=" + timestamp + ",v1=" + toHex(new Uint8Array(signature));
  return headers;
}

function toHex(bytes) {
  return Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
}


function hexToBytes(hex) {
  if (!/^[0-9a-f]{64}$/i.test(hex)) return null;
  const bytes = new Uint8Array(32);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

export function parseWaveSignatureHeader(header) {
  if (typeof header !== "string" || header.length > 2048) return null;

  const fields = header.split(",").map((part) => part.trim());
  let timestamp = null;
  const signatures = [];

  for (const field of fields) {
    const separator = field.indexOf("=");
    if (separator < 1) return null;

    const key = field.slice(0, separator).trim();
    const value = field.slice(separator + 1).trim();

    if (!value) return null;

    if (key === "t") {
      if (timestamp !== null || !/^\d{1,12}$/.test(value)) return null;
      timestamp = Number(value);
    } else if (key === "v1") {
      if (!hexToBytes(value)) return null;
      signatures.push(value.toLowerCase());
    }
  }

  if (timestamp === null || signatures.length === 0) return null;
  return { timestamp, signatures };
}

export async function verifyWaveWebhookSignature({
  rawBody,
  signatureHeader,
  webhookSecret,
  nowSeconds = Math.floor(Date.now() / 1000),
  toleranceSeconds = 300,
  futureToleranceSeconds = 30,
}) {
  if (typeof rawBody !== "string" || typeof webhookSecret !== "string" || !webhookSecret) {
    return { valid: false, reason: "invalid_input" };
  }

  const parsed = parseWaveSignatureHeader(signatureHeader);
  if (!parsed) return { valid: false, reason: "malformed_signature" };

  const age = nowSeconds - parsed.timestamp;
  if (age > toleranceSeconds || age < -futureToleranceSeconds) {
    return { valid: false, reason: "timestamp_out_of_range" };
  }

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(webhookSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );

  const signedPayload = encoder.encode(String(parsed.timestamp) + rawBody);

  for (const signature of parsed.signatures) {
    const signatureBytes = hexToBytes(signature);
    if (signatureBytes && await crypto.subtle.verify("HMAC", key, signatureBytes, signedPayload)) {
      return { valid: true, timestamp: parsed.timestamp };
    }
  }

  return { valid: false, reason: "signature_mismatch" };
}

export function buildWaveCheckoutRequest({
  amountXof,
  clientReference,
  successUrl,
  errorUrl,
}) {
  if (!Number.isSafeInteger(amountXof) || amountXof <= 0) {
    throw new TypeError("amountXof must be a positive safe integer");
  }
  if (typeof clientReference !== "string" || clientReference.trim().length < 12 ||
      clientReference.length > 160) {
    throw new TypeError("clientReference must contain 12 to 160 characters");
  }

  for (const [name, value] of [["successUrl", successUrl], ["errorUrl", errorUrl]]) {
    let parsed;
    try {
      parsed = new URL(value);
    } catch {
      throw new TypeError(name + " must be a valid HTTPS URL");
    }
    if (parsed.protocol !== "https:") {
      throw new TypeError(name + " must be a valid HTTPS URL");
    }
  }

  return {
    amount: String(amountXof),
    currency: "XOF",
    client_reference: clientReference,
    success_url: successUrl,
    error_url: errorUrl,
  };
}


function validateWaveCheckoutSession(session, { amountXof, clientReference }) {
  if (
    !session ||
    typeof session.id !== "string" || !/^cos-[A-Za-z0-9]{1,16}$/.test(session.id) ||
    typeof session.wave_launch_url !== "string" ||
    typeof session.amount !== "string" ||
    session.currency !== "XOF" ||
    !["open", "complete", "expired"].includes(session.checkout_status) ||
    session.client_reference !== clientReference ||
    session.amount !== String(amountXof)
  ) {
    throw new Error("Wave checkout session does not match the expected top-up");
  }

  const launchUrl = new URL(session.wave_launch_url);
  if (launchUrl.protocol !== "https:" || launchUrl.hostname !== "pay.wave.com") {
    throw new Error("Wave returned an unexpected checkout launch URL");
  }

  return {
    id: session.id,
    amount: session.amount,
    currency: session.currency,
    client_reference: session.client_reference,
    checkout_status: session.checkout_status,
    payment_status: session.payment_status,
    transaction_id: session.transaction_id,
    wave_launch_url: launchUrl.toString(),
  };
}

/**
 * @param {{
 *   apiKey: string,
 *   amountXof: number,
 *   clientReference: string,
 *   requestSigningSecret?: string,
 *   fetchImpl?: typeof fetch
 * }} options
 */
export async function searchWaveCheckoutByClientReference({
  apiKey,
  amountXof,
  clientReference,
  requestSigningSecret,
  fetchImpl = fetch,
}) {
  if (typeof apiKey !== "string" || !apiKey.trim()) {
    throw new TypeError("Wave API key is not configured");
  }

  const url = new URL("https://api.wave.com/v1/checkout/sessions/search");
  url.searchParams.set("client_reference", clientReference);

  const response = await fetchImpl(url.toString(), {
    method: "GET",
    headers: await buildWaveRequestHeaders(apiKey, "", requestSigningSecret),
    signal: AbortSignal.timeout(5000),
  });

  if (!response.ok) {
    throw new Error("Wave checkout search failed with HTTP " + response.status);
  }

  const payload = await response.json();
  if (!payload || !Array.isArray(payload.result)) {
    throw new Error("Wave checkout search returned an invalid response");
  }

  const matches = payload.result.map((session) =>
    validateWaveCheckoutSession(session, { amountXof, clientReference })
  );

  if (matches.length > 1) {
    throw new Error("Multiple Wave checkout sessions share one BLC client reference");
  }

  return matches[0] ?? null;
}

/**
 * @param {{
 *   apiKey: string,
 *   checkoutSessionId: string,
 *   amountXof: number,
 *   clientReference: string,
 *   requestSigningSecret?: string,
 *   fetchImpl?: typeof fetch
 * }} options
 */
export async function retrieveWaveCheckoutSession({
  apiKey,
  checkoutSessionId,
  amountXof,
  clientReference,
  requestSigningSecret,
  fetchImpl = fetch,
}) {
  if (typeof apiKey !== "string" || !apiKey.trim()) {
    throw new TypeError("Wave API key is not configured");
  }
  if (typeof checkoutSessionId !== "string" || !/^cos-[A-Za-z0-9]+$/.test(checkoutSessionId)) {
    throw new TypeError("Invalid Wave checkout session ID");
  }

  const response = await fetchImpl(
    "https://api.wave.com/v1/checkout/sessions/" + encodeURIComponent(checkoutSessionId),
    {
      method: "GET",
      headers: await buildWaveRequestHeaders(apiKey, "", requestSigningSecret),
      signal: AbortSignal.timeout(3000),
    },
  );

  if (!response.ok) {
    throw new Error("Wave checkout retrieval failed with HTTP " + response.status);
  }

  return validateWaveCheckoutSession(await response.json(), { amountXof, clientReference });
}

/**
 * @param {{
 *   apiKey: string,
 *   amountXof: number,
 *   clientReference: string,
 *   successUrl: string,
 *   errorUrl: string,
 *   requestSigningSecret?: string,
 *   fetchImpl?: typeof fetch
 * }} options
 */
export async function createWaveCheckoutSession({
  apiKey,
  amountXof,
  clientReference,
  successUrl,
  errorUrl,
  requestSigningSecret,
  fetchImpl = fetch,
}) {
  if (typeof apiKey !== "string" || !apiKey.trim()) {
    throw new TypeError("Wave API key is not configured");
  }

  const requestBody = buildWaveCheckoutRequest({
    amountXof,
    clientReference,
    successUrl,
    errorUrl,
  });

  const rawBody = JSON.stringify(requestBody);
  const headers = await buildWaveRequestHeaders(apiKey, rawBody, requestSigningSecret);
  headers["Content-Type"] = "application/json";

  const response = await fetchImpl("https://api.wave.com/v1/checkout/sessions", {
    method: "POST",
    headers,
    body: rawBody,
    signal: AbortSignal.timeout(5000),
  });

  if (!response.ok) {
    throw new Error("Wave checkout request failed with HTTP " + response.status);
  }

  const session = await response.json();
  if (
    !session ||
    typeof session.id !== "string" || !/^cos-[A-Za-z0-9]{1,16}$/.test(session.id) ||
    typeof session.wave_launch_url !== "string" ||
    typeof session.amount !== "string" ||
    session.currency !== "XOF" ||
    !["open", "complete", "expired"].includes(session.checkout_status) ||
    session.client_reference !== clientReference ||
    session.amount !== String(amountXof)
  ) {
    throw new Error("Wave returned a checkout session that does not match the request");
  }

  const launchUrl = new URL(session.wave_launch_url);
  if (launchUrl.protocol !== "https:" || launchUrl.hostname !== "pay.wave.com") {
    throw new Error("Wave returned an unexpected checkout launch URL");
  }

  return {
    id: session.id,
    amount: session.amount,
    currency: session.currency,
    client_reference: session.client_reference,
    checkout_status: session.checkout_status,
    wave_launch_url: launchUrl.toString(),
  };
}
