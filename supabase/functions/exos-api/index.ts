// exos-api — read-only, org-scoped public REST API for Exos (Hi.Events parity).
//
// Auth: `Authorization: Bearer sk_live_...`. The key is never stored in plaintext
// (migration 20260616200000) — we SHA-256 the presented key and look up the
// matching non-revoked row in exos_api_keys, which yields the org_id every query
// is then scoped to. Read-only: no endpoint mutates anything.
//
// Rate limit: 120 requests per key per minute; over it → 429 with Retry-After.
//
// Required secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
//
// Endpoints (all GET, all scoped to the key's org):
//   GET /events                      → the org's events
//   GET /events/:id                  → one event + its tiers
//   GET /events/:id/attendees        → tickets for the event
//   GET /orders                      → the org's checkout sessions

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const RATE_LIMIT = 120; // requests per key per minute

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "GET") return json({ error: "method not allowed" }, 405);

  const auth = req.headers.get("Authorization") ?? "";
  const key = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
  if (!key) return json({ error: "missing bearer API key" }, 401);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const keyHash = await sha256Hex(key);
  const { data: keyRow } = await sb
    .from("exos_api_keys")
    .select("id, org_id, revoked_at")
    .eq("key_hash", keyHash)
    .is("revoked_at", null)
    .maybeSingle();
  if (!keyRow) return json({ error: "invalid or revoked API key" }, 401);
  const orgId = keyRow.org_id as string;

  // Per-key rate limit: RATE_LIMIT requests per clock minute (fixed window,
  // exos_api_rate_hit, mig 20260925020000). Over the limit → 429 + Retry-After
  // (seconds to the next window). If the counter itself errors we let the
  // request through — the API is read-only and an outage of the limiter
  // shouldn't take the API down with it.
  const { data: allowed, error: rlErr } = await sb.rpc("exos_api_rate_hit", {
    p_key_id: keyRow.id, p_limit: RATE_LIMIT,
  });
  if (rlErr) {
    console.error("exos-api: rate limiter error (allowing request)", rlErr);
  } else if (allowed === false) {
    const retryAfter = Math.max(1, 60 - new Date().getUTCSeconds());
    return json({ error: "rate limit exceeded", limit_per_minute: RATE_LIMIT }, 429, {
      "retry-after": String(retryAfter),
    });
  }

  // Best-effort last-used stamp — awaited so it actually lands before the
  // serverless invocation returns (don't fail the request if it doesn't write).
  try {
    await sb.from("exos_api_keys").update({ last_used_at: new Date().toISOString() }).eq("id", keyRow.id);
  } catch { /* best-effort */ }

  // Path after the function name: /exos-api/<...>.
  const path = new URL(req.url).pathname.replace(/^.*\/exos-api/, "").replace(/\/+$/, "");
  const seg = path.split("/").filter(Boolean); // e.g. ['events', ':id', 'attendees']

  try {
    if (seg[0] === "events" && seg.length === 1) {
      const { data, error } = await sb
        .from("exos_events")
        .select("id, name, slug, status, starts_at, currency, tickets_sold, total_tickets, created_at")
        .eq("org_id", orgId)
        .order("starts_at", { ascending: false });
      if (error) throw error;
      return json({ data });
    }

    if (seg[0] === "events" && seg.length === 2) {
      const { data: ev, error } = await sb
        .from("exos_events")
        .select("id, name, slug, status, starts_at, doors_at, ends_at, timezone, currency, venue_name, venue_location, tickets_sold, total_tickets, created_at")
        .eq("org_id", orgId).eq("id", seg[1]).maybeSingle();
      if (error) throw error;
      if (!ev) return json({ error: "event not found" }, 404);
      const { data: tiers } = await sb
        .from("exos_ticket_tiers")
        .select("id, name, price, capacity, sold, ticket_type, visibility")
        .eq("event_id", seg[1]).order("sort_order", { ascending: true });
      return json({ data: { ...ev, tiers: tiers ?? [] } });
    }

    if (seg[0] === "events" && seg.length === 3 && seg[2] === "attendees") {
      // Confirm the event belongs to this org before exposing its attendees.
      const { data: ev } = await sb.from("exos_events").select("id").eq("org_id", orgId).eq("id", seg[1]).maybeSingle();
      if (!ev) return json({ error: "event not found" }, 404);
      const { data, error } = await sb
        .from("exos_tickets")
        .select("id, tier_name, owner_email, status, check_in_at, price_paid, channel_source, created_at")
        .eq("event_id", seg[1]).eq("org_id", orgId)
        .order("created_at", { ascending: false });
      if (error) throw error;
      return json({ data });
    }

    if (seg[0] === "orders" && seg.length === 1) {
      const { data, error } = await sb
        .from("exos_checkout_sessions")
        .select("session_id, event_id, status, quantity, amount_cents, tax_cents, currency, buyer_email, created_at, fulfilled_at")
        .eq("org_id", orgId)
        .order("created_at", { ascending: false })
        .limit(500);
      if (error) throw error;
      return json({ data });
    }

    if (seg[0] === "invoices" && seg.length === 1) {
      const { data, error } = await sb
        .from("exos_invoices")
        .select("number, event_id, session_id, buyer_email, currency, subtotal_cents, tax_cents, total_cents, status, issued_at")
        .eq("org_id", orgId)
        .order("issued_at", { ascending: false })
        .limit(500);
      if (error) throw error;
      return json({ data });
    }

    return json({ error: "not found", hint: "GET /events, /events/:id, /events/:id/attendees, /orders, /invoices" }, 404);
  } catch (e) {
    console.error("exos-api error:", e);
    return json({ error: "internal error" }, 500);
  }
});

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...extra } });
}
