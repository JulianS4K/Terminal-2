// stripe-webhook — Stripe -> Exos fulfillment + money reconciliation.
//
// Auth: Stripe webhook SIGNATURE verification (constructEventAsync with the
// endpoint's signing secret) — NOT the cron secret. The signature IS the auth
// for a Stripe webhook; Hard Rule #7's cron gate applies to cron-invoked fns.
//
// Events handled:
//   checkout.session.completed / .async_payment_succeeded
//     -> exos_fulfill_checkout() (idempotent mint keyed on session id). If the
//        settled payment can't be fulfilled (sold out / quota / limit / voucher
//        exhausted at fulfillment), the buyer has already been charged, so we
//        AUTO-REFUND via Stripe (idempotency-keyed) and record it — no silent
//        stranded charge. (Was: "operator refunds — TODO".)
//   checkout.session.async_payment_failed -> mark the pending session failed.
//   checkout.session.expired              -> mark the pending session expired.
//   charge.refunded  -> record the refund(s) in the ledger; VOID tickets only on
//                       a FULL refund. A partial refund is recorded (session ->
//                       partially_refunded) but does NOT void the whole order —
//                       which tickets to cancel is an operator decision, not
//                       derivable from a Stripe amount.
//   charge.dispute.created -> void the order's tickets (a charged-back buyer must
//                             not keep valid entry) + record.
//   account.updated  -> exos_record_org_stripe() (Connect onboarding status).
//
// Idempotency: fulfillment (session status gate), refund recording (unique
// refund_id), and refund voiding (session status gate) are each idempotent, so
// Stripe's at-least-once retries and event replays are safe. Auto-refund also
// passes a Stripe idempotency key so a retry can't double-refund.
//
// Session<->PaymentIntent mapping is resolved through the LEDGER first
// (exos_order_payments, written by exos_record_payment) and only falls back to
// the best-effort session.payment_intent column — so a dropped column write
// can't strand a refund/dispute.
//
// Required secrets (operator, at deploy): STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET,
// SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (platform-injected). Optional:
// STRIPE_CONNECT_WEBHOOK_SECRET — the signing secret of the second endpoint that
// listens to connected accounts (needed for organizers' account.updated).
//
// Deploy note: this endpoint must NOT require a JWT (Stripe can't send one) —
// deploy with --no-verify-jwt; the Stripe signature is the gate.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const stripeKey = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const stripe = new Stripe(stripeKey, {
  httpClient: Stripe.createFetchHttpClient(),
  apiVersion: "2024-06-20",
});
const cryptoProvider = Stripe.createSubtleCryptoProvider();

// Resolve a Stripe PaymentIntent id back to our checkout session id. The ledger
// (exos_order_payments) is the reliable source — exos_record_payment persists
// the PI on the settled-payment path — with the best-effort session column as a
// fallback. Returns null if neither knows the PI.
async function sessionIdForPaymentIntent(
  sb: SupabaseClient,
  pi: string,
): Promise<string | null> {
  const { data: pay } = await sb.from("exos_order_payments")
    .select("session_id").eq("payment_intent", pi).maybeSingle();
  if (pay?.session_id) return pay.session_id as string;
  const { data: sess } = await sb.from("exos_checkout_sessions")
    .select("session_id").eq("payment_intent", pi).maybeSingle();
  return (sess?.session_id as string) ?? null;
}

// Fulfill a session whose payment has SETTLED (card `completed` or an async
// method's `async_payment_succeeded`). Throws on a hard/transient error so the
// caller returns 500 and Stripe retries (every step here is idempotent). On a
// graceful fulfillment failure (sold out / quota / limit / voucher) the buyer
// was still charged, so we auto-refund.
async function fulfillSettledSession(
  sb: SupabaseClient,
  session: Stripe.Checkout.Session,
): Promise<void> {
  const { error: fErr } = await sb.rpc("exos_fulfill_checkout", { p_session_id: session.id });
  if (fErr) {
    // exos_fulfill_checkout is idempotent, so a retry after a partial failure is
    // safe. Throw -> 500 -> Stripe redelivers.
    throw new Error(`fulfill failed for ${session.id}: ${fErr.message}`);
  }

  const pi = typeof session.payment_intent === "string"
    ? session.payment_intent
    : session.payment_intent?.id ?? null;

  // Persist the PaymentIntent on the session — CHECKED (was best-effort). This
  // column plus the ledger are the only links a later refund/dispute has back to
  // this order; a silently-dropped write used to strand them. 500 -> retry.
  if (pi) {
    const { error: upErr } = await sb.from("exos_checkout_sessions")
      .update({ payment_intent: pi }).eq("session_id", session.id);
    if (upErr) throw new Error(`payment_intent persist failed for ${session.id}: ${upErr.message}`);
  }

  // Ledger: record the settled payment as a first-class row (idempotent upsert
  // on the PI). This is what sessionIdForPaymentIntent() reads later.
  // Throw on failure (-> 500, Stripe retries): refunds find their session
  // through this row, so losing it strands every later refund.
  const { error: payErr } = await sb.rpc("exos_record_payment", {
    p_session_id: session.id,
    p_payment_intent: pi,
    p_amount_cents: session.amount_total ?? 0,
    p_status: "succeeded",
    p_currency: session.currency ?? "usd",
    p_provider_event_id: session.id,
  });
  if (payErr) throw new Error(`record_payment failed for ${session.id}: ${payErr.message}`);

  // Auto-refund a settled-but-unfulfillable order. exos_fulfill_checkout marks
  // the session 'failed' (not raise) when it can't mint after payment; without
  // this the buyer is charged and gets nothing. Only for real money (a paid PI).
  if (pi && session.payment_status === "paid") {
    const { data: sess } = await sb.from("exos_checkout_sessions")
      .select("status, amount_cents").eq("session_id", session.id).maybeSingle();
    if (sess?.status === "failed") {
      let refund: Stripe.Refund;
      try {
        refund = await stripe.refunds.create(
          {
            payment_intent: pi,
            reason: "requested_by_customer",
            // Destination charge: pull the funds back from the connected account
            // and return our fee, otherwise the platform balance pays the refund.
            reverse_transfer: true,
            refund_application_fee: true,
            metadata: { exos_session_id: session.id, exos_auto: "fulfillment_failed" },
          },
          { idempotencyKey: `exos_autorefund_${session.id}` },
        );
      } catch (e) {
        // Couldn't reach Stripe — 500 so we retry rather than drop the refund.
        throw new Error(`auto-refund create failed for ${session.id}: ${(e as Error).message}`);
      }
      const refundStatus = ["pending", "succeeded", "failed", "canceled"].includes(refund.status ?? "")
        ? refund.status
        : "pending";
      // The Stripe refund is idempotency-keyed, so a 500 + retry is safe.
      const { error: rfErr } = await sb.rpc("exos_record_refund", {
        p_session_id: session.id,
        p_refund_id: refund.id,
        p_amount_cents: refund.amount ?? sess.amount_cents ?? 0,
        p_status: refundStatus,
        p_payment_intent: pi,
        p_reason: "auto-refund: unfulfillable after payment",
        p_currency: refund.currency ?? session.currency ?? "usd",
        p_provider_event_id: session.id,
      });
      if (rfErr) throw new Error(`record_refund (auto) failed for ${session.id}: ${rfErr.message}`);
      console.error(`stripe-webhook: auto-refunded unfulfillable session ${session.id} (refund ${refund.id})`);
    }
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!webhookSecret || !stripeKey) {
    return new Response("server misconfigured: STRIPE_* unset", { status: 500 });
  }
  // Connected-account events (account.updated for organizers' Express accounts)
  // arrive on a separate "connected accounts" endpoint with its own signing
  // secret; both endpoints point here.
  const secrets = [webhookSecret, Deno.env.get("STRIPE_CONNECT_WEBHOOK_SECRET")]
    .filter((x): x is string => !!x);

  const sig = req.headers.get("stripe-signature");
  if (!sig) return new Response("missing stripe-signature", { status: 400 });

  const body = await req.text();
  let event: Stripe.Event | null = null;
  for (const secret of secrets) {
    try {
      event = await stripe.webhooks.constructEventAsync(body, sig, secret, undefined, cryptoProvider);
      break;
    } catch {
      // try the next endpoint's secret
    }
  }
  if (!event) {
    console.error("stripe-webhook: signature verification failed for every configured secret");
    return new Response("invalid signature", { status: 400 });
  }

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    switch (event.type) {
      // Card checkout AND delayed/async methods (ACH/SEPA/etc.) that settle later
      // both land here — completed fires immediately (often unpaid for async), and
      // async_payment_succeeded fires once the money clears. Gate on a settled
      // payment_status so we never mint before the money arrives.
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded": {
        const session = event.data.object as Stripe.Checkout.Session;
        if (session.payment_status === "paid" || session.payment_status === "no_payment_required") {
          try {
            await fulfillSettledSession(sb, session);
          } catch (e) {
            console.error(`stripe-webhook: settle handler error for ${session.id}`, e);
            return new Response("fulfillment error", { status: 500 });
          }
        }
        break;
      }

      // Async method failed to settle (e.g. ACH return): no money arrived, so
      // just retire the pending session. No refund (nothing was captured).
      case "checkout.session.async_payment_failed": {
        const session = event.data.object as Stripe.Checkout.Session;
        await sb.from("exos_checkout_sessions")
          .update({ status: "failed", failure_reason: "async payment failed" })
          .eq("session_id", session.id).eq("status", "pending");
        break;
      }

      // Buyer abandoned checkout / the session TTL lapsed. Mark it expired; the
      // cart hold reserved at create time is reclaimed by its TTL / the hold
      // sweeper (exos_expire_holds), not here.
      case "checkout.session.expired": {
        const session = event.data.object as Stripe.Checkout.Session;
        await sb.from("exos_checkout_sessions")
          .update({ status: "expired" })
          .eq("session_id", session.id).eq("status", "pending");
        break;
      }

      case "account.updated": {
        const acct = event.data.object as Stripe.Account;
        const orgId = acct.metadata?.exos_org_id;
        if (orgId) {
          const { error } = await sb.rpc("exos_record_org_stripe", {
            p_org_id: orgId,
            p_account_id: acct.id,
            p_charges_enabled: !!acct.charges_enabled,
            p_payouts_enabled: !!acct.payouts_enabled,
          });
          if (error) console.error("stripe-webhook: record org stripe failed", error);
        }
        break;
      }

      case "charge.refunded": {
        const charge = event.data.object as Stripe.Charge;
        const pi = typeof charge.payment_intent === "string"
          ? charge.payment_intent
          : charge.payment_intent?.id;
        if (!pi) break;
        const sessionId = await sessionIdForPaymentIntent(sb, pi);
        if (!sessionId) {
          console.error(`stripe-webhook: charge.refunded — no session for PI ${pi}`);
          break;
        }

        // charge.refunded fires for PARTIAL refunds too. Void the whole order
        // ONLY when the charge is fully refunded; a partial refund is recorded in
        // the ledger (reconciles session -> partially_refunded) but leaves the
        // tickets alone (cancelling specific ones is an operator action, not
        // derivable from a Stripe amount).
        const chargeAmount = charge.amount ?? 0;
        const fullyRefunded = chargeAmount > 0 && (charge.amount_refunded ?? 0) >= chargeAmount;

        // Void on a full refund, then record. exos_refund_checkout voids whatever
        // is still active regardless of session status (mig 20260924205115), so
        // the order no longer matters for correctness; voiding first just keeps
        // the session's failure_reason as the refund reason.
        if (fullyRefunded) {
          const { error } = await sb.rpc("exos_refund_checkout", {
            p_session_id: sessionId,
            p_reason: "stripe refund",
          });
          if (error) {
            // 500 -> Stripe retries; exos_refund_checkout is idempotent.
            console.error(`stripe-webhook: refund void failed for ${sessionId}`, error);
            return new Response("refund handling error", { status: 500 });
          }
        }

        // Record every refund on the PaymentIntent by its own id (idempotent on
        // refund_id). Since API 2022-11-15 the Charge no longer embeds
        // `refunds`, so list them; never record a cumulative amount under a NULL
        // id (it double-counted and could mark a session refunded without a void).
        // A failure returns 500 so Stripe retries instead of losing the refund.
        const allowed = new Set(["pending", "succeeded", "failed", "canceled"]);
        let refunds: Stripe.Refund[];
        try {
          refunds = [];
          for await (const rf of stripe.refunds.list({ payment_intent: pi, limit: 100 })) refunds.push(rf);
        } catch (e) {
          console.error(`stripe-webhook: listing refunds for PI ${pi} failed`, e);
          return new Response("refund lookup error", { status: 500 });
        }
        for (const rf of refunds) {
          const { error } = await sb.rpc("exos_record_refund", {
            p_session_id: sessionId,
            p_refund_id: rf.id,
            p_amount_cents: rf.amount ?? 0,
            p_status: allowed.has(rf.status ?? "") ? rf.status : "pending",
            p_payment_intent: pi,
            p_reason: rf.reason ?? "stripe refund",
            p_currency: rf.currency ?? charge.currency ?? "usd",
            p_provider_event_id: event.id,
          });
          if (error) {
            console.error(`stripe-webhook: record_refund ${rf.id} failed for ${sessionId}`, error);
            return new Response("refund record error", { status: 500 });
          }
        }
        break;
      }

      // Chargeback opened: the money is being clawed back, so the tickets must not
      // stay valid for entry. Void the order (idempotent). Mapping via the PI,
      // same as refunds.
      case "charge.dispute.created": {
        const dispute = event.data.object as Stripe.Dispute;
        const pi = typeof dispute.payment_intent === "string"
          ? dispute.payment_intent
          : dispute.payment_intent?.id ?? null;
        if (!pi) break;
        const sessionId = await sessionIdForPaymentIntent(sb, pi);
        if (!sessionId) {
          console.error(`stripe-webhook: dispute — no session for PI ${pi}`);
          break;
        }
        const { error } = await sb.rpc("exos_refund_checkout", {
          p_session_id: sessionId,
          p_reason: `chargeback dispute (${dispute.reason ?? "unknown"})`,
        });
        if (error) {
          console.error(`stripe-webhook: dispute void failed for ${sessionId}`, error);
          return new Response("dispute handling error", { status: 500 });
        }
        break;
      }

      default:
        break; // ignore unhandled event types
    }
  } catch (e) {
    console.error("stripe-webhook: handler threw", e);
    return new Response("handler error", { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
});
