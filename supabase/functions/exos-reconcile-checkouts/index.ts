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
//      payment -> auto-refund via Stripe and mark 'refunded'. Uses the SAME
//      idempotency key + params as stripe-webhook (_shared/auto-refund.ts) and
//      checks Stripe's existing refunds first, so the two paths can't both
//      refund. Each session is stamped by exos_reconcile_mark (mig
//      20260925020000) so the sweep makes progress instead of re-reading the
//      same newest rows.
//
// Required secrets (operator, at deploy): STRIPE_SECRET_KEY, CRON_SECRET,
// SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (platform-injected). Deploy like the
// other cron fns; scheduled by mig 20260702133000.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { autoRefundIdempotencyKey, autoRefundParams, ledgerRefundStatus } from "../_shared/auto-refund.ts";

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

  const out = { checked: 0, fulfilled: 0, expired: 0, swept: 0, refunded: 0, already_refunded: 0, errors: 0 };
  const cutoff = new Date(Date.now() - GRACE_MS).toISOString();

  // 1. Pending-but-maybe-paid: ask Stripe the source of truth.
  const { data: pending } = await sb
    .from("exos_checkout_sessions")
    .select("session_id")
    .eq("status", "pending")
    .lt("created_at", cutoff)
    .order("created_at", { ascending: false })
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
        if (pi) {
          const { error: piErr } = await sb.from("exos_checkout_sessions")
            .update({ payment_intent: pi }).eq("session_id", row.session_id);
          if (piErr) { console.error(`reconcile: payment_intent persist failed for ${row.session_id}`, piErr); out.errors++; }
        }
        out.fulfilled++;
      } else if (cs.status === "expired") {
        const { error: exErr } = await sb.from("exos_checkout_sessions")
          .update({ status: "expired", failure_reason: "checkout session expired unpaid" })
          .eq("session_id", row.session_id).eq("status", "pending");
        if (exErr) { console.error(`reconcile: expire failed for ${row.session_id}`, exErr); out.errors++; continue; }
        out.expired++;
      }
      // else: still legitimately awaiting payment — leave it.
    } catch (e) {
      console.error(`reconcile: pending sweep failed for ${row.session_id}`, e);
      out.errors++;
    }
  }

  // 2. Failed-but-charged: auto-refund so a buyer is never charged with no ticket.
  //    Progress, not starvation: every session looked at is stamped
  //    (exos_reconcile_mark) — done when there's nothing left to do, otherwise
  //    re-checked later with backoff — and the batch reads never-checked / due
  //    rows first, oldest first. The same unrefundable rows can no longer fill
  //    every batch.
  const { data: failed } = await sb
    .from("exos_checkout_sessions")
    .select("session_id, failure_reason")
    .eq("status", "failed")
    .is("reconcile_done_at", null)
    .lt("created_at", cutoff)
    .or(`reconcile_next_at.is.null,reconcile_next_at.lte.${new Date().toISOString()}`)
    .order("reconcile_next_at", { ascending: true, nullsFirst: true })
    .order("created_at", { ascending: true })
    .limit(BATCH);

  const mark = async (sessionId: string, done: boolean, note: string) => {
    const { error } = await sb.rpc("exos_reconcile_mark", { p_session_id: sessionId, p_done: done, p_note: note });
    if (error) { console.error(`reconcile: mark failed for ${sessionId}`, error); out.errors++; }
  };

  for (const row of failed ?? []) {
    out.swept++;
    try {
      const cs = await stripe.checkout.sessions.retrieve(row.session_id);
      const pi = typeof cs.payment_intent === "string" ? cs.payment_intent : cs.payment_intent?.id;
      if (cs.payment_status !== "paid" || !pi) {
        // Never charged. Expired or complete-but-unpaid (async failure) can't
        // be charged any more → done; an open session is re-checked later.
        const final = cs.status === "expired" || cs.status === "complete";
        await mark(row.session_id, final, final ? `not charged (stripe ${cs.status})` : "not charged yet (open)");
        continue;
      }

      // Already refunded (by the webhook, an operator, or an earlier sweep)?
      // Ask Stripe, record what it has (idempotent on refund id), and don't
      // refund again. Also covers Stripe's 24h idempotency-key expiry.
      const existing: Stripe.Refund[] = [];
      for await (const rf of stripe.refunds.list({ payment_intent: pi, limit: 100 })) existing.push(rf);
      let recordFailed = false;
      for (const rf of existing) {
        const { error } = await sb.rpc("exos_record_refund", {
          p_session_id: row.session_id,
          p_refund_id: rf.id,
          p_amount_cents: rf.amount ?? 0,
          p_status: ledgerRefundStatus(rf.status),
          p_payment_intent: pi,
          p_reason: rf.reason ?? "stripe refund",
          p_currency: rf.currency ?? "usd",
        });
        if (error) { console.error(`reconcile: record_refund ${rf.id} failed for ${row.session_id}`, error); recordFailed = true; }
      }
      if (recordFailed) { out.errors++; await mark(row.session_id, false, "refund ledger write failed"); continue; }
      const live = existing.filter((rf) => rf.status === "succeeded" || rf.status === "pending");
      const covered = live.reduce((n, rf) => n + (rf.amount ?? 0), 0);
      const paid = cs.amount_total ?? 0;
      if (live.length > 0 && covered >= paid) {
        const settled = live.every((rf) => rf.status === "succeeded");
        await mark(row.session_id, settled, settled ? "already refunded" : "refund pending at stripe");
        out.already_refunded++;
        continue;
      }

      // Same key + params as stripe-webhook's auto-refund (_shared/auto-refund.ts):
      // if both paths fire for one session, Stripe returns the first refund.
      const refund = await stripe.refunds.create(
        autoRefundParams(pi, row.session_id),
        { idempotencyKey: autoRefundIdempotencyKey(row.session_id) },
      );
      // Ledger row by Stripe refund id (idempotent); it also moves the
      // session to 'refunded' once refunds cover the amount paid.
      const { error: rfErr } = await sb.rpc("exos_record_refund", {
        p_session_id: row.session_id,
        p_refund_id: refund.id,
        p_amount_cents: refund.amount ?? 0,
        p_status: ledgerRefundStatus(refund.status),
        p_payment_intent: pi,
        p_reason: "auto-refund by reconcile: unfulfillable after payment",
        p_currency: refund.currency ?? "usd",
      });
      if (rfErr) {
        console.error(`reconcile: record_refund failed for ${row.session_id}`, rfErr);
        out.errors++;
        await mark(row.session_id, false, "refund issued; ledger write failed");
        continue;
      }
      if (refund.status === "succeeded") {
        const { error: stErr } = await sb.from("exos_checkout_sessions")
          .update({
            status: "refunded",
            failure_reason: `${row.failure_reason ? row.failure_reason + " " : ""}(auto-refunded by reconcile)`,
          })
          .eq("session_id", row.session_id).in("status", ["failed", "refunded"]);
        if (stErr) { console.error(`reconcile: status update failed for ${row.session_id}`, stErr); out.errors++; }
      }
      await mark(row.session_id, refund.status === "succeeded", `auto-refund ${refund.id} ${refund.status ?? ""}`.trim());
      out.refunded++;
    } catch (e) {
      console.error(`reconcile: refund sweep failed for ${row.session_id}`, e);
      out.errors++;
      await mark(row.session_id, false, `error: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  return new Response(JSON.stringify(out), { headers: { "Content-Type": "application/json" } });
});
