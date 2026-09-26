// exos-webhook-drain — deliver queued Exos webhooks (Hi.Events parity).
//
// Cron-invoked (requireCronSecret). CLAIMS due rows via exos_webhook_claim_batch
// (mig 20260925020000: FOR UPDATE SKIP LOCKED + a lease — status 'sending',
// attempts+1, a claim_token), so overlapping runs never POST the same delivery
// twice; a run that dies leaves a lease that is reclaimed after LEASE_MINUTES.
// Every result write is guarded by the row's claim_token, so a run whose lease
// was taken over can't overwrite the newer attempt.
//
// Signing (Stripe-style, replay-resistant):
//   X-Exos-Timestamp: <unix seconds when this attempt was sent>
//   X-Exos-Signature: sha256=<hex HMAC-SHA256(secret, `${timestamp}.${rawBody}`)>
//   X-Exos-Delivery:  <delivery id — the same across retries; dedupe on it>
// Receiver verification recipe:
//   1. Read the raw request body as bytes/string (before any JSON parsing).
//   2. expected = hex(HMAC_SHA256(key = webhook secret, msg = ts + "." + body)).
//   3. Compare to the part after "sha256=" in constant time.
//   4. Reject if |now - ts| > 300 seconds (replay window).
//   5. Treat X-Exos-Delivery as an idempotency key (retries resend it).
// Failures retry with exponential backoff; after MAX_ATTEMPTS the row is 'dead'.
//
// SSRF guard (_shared/ssrf.ts): https-only; A + AAAA resolved and refused if any
// address is non-public; redirects disabled.
//
// Required secrets: CRON_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { urlIsBlocked } from "../_shared/ssrf.ts";

const MAX_ATTEMPTS = 8;
const BATCH = 20;
const TIMEOUT_MS = 8000;
// The lease must outlive a whole run: BATCH x TIMEOUT_MS is ~160s, and the run
// stops starting new sends after RUN_BUDGET_MS, handing unsent rows back.
const LEASE_MINUTES = 15;
const RUN_BUDGET_MS = 100_000;

type Claimed = {
  id: string; webhook_id: string; event_type: string; payload: unknown; attempts: number;
  claim_token: string; url: string; secret: string; enabled: boolean;
};

Deno.serve(async (req: Request): Promise<Response> => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const started = Date.now();

  const { data, error } = await sb.rpc("exos_webhook_claim_batch", {
    p_limit: BATCH, p_max_attempts: MAX_ATTEMPTS, p_lease_minutes: LEASE_MINUTES,
  });
  if (error) {
    console.error("exos-webhook-drain: claim failed", error);
    return json({ error: "claim failed" }, 500);
  }
  const claimed = (data ?? []) as Claimed[];

  let delivered = 0, failed = 0, dead = 0, skipped = 0, released = 0;

  // Result writes only land while we still hold the lease.
  const finish = (row: Claimed, patch: Record<string, unknown>) =>
    sb.from("exos_webhook_deliveries")
      .update({ ...patch, claim_token: null })
      .eq("id", row.id).eq("status", "sending").eq("claim_token", row.claim_token);

  for (const row of claimed) {
    // Out of time: hand the row back untouched (undo the claim's attempt).
    if (Date.now() - started > RUN_BUDGET_MS) {
      await finish(row, { status: "pending", attempts: Math.max(row.attempts - 1, 0) });
      released++;
      continue;
    }

    // Disabled mid-flight → drop quietly.
    if (!row.enabled) {
      await finish(row, { status: "dead", last_error: "webhook disabled" });
      skipped++;
      continue;
    }

    const ssrf = await urlIsBlocked(row.url);
    if (ssrf) {
      await finish(row, { status: "dead", last_error: `blocked url: ${ssrf}` });
      dead++;
      continue;
    }

    const body = JSON.stringify(row.payload);
    const ts = Math.floor(Date.now() / 1000).toString();
    const sig = await hmacHex(row.secret, `${ts}.${body}`);
    let ok = false, code: number | null = null, errText: string | null = null;
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
    try {
      const res = await fetch(row.url, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "user-agent": "Exos-Webhooks/1.0",
          "x-exos-event": String(row.event_type),
          "x-exos-delivery": String(row.id),
          "x-exos-timestamp": ts,
          "x-exos-signature": `sha256=${sig}`,
        },
        body,
        signal: ctrl.signal,
        redirect: "manual", // a 3xx to an internal host would defeat the SSRF check
      });
      code = res.status;
      ok = res.status >= 200 && res.status < 300;
      if (!ok) errText = `http ${res.status}`;
      await res.body?.cancel();
    } catch (e) {
      errText = e instanceof Error ? e.message : "fetch failed";
    } finally {
      clearTimeout(timer);
    }

    // attempts was already incremented by the claim.
    if (ok) {
      await finish(row, {
        status: "delivered", last_status_code: code, last_error: null,
        delivered_at: new Date().toISOString(),
      });
      delivered++;
    } else if (row.attempts >= MAX_ATTEMPTS) {
      await finish(row, { status: "dead", last_status_code: code, last_error: errText });
      dead++;
    } else {
      // Exponential backoff: ~2^attempts minutes, capped at 6h.
      const backoffMs = Math.min(2 ** row.attempts * 60_000, 6 * 3600_000);
      await finish(row, {
        status: "pending", last_status_code: code, last_error: errText,
        next_attempt_at: new Date(Date.now() + backoffMs).toISOString(),
      });
      failed++;
    }
  }

  return json({ processed: claimed.length, delivered, failed, dead, skipped, released });
});

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
