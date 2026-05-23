// exos-checkout — create a Stripe Checkout Session for an event/tier (D4-OPS-7 SCAFFOLD).
//
// Buyer must be AUTHENTICATED (they need a uid to own the minted tickets +
// see them in-app). Destination charge to the org's connected account + an
// application fee. Records a 'pending' row in exos_checkout_sessions keyed on
// the Stripe session id; the stripe-webhook fulfills it on completion.
//
// Required secrets: STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_ANON_KEY,
// SUPABASE_SERVICE_ROLE_KEY. Optional: EXOS_PLATFORM_FEE_BPS (default 500 = 5%).
//
// TODO(operator) before go-live: confirm the application-fee model/%, the
// charge model (destination vs direct), and that 'standard' Connect accounts
// are the right type.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);

  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
  if (!stripeKey) return json({ error: "server misconfigured: STRIPE_SECRET_KEY unset" }, 500);

  // Authenticate the buyer from their JWT.
  const authHeader = req.headers.get("Authorization") ?? "";
  const sbUser = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user } } = await sbUser.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  let p: { event_id?: string; tier_id?: string; quantity?: number; success_url?: string; cancel_url?: string };
  try { p = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }
  const { event_id, tier_id, success_url, cancel_url } = p;
  const quantity = p.quantity ?? 1;
  if (!event_id || !tier_id || !success_url || !cancel_url) {
    return json({ error: "missing event_id / tier_id / success_url / cancel_url" }, 400);
  }
  if (!Number.isInteger(quantity) || quantity < 1 || quantity > 10) {
    return json({ error: "quantity must be 1-10" }, 400);
  }

  // Trusted reads (price/capacity/connected account) + ledger write via service_role.
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data: tier, error: tierErr } = await sb
    .from("exos_ticket_tiers")
    .select("id, name, price, capacity, sold, event_id, exos_events!inner(id, org_id, name, status, currency)")
    .eq("id", tier_id).eq("event_id", event_id).maybeSingle();
  if (tierErr || !tier) return json({ error: "tier not found" }, 404);

  const ev = (tier as unknown as { exos_events: { org_id: string; name: string; status: string; currency: string | null } }).exos_events;
  if (ev.status !== "published") return json({ error: "event not on sale" }, 409);
  if (tier.capacity > 0 && tier.sold + quantity > tier.capacity) {
    return json({ error: "not enough tickets in this tier" }, 409);
  }

  const { data: secrets } = await sb.from("exos_org_secrets").select("payments").eq("org_id", ev.org_id).maybeSingle();
  const payments = (secrets?.payments ?? {}) as { connectedAccountId?: string; chargesEnabled?: boolean };
  if (!payments.connectedAccountId || !payments.chargesEnabled) {
    return json({ error: "organizer has not completed payment setup" }, 409);
  }

  const currency = (ev.currency ?? "usd").toLowerCase();
  const unitAmount = Math.round(Number(tier.price) * 100);
  const amountCents = unitAmount * quantity;
  const feeBps = Number(Deno.env.get("EXOS_PLATFORM_FEE_BPS") ?? "500");
  const applicationFee = Math.round((amountCents * feeBps) / 10000);

  const stripe = new Stripe(stripeKey, { httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20" });

  let session: Stripe.Checkout.Session;
  try {
    session = await stripe.checkout.sessions.create({
      mode: "payment",
      line_items: [{
        quantity,
        price_data: {
          currency,
          unit_amount: unitAmount,
          product_data: { name: `${ev.name} — ${tier.name}` },
        },
      }],
      payment_intent_data: {
        application_fee_amount: applicationFee,
        transfer_data: { destination: payments.connectedAccountId },
      },
      success_url,
      cancel_url,
      customer_email: user.email ?? undefined,
      metadata: { exos_event_id: event_id, exos_tier_id: tier_id, exos_buyer_uid: user.id },
    });
  } catch (e) {
    console.error("exos-checkout: stripe session create failed", e);
    return json({ error: "could not create checkout session" }, 502);
  }

  const { error: insErr } = await sb.from("exos_checkout_sessions").insert({
    session_id: session.id,
    event_id, tier_id, org_id: ev.org_id,
    buyer_uid: user.id, buyer_email: (user.email ?? "").toLowerCase(),
    quantity, amount_cents: amountCents, currency, status: "pending",
  });
  if (insErr) {
    console.error("exos-checkout: ledger insert failed", insErr);
    return json({ error: "could not record session" }, 500);
  }

  return json({ url: session.url, session_id: session.id });
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
