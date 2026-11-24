import { createClient } from "npm:@supabase/supabase-js@2.49.1";
import {
  createWaveCheckoutSession,
  retrieveWaveCheckoutSession,
  searchWaveCheckoutByClientReference,
} from "../_shared/wave.js";

const jsonHeaders = { "Content-Type": "application/json; charset=utf-8" };

function reply(status: number, payload: Record<string, unknown>, cors: Record<string, string>) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...jsonHeaders, ...cors, "Cache-Control": "no-store" },
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

Deno.serve(async (request: Request) => {
  const allowedOrigin = Deno.env.get("BADDIELINK_ALLOWED_ORIGIN");
  const origin = request.headers.get("origin");
  const cors: Record<string, string> = allowedOrigin && origin === allowedOrigin
    ? {
        "Access-Control-Allow-Origin": allowedOrigin,
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Vary": "Origin",
      }
    : {};

  if (request.method === "OPTIONS") {
    if (!allowedOrigin || origin !== allowedOrigin) {
      return new Response(null, { status: 403, headers: cors });
    }
    return new Response(null, { status: 204, headers: cors });
  }

  if (request.method !== "POST") {
    return reply(405, { error: "method_not_allowed" }, cors);
  }

  if (!allowedOrigin || origin !== allowedOrigin) {
    return reply(403, { error: "origin_not_allowed" }, cors);
  }

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > 4096) {
    return reply(413, { error: "request_too_large" }, cors);
  }

  const authorization = request.headers.get("authorization");
  if (!authorization || !/^Bearer\s+\S+$/i.test(authorization)) {
    return reply(401, { error: "authentication_required" }, cors);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const waveApiKey = Deno.env.get("WAVE_SANDBOX_API_KEY");
  const successUrl = Deno.env.get("WAVE_SUCCESS_URL");
  const errorUrl = Deno.env.get("WAVE_ERROR_URL");

  if (!supabaseUrl || !supabaseAnonKey || !waveApiKey || !successUrl || !errorUrl) {
    return reply(503, { error: "checkout_not_configured" }, cors);
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userData, error: userError } = await supabase.auth.getUser();
  if (userError || !userData.user) {
    return reply(401, { error: "invalid_session" }, cors);
  }

  let body: unknown;
  try {
    const raw = await readBodyBounded(request, 4096);
    if (raw === null) return reply(400, { error: "empty_request" }, cors);
    body = JSON.parse(raw);
  } catch {
    return reply(400, { error: "invalid_json" }, cors);
  }

  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return reply(400, { error: "invalid_request" }, cors);
  }

  const input = body as Record<string, unknown>;
  const amountXof = input.amount_xof;
  const idempotencyKey = input.idempotency_key;

  if (typeof amountXof !== "number" || !Number.isSafeInteger(amountXof) || amountXof <= 0) {
    return reply(400, { error: "invalid_amount_xof" }, cors);
  }
  if (
    typeof idempotencyKey !== "string" ||
    idempotencyKey.trim().length < 16 ||
    idempotencyKey.length > 128
  ) {
    return reply(400, { error: "invalid_idempotency_key" }, cors);
  }

  const { data: createdRows, error: createError } = await supabase.rpc(
    "create_wave_topup",
    { p_amount_xof: amountXof, p_idempotency_key: idempotencyKey },
  );

  const topup = Array.isArray(createdRows) ? createdRows[0] : null;
  if (createError || !topup?.topup_id || !topup?.client_reference) {
    return reply(409, { error: "topup_request_rejected" }, cors);
  }

  const { data: claimRows, error: claimError } = await supabase.rpc(
    "claim_wave_checkout_creation",
    { p_topup_id: topup.topup_id },
  );
  const claim = Array.isArray(claimRows) ? claimRows[0] : null;

  if (claimError || !claim?.claim_status) {
    return reply(409, { error: "checkout_claim_failed" }, cors);
  }

  if (claim.claim_status === "in_progress") {
    return new Response(JSON.stringify({ error: "checkout_initializing", retry_after_seconds: 3 }), {
      status: 409,
      headers: {
        ...jsonHeaders,
        ...cors,
        "Cache-Control": "no-store",
        "Retry-After": "3",
      },
    });
  }

  try {
    let session;

    if (claim.claim_status === "already_attached") {
      session = await retrieveWaveCheckoutSession({
        apiKey: waveApiKey,
        checkoutSessionId: claim.checkout_session_id,
        amountXof: Number(topup.amount_xof),
        clientReference: topup.client_reference,
      });
    } else if (claim.claim_status === "claimed") {
      // Wave Checkout does not document an Idempotency-Key for session creation.
      // Search by our stable client_reference first so a retry can recover a
      // session created before a network timeout or process interruption.
      session = await searchWaveCheckoutByClientReference({
        apiKey: waveApiKey,
        amountXof: Number(topup.amount_xof),
        clientReference: topup.client_reference,
      });

      if (!session) {
        session = await createWaveCheckoutSession({
          apiKey: waveApiKey,
          amountXof: Number(topup.amount_xof),
          clientReference: topup.client_reference,
          successUrl,
          errorUrl,
        });
      }

      const { error: attachError } = await supabase.rpc(
        "attach_wave_checkout_session",
        {
          p_topup_id: topup.topup_id,
          p_checkout_session_id: session.id,
        },
      );

      if (attachError) {
        // Confirm persistence from our database, not from Wave's search API.
        // A provider session existing does not prove it is linked to this top-up.
        const { data: recoveryRows, error: recoveryError } = await supabase.rpc(
          "claim_wave_checkout_creation",
          { p_topup_id: topup.topup_id },
        );
        const recovery = Array.isArray(recoveryRows) ? recoveryRows[0] : null;

        if (
          recoveryError ||
          recovery?.claim_status !== "already_attached" ||
          recovery.checkout_session_id !== session.id
        ) {
          return reply(503, { error: "checkout_persistence_pending" }, cors);
        }

        session = await retrieveWaveCheckoutSession({
          apiKey: waveApiKey,
          checkoutSessionId: recovery.checkout_session_id,
          amountXof: Number(topup.amount_xof),
          clientReference: topup.client_reference,
        });
      }
    } else {
      return reply(409, { error: "checkout_state_conflict" }, cors);
    }

    return reply(200, {
      topup_id: topup.topup_id,
      amount_xof: Number(topup.amount_xof),
      currency: "XOF",
      checkout_url: session.wave_launch_url,
      checkout_status: session.checkout_status,
    }, cors);
  } catch {
    // Leave the top-up pending. The next request searches Wave by the same
    // client_reference before creating anything new.
    return reply(502, { error: "wave_checkout_temporarily_unavailable" }, cors);
  }
});
