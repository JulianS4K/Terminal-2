// exos-reconcile-checkouts — safety net for charged-but-no-ticket (audit 2026-07-02).
//
// Auth: cron-secret (X-Cron-Secret) via the shared requireCronSecret — this is a
// machine-invoked sweep that spends money (issues refunds) and mints tickets, so
// per Hard Rule #7 the body-level cron gate is mandatory (platform verify_jwt is
// not sufficient).
//
// Two reconciliations, each bounded per run:
//   1. PENDING sessions older than a grace window whose Stripe checkout actually
//      settled (webhook missed/delayed) -> exos_fulfill_checkout (idempotent mint).
//      An expired-unpaid Stripe session -> mark our row 'expired'.
//   2. FAILED sessions (e.g. sold-out-at-fulfillment) that nonetheless captured a
//      payment -> auto-refund via Stripe (idempotency-keyed) and mark 'refunded'.
//
// Required secrets (operator, at deploy): STRIPE_SECRET_KEY, CRON_SECRET,
// SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (platform-injected). Deploy like the
// other cron fns; scheduled by mig 20260702133000.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";

const stripeKey = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const stripe = new Stripe(stripeKey, {
  httpClient: Stripe.createFetchHttpClient(),
  apiVersion: "2024-06-20",
});

// Don't fight the normal webhook: only touch sessions older than this.
const GRACE_MS = 15 * 60 * 1000;
const BATCH = 100;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;
  if (!stripeKey) return new Response("server misconfigured: STRIPE_SECRET_KEY unset", { status: 500 });

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const out = { checked: 0, fulfilled: 0, expired: 0, refunded: 0, errors: 0 };
  const cutoff = new Date(Date.now() - GRACE_MS).toISOString();

  // 1. Pending-but-maybe-paid: ask Stripe the source of truth.
  const { data: pending } = await sb
    .from("exos_checkout_sessions")
    .select("session_id")
    .eq("status", "pending")
    .lt("created_at", cutoff)
    .limit(BATCH);

  for (const row of pending ?? []) {
    out.checked++;
    try {
      const cs = await stripe.checkout.sessions.retrieve(row.session_id);
      if (cs.payment_status === "paid" || cs.payment_status === "no_payment_required") {
        // Webhook never landed — mint now. exos_fulfill_checkout is idempotent.
        const { error } = await sb.rpc("exos_fulfill_checkout", { p_session_id: row.session_id });
        if (error) { out.errors++; continue; }
        const pi = typeof cs.payment_intent === "string" ? cs.payment_intent : cs.payment_intent?.id;
        if (pi) await sb.from("exos_checkout_sessions").update({ payment_intent: pi }).eq("session_id", row.session_id);
        out.fulfilled++;
      } else if (cs.status === "expired") {
        await sb.from("exos_checkout_sessions")
          .update({ status: "expired", failure_reason: "checkout session expired unpaid" })
          .eq("session_id", row.session_id).eq("status", "pending");
        out.expired++;
      }
      // else: still legitimately awaiting payment — leave it.
    } catch (_e) {
      out.errors++;
    }
  }

  // 2. Failed-but-charged: auto-refund so a buyer is never charged with no ticket.
  const { data: failed } = await sb
    .from("exos_checkout_sessions")
    .select("session_id, failure_reason")
    .eq("status", "failed")
    .limit(BATCH);

  for (const row of failed ?? []) {
    try {
      const cs = await stripe.checkout.sessions.retrieve(row.session_id);
      const pi = typeof cs.payment_intent === "string" ? cs.payment_intent : cs.payment_intent?.id;
      if (cs.payment_status === "paid" && pi) {
        // Idempotency key makes an accidental double-sweep a no-op at Stripe.
        await stripe.refunds.create(
          { payment_intent: pi, reason: "requested_by_customer" },
          { idempotencyKey: `exos_refund_${row.session_id}` },
        );
        await sb.from("exos_checkout_sessions")
          .update({
            status: "refunded",
            failure_reason: `${row.failure_reason ? row.failure_reason + " " : ""}(auto-refunded by reconcile)`,
          })
          .eq("session_id", row.session_id).eq("status", "failed");
        out.refunded++;
      }
      // else: failed and never charged (abandoned) — nothing to refund.
    } catch (_e) {
      out.errors++;
    }
  }

  return new Response(JSON.stringify(out), { headers: { "Content-Type": "application/json" } });
});
