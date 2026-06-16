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

  let p: {
    event_id?: string; tier_id?: string; quantity?: number;
    success_url?: string; cancel_url?: string;
    addons?: { addon_id?: string; quantity?: number }[];
    voucher_code?: string;
  };
  try { p = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }
  const { event_id, tier_id, success_url, cancel_url } = p;
  const quantity = p.quantity ?? 1;
  const addonReq = Array.isArray(p.addons) ? p.addons : [];
  const voucherCode = (p.voucher_code ?? "").trim();
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

  // Voucher (pretix-style access token) — validated server-side. May bypass a
  // sold-out tier and/or pin a price; consumed on fulfillment by a DB trigger
  // (exos_checkout_consume_voucher). Distinct from discount codes.
  let voucherId: string | null = null;
  let bypassCapacity = false;
  let overridePrice: number | null = null;
  if (voucherCode) {
    const { data: vRows, error: vErr } = await sb.rpc("exos_check_voucher", {
      p_event_id: event_id, p_code: voucherCode, p_email: user.email ?? null,
    });
    const v = Array.isArray(vRows) ? vRows[0] : vRows;
    if (vErr || !v?.is_valid) {
      return json({ error: `voucher ${v?.reason ?? "invalid"}` }, 409);
    }
    if (v.restrict_tier_id && v.restrict_tier_id !== tier_id) {
      return json({ error: "voucher is not valid for this ticket type" }, 409);
    }
    voucherId = v.voucher_id;
    bypassCapacity = v.can_bypass === true;
    overridePrice = v.override_price != null ? Number(v.override_price) : null;
  }

  if (!bypassCapacity && tier.capacity > 0 && tier.sold + quantity > tier.capacity) {
    return json({ error: "not enough tickets in this tier" }, 409);
  }

  // Per-person buy limit (maxPerOrder + cumulative maxPerAccount). Same check as
  // the comp path; counts tickets this buyer already holds, so a SECOND purchase
  // that would exceed the limit is refused before a Stripe session is created.
  const { error: limitErr } = await sb.rpc("exos_assert_purchase_limit", {
    p_event_id: event_id,
    p_buyer: user.id,
    p_qty: quantity,
  });
  if (limitErr) {
    return json({ error: limitErr.message || "purchase limit exceeded" }, 409);
  }

  const { data: secrets } = await sb.from("exos_org_secrets").select("payments").eq("org_id", ev.org_id).maybeSingle();
  const payments = (secrets?.payments ?? {}) as { connectedAccountId?: string; chargesEnabled?: boolean };
  if (!payments.connectedAccountId || !payments.chargesEnabled) {
    return json({ error: "organizer has not completed payment setup" }, 409);
  }

  const currency = (ev.currency ?? "usd").toLowerCase();
  // A voucher price override pins the per-ticket price (comp / special rate).
  const unitAmount = Math.round(Number(overridePrice ?? tier.price) * 100);

  // Validate + price add-ons server-side (never trust the client's prices). Each
  // must belong to this event, be public, and have stock. Build the priced
  // snapshot stored on the session (fulfillment reads it to record the purchase).
  type AddonRow = { addon_id: string; quantity: number; unit_price_cents: number; name: string };
  const addonsForSession: AddonRow[] = [];
  let addonTotal = 0;
  if (addonReq.length > 0) {
    // Aggregate duplicate addon_ids FIRST so max_per_order + capacity apply to
    // the COMBINED quantity — otherwise a client could split one add-on across
    // entries ([{X,N},{X,N}]) and slip past the per-order/stock ceilings (each
    // entry checked in isolation), then fulfillment bumps sold per entry with no
    // re-check → oversell.
    const wanted = new Map<string, number>();
    for (const req of addonReq) {
      const id = req.addon_id;
      const qty = Number(req.quantity) || 0;
      if (!id || qty < 1) continue;
      wanted.set(id, (wanted.get(id) ?? 0) + qty);
    }
    const ids = [...wanted.keys()];
    if (ids.length > 0) {
      const { data: catalog, error: addErr } = await sb
        .from("exos_event_addons")
        .select("id, name, price, capacity, sold, max_per_order, visibility, event_id")
        .eq("event_id", event_id).in("id", ids);
      if (addErr) return json({ error: "could not load add-ons" }, 500);
      const byId = new Map((catalog ?? []).map((a) => [a.id, a]));
      for (const [id, qty] of wanted) {
        const a = byId.get(id);
        if (!a || a.visibility !== "public") return json({ error: "add-on not available" }, 409);
        if (a.max_per_order && qty > a.max_per_order) {
          return json({ error: `add-on "${a.name}" limited to ${a.max_per_order} per order` }, 409);
        }
        if (a.capacity > 0 && a.sold + qty > a.capacity) {
          return json({ error: `add-on "${a.name}" is sold out` }, 409);
        }
        const unitCents = Math.round(Number(a.price) * 100);
        addonsForSession.push({ addon_id: a.id, quantity: qty, unit_price_cents: unitCents, name: a.name });
        addonTotal += unitCents * qty;
      }
    }
  }

  const amountCents = unitAmount * quantity + addonTotal;
  const feeBps = Number(Deno.env.get("EXOS_PLATFORM_FEE_BPS") ?? "500");
  const applicationFee = Math.round((amountCents * feeBps) / 10000);

  // Only PAID line items go to Stripe ($0 lines are rejected in payment mode), so
  // a free tier + paid add-ons charges just the add-ons. Ticket quantity is still
  // recorded on the session for minting regardless of the tier's price.
  const lineItems: Stripe.Checkout.SessionCreateParams.LineItem[] = [];
  if (unitAmount > 0) {
    lineItems.push({
      quantity,
      price_data: { currency, unit_amount: unitAmount, product_data: { name: `${ev.name} — ${tier.name}` } },
    });
  }
  for (const a of addonsForSession) {
    if (a.unit_price_cents > 0) {
      lineItems.push({
        quantity: a.quantity,
        price_data: { currency, unit_amount: a.unit_price_cents, product_data: { name: `${ev.name} — ${a.name}` } },
      });
    }
  }
  if (lineItems.length === 0) {
    return json({ error: "nothing to charge — use the free claim path" }, 400);
  }

  const stripe = new Stripe(stripeKey, { httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20" });

  let session: Stripe.Checkout.Session;
  try {
    session = await stripe.checkout.sessions.create({
      mode: "payment",
      line_items: lineItems,
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
    addons: addonsForSession.length > 0 ? addonsForSession : null,
    voucher_id: voucherId,
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
