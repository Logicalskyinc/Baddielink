import { createClient } from "npm:@supabase/supabase-js@2.49.1";
import {
  retrieveWaveCheckoutSession,
  verifyWaveWebhookSignature,
} from "../_shared/wave.js";

const jsonHeaders = { "Content-Type": "application/json; charset=utf-8" };
const encoder = new TextEncoder();

function reply(status: number, payload: Record<string, unknown>) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...jsonHeaders, "Cache-Control": "no-store" },
  });
}

async function readBodyBounded(request: Request, maxBytes: number): Promise<string | null> {
  if (!request.body) return null;
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new RangeError("request_too_large");
    }
    chunks.push(value);
  }

  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(merged);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function toHex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), (value) => value.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") {
    return reply(405, { error: "method_not_allowed" });
  }

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > 65536) {
    return reply(413, { error: "request_too_large" });
  }

  const webhookSecret = Deno.env.get("WAVE_SANDBOX_WEBHOOK_SECRET");
  const waveApiKey = Deno.env.get("WAVE_SANDBOX_API_KEY");
  const providerAccountId = Deno.env.get("WAVE_SANDBOX_PROVIDER_ACCOUNT_ID");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (
    !webhookSecret ||
    !waveApiKey ||
    !providerAccountId ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(providerAccountId) ||
    !supabaseUrl ||
    !serviceRoleKey
  ) {
    return reply(503, { error: "webhook_not_configured" });
  }

  let rawBody: string;
  try {
    const body = await readBodyBounded(request, 65536);
    if (body === null) return reply(400, { error: "empty_request" });
    rawBody = body;
  } catch (error) {
    if (error instanceof RangeError) return reply(413, { error: "request_too_large" });
    return reply(400, { error: "invalid_request_body" });
  }

  const signatureHeader = request.headers.get("Wave-Signature");
  const signature = await verifyWaveWebhookSignature({
    rawBody,
    signatureHeader,
    webhookSecret,
  });

  if (!signature.valid) {
    return reply(401, { error: "invalid_wave_signature" });
  }

  let event: unknown;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return reply(400, { error: "invalid_json" });
  }

  if (
    !isRecord(event) ||
    typeof event.id !== "string" ||
    event.id.length < 1 ||
    event.id.length > 255 ||
    typeof event.type !== "string" ||
    event.type.length < 1 ||
    event.type.length > 128
  ) {
    return reply(400, { error: "invalid_event_envelope" });
  }

  const data = isRecord(event.data) ? event.data : {};
  const payloadHash = toHex(await crypto.subtle.digest("SHA-256", encoder.encode(rawBody)));
  const payloadRedacted = {
    id: event.id,
    type: event.type,
    data: {
      id: typeof data.id === "string" ? data.id : null,
      amount: typeof data.amount === "string" ? data.amount : null,
      currency: typeof data.currency === "string" ? data.currency : null,
      checkout_status: typeof data.checkout_status === "string" ? data.checkout_status : null,
      payment_status: typeof data.payment_status === "string" ? data.payment_status : null,
      client_reference: typeof data.client_reference === "string" ? data.client_reference : null,
      transaction_id: typeof data.transaction_id === "string" ? data.transaction_id : null,
    },
  };

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  if (event.type !== "checkout.session.completed") {
    const { data: ignoredRows, error: ignoredError } = await supabase.rpc(
      "process_wave_checkout_event",
      {
        p_provider_account_id: providerAccountId,
        p_provider_event_id: event.id,
        p_event_type: event.type,
        p_checkout_session_id: typeof data.id === "string" ? data.id : null,
        p_transaction_id: null,
        p_client_reference: null,
        p_amount_xof: null,
        p_currency_code: null,
        p_checkout_status: null,
        p_payment_status: null,
        p_payload_sha256: payloadHash,
        p_signature_timestamp: new Date(signature.timestamp * 1000).toISOString(),
        p_payload_redacted: payloadRedacted,
      },
    );

    if (ignoredError || !Array.isArray(ignoredRows) || !ignoredRows[0]) {
      return reply(503, { error: "event_recording_failed" });
    }

    return reply(200, { received: true, result: ignoredRows[0].processing_result });
  }

  const amountString = data.amount;
  if (
    typeof data.id !== "string" ||
    typeof amountString !== "string" ||
    !/^[1-9]\d*$/.test(amountString) ||
    !Number.isSafeInteger(Number(amountString)) ||
    data.currency !== "XOF" ||
    data.checkout_status !== "complete" ||
    data.payment_status !== "succeeded" ||
    typeof data.client_reference !== "string" ||
    typeof data.transaction_id !== "string"
  ) {
    return reply(400, { error: "invalid_completed_checkout" });
  }

  try {
    const session = await retrieveWaveCheckoutSession({
      apiKey: waveApiKey,
      checkoutSessionId: data.id,
      amountXof: Number(amountString),
      clientReference: data.client_reference,
    });

    if (
      session.checkout_status !== "complete" ||
      session.payment_status !== "succeeded" ||
      session.transaction_id !== data.transaction_id
    ) {
      return reply(409, { error: "wave_session_verification_mismatch" });
    }

    const { data: processedRows, error: processingError } = await supabase.rpc(
      "process_wave_checkout_event",
      {
        p_provider_account_id: providerAccountId,
        p_provider_event_id: event.id,
        p_event_type: event.type,
        p_checkout_session_id: session.id,
        p_transaction_id: session.transaction_id,
        p_client_reference: session.client_reference,
        p_amount_xof: Number(session.amount),
        p_currency_code: session.currency,
        p_checkout_status: session.checkout_status,
        p_payment_status: session.payment_status,
        p_payload_sha256: payloadHash,
        p_signature_timestamp: new Date(signature.timestamp * 1000).toISOString(),
        p_payload_redacted: payloadRedacted,
      },
    );

    if (processingError || !Array.isArray(processedRows) || !processedRows[0]) {
      return reply(503, { error: "wallet_credit_processing_failed" });
    }

    return reply(200, {
      received: true,
      result: processedRows[0].processing_result,
    });
  } catch {
    // Provider or database uncertainty must be retried. The database RPC is
    // idempotent by provider event ID, payload hash and top-up identity.
    return reply(503, { error: "wave_event_temporarily_unavailable" });
  }
});
