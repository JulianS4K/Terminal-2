// exos-api — org-scoped public REST API for Exos (Hi.Events parity): reads +
// programmatic door check-in.
//
// Auth: `Authorization: Bearer sk_live_...`. The key is never stored in plaintext
// (migration 20260616200000) — we SHA-256 the presented key and look up the
// matching non-revoked row in exos_api_keys, which yields the org_id every query
// is then scoped to. Read-only: no endpoint mutates anything.
//
// Required secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
//
// Endpoints (all org-scoped to the key):
//   GET  /events                      → the org's events
//   GET  /events/:id                  → one event + its tiers
//   GET  /events/:id/attendees        → tickets for the event
//   GET  /events/:id/set-times        → the event's lineup schedule
//   GET  /events/:id/check-ins        → the event's scan log
//   GET  /tickets/:id                 → one ticket's status
//   GET  /orders                      → the org's checkout sessions
//   GET  /invoices                    → the org's invoices
//   POST /events/:id/check-in         → programmatic door check-in (body:
//                                        {ticket_id, barcode, idempotency_key?})

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "GET" && req.method !== "POST") return json({ error: "method not allowed" }, 405);

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

  // Best-effort last-used stamp — awaited so it actually lands before the
  // serverless invocation returns (don't fail the request if it doesn't write).
  try {
    await sb.from("exos_api_keys").update({ last_used_at: new Date().toISOString() }).eq("id", keyRow.id);
  } catch { /* best-effort */ }

  // Path after the function name: /exos-api/<...>.
  const path = new URL(req.url).pathname.replace(/^.*\/exos-api/, "").replace(/\/+$/, "");
  const seg = path.split("/").filter(Boolean); // e.g. ['events', ':id', 'attendees']

  try {
    // ── Writes (POST) ─────────────────────────────────────────────────────
    if (req.method === "POST") {
      // POST /events/:id/check-in — programmatic door check-in. Body:
      //   { ticket_id, barcode, idempotency_key? }
      // Calls the service-role, org-scoped RPC (mig 20260713170000): a signed
      // barcode is required, single-use is atomic, and idempotency_key makes a
      // retried POST a no-op.
      if (seg[0] === "events" && seg.length === 3 && seg[2] === "check-in") {
        const { data: ev } = await sb.from("exos_events").select("id").eq("org_id", orgId).eq("id", seg[1]).maybeSingle();
        if (!ev) return json({ error: "event not found" }, 404);
        let body: Record<string, unknown> = {};
        try { body = await req.json(); } catch { /* empty/invalid body → validated below */ }
        const ticketId = body?.ticket_id;
        if (!ticketId || typeof ticketId !== "string") return json({ error: "ticket_id required" }, 400);
        const { data, error } = await sb.rpc("exos_api_check_in_ticket", {
          p_org: orgId,
          p_ticket: ticketId,
          p_barcode_payload: typeof body?.barcode === "string" ? body.barcode : null,
          p_idempotency_key: typeof body?.idempotency_key === "string" ? body.idempotency_key : null,
          p_api_key_id: keyRow.id,
        });
        if (error) throw error;
        const result = (data ?? { ok: false, reason: "not-found" }) as { ok: boolean; reason: string };
        // ok → 200; a refusal (used / voided / barcode-rejected / wrong-org / …)
        // → 422 so the caller can distinguish it from a 5xx.
        return json({ data: result }, result.ok ? 200 : 422);
      }
      return json({ error: "not found", hint: "POST /events/:id/check-in" }, 404);
    }

    // ── Reads (GET) ───────────────────────────────────────────────────────
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

    if (seg[0] === "events" && seg.length === 3 && seg[2] === "set-times") {
      const { data: ev } = await sb.from("exos_events").select("set_times").eq("org_id", orgId).eq("id", seg[1]).maybeSingle();
      if (!ev) return json({ error: "event not found" }, 404);
      return json({ data: ev.set_times ?? [] });
    }

    if (seg[0] === "events" && seg.length === 3 && seg[2] === "check-ins") {
      const { data: ev } = await sb.from("exos_events").select("id").eq("org_id", orgId).eq("id", seg[1]).maybeSingle();
      if (!ev) return json({ error: "event not found" }, 404);
      const { data, error } = await sb
        .from("exos_event_checkins")
        .select("ticket_id, source, verification, scanned_at, scanned_by_email")
        .eq("event_id", seg[1]).eq("org_id", orgId)
        .order("scanned_at", { ascending: false })
        .limit(1000);
      if (error) throw error;
      return json({ data });
    }

    if (seg[0] === "tickets" && seg.length === 2) {
      const { data, error } = await sb
        .from("exos_tickets")
        .select("id, event_id, tier_name, owner_email, status, check_in_at, created_at")
        .eq("org_id", orgId).eq("id", seg[1]).maybeSingle();
      if (error) throw error;
      if (!data) return json({ error: "ticket not found" }, 404);
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

    return json({ error: "not found", hint: "GET /events, /events/:id, /events/:id/{attendees,set-times,check-ins}, /tickets/:id, /orders, /invoices · POST /events/:id/check-in" }, 404);
  } catch (e) {
    console.error("exos-api error:", e);
    return json({ error: "internal error" }, 500);
  }
});

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
