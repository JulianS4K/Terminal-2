// exos-api — org-scoped public REST API for Exos (Hi.Events parity): reads +
// programmatic door check-in.
//
// Auth: `Authorization: Bearer sk_live_...`. The key is never stored in plaintext
// (migration 20260616200000) — we SHA-256 the presented key and look up the
// matching non-revoked row in exos_api_keys, which yields the org_id every query
// is then scoped to. All mutating access is the single POST check-in route.
//
// Required secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
//
// List endpoints accept ?limit= (1..500, default 100) & ?offset= (default 0) and
// return `{ data, page: { limit, offset, returned } }`. Single-object endpoints
// return `{ data }`.
//
// Endpoints (all org-scoped to the key; GET /openapi.json is public):
//   GET  /openapi.json                → OpenAPI 3.1 spec (no auth)
//   GET  /events                      → the org's events            (paginated)
//   GET  /events/:id                  → one event + its tiers
//   GET  /events/:id/attendees        → tickets for the event       (paginated)
//   GET  /events/:id/set-times        → the event's lineup schedule
//   GET  /events/:id/check-ins        → the event's scan log        (paginated)
//   GET  /tickets/:id                 → one ticket's status
//   GET  /orders                      → the org's checkout sessions (paginated)
//   GET  /invoices                    → the org's invoices          (paginated)
//   POST /events/:id/check-in         → programmatic door check-in (body:
//                                        {ticket_id, barcode, idempotency_key?})

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "GET" && req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const url = new URL(req.url);
  // Path after the function name: /exos-api/<...>.
  const path = url.pathname.replace(/^.*\/exos-api/, "").replace(/\/+$/, "");
  const seg = path.split("/").filter(Boolean); // e.g. ['events', ':id', 'attendees']

  // Public, unauthenticated: the machine-readable API description.
  if (req.method === "GET" && seg.length === 1 && seg[0] === "openapi.json") {
    return json(openapiSpec());
  }

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

  const { limit, offset } = pageParams(url);
  const paged = (data: unknown[] | null) => json({ data: data ?? [], page: { limit, offset, returned: data?.length ?? 0 } });

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
        .order("starts_at", { ascending: false })
        .range(offset, offset + limit - 1);
      if (error) throw error;
      return paged(data);
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
        .order("created_at", { ascending: false })
        .range(offset, offset + limit - 1);
      if (error) throw error;
      return paged(data);
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
        .range(offset, offset + limit - 1);
      if (error) throw error;
      return paged(data);
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
        .range(offset, offset + limit - 1);
      if (error) throw error;
      return paged(data);
    }

    if (seg[0] === "invoices" && seg.length === 1) {
      const { data, error } = await sb
        .from("exos_invoices")
        .select("number, event_id, session_id, buyer_email, currency, subtotal_cents, tax_cents, total_cents, status, issued_at")
        .eq("org_id", orgId)
        .order("issued_at", { ascending: false })
        .range(offset, offset + limit - 1);
      if (error) throw error;
      return paged(data);
    }

    return json({ error: "not found", hint: "GET /openapi.json, /events, /events/:id, /events/:id/{attendees,set-times,check-ins}, /tickets/:id, /orders, /invoices · POST /events/:id/check-in" }, 404);
  } catch (e) {
    console.error("exos-api error:", e);
    return json({ error: "internal error" }, 500);
  }
});

/** Clamp ?limit (1..500, default 100) and ?offset (>=0, default 0). */
function pageParams(url: URL): { limit: number; offset: number } {
  const l = parseInt(url.searchParams.get("limit") ?? "", 10);
  const o = parseInt(url.searchParams.get("offset") ?? "", 10);
  const limit = Number.isFinite(l) ? Math.min(Math.max(l, 1), 500) : 100;
  const offset = Number.isFinite(o) && o > 0 ? o : 0;
  return { limit, offset };
}

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

/** OpenAPI 3.1 description of this API, served publicly at GET /openapi.json. */
function openapiSpec(): unknown {
  const paged = {
    type: "object",
    properties: {
      data: { type: "array", items: { type: "object" } },
      page: {
        type: "object",
        properties: {
          limit: { type: "integer" },
          offset: { type: "integer" },
          returned: { type: "integer" },
        },
      },
    },
  };
  const single = { type: "object", properties: { data: { type: "object" } } };
  const listParams = [
    { name: "limit", in: "query", schema: { type: "integer", minimum: 1, maximum: 500, default: 100 } },
    { name: "offset", in: "query", schema: { type: "integer", minimum: 0, default: 0 } },
  ];
  const idParam = { name: "id", in: "path", required: true, schema: { type: "string", format: "uuid" } };
  const ok = (schema: unknown) => ({ "200": { description: "OK", content: { "application/json": { schema } } } });
  return {
    openapi: "3.1.0",
    info: { title: "Exos Public API", version: "1.0.0", description: "Org-scoped ticketing API. Auth: Authorization: Bearer <api key>." },
    servers: [{ url: "/functions/v1/exos-api" }],
    components: {
      securitySchemes: { bearerAuth: { type: "http", scheme: "bearer" } },
    },
    security: [{ bearerAuth: [] }],
    paths: {
      "/events": { get: { summary: "List events", parameters: listParams, responses: ok(paged) } },
      "/events/{id}": { get: { summary: "Get one event + tiers", parameters: [idParam], responses: ok(single) } },
      "/events/{id}/attendees": { get: { summary: "List attendees", parameters: [idParam, ...listParams], responses: ok(paged) } },
      "/events/{id}/set-times": { get: { summary: "Event lineup schedule", parameters: [idParam], responses: ok({ type: "object", properties: { data: { type: "array" } } }) } },
      "/events/{id}/check-ins": { get: { summary: "Event scan log", parameters: [idParam, ...listParams], responses: ok(paged) } },
      "/events/{id}/check-in": {
        post: {
          summary: "Programmatic door check-in",
          parameters: [idParam],
          requestBody: {
            required: true,
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  required: ["ticket_id", "barcode"],
                  properties: {
                    ticket_id: { type: "string", format: "uuid" },
                    barcode: { type: "string", description: "A live signed barcode (T-… or T2-…). Required." },
                    idempotency_key: { type: "string", format: "uuid", description: "Retries with the same key are a no-op." },
                  },
                },
              },
            },
          },
          responses: {
            "200": { description: "Checked in", content: { "application/json": { schema: single } } },
            "422": { description: "Refused (used / voided / barcode-rejected / wrong-org / doors-not-open / barcode-required)" },
          },
        },
      },
      "/tickets/{id}": { get: { summary: "Get one ticket's status", parameters: [idParam], responses: ok(single) } },
      "/orders": { get: { summary: "List checkout sessions", parameters: listParams, responses: ok(paged) } },
      "/invoices": { get: { summary: "List invoices", parameters: listParams, responses: ok(paged) } },
    },
  };
}
