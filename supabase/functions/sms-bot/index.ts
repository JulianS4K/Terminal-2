// Supabase Edge Function: sms-bot
//
// Twilio webhook → verify HMAC-SHA1 sig → whitelist check → Anthropic tool-use
// loop (13 tools, 6 cached + 6 TEvo + zones) → TwiML XML reply → log to bot_messages.
//
// Same behaviour as bot.py but runs in Deno on Supabase, removing the Railway hop.
//
// Required Edge Function secrets (set via `supabase secrets set` or dashboard):
//   ANTHROPIC_API_KEY     — for the bot's tool-use loop
//   TWILIO_AUTH_TOKEN     — for inbound HMAC-SHA1 signature verification
//   CRON_SECRET           — to call collect-listings on demand (already set; same value)
// Provided automatically:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
// TEvo creds come from the Postgres `settings` table (same as collect-listings).
//
// Twilio webhook URL: https://<project-ref>.supabase.co/functions/v1/sms-bot

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const TEVO_HOST = "api.ticketevolution.com";
const TEVO_BASE = `https://${TEVO_HOST}`;
const BOT_MODEL = Deno.env.get("WHATSAPP_BOT_MODEL") ?? "claude-sonnet-4-6";
const MAX_TURNS = parseInt(Deno.env.get("WHATSAPP_MAX_TURNS") ?? "6", 10);

const SYSTEM_PROMPT = `You are a terse market-intelligence assistant for S4K Entertainment, a secondary ticket broker.

The user texts you over SMS / WhatsApp. Reply in Bloomberg-terminal style: short, dense, numeric. Hard target: under 160 characters per reply (single SMS segment). If more is genuinely needed, split into two segments.
Use abbreviations (KNX@ATL G4, $458 med, +17.7%/24h, own 32%). Never wrap output in code blocks or markdown.

You have two sets of tools:

(A) Cached metrics from our Supabase store — refreshed every 20 minutes for events on our watchlist (~488 tracked events). These tools go through a rate-limit gate (get_or_authorize_pull): back-to-back queries serve from cache, and any on-demand refresh feeds the same listings_snapshots the terminal UI reads, which keeps TEvo calls down. Richer (S4K owned share, dispersion, tail premium, portfolio rollups) but only cover events we follow.
  - search_events, get_event_snapshot, get_market_movement, get_portfolio, get_owned_inventory, get_high_value_owned, get_event_zones (internal only)

(B) Live Ticket Evolution API — direct read for ANY event in TEvo's catalog (millions). Slower (~1-2s), uses raw TEvo rate budget per call, does NOT update our cache. Less rich (no owned share, no dispersion).
  - tevo_search_events, tevo_event_detail, tevo_event_stats, tevo_listings, tevo_search_performers, tevo_search_venues

Decision rule: prefer (A) for any event likely on our watchlist (NBA playoffs, Yankees, Knicks, big NYC venues). Fall back to (B) only when (A) returns nothing OR for events we obviously don't track (random concert tour, college football, etc.). Don't run both (A) and (B) on the same event in one turn — that's a redundant TEvo call. When you don't know an event_id, search by name first; prefer search_events over tevo_search_events for the same reason.

When listing events, always include venue (short form, e.g. MSG, TD Gdn, Xfin) and date/time. Default to upcoming events only — call out explicitly if the user asked for past events. For zone queries call get_event_zones (internal-only, permissions checked server-side); sections without curated rules come back as 'unmapped' — surface that count rather than inventing a zone. Returns zone, tickets, min and max retail per zone (no groups, no median — keep replies tight).

Always call a tool when the user asks for live numbers; never guess. If a query is ambiguous, ask one short clarifying question.

If a tool returns nothing useful, say so plainly. Don't pad with caveats. Maximum reply length: 320 characters (2 SMS segments).`;

// ---------------------------------------------------------------------------
// Twilio HMAC-SHA1 signature verification
// ---------------------------------------------------------------------------

async function verifyTwilioSignature(
  authToken: string, requestUrl: string,
  params: Record<string, string>, headerSig: string,
): Promise<boolean> {
  if (!authToken || !headerSig) return false;
  let payload = requestUrl;
  for (const k of Object.keys(params).sort()) payload += k + params[k];
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(authToken),
    { name: "HMAC", hash: "SHA-1" }, false, ["sign"],
  );
  const sigBytes = await crypto.subtle.sign("HMAC", key, enc.encode(payload));
  let bin = "";
  for (const b of new Uint8Array(sigBytes)) bin += String.fromCharCode(b);
  const expected = btoa(bin);
  if (expected.length !== headerSig.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= expected.charCodeAt(i) ^ headerSig.charCodeAt(i);
  }
  return diff === 0;
}

// ---------------------------------------------------------------------------
// TEvo client (port of evo_client.py + collect-listings EvoClient)
// ---------------------------------------------------------------------------

async function hmacSha256Base64(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  let bin = "";
  for (const b of new Uint8Array(sig)) bin += String.fromCharCode(b);
  return btoa(bin);
}

type Params = Record<string, string | number | boolean | null | undefined>;

function canonicalQuery(params: Params): string {
  const pairs: [string, string][] = [];
  for (const [k, v] of Object.entries(params)) {
    if (v === null || v === undefined || v === "") continue;
    const val = typeof v === "boolean" ? (v ? "true" : "false") : String(v);
    pairs.push([k, val]);
  }
  pairs.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
}

class Evo {
  constructor(private token: string, private secret: string) {}
  private async get(path: string, params: Params = {}): Promise<any> {
    const query = canonicalQuery(params);
    const stringToSign = `GET ${TEVO_HOST}${path}?${query}`;
    const signature = await hmacSha256Base64(this.secret, stringToSign);
    const url = `${TEVO_BASE}${path}?${query}`;
    const resp = await fetch(url, {
      headers: {
        "X-Token": this.token,
        "X-Signature": signature,
        "Accept": "application/vnd.ticketevolution.api+json; version=9",
      },
    });
    if (!resp.ok) throw new Error(`${resp.status} ${resp.statusText} on ${path}`);
    return resp.json();
  }
  searchEvents(p: Params) { return this.get("/v9/events", { per_page: 25, ...p }); }
  eventDetail(id: number) { return this.get(`/v9/events/${id}`); }
  eventStats(id: number, inventory_type?: string) {
    return this.get(`/v9/events/${id}/stats`, inventory_type ? { inventory_type } : {});
  }
  ticketGroups(id: number) { return this.get("/v9/ticket_groups", { event_id: id }); }
  searchPerformers(q: string) { return this.get("/v9/performers", { q, per_page: 25 }); }
  searchVenues(q: string) { return this.get("/v9/venues", { q, per_page: 25 }); }
}

async function resolveTevoCreds(db: any): Promise<{ token: string; secret: string } | null> {
  try {
    const { data } = await db.from("settings").select("key,value")
      .in("key", ["tevo_token", "tevo_secret"]);
    const byKey: Record<string, string> = {};
    for (const r of data ?? []) byKey[r.key] = r.value;
    if (byKey.tevo_token && byKey.tevo_secret) return { token: byKey.tevo_token, secret: byKey.tevo_secret };
  } catch (_) { /* ignore */ }
  return null;
}

/**
 * Resolve a secret. Settings table is the source of truth; env var is fallback.
 * Used for ANTHROPIC_API_KEY (settings.anthropic_api_key) and TWILIO_AUTH_TOKEN
 * (settings.twilio_auth_token).
 */
async function resolveSecret(db: any, settingsKey: string, envKey: string): Promise<string | null> {
  try {
    const { data } = await db.from("settings").select("value").eq("key", settingsKey).maybeSingle();
    if (data?.value) return data.value;
  } catch (_) { /* fall through */ }
  return Deno.env.get(envKey) ?? null;
}

// ---------------------------------------------------------------------------
// Tool definitions (same shape as bot.py TOOLS)
// ---------------------------------------------------------------------------

const TOOLS = [
  {
    name: "search_events",
    description: "Search tracked events by free-text query or filter. Defaults to UPCOMING events only (occurs_at_local >= now). For past events pass include_past=true OR an explicit start_at in the past. Returns id, name, occurs_at_local, venue_name, primary_performer_name.",
    input_schema: {
      type: "object",
      properties: {
        query: { type: "string" },
        performer_id: { type: "integer" },
        venue_id: { type: "integer" },
        days_ahead: { type: "integer" },
        start_at: { type: "string" },
        end_at: { type: "string" },
        include_past: { type: "boolean", default: false },
        limit: { type: "integer", default: 10 },
      },
    },
  },
  {
    name: "get_event_snapshot",
    description: "Latest metrics for one event: tickets remaining, retail percentiles, get-in, S4K owned share, dispersion. Goes through cache+rate-limit gate. Use for current state of a watchlist event.",
    input_schema: { type: "object", required: ["event_id"], properties: { event_id: { type: "integer" } } },
  },
  {
    name: "get_market_movement",
    description: "Period-over-period change for one event's metrics. Returns open/now/delta for retail percentiles, get-in, tickets_count.",
    input_schema: {
      type: "object", required: ["event_id"],
      properties: { event_id: { type: "integer" }, hours_back: { type: "integer", default: 24 } },
    },
  },
  {
    name: "get_portfolio",
    description: "Aggregate rollup across all events for a performer or venue.",
    input_schema: {
      type: "object",
      properties: { performer_id: { type: "integer" }, venue_id: { type: "integer" } },
    },
  },
  {
    name: "get_owned_inventory",
    description: "List S4K-owned ticket groups, optionally filtered by event_id or min retail price.",
    input_schema: {
      type: "object",
      properties: {
        event_id: { type: "integer" },
        min_retail_price: { type: "number" },
        limit: { type: "integer", default: 15 },
      },
    },
  },
  {
    name: "get_high_value_owned",
    description: "Top events ranked by S4K's retail-value exposure.",
    input_schema: { type: "object", properties: { limit: { type: "integer", default: 10 } } },
  },
  {
    name: "tevo_search_events",
    description: "LIVE Ticket Evolution event search. Last-resort fallback when the event isn't on our watchlist; prefer search_events first.",
    input_schema: {
      type: "object",
      properties: {
        query: { type: "string" }, performer_id: { type: "integer" }, venue_id: { type: "integer" },
        limit: { type: "integer", default: 8 },
      },
    },
  },
  {
    name: "tevo_event_detail",
    description: "LIVE Ticket Evolution event metadata. Use only when the event isn't on our watchlist.",
    input_schema: { type: "object", required: ["event_id"], properties: { event_id: { type: "integer" } } },
  },
  {
    name: "tevo_event_stats",
    description: "LIVE Ticket Evolution aggregate stats. Use ONLY for off-watchlist events.",
    input_schema: {
      type: "object", required: ["event_id"],
      properties: {
        event_id: { type: "integer" },
        inventory_type: { type: "string", enum: ["event", "parking"] },
      },
    },
  },
  {
    name: "tevo_listings",
    description: "LIVE Ticket Evolution marketplace listings — cheapest N groups for one event. Use only for off-watchlist events.",
    input_schema: {
      type: "object", required: ["event_id"],
      properties: { event_id: { type: "integer" }, limit: { type: "integer", default: 8 } },
    },
  },
  {
    name: "tevo_search_performers",
    description: "LIVE TEvo performer search. Resolve a performer_id by name.",
    input_schema: {
      type: "object", required: ["query"],
      properties: { query: { type: "string" }, limit: { type: "integer", default: 5 } },
    },
  },
  {
    name: "tevo_search_venues",
    description: "LIVE TEvo venue search. Resolve a venue_id by name.",
    input_schema: {
      type: "object", required: ["query"],
      properties: { query: { type: "string" }, limit: { type: "integer", default: 5 } },
    },
  },
  {
    name: "get_event_zones",
    description: "INTERNAL ONLY. Zone-level breakdown for one event using performer_zones + performer_zone_rules. Sections without curated rule = 'unmapped' (do NOT invent). Defaults to S4K-owned only. Returns zone, tickets, min_retail, max_retail (no groups, no median).",
    input_schema: {
      type: "object", required: ["event_id"],
      properties: {
        event_id: { type: "integer" },
        owned_only: { type: "boolean", default: true },
      },
    },
  },
];

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

async function toolSearchEvents(db: any, args: any) {
  const now = new Date();
  let q = db.from("events").select("id,name,occurs_at_local,venue_name,primary_performer_name");
  // occurs_at_local is TEXT, so >= comparison is LEXICAL not timestamp-aware.
  // A 7pm ET game string '2026-05-06T19:00:00-04:00' lexically compares less
  // than UTC-now string '2026-05-06T19:59:22Z' even though the real instant is
  // hours in the future. Workaround: bound by today's UTC date prefix only —
  // any event whose stored string starts with today's date or later passes.
  // (Tradeoff: events that already happened earlier today still match, but
  // for SMS use the model can read occurs_at_local and disambiguate.)
  const todayPrefix = now.toISOString().slice(0, 10); // 'YYYY-MM-DD'
  if (args.start_at) q = q.gte("occurs_at_local", args.start_at);
  else if (!args.include_past) q = q.gte("occurs_at_local", todayPrefix);
  if (args.end_at) q = q.lte("occurs_at_local", args.end_at);
  else if (args.days_ahead) {
    const cutoffDate = new Date(now.getTime() + (args.days_ahead + 1) * 86400_000);
    q = q.lte("occurs_at_local", cutoffDate.toISOString().slice(0, 10));
  }
  if (args.performer_id != null) q = q.or(`primary_performer_id.eq.${args.performer_id},performer_ids.cs.{${args.performer_id}}`);
  if (args.venue_id != null) q = q.eq("venue_id", args.venue_id);
  if (args.query) q = q.ilike("name", `%${args.query}%`);
  const limit = Math.min(args.limit ?? 10, 25);
  const { data } = await q.order("occurs_at_local").limit(limit);
  return { count: (data ?? []).length, events: data ?? [] };
}

async function triggerEventRefresh(eventId: number, pullId: number | null): Promise<any> {
  const cronSecret = Deno.env.get("CRON_SECRET");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  if (!cronSecret || !supabaseUrl) return { ok: false, error: "CRON_SECRET or SUPABASE_URL missing" };
  let url = `${supabaseUrl}/functions/v1/collect-listings?event_id=${eventId}`;
  if (pullId != null) url += `&pull_id=${pullId}`;
  try {
    const r = await fetch(url, { method: "POST", headers: { "x-cron-secret": cronSecret } });
    let body: any = null;
    try { body = await r.json(); } catch (_) { body = { raw: await r.text() }; }
    return { ok: r.ok, status: r.status, ...(body ?? {}) };
  } catch (e) {
    return { ok: false, error: String((e as Error).message) };
  }
}

async function toolEventSnapshot(db: any, args: any, ctx: { requester: string | null; source: string }) {
  const eid = Number(args.event_id);
  const { data: dec } = await db.rpc("get_or_authorize_pull", {
    p_event_id: eid, p_source: ctx.source, p_requester: ctx.requester, p_max_age_seconds: 300,
  });
  let served = (dec ?? {}).decision ?? "unknown";
  let refreshStatus: any = null;
  if (served === "fetch_fresh") {
    refreshStatus = await triggerEventRefresh(eid, (dec ?? {}).pull_id ?? null);
    if (!refreshStatus.ok) served = "fresh_failed";
  }
  const { data: ev } = await db.from("events")
    .select("id,name,occurs_at_local,venue_name,primary_performer_name")
    .eq("id", eid).maybeSingle();
  const { data: m } = await db.from("latest_event_metrics").select("*")
    .eq("event_id", eid).maybeSingle();
  if (!ev && !m) return { error: `event_id ${eid} not found` };
  return {
    event: ev ?? {}, metrics: m ?? {},
    served_from: served, snapshot_age_seconds: (dec ?? {}).age_seconds,
    rate_limit_reason: (dec ?? {}).reason,
    retry_after_seconds: (dec ?? {}).retry_after_seconds,
    refresh_status: refreshStatus,
  };
}

async function toolMarketMovement(db: any, args: any) {
  const eid = Number(args.event_id);
  const hoursBack = Number(args.hours_back ?? 24);
  const since = new Date(Date.now() - hoursBack * 3_600_000).toISOString();
  const { data } = await db.from("event_metrics").select(
    "captured_at,tickets_count,groups_count,retail_min,retail_p25,retail_median,retail_p75,retail_p90,retail_max,getin_price,owned_tickets_count,owned_share",
  ).eq("event_id", eid).gte("captured_at", since).order("captured_at");
  const rows = data ?? [];
  if (rows.length < 2) return { event_id: eid, hours_back: hoursBack, points: rows.length, note: "not enough history in window" };
  const open_ = rows[0], now = rows[rows.length - 1];
  const keys = ["tickets_count","retail_min","retail_p25","retail_median","retail_p75","retail_p90","retail_max","getin_price","owned_tickets_count"];
  const deltas: Record<string, any> = {};
  for (const k of keys) {
    const o = open_[k], n = now[k];
    if (o == null || n == null) continue;
    const oF = Number(o), nF = Number(n);
    const pct = oF !== 0 ? ((nF - oF) / oF) * 100 : null;
    deltas[k] = { open: o, now: n, delta: Math.round((nF - oF) * 100) / 100, pct: pct == null ? null : Math.round(pct * 100) / 100 };
  }
  return { event_id: eid, hours_back: hoursBack, points: rows.length, open_at: open_.captured_at, now_at: now.captured_at, movement: deltas };
}

async function toolPortfolio(db: any, args: any) {
  if (args.performer_id == null && args.venue_id == null) return { error: "provide performer_id or venue_id" };
  let evQ = db.from("events").select("id");
  if (args.performer_id != null) evQ = evQ.or(`primary_performer_id.eq.${args.performer_id},performer_ids.cs.{${args.performer_id}}`);
  else evQ = evQ.eq("venue_id", args.venue_id);
  const { data: evs } = await evQ;
  const eventIds = (evs ?? []).map((r: any) => r.id);
  if (!eventIds.length) return { events_count: 0, tickets_total: 0, owned_tickets_total: 0, retail_value_total: 0 };
  const { data: metrics } = await db.from("latest_event_metrics")
    .select("event_id,tickets_count,owned_tickets_count,retail_sum,retail_median,owned_median_retail")
    .in("event_id", eventIds);
  const m = metrics ?? [];
  const tickets = m.reduce((s: number, r: any) => s + (r.tickets_count ?? 0), 0);
  const owned = m.reduce((s: number, r: any) => s + (r.owned_tickets_count ?? 0), 0);
  const retail = m.reduce((s: number, r: any) => s + Number(r.retail_sum ?? 0), 0);
  const ownedValue = m.reduce((s: number, r: any) => s + (r.owned_tickets_count ?? 0) * Number(r.owned_median_retail ?? 0), 0);
  return {
    events_count: m.length, tickets_total: tickets, owned_tickets_total: owned,
    owned_share_pct: tickets ? Math.round((owned / tickets) * 10000) / 100 : null,
    retail_value_total: Math.round(retail * 100) / 100,
    owned_retail_value_total: Math.round(ownedValue * 100) / 100,
    events_with_owned: m.filter((r: any) => (r.owned_tickets_count ?? 0) > 0).length,
  };
}

async function toolOwnedInventory(db: any, args: any) {
  let q = db.from("listings_snapshots").select("event_id,section,row,quantity,retail_price,office_name,captured_at")
    .eq("is_owned", true).order("captured_at", { ascending: false });
  if (args.event_id != null) q = q.eq("event_id", args.event_id);
  if (args.min_retail_price != null) q = q.gte("retail_price", args.min_retail_price);
  const { data } = await q.limit(Math.min(args.limit ?? 15, 50));
  return { count: (data ?? []).length, rows: data ?? [] };
}

async function toolHighValueOwned(db: any, args: any) {
  const { data: metrics } = await db.from("latest_event_metrics")
    .select("event_id,owned_tickets_count,owned_median_retail,owned_share").gt("owned_tickets_count", 0);
  const m = metrics ?? [];
  if (!m.length) return { count: 0, rows: [] };
  for (const r of m) r.owned_value = Number(r.owned_tickets_count ?? 0) * Number(r.owned_median_retail ?? 0);
  m.sort((a: any, b: any) => b.owned_value - a.owned_value);
  const top = m.slice(0, args.limit ?? 10);
  const ids = top.map((r: any) => r.event_id);
  const { data: evs } = await db.from("events").select("id,name,occurs_at_local,venue_name").in("id", ids);
  const evMap = Object.fromEntries((evs ?? []).map((e: any) => [e.id, e]));
  return {
    count: top.length,
    rows: top.map((r: any) => ({
      event_id: r.event_id, name: evMap[r.event_id]?.name, occurs_at_local: evMap[r.event_id]?.occurs_at_local,
      venue: evMap[r.event_id]?.venue_name,
      owned_tickets: r.owned_tickets_count, owned_median: r.owned_median_retail, owned_share: r.owned_share,
      exposure_usd: Math.round(r.owned_value * 100) / 100,
    })),
  };
}

async function toolTevoSearchEvents(evo: Evo, args: any) {
  try {
    const params: Params = { only_with_available_tickets: true };
    if (args.query) params.q = args.query;
    if (args.performer_id) params.performer_id = args.performer_id;
    if (args.venue_id) params.venue_id = args.venue_id;
    const r = await evo.searchEvents(params);
    const events = (r.events ?? []).slice(0, args.limit ?? 8);
    return {
      count: events.length,
      events: events.map((e: any) => ({
        id: e.id, name: e.name, occurs_at_local: e.occurs_at_local,
        venue: e.venue?.name, performer: e.performances?.find((p: any) => p.primary)?.performer?.name,
      })),
    };
  } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolTevoEventDetail(evo: Evo, args: any) {
  try {
    const r = await evo.eventDetail(args.event_id);
    return { id: r.id, name: r.name, occurs_at_local: r.occurs_at_local, venue: r.venue, performances: r.performances };
  } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolTevoEventStats(evo: Evo, args: any) {
  try { return await evo.eventStats(args.event_id, args.inventory_type); }
  catch (e) { return { error: String((e as Error).message) }; }
}

async function toolTevoListings(evo: Evo, args: any) {
  try {
    const r = await evo.ticketGroups(args.event_id);
    const groups = (r.ticket_groups ?? [])
      .filter((g: any) => g.retail_price != null)
      .sort((a: any, b: any) => Number(a.retail_price) - Number(b.retail_price))
      .slice(0, args.limit ?? 8);
    return {
      count: groups.length,
      listings: groups.map((g: any) => ({
        section: g.section, row: g.row, quantity: g.available_quantity,
        retail_price: g.retail_price, format: g.format,
      })),
    };
  } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolTevoSearchPerformers(evo: Evo, args: any) {
  try {
    const r = await evo.searchPerformers(args.query);
    const items = (r.performers ?? []).slice(0, args.limit ?? 5);
    return { count: items.length, performers: items.map((p: any) => ({ id: p.id, name: p.name, category: p.category?.name })) };
  } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolTevoSearchVenues(evo: Evo, args: any) {
  try {
    const r = await evo.searchVenues(args.query);
    const items = (r.venues ?? []).slice(0, args.limit ?? 5);
    return {
      count: items.length,
      venues: items.map((v: any) => ({
        id: v.id, name: v.name,
        city: v.address?.locality, state: v.address?.region, country: v.address?.country_code,
      })),
    };
  } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolEventZones(db: any, args: any, ctx: { requester: string | null; source: string }) {
  if (!ctx.requester) return { error: "internal data requires an authenticated requester" };
  const { data: user } = await db.from("bot_users").select("is_internal,active")
    .eq("phone", ctx.requester).maybeSingle();
  if (!user || !user.is_internal) return { error: "not authorized — zone data is internal only" };
  const eid = Number(args.event_id);
  const { data: dec } = await db.rpc("get_or_authorize_pull", {
    p_event_id: eid, p_source: ctx.source, p_requester: ctx.requester, p_max_age_seconds: 300,
  });
  if ((dec ?? {}).decision === "fetch_fresh") {
    await triggerEventRefresh(eid, (dec ?? {}).pull_id ?? null);
  }
  const { data: rollup } = await db.rpc("get_event_zones_rollup", {
    p_event_id: eid, p_owned_only: args.owned_only !== false,
  });
  return {
    event_id: eid, owned_only: args.owned_only !== false,
    snapshot_age_seconds: (dec ?? {}).age_seconds,
    served_from: (dec ?? {}).decision,
    zones: rollup ?? [],
  };
}

const CONTEXT_INJECTED = new Set(["get_event_snapshot", "get_event_zones"]);

async function dispatch(name: string, input: any, db: any, evo: Evo | null, ctx: any) {
  switch (name) {
    case "search_events":           return await toolSearchEvents(db, input);
    case "get_event_snapshot":      return await toolEventSnapshot(db, input, ctx);
    case "get_market_movement":     return await toolMarketMovement(db, input);
    case "get_portfolio":           return await toolPortfolio(db, input);
    case "get_owned_inventory":     return await toolOwnedInventory(db, input);
    case "get_high_value_owned":    return await toolHighValueOwned(db, input);
    case "tevo_search_events":      return evo ? await toolTevoSearchEvents(evo, input) : { error: "TEvo not configured" };
    case "tevo_event_detail":       return evo ? await toolTevoEventDetail(evo, input) : { error: "TEvo not configured" };
    case "tevo_event_stats":        return evo ? await toolTevoEventStats(evo, input) : { error: "TEvo not configured" };
    case "tevo_listings":           return evo ? await toolTevoListings(evo, input) : { error: "TEvo not configured" };
    case "tevo_search_performers":  return evo ? await toolTevoSearchPerformers(evo, input) : { error: "TEvo not configured" };
    case "tevo_search_venues":      return evo ? await toolTevoSearchVenues(evo, input) : { error: "TEvo not configured" };
    case "get_event_zones":         return await toolEventZones(db, input, ctx);
    default:                        return { error: `unknown tool ${name}` };
  }
}

// ---------------------------------------------------------------------------
// Anthropic tool-use loop
// ---------------------------------------------------------------------------

async function runClaudeLoop(
  apiKey: string, userMessage: string, db: any, evo: Evo | null,
  ctx: { requester: string | null; source: string },
): Promise<string> {
  const messages: any[] = [{ role: "user", content: userMessage }];
  for (let turn = 0; turn < MAX_TURNS; turn++) {
    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: BOT_MODEL,
        max_tokens: 1024,
        system: SYSTEM_PROMPT,
        tools: TOOLS,
        messages,
      }),
    });
    if (!resp.ok) {
      const text = await resp.text();
      return `bot error: anthropic ${resp.status}: ${text.slice(0, 200)}`;
    }
    const data = await resp.json();
    if (data.stop_reason === "tool_use") {
      const toolResults: any[] = [];
      for (const block of data.content ?? []) {
        if (block.type !== "tool_use") continue;
        const args = { ...(block.input ?? {}) };
        if (CONTEXT_INJECTED.has(block.name)) {
          args.requester = ctx.requester;
          args.source = ctx.source;
        }
        let result: any;
        try { result = await dispatch(block.name, args, db, evo, ctx); }
        catch (e) { result = { error: `tool error: ${(e as Error).message}` }; }
        toolResults.push({ type: "tool_result", tool_use_id: block.id, content: JSON.stringify(result) });
      }
      messages.push({ role: "assistant", content: data.content });
      messages.push({ role: "user", content: toolResults });
      continue;
    }
    const text = (data.content ?? [])
      .filter((b: any) => b.type === "text").map((b: any) => b.text).join("").trim();
    return text || "no reply";
  }
  return "loop hit max_turns; aborting";
}

// ---------------------------------------------------------------------------
// TwiML helper
// ---------------------------------------------------------------------------

function twimlReply(message: string): Response {
  const safe = (message ?? "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .slice(0, 1500);
  const body = `<?xml version="1.0" encoding="UTF-8"?><Response><Message>${safe}</Message></Response>`;
  return new Response(body, { headers: { "Content-Type": "application/xml" } });
}

// ---------------------------------------------------------------------------
// Webhook handler
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const apiKey = await resolveSecret(db, "anthropic_api_key", "ANTHROPIC_API_KEY");
  const twilioToken = await resolveSecret(db, "twilio_auth_token", "TWILIO_AUTH_TOKEN");
  if (!apiKey || !twilioToken) {
    return new Response("sms-bot not configured (missing anthropic_api_key or twilio_auth_token in settings)", { status: 503 });
  }

  // Parse Twilio's application/x-www-form-urlencoded body
  let form: FormData;
  try { form = await req.formData(); }
  catch (_) { return new Response("bad form", { status: 400 }); }
  const params: Record<string, string> = {};
  for (const [k, v] of form.entries()) params[k] = String(v);

  // Twilio sends From="whatsapp:+1..." for WhatsApp, plain "+1..." for SMS.
  // Same function handles both — just strip the prefix for whitelist lookup.
  const rawFrom = (params.From ?? "").trim();
  const isWhatsApp = rawFrom.startsWith("whatsapp:");
  const channel = isWhatsApp ? "whatsapp" : "sms";
  const fromPhone = isWhatsApp ? rawFrom.slice("whatsapp:".length) : rawFrom;
  const bodyIn = (params.Body ?? "").trim();
  const messageSid = params.MessageSid ?? null;

  // Twilio signs against the exact public URL it POSTed to. Supabase's edge
  // runtime rewrites both req.url and the Host header internally, so derive the
  // canonical public URL from the auto-injected SUPABASE_URL env var.
  const publicUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/sms-bot`;

  const sig = req.headers.get("x-twilio-signature") ?? "";
  const ok = await verifyTwilioSignature(twilioToken, publicUrl, params, sig);
  if (!ok) {
    try {
      await db.from("bot_messages").insert({
        channel, direction: "in", phone: fromPhone, body: bodyIn,
        message_sid: messageSid, meta: { reject: "bad_signature", url: publicUrl },
      });
    } catch (_) {}
    return new Response("bad signature", { status: 403 });
  }

  // Audit-log inbound regardless of whitelist outcome
  try {
    await db.from("bot_messages").insert({
      channel, direction: "in", phone: fromPhone, body: bodyIn, message_sid: messageSid,
    });
  } catch (_) {}

  // Whitelist check
  const { data: user } = await db.from("bot_users").select("phone,label,active")
    .eq("phone", fromPhone).maybeSingle();
  let reply: string;
  if (!user || !user.active) {
    reply = "not authorized — contact julian@s4kent.com";
  } else {
    // Resolve TEvo creds (optional — tevo tools degrade gracefully if missing)
    const creds = await resolveTevoCreds(db);
    const evo = creds ? new Evo(creds.token, creds.secret) : null;
    try {
      reply = await runClaudeLoop(apiKey, bodyIn, db, evo,
        { requester: fromPhone, source: channel });
    } catch (e) {
      reply = `bot error: ${(e as Error).message}`;
    }
  }

  // Audit-log outbound
  try {
    await db.from("bot_messages").insert({
      channel, direction: "out", phone: fromPhone, body: reply,
    });
  } catch (_) {}

  return twimlReply(reply);
});
