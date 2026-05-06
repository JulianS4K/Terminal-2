// Supabase Edge Function: web-bot
//
// Browser-facing chat UI for the same bot. RCS-Chat-style: no Twilio in the
// loop, no carrier filtering, replies are immediate. Same tool surface as
// sms-bot (13 tools across cached + TEvo + zones).
//
//   GET  /functions/v1/web-bot       → HTML chat page
//   POST /functions/v1/web-bot       → { requester, message } → { reply, ... }
//
// Auth: pass ?phone=+14253728504 in the URL OR enter it in the chat header;
// the requester is looked up against bot_users (whitelist). is_internal still
// gates get_event_zones.
//
// Reads ANTHROPIC_API_KEY from public.settings (with env fallback).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const TEVO_HOST = "api.ticketevolution.com";
const TEVO_BASE = `https://${TEVO_HOST}`;
const BOT_MODEL = Deno.env.get("WHATSAPP_BOT_MODEL") ?? "claude-sonnet-4-6";
const MAX_TURNS = parseInt(Deno.env.get("WHATSAPP_MAX_TURNS") ?? "6", 10);

const SYSTEM_PROMPT = `You are a terse market-intelligence assistant for S4K Entertainment, a secondary ticket broker.

User chats with you in a web UI. Reply in Bloomberg-terminal style: short, dense, numeric. Aim for ≤2 short lines.
Use abbreviations (KNX@ATL G4, $458 med, +17.7%/24h, own 32%). Plain text — no markdown, no code blocks.

You have two sets of tools:

(A) Cached metrics from our Supabase store — refreshed every 20 minutes. Cache+rate-limit gated. Richer (S4K owned share, dispersion, tail premium).
  - search_events, get_event_snapshot, get_market_movement, get_portfolio, get_owned_inventory, get_high_value_owned, get_event_zones (internal only)

(B) Live Ticket Evolution API — ANY event in TEvo's catalog. Slower, uses raw TEvo budget, does NOT update cache.
  - tevo_search_events, tevo_event_detail, tevo_event_stats, tevo_listings, tevo_search_performers, tevo_search_venues

Decision rule: prefer (A) for watchlist events (NBA playoffs, Yankees, Knicks, big NYC venues). Fall back to (B) only when (A) returns nothing OR for events we obviously don't track. Don't run both on the same event.

When listing events, include venue (short form) and date/time. Default upcoming only; the cached search_events lower bound is lexical-date-prefix so it may include events that already started today — verify occurs_at_local. For zones call get_event_zones (internal-only); 'unmapped' is a real bucket — do not invent zones.`;

async function hmacSha256Base64(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
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
    pairs.push([k, typeof v === "boolean" ? (v ? "true" : "false") : String(v)]);
  }
  pairs.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
}

class Evo {
  constructor(private token: string, private secret: string) {}
  private async get(path: string, params: Params = {}): Promise<any> {
    const query = canonicalQuery(params);
    const sig = await hmacSha256Base64(this.secret, `GET ${TEVO_HOST}${path}?${query}`);
    const r = await fetch(`${TEVO_BASE}${path}?${query}`, {
      headers: { "X-Token": this.token, "X-Signature": sig, "Accept": "application/vnd.ticketevolution.api+json; version=9" },
    });
    if (!r.ok) throw new Error(`${r.status} ${r.statusText} on ${path}`);
    return r.json();
  }
  searchEvents(p: Params) { return this.get("/v9/events", { per_page: 25, ...p }); }
  eventDetail(id: number) { return this.get(`/v9/events/${id}`); }
  eventStats(id: number, t?: string) { return this.get(`/v9/events/${id}/stats`, t ? { inventory_type: t } : {}); }
  ticketGroups(id: number) { return this.get("/v9/ticket_groups", { event_id: id }); }
  searchPerformers(q: string) { return this.get("/v9/performers", { q, per_page: 25 }); }
  searchVenues(q: string) { return this.get("/v9/venues", { q, per_page: 25 }); }
}

async function resolveTevoCreds(db: any) {
  try {
    const { data } = await db.from("settings").select("key,value").in("key", ["tevo_token", "tevo_secret"]);
    const m: Record<string, string> = {};
    for (const r of data ?? []) m[r.key] = r.value;
    if (m.tevo_token && m.tevo_secret) return { token: m.tevo_token, secret: m.tevo_secret };
  } catch (_) {}
  return null;
}

async function resolveSecret(db: any, key: string, env: string): Promise<string | null> {
  try {
    const { data } = await db.from("settings").select("value").eq("key", key).maybeSingle();
    if (data?.value) return data.value;
  } catch (_) {}
  return Deno.env.get(env) ?? null;
}

const TOOLS = [
  { name: "search_events", description: "Search tracked events. Defaults to upcoming only (lexical date-prefix lower bound). Returns id, name, occurs_at_local, venue_name, primary_performer_name.", input_schema: { type: "object", properties: { query: { type: "string" }, performer_id: { type: "integer" }, venue_id: { type: "integer" }, days_ahead: { type: "integer" }, start_at: { type: "string" }, end_at: { type: "string" }, include_past: { type: "boolean", default: false }, limit: { type: "integer", default: 10 } } } },
  { name: "get_event_snapshot", description: "Latest cached metrics for one event. Cache+rate-limit gated.", input_schema: { type: "object", required: ["event_id"], properties: { event_id: { type: "integer" } } } },
  { name: "get_market_movement", description: "Period-over-period change for one event's metrics.", input_schema: { type: "object", required: ["event_id"], properties: { event_id: { type: "integer" }, hours_back: { type: "integer", default: 24 } } } },
  { name: "get_portfolio", description: "Aggregate rollup across all events for a performer or venue.", input_schema: { type: "object", properties: { performer_id: { type: "integer" }, venue_id: { type: "integer" } } } },
  { name: "get_owned_inventory", description: "List S4K-owned ticket groups.", input_schema: { type: "object", properties: { event_id: { type: "integer" }, min_retail_price: { type: "number" }, limit: { type: "integer", default: 15 } } } },
  { name: "get_high_value_owned", description: "Top events by S4K's retail-value exposure.", input_schema: { type: "object", properties: { limit: { type: "integer", default: 10 } } } },
  { name: "tevo_search_events", description: "LIVE TEvo event search (off-watchlist fallback).", input_schema: { type: "object", properties: { query: { type: "string" }, performer_id: { type: "integer" }, venue_id: { type: "integer" }, limit: { type: "integer", default: 8 } } } },
  { name: "tevo_event_detail", description: "LIVE TEvo event metadata.", input_schema: { type: "object", required: ["event_id"], properties: { event_id: { type: "integer" } } } },
  { name: "tevo_event_stats", description: "LIVE TEvo aggregate stats.", input_schema: { type: "object", required: ["event_id"], properties: { event_id: { type: "integer" }, inventory_type: { type: "string", enum: ["event", "parking"] } } } },
  { name: "tevo_listings", description: "LIVE TEvo cheapest N listings.", input_schema: { type: "object", required: ["event_id"], properties: { event_id: { type: "integer" }, limit: { type: "integer", default: 8 } } } },
  { name: "tevo_search_performers", description: "LIVE TEvo performer search.", input_schema: { type: "object", required: ["query"], properties: { query: { type: "string" }, limit: { type: "integer", default: 5 } } } },
  { name: "tevo_search_venues", description: "LIVE TEvo venue search.", input_schema: { type: "object", required: ["query"], properties: { query: { type: "string" }, limit: { type: "integer", default: 5 } } } },
  { name: "get_event_zones", description: "INTERNAL ONLY. Curated zone breakdown. Defaults to S4K-owned only. Returns zone, tickets, min_retail, max_retail.", input_schema: { type: "object", required: ["event_id"], properties: { event_id: { type: "integer" }, owned_only: { type: "boolean", default: true } } } },
];

async function toolSearchEvents(db: any, args: any) {
  const now = new Date();
  let q = db.from("events").select("id,name,occurs_at_local,venue_name,primary_performer_name");
  const todayPrefix = now.toISOString().slice(0, 10);
  if (args.start_at) q = q.gte("occurs_at_local", args.start_at);
  else if (!args.include_past) q = q.gte("occurs_at_local", todayPrefix);
  if (args.end_at) q = q.lte("occurs_at_local", args.end_at);
  else if (args.days_ahead) {
    const cutoff = new Date(now.getTime() + (args.days_ahead + 1) * 86400000).toISOString().slice(0, 10);
    q = q.lte("occurs_at_local", cutoff);
  }
  if (args.performer_id != null) q = q.or(`primary_performer_id.eq.${args.performer_id},performer_ids.cs.{${args.performer_id}}`);
  if (args.venue_id != null) q = q.eq("venue_id", args.venue_id);
  if (args.query) q = q.ilike("name", `%${args.query}%`);
  const { data } = await q.order("occurs_at_local").limit(Math.min(args.limit ?? 10, 25));
  return { count: (data ?? []).length, events: data ?? [] };
}

async function triggerEventRefresh(eventId: number, pullId: number | null) {
  const cs = Deno.env.get("CRON_SECRET"), su = Deno.env.get("SUPABASE_URL");
  if (!cs || !su) return { ok: false, error: "CRON_SECRET or SUPABASE_URL missing" };
  let url = `${su}/functions/v1/collect-listings?event_id=${eventId}`;
  if (pullId != null) url += `&pull_id=${pullId}`;
  try {
    const r = await fetch(url, { method: "POST", headers: { "x-cron-secret": cs } });
    let body: any = null; try { body = await r.json(); } catch (_) { body = { raw: await r.text() }; }
    return { ok: r.ok, status: r.status, ...(body ?? {}) };
  } catch (e) { return { ok: false, error: String((e as Error).message) }; }
}

async function toolEventSnapshot(db: any, args: any, ctx: any) {
  const eid = Number(args.event_id);
  const { data: dec } = await db.rpc("get_or_authorize_pull", { p_event_id: eid, p_source: ctx.source, p_requester: ctx.requester, p_max_age_seconds: 300 });
  let served = (dec ?? {}).decision ?? "unknown";
  let refresh: any = null;
  if (served === "fetch_fresh") {
    refresh = await triggerEventRefresh(eid, (dec ?? {}).pull_id ?? null);
    if (!refresh.ok) served = "fresh_failed";
  }
  const { data: ev } = await db.from("events").select("id,name,occurs_at_local,venue_name,primary_performer_name").eq("id", eid).maybeSingle();
  const { data: m } = await db.from("latest_event_metrics").select("*").eq("event_id", eid).maybeSingle();
  if (!ev && !m) return { error: `event_id ${eid} not found` };
  return { event: ev ?? {}, metrics: m ?? {}, served_from: served, snapshot_age_seconds: (dec ?? {}).age_seconds, rate_limit_reason: (dec ?? {}).reason, retry_after_seconds: (dec ?? {}).retry_after_seconds, refresh_status: refresh };
}

async function toolMarketMovement(db: any, args: any) {
  const eid = Number(args.event_id), hb = Number(args.hours_back ?? 24);
  const since = new Date(Date.now() - hb * 3600000).toISOString();
  const { data } = await db.from("event_metrics").select("captured_at,tickets_count,groups_count,retail_min,retail_p25,retail_median,retail_p75,retail_p90,retail_max,getin_price,owned_tickets_count,owned_share").eq("event_id", eid).gte("captured_at", since).order("captured_at");
  const rows = data ?? [];
  if (rows.length < 2) return { event_id: eid, hours_back: hb, points: rows.length, note: "not enough history in window" };
  const o = rows[0], n = rows[rows.length - 1];
  const keys = ["tickets_count","retail_min","retail_p25","retail_median","retail_p75","retail_p90","retail_max","getin_price","owned_tickets_count"];
  const deltas: any = {};
  for (const k of keys) {
    if (o[k] == null || n[k] == null) continue;
    const oF = Number(o[k]), nF = Number(n[k]);
    const pct = oF !== 0 ? ((nF - oF) / oF) * 100 : null;
    deltas[k] = { open: o[k], now: n[k], delta: Math.round((nF - oF) * 100) / 100, pct: pct == null ? null : Math.round(pct * 100) / 100 };
  }
  return { event_id: eid, hours_back: hb, points: rows.length, open_at: o.captured_at, now_at: n.captured_at, movement: deltas };
}

async function toolPortfolio(db: any, args: any) {
  if (args.performer_id == null && args.venue_id == null) return { error: "provide performer_id or venue_id" };
  let evQ = db.from("events").select("id");
  if (args.performer_id != null) evQ = evQ.or(`primary_performer_id.eq.${args.performer_id},performer_ids.cs.{${args.performer_id}}`);
  else evQ = evQ.eq("venue_id", args.venue_id);
  const { data: evs } = await evQ;
  const ids = (evs ?? []).map((r: any) => r.id);
  if (!ids.length) return { events_count: 0, tickets_total: 0, owned_tickets_total: 0, retail_value_total: 0 };
  const { data: m } = await db.from("latest_event_metrics").select("event_id,tickets_count,owned_tickets_count,retail_sum,retail_median,owned_median_retail").in("event_id", ids);
  const arr = m ?? [];
  const tickets = arr.reduce((s: number, r: any) => s + (r.tickets_count ?? 0), 0);
  const owned = arr.reduce((s: number, r: any) => s + (r.owned_tickets_count ?? 0), 0);
  const retail = arr.reduce((s: number, r: any) => s + Number(r.retail_sum ?? 0), 0);
  const ov = arr.reduce((s: number, r: any) => s + (r.owned_tickets_count ?? 0) * Number(r.owned_median_retail ?? 0), 0);
  return { events_count: arr.length, tickets_total: tickets, owned_tickets_total: owned, owned_share_pct: tickets ? Math.round((owned / tickets) * 10000) / 100 : null, retail_value_total: Math.round(retail * 100) / 100, owned_retail_value_total: Math.round(ov * 100) / 100, events_with_owned: arr.filter((r: any) => (r.owned_tickets_count ?? 0) > 0).length };
}

async function toolOwnedInventory(db: any, args: any) {
  let q = db.from("listings_snapshots").select("event_id,section,row,quantity,retail_price,office_name,captured_at").eq("is_owned", true).order("captured_at", { ascending: false });
  if (args.event_id != null) q = q.eq("event_id", args.event_id);
  if (args.min_retail_price != null) q = q.gte("retail_price", args.min_retail_price);
  const { data } = await q.limit(Math.min(args.limit ?? 15, 50));
  return { count: (data ?? []).length, rows: data ?? [] };
}

async function toolHighValueOwned(db: any, args: any) {
  const { data: m } = await db.from("latest_event_metrics").select("event_id,owned_tickets_count,owned_median_retail,owned_share").gt("owned_tickets_count", 0);
  const arr = m ?? [];
  if (!arr.length) return { count: 0, rows: [] };
  for (const r of arr) r.owned_value = Number(r.owned_tickets_count ?? 0) * Number(r.owned_median_retail ?? 0);
  arr.sort((a: any, b: any) => b.owned_value - a.owned_value);
  const top = arr.slice(0, args.limit ?? 10);
  const ids = top.map((r: any) => r.event_id);
  const { data: evs } = await db.from("events").select("id,name,occurs_at_local,venue_name").in("id", ids);
  const map = Object.fromEntries((evs ?? []).map((e: any) => [e.id, e]));
  return { count: top.length, rows: top.map((r: any) => ({ event_id: r.event_id, name: map[r.event_id]?.name, occurs_at_local: map[r.event_id]?.occurs_at_local, venue: map[r.event_id]?.venue_name, owned_tickets: r.owned_tickets_count, owned_median: r.owned_median_retail, owned_share: r.owned_share, exposure_usd: Math.round(r.owned_value * 100) / 100 })) };
}

async function toolTevoSearchEvents(evo: Evo, args: any) {
  try {
    const p: Params = { only_with_available_tickets: true };
    if (args.query) p.q = args.query;
    if (args.performer_id) p.performer_id = args.performer_id;
    if (args.venue_id) p.venue_id = args.venue_id;
    const r = await evo.searchEvents(p);
    const events = (r.events ?? []).slice(0, args.limit ?? 8);
    return { count: events.length, events: events.map((e: any) => ({ id: e.id, name: e.name, occurs_at_local: e.occurs_at_local, venue: e.venue?.name, performer: e.performances?.find((x: any) => x.primary)?.performer?.name })) };
  } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolTevoEventDetail(evo: Evo, args: any) {
  try { const r = await evo.eventDetail(args.event_id); return { id: r.id, name: r.name, occurs_at_local: r.occurs_at_local, venue: r.venue, performances: r.performances }; } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolTevoEventStats(evo: Evo, args: any) {
  try { return await evo.eventStats(args.event_id, args.inventory_type); } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolTevoListings(evo: Evo, args: any) {
  try {
    const r = await evo.ticketGroups(args.event_id);
    const groups = (r.ticket_groups ?? []).filter((g: any) => g.retail_price != null).sort((a: any, b: any) => Number(a.retail_price) - Number(b.retail_price)).slice(0, args.limit ?? 8);
    return { count: groups.length, listings: groups.map((g: any) => ({ section: g.section, row: g.row, quantity: g.available_quantity, retail_price: g.retail_price, format: g.format })) };
  } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolTevoSearchPerformers(evo: Evo, args: any) {
  try { const r = await evo.searchPerformers(args.query); return { count: (r.performers ?? []).slice(0, args.limit ?? 5).length, performers: (r.performers ?? []).slice(0, args.limit ?? 5).map((p: any) => ({ id: p.id, name: p.name, category: p.category?.name })) }; } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolTevoSearchVenues(evo: Evo, args: any) {
  try { const r = await evo.searchVenues(args.query); const items = (r.venues ?? []).slice(0, args.limit ?? 5); return { count: items.length, venues: items.map((v: any) => ({ id: v.id, name: v.name, city: v.address?.locality, state: v.address?.region, country: v.address?.country_code })) }; } catch (e) { return { error: String((e as Error).message) }; }
}

async function toolEventZones(db: any, args: any, ctx: any) {
  if (!ctx.requester) return { error: "internal data requires an authenticated requester" };
  const { data: user } = await db.from("bot_users").select("is_internal,active").eq("phone", ctx.requester).maybeSingle();
  if (!user || !user.is_internal) return { error: "not authorized — zone data is internal only" };
  const eid = Number(args.event_id);
  const { data: dec } = await db.rpc("get_or_authorize_pull", { p_event_id: eid, p_source: ctx.source, p_requester: ctx.requester, p_max_age_seconds: 300 });
  if ((dec ?? {}).decision === "fetch_fresh") await triggerEventRefresh(eid, (dec ?? {}).pull_id ?? null);
  const { data: rollup } = await db.rpc("get_event_zones_rollup", { p_event_id: eid, p_owned_only: args.owned_only !== false });
  return { event_id: eid, owned_only: args.owned_only !== false, snapshot_age_seconds: (dec ?? {}).age_seconds, served_from: (dec ?? {}).decision, zones: rollup ?? [] };
}

const CONTEXT_INJECTED = new Set(["get_event_snapshot", "get_event_zones"]);

async function dispatch(name: string, input: any, db: any, evo: Evo | null, ctx: any) {
  switch (name) {
    case "search_events": return await toolSearchEvents(db, input);
    case "get_event_snapshot": return await toolEventSnapshot(db, input, ctx);
    case "get_market_movement": return await toolMarketMovement(db, input);
    case "get_portfolio": return await toolPortfolio(db, input);
    case "get_owned_inventory": return await toolOwnedInventory(db, input);
    case "get_high_value_owned": return await toolHighValueOwned(db, input);
    case "tevo_search_events": return evo ? await toolTevoSearchEvents(evo, input) : { error: "TEvo not configured" };
    case "tevo_event_detail": return evo ? await toolTevoEventDetail(evo, input) : { error: "TEvo not configured" };
    case "tevo_event_stats": return evo ? await toolTevoEventStats(evo, input) : { error: "TEvo not configured" };
    case "tevo_listings": return evo ? await toolTevoListings(evo, input) : { error: "TEvo not configured" };
    case "tevo_search_performers": return evo ? await toolTevoSearchPerformers(evo, input) : { error: "TEvo not configured" };
    case "tevo_search_venues": return evo ? await toolTevoSearchVenues(evo, input) : { error: "TEvo not configured" };
    case "get_event_zones": return await toolEventZones(db, input, ctx);
    default: return { error: `unknown tool ${name}` };
  }
}

async function runClaudeLoop(apiKey: string, history: any[], db: any, evo: Evo | null, ctx: any): Promise<{ reply: string; trace: any[] }> {
  const messages = [...history];
  const trace: any[] = [];
  for (let turn = 0; turn < MAX_TURNS; turn++) {
    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: BOT_MODEL, max_tokens: 1024, system: SYSTEM_PROMPT, tools: TOOLS, messages }),
    });
    if (!resp.ok) {
      const text = await resp.text();
      return { reply: `bot error: anthropic ${resp.status}: ${text.slice(0, 200)}`, trace };
    }
    const data = await resp.json();
    if (data.stop_reason === "tool_use") {
      const tr: any[] = [];
      for (const block of data.content ?? []) {
        if (block.type !== "tool_use") continue;
        const args = { ...(block.input ?? {}) };
        if (CONTEXT_INJECTED.has(block.name)) { args.requester = ctx.requester; args.source = ctx.source; }
        let result: any;
        try { result = await dispatch(block.name, args, db, evo, ctx); } catch (e) { result = { error: `tool error: ${(e as Error).message}` }; }
        trace.push({ tool: block.name, input: block.input, result });
        tr.push({ type: "tool_result", tool_use_id: block.id, content: JSON.stringify(result) });
      }
      messages.push({ role: "assistant", content: data.content });
      messages.push({ role: "user", content: tr });
      continue;
    }
    const text = (data.content ?? []).filter((b: any) => b.type === "text").map((b: any) => b.text).join("").trim();
    return { reply: text || "no reply", trace };
  }
  return { reply: "loop hit max_turns; aborting", trace };
}

const CHAT_HTML = `<!doctype html>
<html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>Terminal Bot</title>
<style>
:root{--bg:#0c0e10;--fg:#d4d4d4;--accent:#ff8c00;--in:#1c1f24;--out:#0f2533;--muted:#7a8088;--err:#ff5c5c}
*{box-sizing:border-box}
html,body{margin:0;padding:0;height:100%;background:var(--bg);color:var(--fg);font:14px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace}
.wrap{max-width:780px;margin:0 auto;height:100vh;display:flex;flex-direction:column}
header{padding:14px 18px;border-bottom:1px solid #1f2329;display:flex;align-items:center;gap:12px;flex-wrap:wrap}
header .title{font-weight:600;color:var(--accent);letter-spacing:.5px}
header input{background:#15181d;color:var(--fg);border:1px solid #262a31;border-radius:6px;padding:6px 10px;font:inherit;width:170px}
header .label{color:var(--muted);font-size:12px}
#log{flex:1;overflow-y:auto;padding:18px}
.bubble{max-width:80%;padding:10px 13px;border-radius:14px;margin:6px 0;white-space:pre-wrap;word-wrap:break-word}
.in{background:var(--in);align-self:flex-start;border-bottom-left-radius:4px}
.out{background:var(--out);margin-left:auto;border-bottom-right-radius:4px;color:#cfe7ff}
.err{background:#3a1e1e;color:var(--err)}
.row{display:flex}
.meta{color:var(--muted);font-size:11px;margin:2px 4px}
form{display:flex;gap:8px;padding:12px 14px;border-top:1px solid #1f2329;background:var(--bg)}
form input[type=text]{flex:1;background:#15181d;color:var(--fg);border:1px solid #262a31;border-radius:18px;padding:10px 14px;font:inherit;outline:none}
form input[type=text]:focus{border-color:var(--accent)}
form button{background:var(--accent);color:#0c0e10;border:0;border-radius:18px;padding:0 18px;font-weight:600;cursor:pointer}
form button:disabled{opacity:.4;cursor:default}
.thinking{color:var(--muted);font-style:italic;padding:8px 13px}
.trace{font-size:11px;color:var(--muted);margin:2px 4px 8px;padding-left:13px}
.trace summary{cursor:pointer;list-style:none}
.trace summary::-webkit-details-marker{display:none}
.trace summary:before{content:"\\25B8\\00a0";font-size:10px}
.trace[open] summary:before{content:"\\25BE\\00a0"}
.trace pre{margin:6px 0;padding:6px 8px;background:#15181d;border-radius:4px;overflow-x:auto;font-size:11px}
</style></head><body>
<div class="wrap">
  <header>
    <span class="title">▌ TERMINAL-2 BOT</span>
    <span class="label">requester</span>
    <input id="who" type="text" placeholder="+14253728504"/>
    <span class="label" id="status"></span>
  </header>
  <div id="log"></div>
  <form id="f">
    <input id="msg" type="text" placeholder="ask anything — try: knicks tonight" autocomplete="off" autofocus/>
    <button>send</button>
  </form>
</div>
<script>
const url = new URL(location.href);
const log = document.getElementById('log');
const who = document.getElementById('who');
const f = document.getElementById('f');
const msg = document.getElementById('msg');
const status = document.getElementById('status');
who.value = url.searchParams.get('phone') || localStorage.getItem('webbot.phone') || '+14253728504';
who.addEventListener('change', () => localStorage.setItem('webbot.phone', who.value));

function bubble(text, cls, trace) {
  const row = document.createElement('div');
  row.className = 'row';
  const b = document.createElement('div');
  b.className = 'bubble ' + cls;
  b.textContent = text;
  row.appendChild(b);
  if (cls === 'out') row.style.justifyContent = 'flex-end';
  log.appendChild(row);
  if (trace && trace.length) {
    const det = document.createElement('details');
    det.className = 'trace';
    const sum = document.createElement('summary');
    sum.textContent = trace.length + ' tool call' + (trace.length === 1 ? '' : 's');
    det.appendChild(sum);
    const pre = document.createElement('pre');
    pre.textContent = JSON.stringify(trace, null, 2);
    det.appendChild(pre);
    log.appendChild(det);
  }
  log.scrollTop = log.scrollHeight;
}

let history = [];
let busy = false;

f.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  if (busy) return;
  const text = msg.value.trim();
  if (!text) return;
  msg.value = '';
  busy = true;
  bubble(text, 'in');
  history.push({ role: 'user', content: text });
  const thinking = document.createElement('div');
  thinking.className = 'thinking';
  thinking.textContent = 'thinking…';
  log.appendChild(thinking);
  log.scrollTop = log.scrollHeight;
  status.textContent = 'querying…';
  try {
    const r = await fetch(location.pathname, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ requester: who.value.trim(), history }),
    });
    thinking.remove();
    const data = await r.json();
    if (!r.ok || data.error) {
      bubble(data.error || ('http ' + r.status), 'out err');
    } else {
      bubble(data.reply, 'out', data.trace);
      history.push({ role: 'assistant', content: data.reply });
    }
  } catch (e) {
    thinking.remove();
    bubble('network error: ' + e.message, 'out err');
  } finally {
    busy = false;
    status.textContent = '';
    msg.focus();
  }
});
</script>
</body></html>`;

function jsonResponse(obj: any, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });
}

Deno.serve(async (req) => {
  const method = req.method.toUpperCase();
  if (method === "GET") {
    return new Response(CHAT_HTML, { headers: { "content-type": "text/html; charset=utf-8" } });
  }
  if (method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const apiKey = await resolveSecret(db, "anthropic_api_key", "ANTHROPIC_API_KEY");
  if (!apiKey) return jsonResponse({ error: "anthropic_api_key not in settings" }, 503);

  let body: any = null;
  try { body = await req.json(); } catch (_) { return jsonResponse({ error: "expected JSON body" }, 400); }
  const requester = (body?.requester ?? "").trim() || null;
  const history = Array.isArray(body?.history) ? body.history : (body?.message ? [{ role: "user", content: body.message }] : []);
  if (!history.length) return jsonResponse({ error: "history or message required" }, 400);

  // Whitelist gate (still applies — same bot_users table as SMS)
  let userOk = false;
  if (requester) {
    const { data: u } = await db.from("bot_users").select("active").eq("phone", requester).maybeSingle();
    userOk = !!(u && u.active);
  }
  // Audit-log inbound
  const last = history[history.length - 1];
  const lastText = typeof last?.content === "string" ? last.content : "";
  try {
    await db.from("bot_messages").insert({ channel: "web", direction: "in", phone: requester ?? "anon", body: lastText });
  } catch (_) {}
  if (!userOk) {
    const reply = "not authorized — set requester to a whitelisted phone (e.g. +14253728504)";
    try { await db.from("bot_messages").insert({ channel: "web", direction: "out", phone: requester ?? "anon", body: reply }); } catch (_) {}
    return jsonResponse({ reply, trace: [] });
  }

  const creds = await resolveTevoCreds(db);
  const evo = creds ? new Evo(creds.token, creds.secret) : null;
  let result: { reply: string; trace: any[] };
  try {
    result = await runClaudeLoop(apiKey, history, db, evo, { requester, source: "web" });
  } catch (e) {
    result = { reply: `bot error: ${(e as Error).message}`, trace: [] };
  }
  try {
    await db.from("bot_messages").insert({ channel: "web", direction: "out", phone: requester, body: result.reply });
  } catch (_) {}
  return jsonResponse(result);
});
