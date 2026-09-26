// exos-checkout — create a Stripe Checkout Session for an event/tier (D4-OPS-7 SCAFFOLD).
//
// Buyer must be AUTHENTICATED (they need a uid to own the minted tickets +
// see them in-app). Destination charge to the org's connected account + an
// application fee. Records a 'pending' row in exos_checkout_sessions keyed on
// the Stripe session id; the stripe-webhook fulfills it on completion.
//
// Required secrets: STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_ANON_KEY,
// SUPABASE_SERVICE_ROLE_KEY, EXOS_REDIRECT_ORIGINS (origins success/cancel URLs
// may point at; see _shared/redirects.ts). Optional: EXOS_PLATFORM_FEE_BPS (default 500 = 5%).
// Needs mig 20260924223000 (promoter_id / attribution columns) applied first.
//
// TODO(operator) before go-live: confirm the application-fee model/%, the
// charge model (destination vs direct), and that 'standard' Connect accounts
// are the right type.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { allInCents, effectiveTierPrice } from "../_shared/pricing.ts";
import { isAllowedRedirect, parseRedirectOrigins } from "../_shared/redirects.ts";
import { isEmptyAttribution, readAttribution } from "../_shared/attribution.ts";

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
    // Promoter code + UTM / fbclid / cart_origin from the landing URL.
    attribution?: Record<string, unknown>;
  };
  try { p = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }
  const { event_id, tier_id, success_url, cancel_url } = p;
  const quantity = p.quantity ?? 1;
  const addonReq = Array.isArray(p.addons) ? p.addons : [];
  const voucherCode = (p.voucher_code ?? "").trim();
  const attrIn = p.attribution && typeof p.attribution === "object" ? p.attribution : {};
  const attribution = readAttribution((k) => (attrIn as Record<string, unknown>)[k]);
  const { promoter: promoterId, ...campaignTags } = attribution;
  if (!event_id || !tier_id || !success_url || !cancel_url) {
    return json({ error: "missing event_id / tier_id / success_url / cancel_url" }, 400);
  }
  const allowed = parseRedirectOrigins(Deno.env.get("EXOS_REDIRECT_ORIGINS"));
  if (allowed.length === 0) return json({ error: "server misconfigured: EXOS_REDIRECT_ORIGINS unset" }, 500);
  if (!isAllowedRedirect(success_url, allowed) || !isAllowedRedirect(cancel_url, allowed)) {
    return json({ error: "redirect URL not allowed" }, 400);
  }
  if (!Number.isInteger(quantity) || quantity < 1 || quantity > 10) {
    return json({ error: "quantity must be 1-10" }, 400);
  }

  // Trusted reads (price/capacity/connected account) + ledger write via service_role.
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data: tier, error: tierErr } = await sb
    .from("exos_ticket_tiers")
    .select("id, name, price, price_schedule, capacity, sold, event_id, visibility, tax_rate_id, exos_tax_rules(rate_percent, price_includes_tax), exos_events!inner(id, org_id, name, status, currency)")
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
  let voucherUnlocksTier = false;
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
    // One voucher use buys one ticket (mig 20260924205508); refuse here rather
    // than charging and auto-refunding when fulfillment can't consume enough.
    const { data: vUses } = await sb.from("exos_vouchers")
      .select("max_uses, used_count").eq("id", v.voucher_id).maybeSingle();
    const remainingUses = vUses ? vUses.max_uses - vUses.used_count : 0;
    if (quantity > remainingUses) {
      return json({ error: `voucher covers ${Math.max(remainingUses, 0)} more ticket(s)` }, 409);
    }
    voucherId = v.voucher_id;
    voucherUnlocksTier = v.restrict_tier_id === tier_id;
    bypassCapacity = v.can_bypass === true;
    overridePrice = v.override_price != null ? Number(v.override_price) : null;
  }

  // A hidden tier is only sold through a voucher restricted to it (same rule
  // as the free-claim path); otherwise its UUID alone would unlock it.
  const visibility = (tier as unknown as { visibility?: string | null }).visibility;
  if (visibility && visibility !== "public" && !voucherUnlocksTier) {
    return json({ error: "ticket type not available" }, 409);
  }

  // Availability is enforced by a cart HOLD created just before the Stripe
  // session (exos_create_hold — atomically reserves against tier capacity AND
  // any shared quota for a TTL, so two buyers can't both pay for the last seat).
  // A bypass voucher skips the reservation (allowed to exceed caps). See below.

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
  // A voucher price override pins the per-ticket price (comp / special rate);
  // otherwise charge the tier's scheduled price as of now, the same price the
  // storefront shows (early-bird → regular → last-minute).
  const scheduled = effectiveTierPrice(
    Number(tier.price),
    (tier as unknown as { price_schedule?: unknown }).price_schedule,
  );
  const unitAmount = Math.round(Number(overridePrice ?? scheduled) * 100);

  // Validate + price add-ons server-side (never trust the client's prices). Each
  // must belong to this event, be public, and have stock. Build the priced
  // snapshot stored on the session (fulfillment reads it to record the purchase).
  type AddonRow = { addon_id: string; quantity: number; unit_price_cents: number; name: string };
  const addonsForSession: AddonRow[] = [];
  const addonLines: { id: string; name: string; quantity: number; unit_face: number; unit_all_in: number; unit_tax: number; line_tax: number; tax_included: boolean }[] = [];
  let addonTotal = 0;
  // recordedTax = the tax portion of the order (inclusive or exclusive), stored
  // on the session for invoices/reporting. Exclusive tax is already inside the
  // all-in unit amounts below, never added as a separate charge.
  let recordedTax = 0;
  // All-in pricing: exclusive tax is computed PER UNIT and folded into each
  // line's unit_amount, so the buyer pays exactly the all-in price the
  // storefront showed (allInCents, shared with the SPA). Returns the all-in unit
  // amount; inclusive tax is only recorded (it's already in the price).
  const allInUnit = (unitCents: number, qty: number, rule: { rate_percent?: number; price_includes_tax?: boolean } | null | undefined): number => {
    const rate = Number(rule?.rate_percent ?? 0);
    if (!rate) return unitCents;
    if (rule?.price_includes_tax === true) {
      recordedTax += taxCents(unitCents * qty, rate, true);
      return unitCents;
    }
    const withTax = allInCents(unitCents, rate);
    const tax = (withTax - unitCents) * qty;
    recordedTax += tax;
    return withTax;
  };
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
        .select("id, name, price, capacity, sold, max_per_order, visibility, event_id, tax_rate_id, exos_tax_rules(rate_percent, price_includes_tax)")
        .eq("event_id", event_id).in("id", ids);
      if (addErr) return json({ error: "could not load add-ons" }, 500);
      const byId = new Map((catalog ?? []).map((a) => [a.id, a]));
      for (const [id, qty] of wanted) {
        const a = byId.get(id);
        if (!a || a.visibility !== "public") return json({ error: "add-on not available" }, 409);
        // Hard upper bound mirroring the exos_order_addons CHECK (quantity BETWEEN
        // 1 AND 50). Without this, an add-on with no max_per_order and unlimited
        // capacity (both defaults) accepts any quantity here, the buyer pays, then
        // fulfillment's INSERT violates the CHECK and rolls back — charged, no
        // tickets, infinite webhook retry. Reject over-cap before charging.
        if (qty > 50) {
          return json({ error: `add-on "${a.name}" limited to 50 per order` }, 409);
        }
        if (a.max_per_order && qty > a.max_per_order) {
          return json({ error: `add-on "${a.name}" limited to ${a.max_per_order} per order` }, 409);
        }
        if (a.capacity > 0 && a.sold + qty > a.capacity) {
          return json({ error: `add-on "${a.name}" is sold out` }, 409);
        }
        const unitCents = Math.round(Number(a.price) * 100);
        const addonRule = (a as unknown as { exos_tax_rules?: { rate_percent?: number; price_includes_tax?: boolean } }).exos_tax_rules;
        const taxBefore = recordedTax;
        const allIn = allInUnit(unitCents, qty, addonRule);
        addonsForSession.push({ addon_id: a.id, quantity: qty, unit_price_cents: unitCents, name: a.name });
        addonLines.push({
          id: a.id, name: a.name, quantity: qty, unit_face: unitCents, unit_all_in: allIn, unit_tax: allIn - unitCents,
          line_tax: recordedTax - taxBefore, tax_included: addonRule?.price_includes_tax === true,
        });
        addonTotal += allIn * qty;
      }
    }
  }

  // Tier tax (after the voucher price override is applied to unitAmount).
  const tierRule = (tier as unknown as { exos_tax_rules?: { rate_percent?: number; price_includes_tax?: boolean } }).exos_tax_rules;
  const ticketTaxBefore = recordedTax;
  const ticketAllIn = allInUnit(unitAmount, quantity, tierRule);
  const ticketLineTax = recordedTax - ticketTaxBefore;

  // addonTotal is already all-in; the exclusive tax sits inside both unit amounts.
  const amountCents = ticketAllIn * quantity + addonTotal;
  const feeBps = Number(Deno.env.get("EXOS_PLATFORM_FEE_BPS") ?? "500");
  const applicationFee = Math.round((amountCents * feeBps) / 10000);

  // Only PAID line items go to Stripe ($0 lines are rejected in payment mode), so
  // a free tier + paid add-ons charges just the add-ons. Ticket quantity is still
  // recorded on the session for minting regardless of the tier's price.
  const lineItems: Stripe.Checkout.SessionCreateParams.LineItem[] = [];
  // All-in: one line per product at its all-in unit price; the tax inside it is
  // disclosed in the line description instead of appearing as an extra line.
  const taxNote = (unitTax: number) =>
    unitTax > 0 ? { description: `Includes ${(unitTax / 100).toFixed(2)} ${currency.toUpperCase()} tax per item` } : {};
  if (ticketAllIn > 0) {
    lineItems.push({
      quantity,
      price_data: {
        currency, unit_amount: ticketAllIn,
        product_data: { name: `${ev.name} — ${tier.name}`, ...taxNote(ticketAllIn - unitAmount) },
      },
    });
  }
  for (const a of addonLines) {
    if (a.unit_all_in > 0) {
      lineItems.push({
        quantity: a.quantity,
        price_data: {
          currency, unit_amount: a.unit_all_in,
          product_data: { name: `${ev.name} — ${a.name}`, ...taxNote(a.unit_tax) },
        },
      });
    }
  }
  if (lineItems.length === 0) {
    return json({ error: "nothing to charge — use the free claim path" }, 400);
  }

  // Reserve inventory with a cart hold BEFORE creating the Stripe session, so a
  // buyer who is about to pay actually holds the seats (closes the read-then-
  // charge oversell). Bypass vouchers skip it — they may exceed caps, honored at
  // fulfillment. Held for 30 min; released here on failure, consumed at mint,
  // else swept by the exos_expire_holds cron.
  let holdId: string | null = null;
  if (!bypassCapacity) {
    // A hidden tier's hold re-checks the voucher (mig 20260925003000). Only
    // sent when needed, so public tiers work before that migration is applied.
    const { data: hid, error: holdErr } = await sbUser.rpc("exos_create_hold", {
      p_event_id: event_id, p_tier_id: tier_id, p_quantity: quantity,
      ...(voucherUnlocksTier ? { p_voucher_code: voucherCode } : {}),
    });
    if (holdErr) {
      return json({ error: holdErr.message || "not enough tickets available" }, 409);
    }
    holdId = hid as string;
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
      // Match the 30-minute seat hold (Stripe's minimum) so nobody can pay after
      // their seats went back to the pool and trigger a refund.
      expires_at: Math.floor(Date.now() / 1000) + 30 * 60,
      customer_email: user.email ?? undefined,
      metadata: { exos_event_id: event_id, exos_tier_id: tier_id, exos_buyer_uid: user.id, exos_promoter: promoterId ?? "" },
    });
  } catch (e) {
    console.error("exos-checkout: stripe session create failed", e);
    await releaseHold(sb, holdId);
    return json({ error: "could not create checkout session" }, 502);
  }

  const ledgerRow: Record<string, unknown> = {
    session_id: session.id,
    event_id, tier_id, org_id: ev.org_id,
    buyer_uid: user.id, buyer_email: (user.email ?? "").toLowerCase(),
    quantity, amount_cents: amountCents, currency, status: "pending",
    addons: addonsForSession.length > 0 ? addonsForSession : null,
    voucher_id: voucherId,
    tax_cents: recordedTax > 0 ? recordedTax : null,
    promoter_id: promoterId ?? null,
    attribution: isEmptyAttribution(campaignTags) ? null : campaignTags,
  };
  let { error: insErr } = await sb.from("exos_checkout_sessions").insert(ledgerRow);
  // Deployed before mig 20260924223000 (no promoter_id / attribution columns):
  // record the sale without attribution rather than failing every checkout.
  if (insErr && (insErr.code === "42703" || insErr.code === "PGRST204")) {
    console.error("exos-checkout: attribution columns missing (apply 20260924223000); recording without them");
    delete ledgerRow.promoter_id;
    delete ledgerRow.attribution;
    ({ error: insErr } = await sb.from("exos_checkout_sessions").insert(ledgerRow));
  }
  if (insErr) {
    console.error("exos-checkout: ledger insert failed", insErr);
    await releaseHold(sb, holdId);
    return json({ error: "could not record session" }, 500);
  }

  // Link the hold to the now-existing session so fulfillment consumes it (and it
  // stops counting against availability once the sale lands). Insert-then-link
  // ordering matters: exos_cart_holds.checkout_session_id FKs the session row.
  if (holdId) {
    const { error: linkErr } = await sb.from("exos_cart_holds")
      .update({ checkout_session_id: session.id }).eq("id", holdId);
    if (linkErr) console.error("exos-checkout: hold link failed (non-fatal)", linkErr);
  }

  // Price-disclosure record (mig 20260926070000): what the buyer is shown on
  // Stripe's page, per line, so the charged amount can be checked against it
  // (NY ACAL 25.07 / FTC fee rule). Exos adds no buyer fee. Non-fatal: the
  // sale is already recorded; a missing record is visible in the export.
  const { error: pdErr } = await sb.rpc("exos_record_price_disclosure", {
    p_session_id: session.id,
    p_currency: currency,
    p_lines: [
      {
        kind: "ticket", item_id: tier_id, name: tier.name, quantity,
        face_unit_cents: unitAmount, tax_cents: ticketLineTax,
        tax_included: tierRule?.price_includes_tax === true,
        fee_cents: 0, unit_all_in_cents: ticketAllIn,
      },
      ...addonLines.map((a) => ({
        kind: "addon", item_id: a.id, name: a.name, quantity: a.quantity,
        face_unit_cents: a.unit_face, tax_cents: a.line_tax, tax_included: a.tax_included,
        fee_cents: 0, unit_all_in_cents: a.unit_all_in,
      })),
    ],
  });
  if (pdErr) console.error("exos-checkout: price disclosure record failed (non-fatal)", pdErr);

  return json({ url: session.url, session_id: session.id });
});

// Best-effort release of a reservation when checkout can't complete (Stripe
// error, ledger insert failure). Never throws — a stuck hold self-expires via
// the exos_expire_holds cron regardless.
// deno-lint-ignore no-explicit-any
async function releaseHold(sb: SupabaseClient<any, any, any>, holdId: string | null): Promise<void> {
  if (!holdId) return;
  try {
    await sb.from("exos_cart_holds")
      .update({ status: "released", released_at: new Date().toISOString() })
      .eq("id", holdId).eq("status", "active");
  } catch (e) {
    console.error("exos-checkout: hold release failed (non-fatal)", e);
  }
}

// Mirrors public.exos_tax_cents: inclusive extracts the embedded tax from the
// gross; exclusive computes the tax to add on top of the net.
function taxCents(amount: number, ratePercent: number, inclusive: boolean): number {
  if (!ratePercent) return 0;
  return inclusive
    ? Math.round((amount * ratePercent) / (100 + ratePercent))
    : Math.round((amount * ratePercent) / 100);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
