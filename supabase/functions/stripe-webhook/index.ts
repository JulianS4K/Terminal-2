// stripe-webhook — Stripe -> Exos fulfillment (D4-OPS-7 SCAFFOLD).
//
// Auth: Stripe webhook SIGNATURE verification (constructEventAsync with the
// endpoint's signing secret) — NOT the cron secret. The signature IS the auth
// for a Stripe webhook; Hard Rule #7's cron gate applies to cron-invoked fns.
//
// On `checkout.session.completed` -> exos_fulfill_checkout() (idempotent mint,
// keyed on the session id, so Stripe's at-least-once retries mint exactly once).
// On `account.updated` -> exos_record_org_stripe() (Connect onboarding status).
//
// Required secrets (operator, at deploy): STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET,
// SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (platform-injected).
//
// Deploy note: this endpoint must NOT require a JWT (Stripe can't send one) —
// deploy with --no-verify-jwt; the Stripe signature is the gate.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const stripeKey = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const stripe = new Stripe(stripeKey, {
  httpClient: Stripe.createFetchHttpClient(),
  apiVersion: "2024-06-20",
});
const cryptoProvider = Stripe.createSubtleCryptoProvider();

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!webhookSecret || !stripeKey) {
    return new Response("server misconfigured: STRIPE_* unset", { status: 500 });
  }

  const sig = req.headers.get("stripe-signature");
  if (!sig) return new Response("missing stripe-signature", { status: 400 });

  const body = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, sig, webhookSecret, undefined, cryptoProvider);
  } catch (e) {
    console.error("stripe-webhook: signature verification failed", e);
    return new Response("invalid signature", { status: 400 });
  }

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        // Only fulfill once payment has actually settled. `status==='complete'`
        // also fires for delayed/async methods (ACH/SEPA/etc.) while
        // payment_status is still 'unpaid'/'processing' — gating on it would
        // mint tickets before the money arrives, and an async_payment_failed
        // later can't unwind them. Gate strictly on a settled payment_status.
        if (session.payment_status === "paid" || session.payment_status === "no_payment_required") {
          const { error } = await sb.rpc("exos_fulfill_checkout", { p_session_id: session.id });
          if (error) {
            // 500 -> Stripe retries. exos_fulfill_checkout is idempotent, so a
            // retry after a partial failure is safe. A hard 'sold out at
            // fulfillment' marks the session 'failed' (operator refunds — TODO).
            console.error(`stripe-webhook: fulfill failed for ${session.id}`, error);
            return new Response("fulfillment error", { status: 500 });
          }
          if (typeof session.payment_intent === "string") {
            await sb.from("exos_checkout_sessions")
              .update({ payment_intent: session.payment_intent })
              .eq("session_id", session.id);
          }
        }
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
        // Full refund of a paid order -> void its tickets + free inventory.
        // Map the charge back to our session via the stored payment_intent.
        const charge = event.data.object as Stripe.Charge;
        const pi = typeof charge.payment_intent === "string"
          ? charge.payment_intent
          : charge.payment_intent?.id;
        if (pi) {
          const { data: sess } = await sb.from("exos_checkout_sessions")
            .select("session_id").eq("payment_intent", pi).maybeSingle();
          if (sess?.session_id) {
            const { error } = await sb.rpc("exos_refund_checkout", {
              p_session_id: sess.session_id,
              p_reason: "stripe refund",
            });
            if (error) {
              // 500 -> Stripe retries; exos_refund_checkout is idempotent.
              console.error(`stripe-webhook: refund handling failed for ${sess.session_id}`, error);
              return new Response("refund handling error", { status: 500 });
            }
          }
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
